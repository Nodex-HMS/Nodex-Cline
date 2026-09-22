/// Tests for the appointment repository over a fake local store.
///
/// Mirrors the encounter repository tests: the SQL surface is faked with just
/// enough understanding for the repository's queries.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/appointments/appointment_repository.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';

/// In-memory [PatientLocalStore] extended with the appointments table.
final class FakeAppointmentStore implements PatientLocalStore {
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
    if (sql.contains(LocalTables.appUsers)) {
      return _table(LocalTables.appUsers).values.toList(growable: false);
    }
    if (sql.contains(LocalTables.appointments)) {
      Iterable<Map<String, Object?>> rows = _table(LocalTables.appointments)
          .values;
      if (sql.contains('patient_id = ?')) {
        final String patientId = parameters[0]! as String;
        rows = rows.where(
          (Map<String, Object?> r) => r['patient_id'] == patientId,
        );
      } else if (sql.contains('provider_id = ?')) {
        final String providerId = parameters[0]! as String;
        final String from = parameters[1]! as String;
        rows = rows.where(
          (Map<String, Object?> r) =>
              r['provider_id'] == providerId &&
              (r['scheduled_start']! as String).compareTo(from) >= 0,
        );
      } else {
        final String from = parameters[0]! as String;
        rows = rows.where(
          (Map<String, Object?> r) =>
              (r['scheduled_start']! as String).compareTo(from) >= 0,
        );
      }
      final List<Map<String, Object?>> sorted = rows.toList();
      sorted.sort(
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (a['scheduled_start']! as String).compareTo(
              b['scheduled_start']! as String,
            ),
      );
      return sorted;
    }
    throw UnimplementedError('FakeAppointmentStore cannot run: $sql');
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
  late FakeAppointmentStore store;
  late DefaultAppointmentRepository repository;

  setUp(() {
    store = FakeAppointmentStore();
    repository = DefaultAppointmentRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
  });

  Future<String> seedBooking({String code = 'APT-001', DateTime? start}) async {
    final DateTime at = start ?? DateTime.utc(2026, 10, 1, 9);
    return repository.bookAppointment(
      Appointment.bookRow(
        tenantId: 'tenant-1',
        patientId: 'patient-1',
        providerId: 'doctor-1',
        bookedBy: 'nurse-1',
        appointmentCode: code,
        visitType: VisitType.outpatient,
        priority: AppointmentPriority.routine,
        scheduledStart: at,
        scheduledEnd: at.add(const Duration(minutes: 30)),
      ),
    );
  }

  group('schedule', () {
    test('upcoming returns future bookings earliest first', () async {
      await seedBooking(code: 'APT-LATER', start: DateTime.utc(2026, 10, 2, 9));
      final String first = await seedBooking(code: 'APT-FIRST');

      final List<Appointment> upcoming = await repository.listUpcoming(
        from: DateTime.utc(2026, 10, 1),
      );
      expect(upcoming.map((Appointment a) => a.id).first, first);
      expect(upcoming.length, 2);
    });

    test('past bookings fall out of upcoming', () async {
      await seedBooking();
      final List<Appointment> upcoming = await repository.listUpcoming(
        from: DateTime.utc(2026, 11, 1),
      );
      expect(upcoming, isEmpty);
    });

    test('for-patient and for-provider scopes filter', () async {
      await seedBooking();
      expect((await repository.listForPatient('patient-1')).length, 1);
      expect((await repository.listForPatient('patient-9')).isEmpty, isTrue);
      expect(
        (await repository.listForProvider(
          providerId: 'doctor-1',
          from: DateTime.utc(2026, 10, 1),
        )).length,
        1,
      );
    });

    test('getAppointment returns null when absent', () async {
      expect(await repository.getAppointment('missing'), isNull);
    });

    test('a closed store surfaces PersistenceError', () async {
      store.closed = true;
      await expectLater(
        repository.listUpcoming(from: DateTime.utc(2026, 10, 1)),
        throwsA(isA<PersistenceError>()),
      );
    });
  });
}
