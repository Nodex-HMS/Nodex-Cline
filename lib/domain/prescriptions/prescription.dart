/// Prescription and pharmacy dispensing entities (Module 25).
///
/// The lifecycle is intentionally explicit: draft -> finalized -> dispensed,
/// with a change producing a new version that supersedes the prior order.
/// A finalized order stays readable exactly as authorized; dispensing and
/// medication administration are immutable event rows.
// ignore_for_file: sort_constructors_first
library;

import 'package:meta/meta.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';

/// Priority of a prescription order.
enum PrescriptionPriority {
  /// Normal turnaround.
  routine('routine'),

  /// Expedited turnaround.
  urgent('urgent'),

  /// Immediate clinical priority.
  stat('stat');

  const PrescriptionPriority(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Human-readable label.
  String get label => switch (this) {
    PrescriptionPriority.routine => 'Routine',
    PrescriptionPriority.urgent => 'Urgent',
    PrescriptionPriority.stat => 'STAT',
  };

  /// Parses a stored value.
  static PrescriptionPriority fromWire(String value) =>
      PrescriptionPriority.values.firstWhere(
        (PrescriptionPriority priority) => priority.wireValue == value,
        orElse: () => PrescriptionPriority.routine,
      );
}

/// Prescription order lifecycle.
enum PrescriptionStatus {
  /// Editable draft, not yet authorized.
  draft('draft'),

  /// Authorized and immutable; dispensing may proceed.
  finalized('finalized'),

  /// Replaced by a newer version, kept readable as authorized.
  superseded('superseded'),

  /// Stopped with a reason.
  discontinued('discontinued'),

  /// Cancelled with a reason before completion.
  cancelled('cancelled');

  const PrescriptionStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Whether the order can still be edited.
  bool get isEditable => this == PrescriptionStatus.draft;

  /// Whether the order reached a terminal state.
  bool get isTerminal =>
      this == PrescriptionStatus.superseded ||
      this == PrescriptionStatus.discontinued ||
      this == PrescriptionStatus.cancelled;

  /// Parses a stored value.
  static PrescriptionStatus fromWire(String value) =>
      PrescriptionStatus.values.firstWhere(
        (PrescriptionStatus status) => status.wireValue == value,
        orElse: () => PrescriptionStatus.draft,
      );
}

/// Prescription line lifecycle.
enum PrescriptionItemStatus {
  /// On a draft order.
  draft('draft'),

  /// Released to the pharmacy by finalization.
  ordered('ordered'),

  /// Partially dispensed.
  partiallyDispensed('partially_dispensed'),

  /// Fully dispensed.
  dispensed('dispensed'),

  /// Cancelled with the order.
  cancelled('cancelled');

  const PrescriptionItemStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Parses a stored value.
  static PrescriptionItemStatus fromWire(String value) =>
      PrescriptionItemStatus.values.firstWhere(
        (PrescriptionItemStatus status) => status.wireValue == value,
        orElse: () => PrescriptionItemStatus.draft,
      );
}

/// Prescription order header. One row per version.
@immutable
final class Prescription {
  /// Creates a prescription.
  const Prescription({
    required this.id,
    required this.tenantId,
    required this.patientId,
    required this.prescribedBy,
    required this.prescriptionCode,
    required this.version,
    required this.priority,
    required this.status,
    required this.createdAt,
    this.encounterId,
    this.indication,
    this.finalizedBy,
    this.finalizedAt,
    this.supersedes,
    this.supersededBy,
    this.closedAt,
    this.closureReason,
  });

  /// Validates and builds a new draft row (version 1).
  static Map<String, Object?> draftRow({
    required String tenantId,
    required String patientId,
    required String prescribedBy,
    required String prescriptionCode,
    required PrescriptionPriority priority,
    String? encounterId,
    String? indication,
  }) {
    final Map<String, String> fieldErrors = <String, String>{};
    if (tenantId.isEmpty) {
      fieldErrors['tenant_id'] = 'Tenant is required.';
    }
    if (patientId.isEmpty) {
      fieldErrors['patient_id'] = 'Patient is required.';
    }
    if (prescribedBy.isEmpty) {
      fieldErrors['prescribed_by'] = 'Prescribing clinician is required.';
    }
    if (prescriptionCode.trim().isEmpty) {
      fieldErrors['prescription_code'] = 'Prescription code is required.';
    }
    if (fieldErrors.isNotEmpty) {
      throw ValidationError(
        message: 'Prescription draft failed validation.',
        fieldErrors: fieldErrors,
        code: 'prescription_invalid',
      );
    }

    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'patient_id': patientId,
      'encounter_id': encounterId,
      'prescribed_by': prescribedBy,
      'prescription_code': prescriptionCode.trim(),
      'version': 1,
      'priority': priority.wireValue,
      'status': PrescriptionStatus.draft.wireValue,
      'indication': _clean(indication),
      'finalized_by': null,
      'finalized_at': null,
      'supersedes': null,
      'superseded_by': null,
      'closed_at': null,
      'closure_reason': null,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds a successor version row for [original].
  static Map<String, Object?> nextVersionRow({
    required Prescription original,
    required PrescriptionPriority priority,
    String? indication,
  }) {
    if (!original.status.isVersionable) {
      throw const AuthorizationError(
        message: 'Only a finalized prescription can receive a new version.',
        code: 'prescription_not_finalized',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': original.tenantId,
      'patient_id': original.patientId,
      'encounter_id': original.encounterId,
      'prescribed_by': original.prescribedBy,
      'prescription_code': original.prescriptionCode,
      'version': original.version + 1,
      'priority': priority.wireValue,
      'status': PrescriptionStatus.draft.wireValue,
      'indication': _clean(indication) ?? original.indication,
      'finalized_by': null,
      'finalized_at': null,
      'supersedes': original.id,
      'superseded_by': null,
      'closed_at': null,
      'closure_reason': null,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds the finalization transition.
  static Map<String, Object?> finalizeChanges({required String finalizerId}) =>
      <String, Object?>{
        'status': PrescriptionStatus.finalized.wireValue,
        'finalized_by': finalizerId,
        'finalized_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  /// Builds the supersede transition pointing at [successorId].
  static Map<String, Object?> supersedeChanges({required String successorId}) =>
      <String, Object?>{
        'status': PrescriptionStatus.superseded.wireValue,
        'superseded_by': successorId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  /// Builds the close transition (cancel a draft, discontinue an order).
  static Map<String, Object?> closeChanges({
    required PrescriptionStatus closure,
    required String reason,
  }) {
    if (reason.trim().isEmpty) {
      throw const ValidationError(
        message: 'Closing a prescription requires a reason.',
        fieldErrors: <String, String>{'reason': 'Enter the closure reason.'},
        code: 'prescription_closure_reason_required',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'status': closure.wireValue,
      'closed_at': now,
      'closure_reason': reason.trim(),
      'updated_at': now,
    };
  }

  /// Materializes a prescription from a local row.
  factory Prescription.fromRow(Map<String, Object?> row) => Prescription(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    patientId: row['patient_id']! as String,
    prescribedBy: row['prescribed_by']! as String,
    prescriptionCode: row['prescription_code']! as String,
    version: _asInt(row['version']),
    priority: PrescriptionPriority.fromWire(row['priority']! as String),
    status: PrescriptionStatus.fromWire(row['status']! as String),
    createdAt: DateTime.parse(row['created_at']! as String),
    encounterId: row['encounter_id'] as String?,
    indication: row['indication'] as String?,
    finalizedBy: row['finalized_by'] as String?,
    finalizedAt: row['finalized_at'] == null
        ? null
        : DateTime.parse(row['finalized_at']! as String),
    supersedes: row['supersedes'] as String?,
    supersededBy: row['superseded_by'] as String?,
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

  /// Prescribing clinician.
  final String prescribedBy;

  /// Tenant-scoped order series code, stable across versions.
  final String prescriptionCode;

  /// Version within the series, starting at 1.
  final int version;

  /// Turnaround priority.
  final PrescriptionPriority priority;

  /// Current order state.
  final PrescriptionStatus status;

  /// Optional encounter identifier.
  final String? encounterId;

  /// Why the medication was prescribed.
  final String? indication;

  /// Authorizer, once finalized.
  final String? finalizedBy;

  /// Authorization time.
  final DateTime? finalizedAt;

  /// Previous version id, for successor versions.
  final String? supersedes;

  /// Successor version id, once superseded.
  final String? supersededBy;

  /// Closure timestamp, if closed.
  final DateTime? closedAt;

  /// Closure reason, if closed.
  final String? closureReason;

  /// When created.
  final DateTime createdAt;

  static String? _clean(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Local integer columns arrive as int or numeric text depending on the
  /// projection; the mutation path requires real integers.
  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.parse(raw! as String);
  }
}

/// One medication line on a prescription.
@immutable
final class PrescriptionItem {
  /// Creates an item.
  const PrescriptionItem({
    required this.id,
    required this.tenantId,
    required this.prescriptionId,
    required this.lineNumber,
    required this.drugCode,
    required this.drugName,
    required this.dosageText,
    required this.quantityPrescribed,
    required this.status,
    this.strength,
    this.route,
    this.frequency,
    this.durationDays,
  });

  /// Builds a draft line row.
  static Map<String, Object?> draftRow({
    required String tenantId,
    required String prescriptionId,
    required int lineNumber,
    required String drugCode,
    required String drugName,
    required String dosageText,
    required double quantityPrescribed,
    String? strength,
    String? route,
    String? frequency,
    int? durationDays,
  }) {
    final Map<String, String> fieldErrors = <String, String>{};
    if (tenantId.isEmpty) {
      fieldErrors['tenant_id'] = 'Tenant is required.';
    }
    if (prescriptionId.isEmpty) {
      fieldErrors['prescription_id'] = 'Prescription is required.';
    }
    if (lineNumber <= 0) {
      fieldErrors['line_number'] = 'Line number must be positive.';
    }
    if (drugCode.trim().isEmpty) {
      fieldErrors['drug_code'] = 'Drug code is required.';
    }
    if (drugName.trim().isEmpty) {
      fieldErrors['drug_name'] = 'Drug name is required.';
    }
    if (dosageText.trim().isEmpty) {
      fieldErrors['dosage_text'] = 'Dosage is required.';
    }
    if (quantityPrescribed <= 0) {
      fieldErrors['quantity_prescribed'] = 'Quantity must be positive.';
    }
    if (durationDays != null && durationDays <= 0) {
      fieldErrors['duration_days'] = 'Duration must be positive.';
    }
    if (fieldErrors.isNotEmpty) {
      throw ValidationError(
        message: 'Prescription line failed validation.',
        fieldErrors: fieldErrors,
        code: 'prescription_item_invalid',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'prescription_id': prescriptionId,
      'line_number': lineNumber,
      'drug_code': drugCode.trim(),
      'drug_name': drugName.trim(),
      'strength': strength?.trim(),
      'dosage_text': dosageText.trim(),
      'route': route?.trim(),
      'frequency': frequency?.trim(),
      'duration_days': durationDays,
      'quantity_prescribed': quantityPrescribed,
      'status': PrescriptionItemStatus.draft.wireValue,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds the dispense-progression transition.
  static Map<String, Object?> progressChanges({
    required PrescriptionItemStatus status,
  }) => <String, Object?>{
    'status': status.wireValue,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };

  /// Materializes an item from a local row.
  factory PrescriptionItem.fromRow(Map<String, Object?> row) =>
      PrescriptionItem(
        id: row['id']! as String,
        tenantId: row['tenant_id']! as String,
        prescriptionId: row['prescription_id']! as String,
        lineNumber: Prescription._asInt(row['line_number']),
        drugCode: row['drug_code']! as String,
        drugName: row['drug_name']! as String,
        dosageText: row['dosage_text']! as String,
        quantityPrescribed: (row['quantity_prescribed'] as num).toDouble(),
        status: PrescriptionItemStatus.fromWire(row['status']! as String),
        strength: row['strength'] as String?,
        route: row['route'] as String?,
        frequency: row['frequency'] as String?,
        durationDays: row['duration_days'] == null
            ? null
            : Prescription._asInt(row['duration_days']),
      );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Parent prescription identifier.
  final String prescriptionId;

  /// Stable line position within the order.
  final int lineNumber;

  /// Formulary drug code.
  final String drugCode;

  /// Display drug name.
  final String drugName;

  /// Dosage instruction.
  final String dosageText;

  /// Ordered quantity.
  final double quantityPrescribed;

  /// Current line state.
  final PrescriptionItemStatus status;

  /// Strength, e.g. 500mg.
  final String? strength;

  /// Administration route.
  final String? route;

  /// Frequency, e.g. twice daily.
  final String? frequency;

  /// Duration in days.
  final int? durationDays;
}

/// One pharmacy dispense event against a line. Immutable once recorded.
@immutable
final class PharmacyDispense {
  /// Creates a dispense event.
  const PharmacyDispense({
    required this.id,
    required this.tenantId,
    required this.prescriptionId,
    required this.itemId,
    required this.dispensedBy,
    required this.quantityDispensed,
    required this.dispensedAt,
    this.batchNumber,
    this.note,
  });

  /// Builds a dispense event row.
  static Map<String, Object?> eventRow({
    required String tenantId,
    required String prescriptionId,
    required String itemId,
    required String dispensedBy,
    required double quantityDispensed,
    String? batchNumber,
    String? note,
  }) {
    if (tenantId.isEmpty ||
        prescriptionId.isEmpty ||
        itemId.isEmpty ||
        dispensedBy.isEmpty) {
      throw const ValidationError(
        message: 'Dispense is missing a required identity field.',
        code: 'dispense_invalid',
      );
    }
    if (quantityDispensed <= 0) {
      throw const ValidationError(
        message: 'Dispensed quantity must be positive.',
        fieldErrors: <String, String>{
          'quantity_dispensed': 'Enter a positive quantity.',
        },
        code: 'dispense_quantity_required',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'prescription_id': prescriptionId,
      'item_id': itemId,
      'dispensed_by': dispensedBy,
      'quantity_dispensed': quantityDispensed,
      'batch_number': batchNumber?.trim(),
      'note': note?.trim(),
      'dispensed_at': now,
      'created_at': now,
    };
  }

  /// Materializes a dispense event from a local row.
  factory PharmacyDispense.fromRow(Map<String, Object?> row) =>
      PharmacyDispense(
        id: row['id']! as String,
        tenantId: row['tenant_id']! as String,
        prescriptionId: row['prescription_id']! as String,
        itemId: row['item_id']! as String,
        dispensedBy: row['dispensed_by']! as String,
        quantityDispensed: (row['quantity_dispensed'] as num).toDouble(),
        dispensedAt: DateTime.parse(row['dispensed_at']! as String),
        batchNumber: row['batch_number'] as String?,
        note: row['note'] as String?,
      );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Parent prescription identifier.
  final String prescriptionId;

  /// Dispensed line identifier.
  final String itemId;

  /// Dispensing pharmacist.
  final String dispensedBy;

  /// Quantity handed over.
  final double quantityDispensed;

  /// When dispensed.
  final DateTime dispensedAt;

  /// Stock batch, when tracked.
  final String? batchNumber;

  /// Dispense note.
  final String? note;
}

/// One medication administration event. Immutable once recorded.
@immutable
final class MedicationAdministration {
  /// Creates an administration event.
  const MedicationAdministration({
    required this.id,
    required this.tenantId,
    required this.patientId,
    required this.prescriptionId,
    required this.itemId,
    required this.administeredBy,
    required this.doseText,
    required this.administeredAt,
    this.dispenseId,
    this.route,
    this.site,
    this.note,
  });

  /// Builds an administration event row.
  static Map<String, Object?> eventRow({
    required String tenantId,
    required String patientId,
    required String prescriptionId,
    required String itemId,
    required String administeredBy,
    required String doseText,
    String? dispenseId,
    String? route,
    String? site,
    String? note,
  }) {
    if (tenantId.isEmpty ||
        patientId.isEmpty ||
        prescriptionId.isEmpty ||
        itemId.isEmpty ||
        administeredBy.isEmpty) {
      throw const ValidationError(
        message: 'Administration is missing a required identity field.',
        code: 'administration_invalid',
      );
    }
    if (doseText.trim().isEmpty) {
      throw const ValidationError(
        message: 'An administration must record the dose given.',
        fieldErrors: <String, String>{'dose_text': 'Enter the dose given.'},
        code: 'administration_dose_required',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'patient_id': patientId,
      'prescription_id': prescriptionId,
      'item_id': itemId,
      'dispense_id': dispenseId,
      'administered_by': administeredBy,
      'administered_at': now,
      'dose_text': doseText.trim(),
      'route': route?.trim(),
      'site': site?.trim(),
      'note': note?.trim(),
      'created_at': now,
    };
  }

  /// Materializes an administration event from a local row.
  factory MedicationAdministration.fromRow(Map<String, Object?> row) =>
      MedicationAdministration(
        id: row['id']! as String,
        tenantId: row['tenant_id']! as String,
        patientId: row['patient_id']! as String,
        prescriptionId: row['prescription_id']! as String,
        itemId: row['item_id']! as String,
        administeredBy: row['administered_by']! as String,
        doseText: row['dose_text']! as String,
        administeredAt: DateTime.parse(row['administered_at']! as String),
        dispenseId: row['dispense_id'] as String?,
        route: row['route'] as String?,
        site: row['site'] as String?,
        note: row['note'] as String?,
      );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Patient identifier.
  final String patientId;

  /// Parent prescription identifier.
  final String prescriptionId;

  /// Administered line identifier.
  final String itemId;

  /// Administering clinician.
  final String administeredBy;

  /// Dose given, as recorded at the bedside.
  final String doseText;

  /// When administered.
  final DateTime administeredAt;

  /// Source dispense event, when linked.
  final String? dispenseId;

  /// Administration route.
  final String? route;

  /// Administration site.
  final String? site;

  /// Administration note.
  final String? note;
}

extension on PrescriptionStatus {
  /// Whether a new version may be drafted from this order.
  bool get isVersionable => this == PrescriptionStatus.finalized;
}
