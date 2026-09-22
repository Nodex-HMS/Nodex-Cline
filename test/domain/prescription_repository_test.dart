/// Tests for the prescription repository over a fake local store.
///
/// Mirrors the encounter repository tests: the SQL surface is faked with just
/// enough understanding for the repository's queries, so query construction,
/// mapping and error surfacing are pinned without native SQLite.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:nodex_hms/domain/prescriptions/prescription_repository.dart';

/// In-memory [PatientLocalStore] extended with the prescription tables.
final class FakePrescriptionStore implements PatientLocalStore {
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
    if (sql.contains(LocalTables.prescriptionItems)) {
      final String prescriptionId = parameters[0]! as String;
      return _table(LocalTables.prescriptionItems).values
          .where(
            (Map<String, Object?> r) => r['prescription_id'] == prescriptionId,
          )
          .toList(growable: false);
    }
    if (sql.contains(LocalTables.pharmacyDispenses)) {
      final String itemId = parameters[0]! as String;
      return _table(LocalTables.pharmacyDispenses).values
          .where((Map<String, Object?> r) => r['item_id'] == itemId)
          .toList(growable: false);
    }
    if (sql.contains(LocalTables.medicationAdministrations)) {
      final String itemId = parameters[0]! as String;
      return _table(LocalTables.medicationAdministrations).values
          .where((Map<String, Object?> r) => r['item_id'] == itemId)
          .toList(growable: false);
    }
    if (sql.contains(LocalTables.prescriptions)) {
      if (sql.contains('prescription_code = ?')) {
        final String code = parameters[0]! as String;
        return _table(LocalTables.prescriptions).values
            .where((Map<String, Object?> r) => r['prescription_code'] == code)
            .toList(growable: false);
      }
      final String patientId = parameters[0]! as String;
      return _table(LocalTables.prescriptions).values
          .where((Map<String, Object?> r) => r['patient_id'] == patientId)
          .toList(growable: false);
    }
    throw UnimplementedError('FakePrescriptionStore cannot run: $sql');
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
  late FakePrescriptionStore store;
  late DefaultPrescriptionRepository repository;

  setUp(() {
    store = FakePrescriptionStore();
    repository = DefaultPrescriptionRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
  });

  Future<String> seedDraft() => repository.createPrescription(
    Prescription.draftRow(
      tenantId: 'tenant-1',
      patientId: 'patient-1',
      prescribedBy: 'doctor-1',
      prescriptionCode: 'RX-001',
      priority: PrescriptionPriority.routine,
    ),
  );

  group('orders', () {
    test('creates and lists drafts for a patient', () async {
      final String id = await seedDraft();

      final List<Prescription> orders = await repository
          .listPrescriptionsForPatient('patient-1');
      expect(orders.map((Prescription o) => o.id), contains(id));
      expect(orders.single.status, PrescriptionStatus.draft);
    });

    test('getPrescription returns null when absent', () async {
      expect(await repository.getPrescription('missing'), isNull);
    });

    test('versions share the series code in order', () async {
      final String v1 = await seedDraft();
      await repository.createPrescription(<String, Object?>{
        'tenant_id': 'tenant-1',
        'patient_id': 'patient-1',
        'prescribed_by': 'doctor-1',
        'prescription_code': 'RX-001',
        'version': 2,
        'priority': 'routine',
        'status': 'draft',
        'created_at': '2026-09-17T00:00:00.000Z',
        'updated_at': '2026-09-17T00:00:00.000Z',
      });

      final List<Prescription> versions = await repository.listVersions(
        'RX-001',
      );
      expect(versions.map((Prescription v) => v.id), containsAll(<String>[v1]));
      expect(versions.length, 2);
    });

    test('normalizes integer columns to integers', () async {
      final String id = await repository.createPrescription(<String, Object?>{
        ...Prescription.draftRow(
          tenantId: 'tenant-1',
          patientId: 'patient-1',
          prescribedBy: 'doctor-1',
          prescriptionCode: 'RX-002',
          priority: PrescriptionPriority.routine,
        ),
        'version': '1',
      });

      final Prescription? order = await repository.getPrescription(id);
      expect(order!.version, 1);
    });
  });

  group('lines and events', () {
    test('adds lines and records dispense plus administration', () async {
      final String orderId = await seedDraft();
      final String lineId = await repository.addItem(
        PrescriptionItem.draftRow(
          tenantId: 'tenant-1',
          prescriptionId: orderId,
          lineNumber: 1,
          drugCode: 'PARA500',
          drugName: 'Paracetamol',
          dosageText: '500mg twice daily',
          quantityPrescribed: 20,
        ),
      );

      final List<PrescriptionItem> items = await repository.listItems(orderId);
      expect(items.single.id, lineId);

      final String dispenseId = await repository.recordDispense(
        PharmacyDispense.eventRow(
          tenantId: 'tenant-1',
          prescriptionId: orderId,
          itemId: lineId,
          dispensedBy: 'pharm-1',
          quantityDispensed: 20,
        ),
      );
      expect((await repository.listDispenses(lineId)).single.id, dispenseId);

      final String adminId = await repository.recordAdministration(
        MedicationAdministration.eventRow(
          tenantId: 'tenant-1',
          patientId: 'patient-1',
          prescriptionId: orderId,
          itemId: lineId,
          administeredBy: 'nurse-1',
          doseText: '500mg',
          dispenseId: dispenseId,
        ),
      );
      expect((await repository.listAdministrations(lineId)).single.id, adminId);
    });

    test('a closed store surfaces PersistenceError', () async {
      store.closed = true;
      await expectLater(
        repository.listPrescriptionsForPatient('patient-1'),
        throwsA(isA<PersistenceError>()),
      );
    });
  });
}
