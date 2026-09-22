/// Bed and occupancy assignment entities (Module 11).
///
/// Beds are ward master data; occupancy derives from the active assignment,
/// never stored twice. Allocation is server-arbitrated: at most one active
/// assignment per bed and per patient.
// ignore_for_file: sort_constructors_first
library;

import 'package:meta/meta.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';

/// Bed availability. Occupancy is derived, never stored: "occupied" is the
/// presence of an active assignment row, so the two cannot disagree.
enum BedStatus {
  /// Accepts occupants.
  available('available'),

  /// Out of service; holds no one.
  maintenance('maintenance');

  const BedStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Parses a stored value.
  static BedStatus fromWire(String value) => BedStatus.values.firstWhere(
    (BedStatus status) => status.wireValue == value,
    orElse: () => BedStatus.available,
  );
}

/// Bed type, mirroring the ward type vocabulary.
enum BedType {
  /// General ward bed.
  general('general'),

  /// Private room bed.
  private('private'),

  /// Intensive care bed.
  icu('icu'),

  /// High dependency bed.
  hdu('hdu'),

  /// Emergency bed.
  emergency('emergency'),

  /// Maternity bed.
  maternity('maternity'),

  /// Paediatric bed.
  paediatric('paediatric'),

  /// Isolation bed.
  isolation('isolation'),

  /// Any other bed.
  other('other');

  const BedType(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Human-readable label.
  String get label => switch (this) {
    BedType.general => 'General',
    BedType.private => 'Private',
    BedType.icu => 'ICU',
    BedType.hdu => 'HDU',
    BedType.emergency => 'Emergency',
    BedType.maternity => 'Maternity',
    BedType.paediatric => 'Paediatric',
    BedType.isolation => 'Isolation',
    BedType.other => 'Other',
  };

  /// Parses a stored value.
  static BedType fromWire(String value) => BedType.values.firstWhere(
    (BedType type) => type.wireValue == value,
    orElse: () => BedType.general,
  );
}

/// Occupancy assignment lifecycle.
enum BedAssignmentStatus {
  /// Patient holds the bed.
  active('active'),

  /// Stay ended with a reason.
  released('released'),

  /// Mistaken entry, retired with a reason.
  cancelled('cancelled');

  const BedAssignmentStatus(this.wireValue);

  /// Stored value.
  final String wireValue;

  /// Whether the assignment still holds the bed.
  bool get isActive => this == BedAssignmentStatus.active;

  /// Parses a stored value.
  static BedAssignmentStatus fromWire(String value) =>
      BedAssignmentStatus.values.firstWhere(
        (BedAssignmentStatus status) => status.wireValue == value,
        orElse: () => BedAssignmentStatus.active,
      );
}

/// Ward bed.
@immutable
final class Bed {
  /// Creates a bed.
  const Bed({
    required this.id,
    required this.tenantId,
    required this.wardId,
    required this.bedCode,
    required this.bedType,
    required this.status,
  });

  /// Validates and builds a new bed row. Beds are master data: registration
  /// requires ward administration, while allocation needs only bed.assign.
  static Map<String, Object?> registerRow({
    required String tenantId,
    required String wardId,
    required String bedCode,
    required BedType bedType,
  }) {
    final Map<String, String> fieldErrors = <String, String>{};
    if (tenantId.isEmpty) {
      fieldErrors['tenant_id'] = 'Tenant is required.';
    }
    if (wardId.isEmpty) {
      fieldErrors['ward_id'] = 'Ward is required.';
    }
    if (bedCode.trim().isEmpty) {
      fieldErrors['bed_code'] = 'Bed code is required.';
    }
    if (fieldErrors.isNotEmpty) {
      throw ValidationError(
        message: 'Bed registration failed validation.',
        fieldErrors: fieldErrors,
        code: 'bed_invalid',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'ward_id': wardId,
      'bed_code': bedCode.trim(),
      'bed_type': bedType.wireValue,
      'status': BedStatus.available.wireValue,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds the availability transition.
  static Map<String, Object?> statusChanges({required BedStatus status}) =>
      <String, Object?>{
        'status': status.wireValue,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  /// Materializes a bed from a local row.
  factory Bed.fromRow(Map<String, Object?> row) => Bed(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    wardId: row['ward_id']! as String,
    bedCode: row['bed_code']! as String,
    bedType: BedType.fromWire(row['bed_type']! as String),
    status: BedStatus.fromWire(row['status']! as String),
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Ward identifier.
  final String wardId;

  /// Bed code within the ward.
  final String bedCode;

  /// Bed type.
  final BedType bedType;

  /// Availability.
  final BedStatus status;
}

/// Occupancy assignment of a patient to a bed.
@immutable
final class BedAssignment {
  /// Creates an assignment.
  const BedAssignment({
    required this.id,
    required this.tenantId,
    required this.bedId,
    required this.patientId,
    required this.assignedBy,
    required this.status,
    required this.admittedAt,
    this.encounterId,
    this.releasedAt,
    this.releaseReason,
  });

  /// Builds a new active assignment row.
  static Map<String, Object?> assignRow({
    required String tenantId,
    required String bedId,
    required String patientId,
    required String assignedBy,
    String? encounterId,
  }) {
    if (tenantId.isEmpty ||
        bedId.isEmpty ||
        patientId.isEmpty ||
        assignedBy.isEmpty) {
      throw const ValidationError(
        message: 'Assignment is missing a required identity field.',
        code: 'bed_assignment_invalid',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'tenant_id': tenantId,
      'bed_id': bedId,
      'patient_id': patientId,
      'encounter_id': encounterId,
      'assigned_by': assignedBy,
      'status': BedAssignmentStatus.active.wireValue,
      'admitted_at': now,
      'released_at': null,
      'release_reason': null,
      'created_at': now,
      'updated_at': now,
    };
  }

  /// Builds the release (or mistaken-entry cancellation) transition.
  static Map<String, Object?> closeChanges({
    required BedAssignmentStatus closure,
    required String reason,
  }) {
    if (closure == BedAssignmentStatus.active) {
      throw const ValidationError(
        message: 'Closing an assignment requires a terminal state.',
        code: 'bed_assignment_invalid',
      );
    }
    if (reason.trim().isEmpty) {
      throw const ValidationError(
        message: 'Closing an assignment requires a reason.',
        fieldErrors: <String, String>{'reason': 'Enter the release reason.'},
        code: 'bed_assignment_reason_required',
      );
    }
    final String now = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'status': closure.wireValue,
      'released_at': now,
      'release_reason': reason.trim(),
      'updated_at': now,
    };
  }

  /// Materializes an assignment from a local row.
  factory BedAssignment.fromRow(Map<String, Object?> row) => BedAssignment(
    id: row['id']! as String,
    tenantId: row['tenant_id']! as String,
    bedId: row['bed_id']! as String,
    patientId: row['patient_id']! as String,
    assignedBy: row['assigned_by']! as String,
    status: BedAssignmentStatus.fromWire(row['status']! as String),
    admittedAt: DateTime.parse(row['admitted_at']! as String),
    encounterId: row['encounter_id'] as String?,
    releasedAt: row['released_at'] == null
        ? null
        : DateTime.parse(row['released_at']! as String),
    releaseReason: row['release_reason'] as String?,
  );

  /// Database identifier.
  final String id;

  /// Tenant identifier.
  final String tenantId;

  /// Bed identifier.
  final String bedId;

  /// Occupant.
  final String patientId;

  /// Assigning user.
  final String assignedBy;

  /// Current assignment state.
  final BedAssignmentStatus status;

  /// Admission time.
  final DateTime admittedAt;

  /// Linked encounter, when the stay has one.
  final String? encounterId;

  /// Release time.
  final DateTime? releasedAt;

  /// Release reason.
  final String? releaseReason;
}
