/// Tests for the appointment use-case gates (Module 07).
///
/// Booking, transitions and rescheduling all require `appointment.write`.
/// Illegal jumps fail fast locally; the database guard is the final enforcer.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/authorization_snapshot.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/appointments/appointment_repository.dart';
import 'package:nodex_hms/domain/appointments/appointment_use_cases.dart';

import 'appointment_repository_test.dart' show FakeAppointmentStore;

/// Builds a policy holding exactly [permissions].
AuthorizationPolicy policyWith(Set<String> permissions) {
  final DateTime issuedAt = DateTime.now().toUtc();
  return AuthorizationPolicy(
    snapshot: AuthorizationSnapshot(
      snapshotId: 'snapshot-1',
      tenantId: 'tenant-1',
      userId: 'nurse-1',
      deviceId: 'device-1',
      revision: 1,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(const Duration(days: 30)),
      payloadDigest: 'digest',
      roles: const <String>{NodexRoles.nursingStaff},
      permissions: permissions,
      offlinePermissions: permissions,
      facilityIds: const <String>{},
      departmentIds: const <String>{},
      wardIds: const <String>{},
    ),
    connectivity: ConnectivityState.online,
  );
}

void main() {
  late FakeAppointmentStore store;
  late DefaultAppointmentRepository repository;
  late BookAppointmentUseCase book;
  late TransitionAppointmentUseCase transition;
  late RescheduleAppointmentUseCase reschedule;
  late LinkEncounterAppointmentUseCase link;

  const Set<String> writer = <String>{NodexPermissions.appointmentWrite};
  const Set<String> reader = <String>{NodexPermissions.appointmentRead};

  setUp(() {
    store = FakeAppointmentStore();
    repository = DefaultAppointmentRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
    book = BookAppointmentUseCase(repository: repository);
    transition = TransitionAppointmentUseCase(repository: repository);
    reschedule = RescheduleAppointmentUseCase(repository: repository);
    link = LinkEncounterAppointmentUseCase(repository: repository);
  });

  Future<Appointment> seedBooking() async {
    final DateTime at = DateTime.utc(2026, 10, 1, 9);
    final String id = await book.call(
      policy: policyWith(writer),
      tenantId: 'tenant-1',
      patientId: 'patient-1',
      providerId: 'doctor-1',
      bookedBy: 'nurse-1',
      appointmentCode: 'APT-001',
      visitType: VisitType.outpatient,
      priority: AppointmentPriority.routine,
      scheduledStart: at,
      scheduledEnd: at.add(const Duration(minutes: 30)),
    );
    return (await repository.getAppointment(id))!;
  }

  group('authorization gates', () {
    test('booking requires appointment.write', () {
      final DateTime at = DateTime.utc(2026, 10, 1, 9);
      expect(
        book.call(
          policy: policyWith(reader),
          tenantId: 'tenant-1',
          patientId: 'patient-1',
          providerId: 'doctor-1',
          bookedBy: 'nurse-1',
          appointmentCode: 'APT-001',
          visitType: VisitType.outpatient,
          priority: AppointmentPriority.routine,
          scheduledStart: at,
          scheduledEnd: at.add(const Duration(minutes: 30)),
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('a reader cannot transition, reschedule or link', () async {
      final Appointment booking = await seedBooking();
      final DateTime at = DateTime.utc(2026, 10, 2, 9);
      await expectLater(
        transition.call(
          policy: policyWith(reader),
          appointment: booking,
          status: AppointmentStatus.confirmed,
        ),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        reschedule.call(
          policy: policyWith(reader),
          appointment: booking,
          scheduledStart: at,
          scheduledEnd: at.add(const Duration(minutes: 30)),
        ),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        link.call(
          policy: policyWith(reader),
          appointment: booking,
          encounterId: 'enc-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });
  });

  group('lifecycle', () {
    test('booked to completed through every gate', () async {
      Appointment booking = await seedBooking();
      for (final AppointmentStatus status in <AppointmentStatus>[
        AppointmentStatus.confirmed,
        AppointmentStatus.checkedIn,
        AppointmentStatus.inProgress,
        AppointmentStatus.completed,
      ]) {
        await transition.call(
          policy: policyWith(writer),
          appointment: booking,
          status: status,
        );
        booking = (await repository.getAppointment(booking.id))!;
        expect(booking.status, status);
      }
    });

    test('illegal jumps fail fast', () async {
      final Appointment booking = await seedBooking();
      await expectLater(
        transition.call(
          policy: policyWith(writer),
          appointment: booking,
          status: AppointmentStatus.completed,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('terminal records refuse transitions and links', () async {
      Appointment booking = await seedBooking();
      await transition.call(
        policy: policyWith(writer),
        appointment: booking,
        status: AppointmentStatus.confirmed,
      );
      booking = (await repository.getAppointment(booking.id))!;
      await transition.call(
        policy: policyWith(writer),
        appointment: booking,
        status: AppointmentStatus.cancelled,
        cancelReason: 'Duplicate',
      );
      booking = (await repository.getAppointment(booking.id))!;
      expect(booking.status, AppointmentStatus.cancelled);
      await expectLater(
        transition.call(
          policy: policyWith(writer),
          appointment: booking,
          status: AppointmentStatus.confirmed,
        ),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        link.call(
          policy: policyWith(writer),
          appointment: booking,
          encounterId: 'enc-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('rescheduling moves the slot while unconfirmed', () async {
      final Appointment booking = await seedBooking();
      final DateTime at = DateTime.utc(2026, 10, 3, 9);
      await reschedule.call(
        policy: policyWith(writer),
        appointment: booking,
        scheduledStart: at,
        scheduledEnd: at.add(const Duration(minutes: 30)),
      );
      final Appointment moved = (await repository.getAppointment(booking.id))!;
      expect(moved.scheduledStart, at);
    });

    test('checked-in bookings cannot reschedule', () async {
      Appointment booking = await seedBooking();
      await transition.call(
        policy: policyWith(writer),
        appointment: booking,
        status: AppointmentStatus.checkedIn,
      );
      booking = (await repository.getAppointment(booking.id))!;
      final DateTime at = DateTime.utc(2026, 10, 3, 9);
      await expectLater(
        reschedule.call(
          policy: policyWith(writer),
          appointment: booking,
          scheduledStart: at,
          scheduledEnd: at.add(const Duration(minutes: 30)),
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });
  });
}
