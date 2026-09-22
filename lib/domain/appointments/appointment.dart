/// Appointment and visit scheduling entities (Module 07).
///
/// Booking -> confirmed -> checked-in -> in-progress -> completed, with cancel
/// and no-show as terminal markers. Slot allocation is server-arbitrated: the
/// no-double-book exclusion is the arbiter, so a conflicting offline booking
/// is rejected on upload and the client reconciles to server state
/// (ConflictPolicy.serverAuthoritative).
// ignore_for_file: sort_constructors_first
library;

import 'package:meta/meta.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';

/// Visit priority.
enum AppointmentPriority {
  /// Normal scheduling.
  routine('routine'),

  /// Expedited scheduling.
  urgent('urgent'),

  /// Immediate clinical priority.
  stat('stat');

  const AppointmentPriority(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Human-readable label.
  String get label => switch (this) {
    AppointmentPriority.routine => 'Routine',
    AppointmentPriority.urgent => 'Urgent',
    AppointmentPriority.stat => 'STAT',
  };

  /// Parses a stored value.
  static AppointmentPriority fromWire(String value) =>
      AppointmentPriority.values.firstWhere(
        (AppointmentPriority priority) => priority.wireValue == value,
        orElse: () => AppointmentPriority.routine,
      );
}

/// Visit type.
enum VisitType {
  /// Walk-in or scheduled outpatient visit.
  outpatient('outpatient'),

  /// Follow-up on an earlier encounter.
  followUp('follow_up'),

  /// Remote consultation.
  telehealth('telehealth'),

  /// Emergency presentation.
  emergency('emergency'),

  /// Booked procedure slot.
  procedure('procedure');

  const VisitType(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Human-readable label.
  String get label => switch (this) {
    VisitType.outpatient => 'Outpatient',
    VisitType.followUp => 'Follow-up',
    VisitType.telehealth => 'Telehealth',
    VisitType.emergency => 'Emergency',
    VisitType.procedure => 'Procedure',
  };

  /// Parses a stored value.
  static VisitType fromWire(String value) => VisitType.values.firstWhere(
    (VisitType type) => type.wireValue == value,
    orElse: () => VisitType.outpatient,
  );
}

/// Appointment lifecycle.
enum AppointmentStatus {
  /// Booked, awaiting confirmation.
  booked('booked'),

  /// Confirmed with the patient.
  confirmed('confirmed'),

  /// Patient arrived.
  checkedIn('checked_in'),

  /// Visit under way.
  inProgress('in_progress'),

  /// Visit finished.
  completed('completed'),

  /// Cancelled with a reason.
  cancelled('cancelled'),

  /// Patient did not arrive.
  noShow('no_show');

  const AppointmentStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Whether the booking still accepts schedule and detail edits.
  bool get isSchedulable =>
      this == AppointmentStatus.booked || this == AppointmentStatus.confirmed;

  /// Whether the record reached a terminal state.
  bool get isTerminal =>
      this == AppointmentStatus.completed ||
      this == AppointmentStatus.cancelled ||
      this == AppointmentStatus.noShow;

  /// Parses a stored value.
  static AppointmentStatus fromWire(String value) =>
      AppointmentStatus.values.firstWhere(
        (AppointmentStatus status) => status.wireValue == value,
        orElse: () => AppointmentStatus.booked,
      );
}

/// Visit booking.
@immutable
final class Appointment {
  /// Creates an appointment.
  const Appointment({
    required this.id,
    required this.tenantId,
    required this.patientId,
    required this.providerId,
    required this.bookedBy,
    required this.appointmentCode,
    required this.visitType,
    required this.priority,
    required this.status,
    required this.scheduledStart,
    required this.scheduledEnd,
    required this.createdAt,
    this.facilityId,
    this.encounterId,
    this.reason,
    this.checkedInAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancelReason,
  });

  /// Validates and builds a new booking row.
  static Map<String, Object?> bookRow({
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
  }) {
    final Map<String, String> fieldErrors = <String, String>{};
    if (tenantId.isEmpty) {
      fieldErrors['tenant_id'] = 'Tenant is required.';
    }
    if (patientId.isEmpty) {
      fieldErrors['patient_id'] = 'Patient is required.';
    }
    if (providerId.isEmpty) {
      fieldErrors['provider_id'] = 'Provider is required.';
    }
    if (bookedBy.isEmpty) {
      fieldErrors['booked_by'] = 'Booking user is required.';
    }
    if (appointmentCode.trim().isEmpty) {
      fieldErrors['appointment_code'] = 'Appointment code is required.';
    }
    if (!scheduledEnd.isAfter(scheduledStart)) {
      fieldErrors['scheduled_end'] = 'The visit must end after it starts.';
    }
    if (fieldErrors.isNotEmpty) {
      throw ValidationError(
        message: 'Appointment booking failed validation.',
        fieldErrors: fieldErrors,
        code: 'appointment_invalid',
      );
    }

    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'facility_id': facilityId,
      'patient_id': patientId,
      'provider_id': providerId,
      'booked_by': bookedBy,
      'encounter_id': null,
      'appointment_code': appointmentCode.trim(),
      'visit_type': visitType.wireValue,
      'priority': priority.wireValue,
      'status': AppointmentStatus.booked.wireValue,
      'reason': _clean(reason),
      'scheduled_start': scheduledStart.toUtc().toIso8601String(),
      'scheduled_end': scheduledEnd.toUtc().toIso8601String(),
      'checked_in_at': null,
      'started_at': null,
      'completed_at': null,
      'cancelled_at': null,
      'cancel_reason': null,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds a reschedule transition. Only unconfirmed bookings move.
  static Map<String, Object?> rescheduleChanges({
    required DateTime scheduledStart,
    required DateTime scheduledEnd,
  }) {
    if (!scheduledEnd.isAfter(scheduledStart)) {
      throw const ValidationError(
        message: 'The visit must end after it starts.',
        fieldErrors: <String, String>{
          'scheduled_end': 'The visit must end after it starts.',
        },
        code: 'appointment_invalid',
      );
    }
    return <String, Object?>{
      'scheduled_start': scheduledStart.toUtc().toIso8601String(),
      'scheduled_end': scheduledEnd.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// Builds a status transition, stamping the timestamps the database
  /// requires for the target state.
  static Map<String, Object?> statusChanges({
    required AppointmentStatus status,
    String? cancelReason,
  }) {
    if ((status == AppointmentStatus.cancelled) &&
        (cancelReason == null || cancelReason.trim().isEmpty)) {
      throw const ValidationError(
        message: 'Cancelling an appointment requires a reason.',
        fieldErrors: <String, String>{'reason': 'Enter the cancel reason.'},
        code: 'appointment_cancel_reason_required',
      );
    }
    // Only the target state's timestamp travels: earlier stamps belong to the
    // record's history and must survive the transition (the database requires
    // checked_in_at alongside in_progress and completed).
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'status': status.wireValue,
      if (status == AppointmentStatus.checkedIn) 'checked_in_at': now,
      if (status == AppointmentStatus.inProgress) 'started_at': now,
      if (status == AppointmentStatus.completed) 'completed_at': now,
      if (status == AppointmentStatus.cancelled) ...<String, Object?>{
        'cancelled_at': now,
        'cancel_reason': cancelReason!.trim(),
      },
      'updated_at': now,
    };
  }

  /// Builds the encounter link once the visit becomes a clinical encounter.
  static Map<String, Object?> linkEncounterChanges({
    required String encounterId,
  }) => <String, Object?>{
    'encounter_id': encounterId,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };

  /// Materializes an appointment from a local row.
  factory Appointment.fromRow(Map<String, Object?> row) => Appointment(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    patientId: row['patient_id']! as String,
    providerId: row['provider_id']! as String,
    bookedBy: row['booked_by']! as String,
    appointmentCode: row['appointment_code']! as String,
    visitType: VisitType.fromWire(row['visit_type']! as String),
    priority: AppointmentPriority.fromWire(row['priority']! as String),
    status: AppointmentStatus.fromWire(row['status']! as String),
    scheduledStart: DateTime.parse(row['scheduled_start']! as String),
    scheduledEnd: DateTime.parse(row['scheduled_end']! as String),
    createdAt: DateTime.parse(row['created_at']! as String),
    facilityId: row['facility_id'] as String?,
    encounterId: row['encounter_id'] as String?,
    reason: row['reason'] as String?,
    checkedInAt: _parseTime(row['checked_in_at']),
    startedAt: _parseTime(row['started_at']),
    completedAt: _parseTime(row['completed_at']),
    cancelledAt: _parseTime(row['cancelled_at']),
    cancelReason: row['cancel_reason'] as String?,
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Patient identifier.
  final String patientId;

  /// Responsible clinician.
  final String providerId;

  /// Booking user.
  final String bookedBy;

  /// Tenant-scoped booking code.
  final String appointmentCode;

  /// Visit type.
  final VisitType visitType;

  /// Scheduling priority.
  final AppointmentPriority priority;

  /// Current booking state.
  final AppointmentStatus status;

  /// Scheduled start.
  final DateTime scheduledStart;

  /// Scheduled end.
  final DateTime scheduledEnd;

  /// When created.
  final DateTime createdAt;

  /// Facility identifier, when booked against one.
  final String? facilityId;

  /// Linked encounter, once the visit starts one.
  final String? encounterId;

  /// Booking reason.
  final String? reason;

  /// Check-in time.
  final DateTime? checkedInAt;

  /// Visit start time.
  final DateTime? startedAt;

  /// Completion time.
  final DateTime? completedAt;

  /// Cancellation time.
  final DateTime? cancelledAt;

  /// Cancellation reason.
  final String? cancelReason;

  static String? _clean(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _parseTime(Object? raw) =>
      raw == null ? null : DateTime.parse(raw as String);
}
