/// Discharge finalization entities (Module 23).
///
/// Draft -> finalized discharge per encounter. A finalized discharge is the
/// authorized record of the episode and stays readable exactly as issued; a
/// readmission is a new encounter with its own discharge.
// ignore_for_file: sort_constructors_first
library;

import 'package:meta/meta.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';

/// Discharge disposition.
enum DischargeType {
  /// Routine discharge home.
  routine('routine'),

  /// Transfer to another facility.
  referralTransfer('referral_transfer'),

  /// Left against medical advice.
  againstAdvice('against_advice'),

  /// Left without being seen or absconded.
  absconded('absconded'),

  /// Death.
  death('death');

  const DischargeType(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Human-readable label.
  String get label => switch (this) {
    DischargeType.routine => 'Routine',
    DischargeType.referralTransfer => 'Referral transfer',
    DischargeType.againstAdvice => 'Against advice',
    DischargeType.absconded => 'Absconded',
    DischargeType.death => 'Death',
  };

  /// Parses a stored value.
  static DischargeType fromWire(String value) =>
      DischargeType.values.firstWhere(
        (DischargeType type) => type.wireValue == value,
        orElse: () => DischargeType.routine,
      );
}

/// Discharge lifecycle.
enum DischargeStatus {
  /// Editable draft, not yet authorized.
  draft('draft'),

  /// Authorized and immutable.
  finalized('finalized'),

  /// Mistaken draft, retired with a reason.
  cancelled('cancelled');

  const DischargeStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Whether the record can still be edited.
  bool get isEditable => this == DischargeStatus.draft;

  /// Parses a stored value.
  static DischargeStatus fromWire(String value) =>
      DischargeStatus.values.firstWhere(
        (DischargeStatus status) => status.wireValue == value,
        orElse: () => DischargeStatus.draft,
      );
}

/// Discharge record for one encounter.
@immutable
final class Discharge {
  /// Creates a discharge.
  const Discharge({
    required this.id,
    required this.tenantId,
    required this.patientId,
    required this.encounterId,
    required this.createdBy,
    required this.dischargeCode,
    required this.dischargeType,
    required this.status,
    required this.createdAt,
    this.summary,
    this.followUpPlan,
    this.finalizedBy,
    this.finalizedAt,
    this.closedAt,
    this.closureReason,
  });

  /// Validates and builds a new draft row.
  static Map<String, Object?> draftRow({
    required String tenantId,
    required String patientId,
    required String encounterId,
    required String createdBy,
    required String dischargeCode,
    required DischargeType dischargeType,
    String? summary,
    String? followUpPlan,
  }) {
    final Map<String, String> fieldErrors = <String, String>{};
    if (tenantId.isEmpty) {
      fieldErrors['tenant_id'] = 'Tenant is required.';
    }
    if (patientId.isEmpty) {
      fieldErrors['patient_id'] = 'Patient is required.';
    }
    if (encounterId.isEmpty) {
      fieldErrors['encounter_id'] = 'Encounter is required.';
    }
    if (createdBy.isEmpty) {
      fieldErrors['created_by'] = 'Authoring clinician is required.';
    }
    if (dischargeCode.trim().isEmpty) {
      fieldErrors['discharge_code'] = 'Discharge code is required.';
    }
    if (fieldErrors.isNotEmpty) {
      throw ValidationError(
        message: 'Discharge draft failed validation.',
        fieldErrors: fieldErrors,
        code: 'discharge_invalid',
      );
    }

    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'patient_id': patientId,
      'encounter_id': encounterId,
      'created_by': createdBy,
      'discharge_code': dischargeCode.trim(),
      'discharge_type': dischargeType.wireValue,
      'status': DischargeStatus.draft.wireValue,
      'summary': _clean(summary),
      'follow_up_plan': _clean(followUpPlan),
      'finalized_by': null,
      'finalized_at': null,
      'closed_at': null,
      'closure_reason': null,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds the finalization transition.
  static Map<String, Object?> finalizeChanges({required String finalizerId}) {
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'status': DischargeStatus.finalized.wireValue,
      'finalized_by': finalizerId,
      'finalized_at': now,
      'updated_at': now,
    };
  }

  /// Builds the draft cancellation transition.
  static Map<String, Object?> cancelChanges({required String reason}) {
    if (reason.trim().isEmpty) {
      throw const ValidationError(
        message: 'Cancelling a discharge requires a reason.',
        fieldErrors: <String, String>{'reason': 'Enter the cancel reason.'},
        code: 'discharge_cancel_reason_required',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'status': DischargeStatus.cancelled.wireValue,
      'closed_at': now,
      'closure_reason': reason.trim(),
      'updated_at': now,
    };
  }

  /// Materializes a discharge from a local row.
  factory Discharge.fromRow(Map<String, Object?> row) => Discharge(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    patientId: row['patient_id']! as String,
    encounterId: row['encounter_id']! as String,
    createdBy: row['created_by']! as String,
    dischargeCode: row['discharge_code']! as String,
    dischargeType: DischargeType.fromWire(row['discharge_type']! as String),
    status: DischargeStatus.fromWire(row['status']! as String),
    createdAt: DateTime.parse(row['created_at']! as String),
    summary: row['summary'] as String?,
    followUpPlan: row['follow_up_plan'] as String?,
    finalizedBy: row['finalized_by'] as String?,
    finalizedAt: row['finalized_at'] == null
        ? null
        : DateTime.parse(row['finalized_at']! as String),
    closedAt: row['closed_at'] == null
        ? null
        : DateTime.parse(row['closed_at']! as String),
    closureReason: row['closure_reason'] as String?,
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Patient identifier.
  final String patientId;

  /// Episode encounter identifier.
  final String encounterId;

  /// Authoring clinician.
  final String createdBy;

  /// Tenant-scoped discharge code.
  final String dischargeCode;

  /// Disposition.
  final DischargeType dischargeType;

  /// Current record state.
  final DischargeStatus status;

  /// When created.
  final DateTime createdAt;

  /// Discharge summary content.
  final String? summary;

  /// Follow-up instructions.
  final String? followUpPlan;

  /// Authorizer, once finalized.
  final String? finalizedBy;

  /// Authorization time.
  final DateTime? finalizedAt;

  /// Cancellation timestamp, if cancelled.
  final DateTime? closedAt;

  /// Cancellation reason, if cancelled.
  final String? closureReason;

  static String? _clean(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
