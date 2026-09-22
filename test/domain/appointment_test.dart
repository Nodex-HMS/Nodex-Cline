/// Tests for the appointment entities (Module 07).
///
/// Booking -> confirmed -> checked-in -> in-progress -> completed, with cancel
/// and no-show terminal. Slot allocation is server-arbitrated; the database
/// exclusion is the arbiter and the client reconciles to server state.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';

void main() {
  DateTime start() => DateTime.utc(2026, 10, 1, 9);
  DateTime end() => DateTime.utc(2026, 10, 1, 9, 30);

  group('Appointment.bookRow', () {
    test('builds a booked visit', () {
      final Map<String, Object?> row = Appointment.bookRow(
        tenantId: 'tenant-1',
        patientId: 'patient-1',
        providerId: 'doctor-1',
        bookedBy: 'nurse-1',
        appointmentCode: 'APT-001',
        visitType: VisitType.outpatient,
        priority: AppointmentPriority.routine,
        scheduledStart: start(),
        scheduledEnd: end(),
        reason: 'Fever',
      );

      expect(row['status'], AppointmentStatus.booked.wireValue);
      expect(row['encounter_id'], isNull);
      final Appointment booking = Appointment.fromRow(<String, Object?>{
        ...row,
        'id': 'appt-1',
      });
      expect(booking.scheduledStart, start());
      expect(booking.status.isSchedulable, isTrue);
    });

    test('rejects blank identity and inverted slots with field errors', () {
      try {
        Appointment.bookRow(
          tenantId: '',
          patientId: '',
          providerId: '',
          bookedBy: '',
          appointmentCode: '  ',
          visitType: VisitType.outpatient,
          priority: AppointmentPriority.routine,
          scheduledStart: end(),
          scheduledEnd: start(),
        );
        fail('expected ValidationError');
      } on ValidationError catch (error) {
        expect(error.code, 'appointment_invalid');
        expect(
          error.fieldErrors.keys,
          containsAll(<String>[
            'tenant_id',
            'patient_id',
            'provider_id',
            'booked_by',
            'appointment_code',
            'scheduled_end',
          ]),
        );
      }
    });
  });

  group('transitions', () {
    test('status changes stamp only the target state', () {
      final Map<String, Object?> checkedIn = Appointment.statusChanges(
        status: AppointmentStatus.checkedIn,
      );
      expect(checkedIn['checked_in_at'], isNotNull);
      expect(checkedIn.containsKey('started_at'), isFalse);

      final Map<String, Object?> cancelled = Appointment.statusChanges(
        status: AppointmentStatus.cancelled,
        cancelReason: 'Duplicate',
      );
      expect(cancelled['cancel_reason'], 'Duplicate');

      expect(
        () => Appointment.statusChanges(status: AppointmentStatus.cancelled),
        throwsA(isA<ValidationError>()),
      );
    });

    test('rescheduling requires a forward slot', () {
      final Map<String, Object?> moved = Appointment.rescheduleChanges(
        scheduledStart: start(),
        scheduledEnd: end(),
      );
      expect(moved['scheduled_start'], isNotNull);
      expect(
        () => Appointment.rescheduleChanges(
          scheduledStart: end(),
          scheduledEnd: start(),
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('terminal states are terminal', () {
      expect(AppointmentStatus.completed.isTerminal, isTrue);
      expect(AppointmentStatus.cancelled.isTerminal, isTrue);
      expect(AppointmentStatus.noShow.isTerminal, isTrue);
      expect(AppointmentStatus.booked.isTerminal, isFalse);
    });
  });
}
