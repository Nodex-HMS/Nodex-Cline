/// Bed allocation use cases (Module 11).
library;

import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/beds/bed.dart';
import 'package:nodex_hms/domain/beds/bed_repository.dart';

/// Registers a bed. Beds are master data owned by ward administration.
final class RegisterBedUseCase {
  /// Creates the use case.
  RegisterBedUseCase({required this._repository});

  final BedRepository _repository;

  /// Registers the bed locally.
  Future<String> call({
    required AuthorizationPolicy policy,
    required String tenantId,
    required String wardId,
    required String bedCode,
    required BedType bedType,
  }) async {
    policy.require(NodexPermissions.wardAdminister);
    return _repository.registerBed(
      Bed.registerRow(
        tenantId: tenantId,
        wardId: wardId,
        bedCode: bedCode,
        bedType: bedType,
      ),
    );
  }
}

/// Toggles bed availability (maintenance rotation).
final class SetBedStatusUseCase {
  /// Creates the use case.
  SetBedStatusUseCase({required this._repository});

  final BedRepository _repository;

  /// Applies the transition, refusing to take an occupied bed offline.
  Future<void> call({
    required AuthorizationPolicy policy,
    required Bed bed,
    required BedStatus status,
  }) async {
    policy.require(NodexPermissions.wardAdminister);
    if (status == BedStatus.maintenance) {
      final BedAssignment? occupant = await _repository.activeAssignmentForBed(
        bed.id,
      );
      if (occupant != null) {
        throw const AuthorizationError(
          message: 'An occupied bed cannot go to maintenance.',
          code: 'bed_occupied',
        );
      }
    }
    await _repository.updateBed(bed.id, Bed.statusChanges(status: status));
  }
}

/// Assigns a patient to a bed.
final class AssignBedUseCase {
  /// Creates the use case.
  AssignBedUseCase({required this._repository});

  final BedRepository _repository;

  /// Assigns [patientId] to [bed], refusing maintenance beds and patients
  /// who already hold one. The exclusion constraints arbitrate races on
  /// upload; this check fails fast locally.
  Future<String> call({
    required AuthorizationPolicy policy,
    required Bed bed,
    required String patientId,
    required String assignedBy,
    String? encounterId,
  }) async {
    policy.require(NodexPermissions.bedAssign);
    if (bed.status != BedStatus.available) {
      throw const AuthorizationError(
        message: 'Only available beds accept occupants.',
        code: 'bed_not_available',
      );
    }
    if (patientId.isEmpty) {
      throw const ValidationError(
        message: 'Assignment requires a patient.',
        code: 'bed_assignment_invalid',
      );
    }
    final BedAssignment? bedOccupant = await _repository.activeAssignmentForBed(
      bed.id,
    );
    if (bedOccupant != null) {
      throw const AuthorizationError(
        message: 'This bed is already occupied.',
        code: 'bed_occupied',
      );
    }
    final BedAssignment? patientStay = await _repository
        .activeAssignmentForPatient(patientId);
    if (patientStay != null) {
      throw const AuthorizationError(
        message: 'This patient already holds a bed; release it first.',
        code: 'bed_patient_occupied',
      );
    }
    return _repository.assignBed(
      BedAssignment.assignRow(
        tenantId: bed.tenantId,
        bedId: bed.id,
        patientId: patientId,
        assignedBy: assignedBy,
        encounterId: encounterId,
      ),
    );
  }
}

/// Releases a bed, ending the stay with a reason.
final class ReleaseBedUseCase {
  /// Creates the use case.
  ReleaseBedUseCase({required this._repository});

  final BedRepository _repository;

  /// Releases [assignment], refusing records that already closed.
  Future<void> call({
    required AuthorizationPolicy policy,
    required BedAssignment assignment,
    required String reason,
    bool cancelled = false,
  }) async {
    policy.require(NodexPermissions.bedAssign);
    if (!assignment.status.isActive) {
      throw const AuthorizationError(
        message: 'This assignment is already closed.',
        code: 'bed_assignment_closed',
      );
    }
    await _repository.updateAssignment(
      assignment.id,
      BedAssignment.closeChanges(
        closure: cancelled
            ? BedAssignmentStatus.cancelled
            : BedAssignmentStatus.released,
        reason: reason,
      ),
    );
  }
}

/// Transfers a patient: releases the old stay before creating the new one,
/// so a crash leaves a visibly bedless patient, never a double allocation.
final class TransferBedUseCase {
  /// Creates the use case.
  TransferBedUseCase({required this._repository});

  final BedRepository _repository;

  /// Transfers [patientId] from [from] to [toBed].
  Future<String> call({
    required AuthorizationPolicy policy,
    required BedAssignment from,
    required Bed toBed,
    required String patientId,
    required String assignedBy,
    required String reason,
  }) async {
    policy.require(NodexPermissions.bedAssign);
    await ReleaseBedUseCase(repository: _repository)
        .call(policy: policy, assignment: from, reason: reason);
    final Bed? target = await _repository.getBed(toBed.id);
    if (target == null) {
      throw const PersistenceError(
        message: 'The destination bed is not available on this device.',
        code: 'bed_not_found_locally',
      );
    }
    return AssignBedUseCase(repository: _repository).call(
      policy: policy,
      bed: target,
      patientId: patientId,
      assignedBy: assignedBy,
    );
  }
}
