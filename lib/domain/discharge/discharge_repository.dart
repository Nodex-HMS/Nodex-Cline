/// Discharge repository contract and local implementation (Module 23).
library;

import 'package:nodex_hms/core/errors/error_mapper.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/discharge/discharge.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';
import 'package:uuid/uuid.dart';

/// Repository operations for discharge finalization.
abstract interface class DischargeRepository {
  /// Discharges for one patient, newest first.
  Future<List<Discharge>> listForPatient(String patientId);

  /// One discharge by id, or null.
  Future<Discharge?> getDischarge(String id);

  /// Discharge for one encounter, or null. At most one exists.
  Future<Discharge?> getByEncounter(String encounterId);

  /// Creates a local draft.
  Future<String> createDischarge(Map<String, Object?> row);

  /// Applies a discharge transition (finalize or cancel).
  Future<void> updateDischarge(String id, Map<String, Object?> changes);
}

/// PowerSync-backed discharge repository.
final class DefaultDischargeRepository implements DischargeRepository {
  /// Creates a repository over a local store.
  DefaultDischargeRepository({required this._store, required this._logger});

  static const String _module = 'domain.discharge';

  final PatientLocalStore _store;
  final NodexLogger _logger;

  @override
  Future<List<Discharge>> listForPatient(String patientId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.discharges} WHERE patient_id = ? ORDER BY created_at DESC',
        <Object?>[patientId],
      );
      return rows.map(Discharge.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'discharge.patient');
    }
  }

  @override
  Future<Discharge?> getDischarge(String id) async {
    final Map<String, Object?>? row = await _store.getById(
      LocalTables.discharges,
      id,
    );
    return row == null ? null : Discharge.fromRow(row);
  }

  @override
  Future<Discharge?> getByEncounter(String encounterId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.discharges} WHERE encounter_id = ?',
        <Object?>[encounterId],
      );
      if (rows.isEmpty) return null;
      return Discharge.fromRow(rows.first);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'discharge.encounter');
    }
  }

  @override
  Future<String> createDischarge(Map<String, Object?> row) async {
    final String id = const Uuid().v4();
    try {
      await _store.insert(LocalTables.discharges, <String, Object?>{
        ...row,
        'id': id,
      });
      _logger.info(
        _module,
        'Discharge draft committed locally.',
        operation: 'discharge.draft',
        outcome: 'queued',
      );
      return id;
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'discharge.draft');
    }
  }

  @override
  Future<void> updateDischarge(String id, Map<String, Object?> changes) async {
    try {
      await _store.update(LocalTables.discharges, id, changes);
      _logger.info(
        _module,
        'Discharge transition committed locally.',
        operation: 'discharge.update',
        outcome: 'queued',
      );
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'discharge.update');
    }
  }

  Never _mapped(Object error, StackTrace stackTrace, String operation) {
    if (error is NodexError) throw error;
    final NodexError mapped = NodexErrorMapper.map(error, operation: operation);
    _logger.error(
      _module,
      'Discharge repository failure.',
      operation: operation,
      outcome: 'failed',
      errorCode: mapped.code,
      stackTrace: stackTrace,
    );
    throw mapped;
  }
}
