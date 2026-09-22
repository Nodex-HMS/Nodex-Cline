/// Appointment repository contract and local implementation (Module 07).
library;

import 'package:nodex_hms/core/errors/error_mapper.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';
import 'package:uuid/uuid.dart';

/// Repository operations for visit scheduling.
abstract interface class AppointmentRepository {
  /// Upcoming bookings scope-wide, earliest first.
  Future<List<Appointment>> listUpcoming({required DateTime from});

  /// Bookings for one patient, newest first.
  Future<List<Appointment>> listForPatient(String patientId);

  /// Bookings for one provider from [from], earliest first.
  Future<List<Appointment>> listForProvider({
    required String providerId,
    required DateTime from,
  });

  /// One booking by id, or null.
  Future<Appointment?> getAppointment(String id);

  /// Staff directory entries for the provider picker.
  Future<List<StaffMember>> listProviders();

  /// Creates a local booking.
  Future<String> bookAppointment(Map<String, Object?> row);

  /// Applies a booking transition.
  Future<void> updateAppointment(String id, Map<String, Object?> changes);
}

/// Directory entry for booking against a clinician.
final class StaffMember {
  /// Creates an entry.
  const StaffMember({required this.id, required this.displayName});

  /// User identifier.
  final String id;

  /// Display name, falling back to the full name.
  final String displayName;
}

/// PowerSync-backed appointment repository.
final class DefaultAppointmentRepository implements AppointmentRepository {
  /// Creates a repository over a local store.
  DefaultAppointmentRepository({required this._store, required this._logger});

  static const String _module = 'domain.appointments';

  final PatientLocalStore _store;
  final NodexLogger _logger;

  @override
  Future<List<Appointment>> listUpcoming({required DateTime from}) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.appointments} WHERE scheduled_start >= ? ORDER BY scheduled_start',
        <Object?>[from.toUtc().toIso8601String()],
      );
      return rows.map(Appointment.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'appt.upcoming');
    }
  }

  @override
  Future<List<Appointment>> listForPatient(String patientId) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.appointments} WHERE patient_id = ? ORDER BY scheduled_start DESC',
        <Object?>[patientId],
      );
      return rows.map(Appointment.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'appt.patient');
    }
  }

  @override
  Future<List<Appointment>> listForProvider({
    required String providerId,
    required DateTime from,
  }) async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.appointments} WHERE provider_id = ? AND scheduled_start >= ? ORDER BY scheduled_start',
        <Object?>[providerId, from.toUtc().toIso8601String()],
      );
      return rows.map(Appointment.fromRow).toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'appt.provider');
    }
  }

  @override
  Future<Appointment?> getAppointment(String id) async {
    final Map<String, Object?>? row = await _store.getById(
      LocalTables.appointments,
      id,
    );
    return row == null ? null : Appointment.fromRow(row);
  }

  @override
  Future<List<StaffMember>> listProviders() async {
    try {
      final List<Map<String, Object?>> rows = await _store.query(
        'SELECT * FROM ${LocalTables.appUsers} ORDER BY display_name',
        const <Object?>[],
      );
      return rows
          .map(
            (Map<String, Object?> row) => StaffMember(
              id: row['id']! as String,
              displayName:
                  (row['display_name'] as String?) ??
                  (row['full_name'] as String?) ??
                  row['id']! as String,
            ),
          )
          .toList(growable: false);
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'appt.providers');
    }
  }

  @override
  Future<String> bookAppointment(Map<String, Object?> row) async {
    final String id = const Uuid().v4();
    try {
      await _store.insert(LocalTables.appointments, <String, Object?>{
        ...row,
        'id': id,
      });
      _logger.info(
        _module,
        'Appointment booked locally.',
        operation: 'appt.book',
        outcome: 'queued',
      );
      return id;
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'appt.book');
    }
  }

  @override
  Future<void> updateAppointment(
    String id,
    Map<String, Object?> changes,
  ) async {
    try {
      await _store.update(LocalTables.appointments, id, changes);
      _logger.info(
        _module,
        'Appointment transition committed locally.',
        operation: 'appt.update',
        outcome: 'queued',
      );
    } on Object catch (error, stackTrace) {
      throw _mapped(error, stackTrace, 'appt.update');
    }
  }

  Never _mapped(Object error, StackTrace stackTrace, String operation) {
    if (error is NodexError) throw error;
    final NodexError mapped = NodexErrorMapper.map(error, operation: operation);
    _logger.error(
      _module,
      'Appointment repository failure.',
      operation: operation,
      outcome: 'failed',
      errorCode: mapped.code,
      stackTrace: stackTrace,
    );
    throw mapped;
  }
}
