/// Bed repository contract and local implementation (Module 11).
library;

import 'package:nodex_hms/core/errors/error_mapper.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/beds/bed.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';
import 'package:uuid/uuid.dart';

/// Repository operations for beds and occupancy.
abstract interface class BedRepository {
  /// Wards in the local scope, for the census picker.
  Future<List<WardInfo>> listWards();

  /// Beds for one ward, ordered by code.
  Future<List<Bed>> listBedsForWard(String wardId);

  /// Active assignment for a bed, or null when vacant.
  Future<BedAssignment?> activeAssignmentForBed(String bedId);

  /// Active assignment for a patient, or null when not admitted.
  Future<BedAssignment?> activeAssignmentForPatient(String patientId);

  /// Assignment history for a patient, newest first.
  Future<List<BedAssignment>> listAssignmentsForPatient(String patientId);

  /// One bed by id, or null.
  Future<Bed?> getBed(String id);

  /// Registers a bed.
  Future<String> registerBed(Map<String, Object?> row);

  /// Applies a bed availability transition.
  Future<void> updateBed(String id, Map<String, Object?> changes);

  /// Creates an active assignment.
  Future<String> assignBed(Map<String, Object?> row);

  /// Applies an assignment transition (release or cancel).
  Future<void> updateAssignment(String id, Map<String, Object?> changes);
}

/// Ward directory entry for the census picker.
final class WardInfo {
  /// Creates an entry.
  const WardInfo({required this.id, required this.displayName});

  /// Ward identifier.
  final String id;

  /// Display name.
  final String displayName;
}

/// One bed with its live occupant, if any.
final class BedCensusEntry {
  /// Creates an entry.
  const BedCensusEntry({required this.bed, this.assignment});

  /// The bed.
  final Bed bed;

  /// The active assignment, or null when vacant.
  final BedAssignment? assignment;

  /// Whether a patient holds the bed.
  bool get isOccupied => assignment != null;
}

/// PowerSync-backed bed repository.
final class DefaultBedRepository implements BedRepository {
  /// Creates a repository over a local store.
  DefaultBedRepository({required this._store, required this._logger});

  static const String _module = 'domain.beds';

  final PatientLocalStore _store;
  final NodexLogger _logger;

  @override
  Future<List<WardInfo>> listWards() async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.wards} ORDER BY display_name',
        const <Object?>[],
      );
      return rows
          .map(
            (Map<String, Object?> row) => WardInfo(
              id: row['id']! as String,
              displayName:
                  (row['display_name'] as String?) ??
                  (row['code'] as String?) ??
                  row['id']! as String,
            ),
          )
          .toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'bed.wards');
    }
  }

  @override
  Future<List<Bed>> listBedsForWard(String wardId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.beds} WHERE ward_id = ? ORDER BY bed_code',
        <Object?>[wardId],
      );
      return rows.map(Bed.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'bed.ward');
    }
  }

  @override
  Future<BedAssignment?> activeAssignmentForBed(String bedId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.bedAssignments} WHERE bed_id = ? AND status = ?',
        <Object?>[bedId, BedAssignmentStatus.active.wireValue],
      );
      if (rows.isEmpty) return null;
      return BedAssignment.fromRow(rows.first);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'bed.occupant');
    }
  }

  @override
  Future<BedAssignment?> activeAssignmentForPatient(String patientId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.bedAssignments} WHERE patient_id = ? AND status = ?',
        <Object?>[patientId, BedAssignmentStatus.active.wireValue],
      );
      if (rows.isEmpty) return null;
      return BedAssignment.fromRow(rows.first);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'bed.stay');
    }
  }

  @override
  Future<List<BedAssignment>> listAssignmentsForPatient(
    String patientId,
  ) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.bedAssignments} WHERE patient_id = ? ORDER BY admitted_at DESC',
        <Object?>[patientId],
      );
      return rows.map(BedAssignment.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'bed.history');
    }
  }

  @override
  Future<Bed?> getBed(String id) async {
    final Map<String, Object?>? row = await _store.getById(
      LocalTables.beds,
      id,
    );
    return row == null ? null : Bed.fromRow(row);
  }

  @override
  Future<String> registerBed(Map<String, Object?> row) =>
      _insert(LocalTables.beds, row, 'bed.register');

  @override
  Future<void> updateBed(String id, Map<String, Object?> changes) =>
      _update(LocalTables.beds, id, changes, 'bed.update');

  @override
  Future<String> assignBed(Map<String, Object?> row) =>
      _insert(LocalTables.bedAssignments, row, 'bed.assign');

  @override
  Future<void> updateAssignment(String id, Map<String, Object?> changes) =>
      _update(LocalTables.bedAssignments, id, changes, 'bed.release');

  Future<String> _insert(
    String table,
    Map<String, Object?> row,
    String operation,
  ) async {
    final String id = const Uuid().v4();
    try {
      await _store.insert(table, <String, Object?>{...row, 'id': id});
      _logger.info(
        _module,
        'Bed write committed locally.',
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
      await _store.update(table, id, changes);
      _logger.info(
        _module,
        'Bed transition committed locally.',
        operation: operation,
        outcome: 'queued',
      );
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, operation);
    }
  }

  Never _mapped(Object error, StackTrace stackTrace, String operation) {
    if (error is NodexError) throw error;
    final NodexError mapped = NodexErrorMapper.map(error, operation: operation);
    _logger.error(
      _module,
      'Bed repository failure.',
      operation: operation,
      outcome: 'failed',
      errorCode: mapped.code,
      stackTrace: stackTrace,
    );
    throw mapped;
  }
}
