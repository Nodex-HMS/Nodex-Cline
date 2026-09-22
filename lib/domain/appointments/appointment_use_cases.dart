/// Appointment scheduling use cases (Module 07).
library;

import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/appointments/appointment_repository.dart';

/// Books a visit. The server arbitrates the slot on upload; a conflicting
/// offline booking is rejected and the client reconciles to server state.
final class BookAppointmentUseCase {
  /// Creates the use case.
  BookAppointmentUseCase({required this._repository});

  final AppointmentRepository _repository;

  /// Books the visit locally.
  Future<String> call({
    required AuthorizationPolicy policy,
    required String tenantId,
    required String patientId,
    required String providerId,
    required String bookedBy,
    required String appointmentCode,
    required VisitType visitType,
    required AppointmentPriority priority,
    required DateTime scheduledStart,
    required DateTime scheduledEnd,
    String? facilityId,
    String? reason,
  }) async {
    policy.require(NodexPermissions.appointmentWrite);
    return _repository.bookAppointment(
      Appointment.bookRow(
        tenantId: tenantId,
        patientId: patientId,
        providerId: providerId,
        bookedBy: bookedBy,
        appointmentCode: appointmentCode,
        visitType: visitType,
        priority: priority,
        scheduledStart: scheduledStart,
        scheduledEnd: scheduledEnd,
        facilityId: facilityId,
        reason: reason,
      ),
    );
  }
}

/// Moves a booking one step along its lifecycle.
final class TransitionAppointmentUseCase {
  /// Creates the use case.
  TransitionAppointmentUseCase({required this._repository});

  final AppointmentRepository _repository;

  /// Applies [status], refusing terminal records and illegal jumps. The
  /// database guard is the final enforcer; this check fails fast locally.
  Future<void> call({
    required AuthorizationPolicy policy,
    required Appointment appointment,
    required AppointmentStatus status,
    String? cancelReason,
  }) async {
    policy.require(NodexPermissions.appointmentWrite);
    if (!_permitted(appointment.status, status)) {
      throw const AuthorizationError(
        message: 'This appointment transition is not permitted.',
        code: 'appointment_transition_denied',
      );
    }
    await _repository.updateAppointment(
      appointment.id,
      Appointment.statusChanges(status: status, cancelReason: cancelReason),
    );
  }

  static bool _permitted(AppointmentStatus from, AppointmentStatus to) {
    if (from.isTerminal || from == to) return false;
    return switch (from) {
      AppointmentStatus.booked =>
        to == AppointmentStatus.confirmed ||
            to == AppointmentStatus.checkedIn ||
            to == AppointmentStatus.cancelled,
      AppointmentStatus.confirmed =>
        to == AppointmentStatus.checkedIn || to == AppointmentStatus.cancelled,
      AppointmentStatus.checkedIn =>
        to == AppointmentStatus.inProgress ||
            to == AppointmentStatus.noShow ||
            to == AppointmentStatus.cancelled,
      AppointmentStatus.inProgress =>
        to == AppointmentStatus.completed || to == AppointmentStatus.cancelled,
      AppointmentStatus.completed ||
      AppointmentStatus.cancelled ||
      AppointmentStatus.noShow => false,
    };
  }
}

/// Moves an unconfirmed booking to a new slot.
final class RescheduleAppointmentUseCase {
  /// Creates the use case.
  RescheduleAppointmentUseCase({required this._repository});

  final AppointmentRepository _repository;

  /// Reschedules [appointment], refusing records past check-in.
  Future<void> call({
    required AuthorizationPolicy policy,
    required Appointment appointment,
    required DateTime scheduledStart,
    required DateTime scheduledEnd,
  }) async {
    policy.require(NodexPermissions.appointmentWrite);
    if (!appointment.status.isSchedulable) {
      throw const AuthorizationError(
        message: 'Only unconfirmed bookings can be rescheduled.',
        code: 'appointment_reschedule_denied',
      );
    }
    await _repository.updateAppointment(
      appointment.id,
      Appointment.rescheduleChanges(
        scheduledStart: scheduledStart,
        scheduledEnd: scheduledEnd,
      ),
    );
  }
}

/// Links the encounter a visit produced.
final class LinkEncounterAppointmentUseCase {
  /// Creates the use case.
  LinkEncounterAppointmentUseCase({required this._repository});

  final AppointmentRepository _repository;

  /// Links [encounterId], refusing terminal records.
  Future<void> call({
    required AuthorizationPolicy policy,
    required Appointment appointment,
    required String encounterId,
  }) async {
    policy.require(NodexPermissions.appointmentWrite);
    if (appointment.status.isTerminal) {
      throw const AuthorizationError(
        message: 'A closed appointment cannot gain an encounter link.',
        code: 'appointment_terminal',
      );
    }
    await _repository.updateAppointment(
      appointment.id,
      Appointment.linkEncounterChanges(encounterId: encounterId),
    );
  }
}
