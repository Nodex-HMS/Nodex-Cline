/// Laboratory workflow entities (Module 17).
///
/// The workflow is intentionally explicit: order -> specimen collected ->
/// result entered -> verified. Verified values are immutable; a correction is
/// a new result linked through `correction_of`, preserving the original value,
/// verifier and timestamp.
// ignore_for_file: sort_constructors_first
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';

/// Priority of a laboratory order.
enum LabPriority {
  /// Normal turnaround.
  routine('routine'),

  /// Expedited turnaround.
  urgent('urgent'),

  /// Immediate clinical priority.
  stat('stat');

  const LabPriority(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Human-readable label.
  String get label => switch (this) {
    LabPriority.routine => 'Routine',
    LabPriority.urgent => 'Urgent',
    LabPriority.stat => 'STAT',
  };

  /// Parses a stored value.
  static LabPriority fromWire(String value) => LabPriority.values.firstWhere(
    (LabPriority priority) => priority.wireValue == value,
    orElse: () => LabPriority.routine,
  );
}

/// Laboratory order lifecycle.
enum LabOrderStatus {
  /// Order exists but no specimen is complete.
  ordered('ordered'),

  /// Some, but not all, requested specimens are collected.
  partiallyCollected('partially_collected'),

  /// Requested specimens are collected.
  collected('collected'),

  /// Results have completed the workflow.
  completed('completed'),

  /// Order was cancelled with a reason.
  cancelled('cancelled');

  const LabOrderStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Parses a stored value.
  static LabOrderStatus fromWire(String value) =>
      LabOrderStatus.values.firstWhere(
        (LabOrderStatus status) => status.wireValue == value,
        orElse: () => LabOrderStatus.ordered,
      );
}

/// Specimen lifecycle.
enum LabSpecimenStatus {
  /// Expected but not collected.
  pending('pending'),

  /// Collected from the patient.
  collected('collected'),

  /// Rejected with a reason.
  rejected('rejected'),

  /// Received by the laboratory.
  received('received'),

  /// Processing completed.
  processed('processed');

  const LabSpecimenStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Parses a stored value.
  static LabSpecimenStatus fromWire(String value) =>
      LabSpecimenStatus.values.firstWhere(
        (LabSpecimenStatus status) => status.wireValue == value,
        orElse: () => LabSpecimenStatus.pending,
      );
}

/// Laboratory result lifecycle.
enum LabResultStatus {
  /// Entered but not clinically verified.
  entered('entered'),

  /// Verified and immutable.
  verified('verified'),

  /// Explicit correction linked to the original.
  corrected('corrected'),

  /// Cancelled before verification.
  cancelled('cancelled');

  const LabResultStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Whether the result can still be edited.
  bool get isEditable => this == LabResultStatus.entered;

  /// Parses a stored value.
  static LabResultStatus fromWire(String value) =>
      LabResultStatus.values.firstWhere(
        (LabResultStatus status) => status.wireValue == value,
        orElse: () => LabResultStatus.entered,
      );
}

/// One requested analyte in an order.
@immutable
final class LabTestRequest {
  /// Creates a test request.
  const LabTestRequest({required this.code, required this.name});

  /// Standardized test code.
  final String code;

  /// Display name.
  final String name;

  /// JSON representation persisted in `lab_orders.tests`.
  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'name': name,
  };

  /// Parses one JSON entry.
  static LabTestRequest fromJson(Map<String, Object?> json) => LabTestRequest(
    code: json['code']! as String,
    name: json['name']! as String,
  );
}

/// Laboratory order.
@immutable
final class LabOrder {
  /// Creates an order.
  const LabOrder({
    required this.id,
    required this.tenantId,
    required this.patientId,
    required this.orderedBy,
    required this.orderCode,
    required this.priority,
    required this.status,
    required this.tests,
    required this.orderedAt,
    this.encounterId,
    this.clinicalIndication,
    this.cancelledAt,
    this.cancelledReason,
  });

  /// Validates and builds a new order row.
  static Map<String, Object?> orderRow({
    required String tenantId,
    required String patientId,
    required String orderedBy,
    required String orderCode,
    required LabPriority priority,
    required List<LabTestRequest> tests,
    String? encounterId,
    String? clinicalIndication,
  }) {
    final Map<String, String> fieldErrors = <String, String>{};
    if (tenantId.isEmpty) {
      fieldErrors['tenant_id'] = 'Tenant is required.';
    }
    if (patientId.isEmpty) {
      fieldErrors['patient_id'] = 'Patient is required.';
    }
    if (orderedBy.isEmpty) {
      fieldErrors['ordered_by'] = 'Ordering clinician is required.';
    }
    if (orderCode.trim().isEmpty) {
      fieldErrors['order_code'] = 'Order code is required.';
    }
    if (tests.isEmpty) {
      fieldErrors['tests'] = 'At least one test is required.';
    }
    if (fieldErrors.isNotEmpty) {
      throw ValidationError(
        message: 'Laboratory order failed validation.',
        fieldErrors: fieldErrors,
        code: 'lab_order_invalid',
      );
    }

    return <String, Object?>{
      'tenant_id': tenantId,
      'patient_id': patientId,
      'encounter_id': encounterId,
      'ordered_by': orderedBy,
      'order_code': orderCode.trim(),
      'priority': priority.wireValue,
      'status': LabOrderStatus.ordered.wireValue,
      'clinical_indication': _clean(clinicalIndication),
      'tests': jsonEncode(<Object?>[
        for (final LabTestRequest test in tests) test.toJson(),
      ]),
      'ordered_at': DateTime.now().toUtc().toIso8601String(),
      'cancelled_at': null,
      'cancelled_reason': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// Materializes an order from a local row.
  factory LabOrder.fromRow(Map<String, Object?> row) => LabOrder(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    patientId: row['patient_id']! as String,
    orderedBy: row['ordered_by']! as String,
    orderCode: row['order_code']! as String,
    priority: LabPriority.fromWire(row['priority']! as String),
    status: LabOrderStatus.fromWire(row['status']! as String),
    tests: _decodeTests(row['tests']),
    orderedAt: DateTime.parse(row['ordered_at']! as String),
    encounterId: row['encounter_id'] as String?,
    clinicalIndication: row['clinical_indication'] as String?,
    cancelledAt: row['cancelled_at'] == null
        ? null
        : DateTime.parse(row['cancelled_at']! as String),
    cancelledReason: row['cancelled_reason'] as String?,
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Patient identifier.
  final String patientId;

  /// Optional encounter identifier.
  final String? encounterId;

  /// Ordering clinician.
  final String orderedBy;

  /// Tenant-scoped accession/order code.
  final String orderCode;

  /// Turnaround priority.
  final LabPriority priority;

  /// Current order state.
  final LabOrderStatus status;

  /// Requested analytes.
  final List<LabTestRequest> tests;

  /// Why the tests were requested.
  final String? clinicalIndication;

  /// When ordered.
  final DateTime orderedAt;

  /// Cancellation timestamp, if cancelled.
  final DateTime? cancelledAt;

  /// Cancellation reason, if cancelled.
  final String? cancelledReason;

  static String? _clean(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static List<LabTestRequest> _decodeTests(Object? raw) {
    try {
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List<Object?>) return const <LabTestRequest>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> value) =>
                LabTestRequest.fromJson(value.cast<String, Object?>()),
          )
          .toList(growable: false);
    } on FormatException {
      return const <LabTestRequest>[];
    }
  }
}

/// Barcode-tracked specimen.
@immutable
final class LabSpecimen {
  /// Creates a specimen.
  const LabSpecimen({
    required this.id,
    required this.tenantId,
    required this.labOrderId,
    required this.accessionBarcode,
    required this.specimenType,
    required this.status,
    this.collectedBy,
    this.collectedAt,
    this.rejectionReason,
    this.receivedAt,
  });

  /// Builds a pending specimen row.
  static Map<String, Object?> pendingRow({
    required String tenantId,
    required String labOrderId,
    required String accessionBarcode,
    required String specimenType,
  }) {
    if (tenantId.isEmpty ||
        labOrderId.isEmpty ||
        accessionBarcode.trim().isEmpty ||
        specimenType.trim().isEmpty) {
      throw const ValidationError(
        message: 'Specimen requires tenant, order, barcode and type.',
        code: 'lab_specimen_invalid',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'lab_order_id': labOrderId,
      'accession_barcode': accessionBarcode.trim(),
      'specimen_type': specimenType.trim(),
      'status': LabSpecimenStatus.pending.wireValue,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds the collection transition.
  static Map<String, Object?> collectChanges({required String collectorId}) =>
      <String, Object?>{
        'status': LabSpecimenStatus.collected.wireValue,
        'collected_by': collectorId,
        'collected_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  /// Materializes a specimen from a local row.
  factory LabSpecimen.fromRow(Map<String, Object?> row) => LabSpecimen(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    labOrderId: row['lab_order_id']! as String,
    accessionBarcode: row['accession_barcode']! as String,
    specimenType: row['specimen_type']! as String,
    status: LabSpecimenStatus.fromWire(row['status']! as String),
    collectedBy: row['collected_by'] as String?,
    collectedAt: row['collected_at'] == null
        ? null
        : DateTime.parse(row['collected_at']! as String),
    rejectionReason: row['rejection_reason'] as String?,
    receivedAt: row['received_at'] == null
        ? null
        : DateTime.parse(row['received_at']! as String),
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Parent order identifier.
  final String labOrderId;

  /// Machine-readable accession barcode.
  final String accessionBarcode;

  /// Material type.
  final String specimenType;

  /// Current specimen state.
  final LabSpecimenStatus status;

  /// Collector.
  final String? collectedBy;

  /// Collection time.
  final DateTime? collectedAt;

  /// Rejection reason.
  final String? rejectionReason;

  /// Laboratory receipt time.
  final DateTime? receivedAt;
}

/// Laboratory result, immutable once verified.
@immutable
final class LabResult {
  /// Creates a result.
  const LabResult({
    required this.id,
    required this.tenantId,
    required this.labOrderId,
    required this.specimenId,
    required this.analyteCode,
    required this.analyteName,
    required this.status,
    required this.enteredBy,
    required this.enteredAt,
    this.valueText,
    this.valueNumeric,
    this.unit,
    this.referenceRange,
    this.abnormalFlag,
    this.verifiedBy,
    this.verifiedAt,
    this.correctionOf,
    this.correctionReason,
  });

  /// Builds an entered result row.
  static Map<String, Object?> enteredRow({
    required String tenantId,
    required String labOrderId,
    required String specimenId,
    required String analyteCode,
    required String analyteName,
    required String enteredBy,
    String? valueText,
    double? valueNumeric,
    String? unit,
    String? referenceRange,
    String? abnormalFlag,
  }) {
    if (tenantId.isEmpty ||
        labOrderId.isEmpty ||
        specimenId.isEmpty ||
        analyteCode.trim().isEmpty ||
        analyteName.trim().isEmpty ||
        enteredBy.isEmpty) {
      throw const ValidationError(
        message: 'Result is missing a required identity field.',
        code: 'lab_result_invalid',
      );
    }
    if (valueText == null && valueNumeric == null) {
      throw const ValidationError(
        message: 'A laboratory result must contain a text or numeric value.',
        fieldErrors: <String, String>{'value': 'Enter a result value.'},
        code: 'lab_result_value_required',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'lab_order_id': labOrderId,
      'specimen_id': specimenId,
      'analyte_code': analyteCode.trim(),
      'analyte_name': analyteName.trim(),
      'value_text': valueText?.trim(),
      'value_numeric': valueNumeric,
      'unit': unit?.trim(),
      'reference_range': referenceRange?.trim(),
      'abnormal_flag': abnormalFlag,
      'status': LabResultStatus.entered.wireValue,
      'entered_by': enteredBy,
      'entered_at': now,
      'verified_by': null,
      'verified_at': null,
      'correction_of': null,
      'correction_reason': null,
      'created_at': now,
    };
  }

  /// Builds the verification transition.
  static Map<String, Object?> verifyChanges({required String verifierId}) =>
      <String, Object?>{
        'status': LabResultStatus.verified.wireValue,
        'verified_by': verifierId,
        'verified_at': DateTime.now().toUtc().toIso8601String(),
      };

  /// Materializes a result from a local row.
  factory LabResult.fromRow(Map<String, Object?> row) => LabResult(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    labOrderId: row['lab_order_id']! as String,
    specimenId: row['specimen_id']! as String,
    analyteCode: row['analyte_code']! as String,
    analyteName: row['analyte_name']! as String,
    status: LabResultStatus.fromWire(row['status']! as String),
    enteredBy: row['entered_by']! as String,
    enteredAt: DateTime.parse(row['entered_at']! as String),
    valueText: row['value_text'] as String?,
    valueNumeric: (row['value_numeric'] as num?)?.toDouble(),
    unit: row['unit'] as String?,
    referenceRange: row['reference_range'] as String?,
    abnormalFlag: row['abnormal_flag'] as String?,
    verifiedBy: row['verified_by'] as String?,
    verifiedAt: row['verified_at'] == null
        ? null
        : DateTime.parse(row['verified_at']! as String),
    correctionOf: row['correction_of'] as String?,
    correctionReason: row['correction_reason'] as String?,
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Parent order identifier.
  final String labOrderId;

  /// Specimen identifier.
  final String specimenId;

  /// Standardized analyte code.
  final String analyteCode;

  /// Display analyte name.
  final String analyteName;

  /// Current result state.
  final LabResultStatus status;

  /// Text result.
  final String? valueText;

  /// Numeric result.
  final double? valueNumeric;

  /// Unit.
  final String? unit;

  /// Reference interval.
  final String? referenceRange;

  /// Normal/low/high/critical flag.
  final String? abnormalFlag;

  /// Entering technician.
  final String enteredBy;

  /// Entry time.
  final DateTime enteredAt;

  /// Verifier, when verified.
  final String? verifiedBy;

  /// Verification time.
  final DateTime? verifiedAt;

  /// Original result id when this row is a correction.
  final String? correctionOf;

  /// Why this corrected result replaced the original.
  final String? correctionReason;
}
