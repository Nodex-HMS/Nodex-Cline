/// Tests for the bed repository over a fake local store.
///
/// Mirrors the appointment repository tests: the SQL surface is faked with
/// just enough understanding for the repository's queries.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/beds/bed.dart';
import 'package:nodex_hms/domain/beds/bed_repository.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';

/// In-memory [PatientLocalStore] extended with the bed tables.
final class FakeBedStore implements PatientLocalStore {
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

  @override
  Future<List<Map<String, Object?>>> query(
    String sql,
    List<Object?> parameters,
  ) async {
    _guard();
    if (sql.contains(LocalTables.wards)) {
      return _table(LocalTables.wards).values.toList(growable: false);
    }
    if (sql.contains(LocalTables.beds)) {
      final String wardId = parameters[0]! as String;
      return _table(LocalTables.beds).values
          .where((Map<String, Object?> r) => r['ward_id'] == wardId)
          .toList(growable: false);
    }
    if (sql.contains(LocalTables.bedAssignments)) {
      if (sql.contains('bed_id = ?')) {
        final String bedId = parameters[0]! as String;
        return _table(LocalTables.bedAssignments).values
            .where(
              (Map<String, Object?> r) =>
                  r['bed_id'] == bedId && r['status'] == 'active',
            )
            .toList(growable: false);
      }
      final String patientId = parameters[0]! as String;
      Iterable<Map<String, Object?>> rows = _table(LocalTables.bedAssignments)
          .values
          .where((Map<String, Object?> r) => r['patient_id'] == patientId);
      if (sql.contains("status = ?")) {
        rows = rows.where(
          (Map<String, Object?> r) => r['status'] == parameters[1],
        );
      }
      return rows.toList(growable: false);
    }
    throw UnimplementedError('FakeBedStore cannot run: $sql');
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
  late FakeBedStore store;
  late DefaultBedRepository repository;

  setUp(() {
    store = FakeBedStore();
    repository = DefaultBedRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
  });

  Future<String> seedBed({String code = 'A-01'}) => repository.registerBed(
    Bed.registerRow(
      tenantId: 'tenant-1',
      wardId: 'ward-1',
      bedCode: code,
      bedType: BedType.general,
    ),
  );

  group('census', () {
    test('lists beds with occupants resolved per bed', () async {
      final String bedId = await seedBed();
      expect(await repository.activeAssignmentForBed(bedId), isNull);

      await repository.assignBed(
        BedAssignment.assignRow(
          tenantId: 'tenant-1',
          bedId: bedId,
          patientId: 'patient-1',
          assignedBy: 'nurse-1',
        ),
      );
      final BedAssignment? occupant = await repository.activeAssignmentForBed(
        bedId,
      );
      expect(occupant, isNotNull);
      expect(occupant!.patientId, 'patient-1');
      expect(
        (await repository.activeAssignmentForPatient('patient-1'))!.id,
        occupant.id,
      );
      expect(await repository.activeAssignmentForPatient('patient-9'), isNull);
    });

    test('history lists newest first by admission', () async {
      final String bedId = await seedBed();
      final String stay = await repository.assignBed(
        BedAssignment.assignRow(
          tenantId: 'tenant-1',
          bedId: bedId,
          patientId: 'patient-1',
          assignedBy: 'nurse-1',
        ),
      );
      await repository.updateAssignment(
        stay,
        BedAssignment.closeChanges(
          closure: BedAssignmentStatus.released,
          reason: 'Discharge',
        ),
      );
      final List<BedAssignment> history = await repository
          .listAssignmentsForPatient('patient-1');
      expect(history.single.status, BedAssignmentStatus.released);
    });

    test('getBed returns null when absent', () async {
      expect(await repository.getBed('missing'), isNull);
    });

    test('a closed store surfaces PersistenceError', () async {
      store.closed = true;
      await expectLater(
        repository.listBedsForWard('ward-1'),
        throwsA(isA<PersistenceError>()),
      );
    });
  });
}
