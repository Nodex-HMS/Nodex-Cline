/// Tests for the inventory repository over a fake local store.
///
/// Mirrors the discharge repository tests: the SQL surface is faked with just
/// enough understanding for the repository's queries. Two behaviours here are
/// regression guards for defects found after the module was pushed:
/// `StockItem.fromRow` must read the local 0/1 boolean shape as well as the
/// server's JSON booleans, and `listBatchesAtLocation` must not filter on a
/// `stock_batches.batch_id` column that does not exist.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/inventory/inventory.dart';
import 'package:nodex_hms/domain/inventory/inventory_repository.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';

/// In-memory [PatientLocalStore] extended with the four stock tables.
final class FakeInventoryStore implements PatientLocalStore {
  final Map<String, Map<String, Map<String, Object?>>> tables =
      <String, Map<String, Map<String, Object?>>>{};

  /// When true, every operation throws to simulate a closed database.
  bool closed = false;

  Map<String, Map<String, Object?>> _table(String name) =>
      tables.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  void _guard() {
    if (closed) {
      throw const PersistenceError(
        message: 'The local clinical database has not been opened.',
        code: 'database_not_open',
      );
    }
  }

  List<Map<String, Object?>> _matching(
    String table,
    bool Function(Map<String, Object?> row) test,
    int Function(Map<String, Object?> a, Map<String, Object?> b) compare,
  ) => _table(table).values.where(test).toList()..sort(compare);

  static int _descending(Object? a, Object? b) =>
      (b! as String).compareTo(a! as String);

  @override
  Future<List<Map<String, Object?>>> query(
    String sql,
    List<Object?> parameters,
  ) async {
    _guard();

    final bool byLocation = sql.contains(
      'FROM ${LocalTables.stockMovements} WHERE to_location_id',
    );

    // Checked before stock_batches: this query mentions both tables, and the
    // location is expressed through the movement ledger.
    if (byLocation) {
      final String locationId = parameters[0]! as String;
      final Set<String> itemIds = _table(LocalTables.stockMovements).values
          .where(
            (Map<String, Object?> m) =>
                m['to_location_id'] == locationId ||
                m['from_location_id'] == locationId,
          )
          .map((Map<String, Object?> m) => m['item_id']! as String)
          .toSet();
      final Set<String> statuses = <String>{
        parameters[2]! as String,
        parameters[3]! as String,
      };
      return _matching(
        LocalTables.stockBatches,
        (Map<String, Object?> r) =>
            itemIds.contains(r['item_id']) &&
            statuses.contains(r['status'] as String?),
        (Map<String, Object?> a, Map<String, Object?> b) =>
            _descending(a['received_at'], b['received_at']),
      );
    }
    if (sql.contains(LocalTables.stockMovements)) {
      final String itemId = parameters[0]! as String;
      return _matching(
        LocalTables.stockMovements,
        (Map<String, Object?> r) => r['item_id'] == itemId,
        (Map<String, Object?> a, Map<String, Object?> b) =>
            _descending(a['recorded_at'], b['recorded_at']),
      );
    }
    if (sql.contains(LocalTables.stockBatches)) {
      final String itemId = parameters[0]! as String;
      final bool activeOnly = sql.contains('status IN');
      final Set<String> statuses = activeOnly
          ? <String>{parameters[1]! as String, parameters[2]! as String}
          : <String>{};
      return _matching(
        LocalTables.stockBatches,
        (Map<String, Object?> r) =>
            r['item_id'] == itemId &&
            (!activeOnly || statuses.contains(r['status'] as String?)),
        (Map<String, Object?> a, Map<String, Object?> b) =>
            _descending(a['received_at'], b['received_at']),
      );
    }
    if (sql.contains(LocalTables.stockItems)) {
      final bool byStatus = sql.contains('status = ?');
      final String? status = byStatus ? parameters[0]! as String : null;
      return _matching(
        LocalTables.stockItems,
        (Map<String, Object?> r) => !byStatus || r['status'] == status,
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (a['item_code']! as String).compareTo(b['item_code']! as String),
      );
    }
    throw UnimplementedError('FakeInventoryStore cannot run: $sql');
  }

  @override
  Future<Map<String, Object?>?> getById(String table, String id) async {
    _guard();
    return _table(table)[id];
  }

  @override
  Future<void> insert(String table, Map<String, Object?> row) async {
    _guard();
    _table(table)[row['id']! as String] = Map<String, Object?>.from(row);
  }

  @override
  Future<void> update(
    String table,
    String id,
    Map<String, Object?> changes,
  ) async {
    _guard();
    final Map<String, Object?>? existing = _table(table)[id];
    if (existing == null) {
      throw StateError('row $id not found in $table');
    }
    _table(table)[id] = <String, Object?>{...existing, ...changes};
  }
}

void main() {
  late FakeInventoryStore store;
  late DefaultInventoryRepository repository;

  setUp(() {
    store = FakeInventoryStore();
    repository = DefaultInventoryRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
  });

  Future<String> seedItem({
    String itemCode = 'GEN-001',
    bool requiresBatch = true,
  }) => repository.registerItem(
    StockItem.registerRow(
      tenantId: 'tenant-1',
      itemCode: itemCode,
      name: 'Paracetamol 500mg',
      category: 'analgesic',
      unit: 'tablet',
      requiresBatch: requiresBatch,
      createdBy: 'pharmacist-1',
    ),
  );

  group('items', () {
    test('registers an item that lists by code', () async {
      final String id = await seedItem();
      final List<StockItem> items = await repository.listItems();

      expect(items.map((StockItem i) => i.id), contains(id));
      expect(items.single.itemCode, 'GEN-001');
      expect(items.single.status, StockItemStatus.active);
      expect(items.single.requiresBatch, isTrue);
    });

    test('a status filter narrows the list', () async {
      await seedItem();
      expect(await repository.listItems(status: 'discontinued'), isEmpty);
      expect(await repository.listItems(status: 'active'), hasLength(1));
    });

    test('getItem returns null when absent', () async {
      expect(await repository.getItem('missing'), isNull);
    });

    test('reads the local 0/1 boolean shape as well as JSON booleans', () {
      // The SQLite projection holds integers for booleans while PostgREST sends
      // JSON booleans. A plain `as bool?` cast worked online and threw on the
      // device, which is exactly the failure a server-side test cannot see.
      final StockItem local = StockItem.fromRow(<String, Object?>{
        'id': 'item-1',
        'tenant_id': 'tenant-1',
        'item_code': 'GEN-002',
        'name': 'Amoxicillin 250mg',
        'category': 'antibiotic',
        'unit': 'capsule',
        'status': 'active',
        'created_at': '2026-09-01T00:00:00.000Z',
        'requires_batch': 1,
        'requires_expiry': 0,
      });

      expect(local.requiresBatch, isTrue);
      expect(local.requiresExpiry, isFalse);

      final StockItem server = StockItem.fromRow(<String, Object?>{
        'id': 'item-2',
        'tenant_id': 'tenant-1',
        'item_code': 'GEN-003',
        'name': 'Salbutamol inhaler',
        'category': 'respiratory',
        'unit': 'unit',
        'status': 'active',
        'created_at': '2026-09-01T00:00:00.000Z',
        'requires_batch': false,
        'requires_expiry': true,
      });

      expect(server.requiresBatch, isFalse);
      expect(server.requiresExpiry, isTrue);
    });

    test('a missing flag stays null rather than defaulting to false', () {
      final StockItem item = StockItem.fromRow(<String, Object?>{
        'id': 'item-4',
        'tenant_id': 'tenant-1',
        'item_code': 'GEN-004',
        'name': 'Gauze roll',
        'category': 'consumable',
        'unit': 'roll',
        'status': 'active',
        'created_at': '2026-09-01T00:00:00.000Z',
      });

      expect(item.requiresBatch, isNull);
      expect(item.requiresExpiry, isNull);
    });

    test('a non-boolean flag is a named error, not a cast failure', () {
      expect(
        () => StockItem.fromRow(<String, Object?>{
          'id': 'item-5',
          'tenant_id': 'tenant-1',
          'item_code': 'GEN-005',
          'name': 'Broken row',
          'category': 'consumable',
          'unit': 'roll',
          'status': 'active',
          'created_at': '2026-09-01T00:00:00.000Z',
          'requires_batch': <String>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a status transition is persisted in place', () async {
      final String id = await seedItem();
      await repository.updateItem(
        id,
        StockItem.statusChanges(status: StockItemStatus.discontinued),
      );

      expect(
        (await repository.getItem(id))!.status,
        StockItemStatus.discontinued,
      );
    });
  });

  group('batches', () {
    Future<String> seedBatch(
      String itemId, {
      String batchNumber = 'B-001',
      int quantityMinor = 1000,
    }) => repository.registerBatch(
      StockBatch.eventRow(
        tenantId: 'tenant-1',
        itemId: itemId,
        batchNumber: batchNumber,
        quantityMinor: quantityMinor,
      ),
    );

    test('a batch lists under its item', () async {
      final String itemId = await seedItem();
      final String batchId = await seedBatch(itemId);

      final List<StockBatch> batches = await repository.listBatches(itemId);
      expect(batches.single.id, batchId);
      expect(batches.single.batchNumber, 'B-001');
      expect(batches.single.quantityMinor, 1000);
      expect(batches.single.status, BatchStatus.available);
    });

    test('batches of another item are not returned', () async {
      final String itemId = await seedItem();
      await seedBatch(itemId);
      expect(await repository.listBatches('other-item'), isEmpty);
    });

    test('active batches exclude consumed stock', () async {
      final String itemId = await seedItem();
      await seedBatch(itemId, batchNumber: 'B-001');
      final String consumed = await seedBatch(itemId, batchNumber: 'B-002');
      await repository.updateBatch(consumed, <String, Object?>{
        'status': BatchStatus.consumed.wireValue,
      });

      expect(await repository.listActiveBatches(itemId), hasLength(1));
      expect(await repository.listBatches(itemId), hasLength(2));
    });
  });

  group('movements', () {
    test(
      'records an issue against an item and reads it back newest first',
      () async {
        final String itemId = await seedItem();
        await repository.recordMovement(
          StockMovement.eventRow(
            tenantId: 'tenant-1',
            itemId: itemId,
            movementType: MovementType.receipt,
            quantityMinor: 500,
            recordedBy: 'pharmacist-1',
            toLocationId: 'loc-1',
          ),
        );
        await repository.recordMovement(
          StockMovement.eventRow(
            tenantId: 'tenant-1',
            itemId: itemId,
            movementType: MovementType.issue,
            quantityMinor: 20,
            recordedBy: 'nurse-1',
            fromLocationId: 'loc-1',
            reason: 'Ward request',
          ),
        );

        final List<StockMovement> movements = await repository.listMovements(
          itemId,
        );
        expect(movements, hasLength(2));
        expect(
          movements.map((StockMovement m) => m.movementType),
          containsAll(<MovementType>[MovementType.receipt, MovementType.issue]),
        );
        expect(
          movements.first.recordedAt.isBefore(movements.last.recordedAt),
          isFalse,
        );
      },
    );

    test('a zero-quantity movement is refused before it reaches the store', () {
      expect(
        () => StockMovement.eventRow(
          tenantId: 'tenant-1',
          itemId: 'item-1',
          movementType: MovementType.adjustment,
          quantityMinor: 0,
          recordedBy: 'pharmacist-1',
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('batches at a location', () {
    test(
      'returns issuable batches of items the ledger links to the location',
      () async {
        final String moved = await seedItem(itemCode: 'GEN-010');
        final String unmoved = await seedItem(itemCode: 'GEN-011');
        final String movedBatch = await repository.registerBatch(
          StockBatch.eventRow(
            tenantId: 'tenant-1',
            itemId: moved,
            batchNumber: 'B-100',
            quantityMinor: 100,
          ),
        );
        await repository.registerBatch(
          StockBatch.eventRow(
            tenantId: 'tenant-1',
            itemId: unmoved,
            batchNumber: 'B-200',
            quantityMinor: 100,
          ),
        );
        await repository.recordMovement(
          StockMovement.eventRow(
            tenantId: 'tenant-1',
            itemId: moved,
            movementType: MovementType.transfer,
            quantityMinor: 100,
            recordedBy: 'pharmacist-1',
            toLocationId: 'loc-1',
          ),
        );

        final List<StockBatch> batches = await repository.listBatchesAtLocation(
          'loc-1',
        );
        expect(batches.map((StockBatch b) => b.id), <String>[movedBatch]);
      },
    );

    test('a location with no ledger entries returns nothing', () async {
      final String itemId = await seedItem();
      await repository.registerBatch(
        StockBatch.eventRow(
          tenantId: 'tenant-1',
          itemId: itemId,
          batchNumber: 'B-300',
          quantityMinor: 100,
        ),
      );

      expect(await repository.listBatchesAtLocation('loc-empty'), isEmpty);
    });
  });

  group('failures', () {
    test('a closed store surfaces PersistenceError on read', () async {
      store.closed = true;
      await expectLater(
        repository.listItems(),
        throwsA(isA<PersistenceError>()),
      );
    });

    test('a closed store surfaces PersistenceError on write', () async {
      store.closed = true;
      await expectLater(seedItem(), throwsA(isA<PersistenceError>()));
    });
  });
}
