/// Prescription repository contract and local implementation (Module 25).
library;

import 'package:nodex_hms/core/errors/error_mapper.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:uuid/uuid.dart';

/// Repository operations for prescriptions, dispensing and the MAR.
abstract interface class PrescriptionRepository {
  /// Orders for one patient, newest first.
  Future<List<Prescription>> listPrescriptionsForPatient(String patientId);

  /// One order version by id, or null.
  Future<Prescription?> getPrescription(String id);

  /// All versions of an order series, oldest first.
  Future<List<Prescription>> listVersions(String prescriptionCode);

  /// Lines for one order version, in line order.
  Future<List<PrescriptionItem>> listItems(String prescriptionId);

  /// One line by id, or null.
  Future<PrescriptionItem?> getItem(String id);

  /// Dispenses for one line, oldest first.
  Future<List<PharmacyDispense>> listDispenses(String itemId);

  /// Administrations for one line, oldest first.
  Future<List<MedicationAdministration>> listAdministrations(String itemId);

  /// Creates a local draft order.
  Future<String> createPrescription(Map<String, Object?> row);

  /// Adds a draft line.
  Future<String> addItem(Map<String, Object?> row);

  /// Applies an order transition (finalize, supersede, close).
  Future<void> updatePrescription(String id, Map<String, Object?> changes);

  /// Applies a line transition (dispense progression).
  Future<void> updateItem(String id, Map<String, Object?> changes);

  /// Records a dispense event.
  Future<String> recordDispense(Map<String, Object?> row);

  /// Records an administration event.
  Future<String> recordAdministration(Map<String, Object?> row);
}

/// PowerSync-backed prescription repository.
final class DefaultPrescriptionRepository implements PrescriptionRepository {
  /// Creates a repository over a local store.
  DefaultPrescriptionRepository({required this._store, required this._logger});

  static const String _module = 'domain.prescriptions';

  final PatientLocalStore _store;
  final NodexLogger _logger;

  @override
  Future<List<Prescription>> listPrescriptionsForPatient(
    String patientId,
  ) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.prescriptions} WHERE patient_id = ? ORDER BY created_at DESC',
        <Object?>[patientId],
      );
      return rows.map(Prescription.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'rx.orders');
    }
  }

  @override
  Future<Prescription?> getPrescription(String id) async {
    final Map<String, Object?>? row = await _store.getById(
      LocalTables.prescriptions,
      id,
    );
    return row == null ? null : Prescription.fromRow(row);
  }

  @override
  Future<List<Prescription>> listVersions(String prescriptionCode) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.prescriptions} WHERE prescription_code = ? ORDER BY version',
        <Object?>[prescriptionCode],
      );
      return rows.map(Prescription.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'rx.versions');
    }
  }

  @override
  Future<List<PrescriptionItem>> listItems(String prescriptionId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.prescriptionItems} WHERE prescription_id = ? ORDER BY line_number',
        <Object?>[prescriptionId],
      );
      return rows.map(PrescriptionItem.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'rx.items');
    }
  }

  @override
  Future<PrescriptionItem?> getItem(String id) async {
    final Map<String, Object?>? row = await _store.getById(
      LocalTables.prescriptionItems,
      id,
    );
    return row == null ? null : PrescriptionItem.fromRow(row);
  }

  @override
  Future<List<PharmacyDispense>> listDispenses(String itemId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.pharmacyDispenses} WHERE item_id = ? ORDER BY dispensed_at',
        <Object?>[itemId],
      );
      return rows.map(PharmacyDispense.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'rx.dispenses');
    }
  }

  @override
  Future<List<MedicationAdministration>> listAdministrations(
    String itemId,
  ) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.medicationAdministrations} WHERE item_id = ? ORDER BY administered_at',
        <Object?>[itemId],
      );
      return rows.map(MedicationAdministration.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'rx.administrations');
    }
  }

  @override
  Future<String> createPrescription(Map<String, Object?> row) =>
      _insert(LocalTables.prescriptions, row, 'rx.prescription');

  @override
  Future<String> addItem(Map<String, Object?> row) =>
      _insert(LocalTables.prescriptionItems, row, 'rx.item');

  @override
  Future<void> updatePrescription(String id, Map<String, Object?> changes) =>
      _update(LocalTables.prescriptions, id, changes, 'rx.prescription.update');

  @override
  Future<void> updateItem(String id, Map<String, Object?> changes) =>
      _update(LocalTables.prescriptionItems, id, changes, 'rx.item.update');

  @override
  Future<String> recordDispense(Map<String, Object?> row) =>
      _insert(LocalTables.pharmacyDispenses, row, 'rx.dispense.record');

  @override
  Future<String> recordAdministration(Map<String, Object?> row) =>
      _insert(LocalTables.medicationAdministrations, row, 'rx.administer');

  Future<String> _insert(
    String table,
    Map<String, Object?> row,
    String operation,
  ) async {
    final String id = const Uuid().v4();
    try {
      await _store.insert(table, <String, Object?>{
        ..._normalized(row),
        'id': id,
      });
      _logger.info(
        _module,
        'Prescription write committed locally.',
        operation: operation,
        outcome: 'queued',
      );
      return id;
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, operation);
    }
  }

  Future<void> _update(
    String table,
    String id,
    Map<String, Object?> changes,
    String operation,
  ) async {
    try {
      await _store.update(table, id, _normalized(changes));
      _logger.info(
        _module,
        'Prescription transition committed locally.',
        operation: operation,
        outcome: 'queued',
      );
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, operation);
    }
  }

  /// Normalizes integer columns to real integers: the local projection stores
  /// them as TEXT, but the mutation path validates them as integers and
  /// PostgreSQL stores them as integer.
  static Map<String, Object?> _normalized(Map<String, Object?> row) {
    if (!row.keys.any(_integerColumns.contains)) return row;
    final Map<String, Object?> normalized = Map<String, Object?>.of(row);
    for (final String column in _integerColumns) {
      final Object? value = normalized[column];
      if (value is String) {
        normalized[column] = int.parse(value);
      }
    }
    return normalized;
  }

  static const Set<String> _integerColumns = <String>{
    'version',
    'line_number',
    'duration_days',
  };

  Never _mapped(Object error, StackTrace stackTrace, String operation) {
    if (error is NodexError) throw error;
    final NodexError mapped = NodexErrorMapper.map(error, operation: operation);
    _logger.error(
      _module,
      'Prescription repository failure.',
      operation: operation,
      outcome: 'failed',
      errorCode: mapped.code,
      stackTrace: stackTrace,
    );
    throw mapped;
  }
}
