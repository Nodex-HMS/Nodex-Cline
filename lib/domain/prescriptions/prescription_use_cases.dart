/// Prescription and pharmacy use cases (Module 25).
library;

import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:nodex_hms/domain/prescriptions/prescription_repository.dart';

/// Drafts a new prescription order (version 1).
final class DraftPrescriptionUseCase {
  /// Creates the use case.
  DraftPrescriptionUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Drafts an order locally.
  Future<String> call({
    required AuthorizationPolicy policy,
    required String tenantId,
    required String patientId,
    required String prescribedBy,
    required String prescriptionCode,
    required PrescriptionPriority priority,
    String? encounterId,
    String? indication,
  }) async {
    policy.require(NodexPermissions.prescriptionDraft);
    return _repository.createPrescription(
      Prescription.draftRow(
        tenantId: tenantId,
        patientId: patientId,
        prescribedBy: prescribedBy,
        prescriptionCode: prescriptionCode,
        priority: priority,
        encounterId: encounterId,
        indication: indication,
      ),
    );
  }
}

/// Adds a medication line to a draft order.
final class AddPrescriptionItemUseCase {
  /// Creates the use case.
  AddPrescriptionItemUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Adds the line, refusing a parent that is no longer a draft.
  Future<String> call({
    required AuthorizationPolicy policy,
    required Prescription prescription,
    required int lineNumber,
    required String drugCode,
    required String drugName,
    required String dosageText,
    required double quantityPrescribed,
    String? strength,
    String? route,
    String? frequency,
    int? durationDays,
  }) async {
    policy.require(NodexPermissions.prescriptionDraft);
    if (!prescription.status.isEditable) {
      throw const AuthorizationError(
        message: 'Lines can only be added to a draft prescription.',
        code: 'prescription_not_draft',
      );
    }
    return _repository.addItem(
      PrescriptionItem.draftRow(
        tenantId: prescription.tenantId,
        prescriptionId: prescription.id,
        lineNumber: lineNumber,
        drugCode: drugCode,
        drugName: drugName,
        dosageText: dosageText,
        quantityPrescribed: quantityPrescribed,
        strength: strength,
        route: route,
        frequency: frequency,
        durationDays: durationDays,
      ),
    );
  }
}

/// Finalizes a draft, authorizing dispensing.
final class FinalizePrescriptionUseCase {
  /// Creates the use case.
  FinalizePrescriptionUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Finalizes [prescription], refusing anything but a draft.
  Future<void> call({
    required AuthorizationPolicy policy,
    required Prescription prescription,
    required String finalizerId,
  }) async {
    policy.require(NodexPermissions.prescriptionFinalize);
    if (!prescription.status.isEditable) {
      throw const AuthorizationError(
        message: 'Only a draft prescription can be finalized.',
        code: 'prescription_not_draft',
      );
    }
    await _repository.updatePrescription(
      prescription.id,
      Prescription.finalizeChanges(finalizerId: finalizerId),
    );
  }
}

/// Drafts a successor version of a finalized order.
final class SupersedePrescriptionUseCase {
  /// Creates the use case.
  SupersedePrescriptionUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Creates the successor draft, then marks [original] superseded. The new
  /// version lands first so a crash leaves a dangling draft, never a version
  /// gap — mirroring the encounter amend ordering.
  Future<String> call({
    required AuthorizationPolicy policy,
    required Prescription original,
    required List<PrescriptionItem> carriedLines,
    required PrescriptionPriority priority,
    String? indication,
  }) async {
    policy.require(NodexPermissions.prescriptionFinalize);
    final String successorId = await _repository.createPrescription(
      Prescription.nextVersionRow(
        original: original,
        priority: priority,
        indication: indication,
      ),
    );
    var lineNumber = 0;
    for (final PrescriptionItem line in carriedLines) {
      lineNumber += 1;
      await _repository.addItem(
        PrescriptionItem.draftRow(
          tenantId: line.tenantId,
          prescriptionId: successorId,
          lineNumber: lineNumber,
          drugCode: line.drugCode,
          drugName: line.drugName,
          dosageText: line.dosageText,
          quantityPrescribed: line.quantityPrescribed,
          strength: line.strength,
          route: line.route,
          frequency: line.frequency,
          durationDays: line.durationDays,
        ),
      );
    }
    await _repository.updatePrescription(
      original.id,
      Prescription.supersedeChanges(successorId: successorId),
    );
    return successorId;
  }
}

/// Closes an order: cancels a draft, discontinues a finalized order.
final class ClosePrescriptionUseCase {
  /// Creates the use case.
  ClosePrescriptionUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Closes [prescription] with [reason].
  Future<void> call({
    required AuthorizationPolicy policy,
    required Prescription prescription,
    required String reason,
  }) async {
    final PrescriptionStatus closure = switch (prescription.status) {
      PrescriptionStatus.draft => PrescriptionStatus.cancelled,
      PrescriptionStatus.finalized => PrescriptionStatus.discontinued,
      PrescriptionStatus.superseded ||
      PrescriptionStatus.discontinued ||
      PrescriptionStatus.cancelled => throw const AuthorizationError(
        message: 'This prescription is already closed.',
        code: 'prescription_already_closed',
      ),
    };
    policy.require(
      closure == PrescriptionStatus.discontinued
          ? NodexPermissions.prescriptionFinalize
          : NodexPermissions.prescriptionDraft,
    );
    await _repository.updatePrescription(
      prescription.id,
      Prescription.closeChanges(closure: closure, reason: reason),
    );
  }
}

/// Records a pharmacy dispense event and advances the line.
final class RecordDispenseUseCase {
  /// Creates the use case.
  RecordDispenseUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Records the event, refusing lines that are not released. The line moves
  /// to dispensed once the cumulative quantity covers the order.
  Future<String> call({
    required AuthorizationPolicy policy,
    required PrescriptionItem item,
    required String dispensedBy,
    required double quantityDispensed,
    String? batchNumber,
    String? note,
  }) async {
    policy.require(NodexPermissions.pharmacyDispense);
    if (item.status != PrescriptionItemStatus.ordered &&
        item.status != PrescriptionItemStatus.partiallyDispensed) {
      throw const AuthorizationError(
        message: 'Only a released line can be dispensed.',
        code: 'prescription_item_not_released',
      );
    }
    final List<PharmacyDispense> prior = await _repository.listDispenses(
      item.id,
    );
    final double dispensedSoFar = prior.fold<double>(
      0,
      (double total, PharmacyDispense event) => total + event.quantityDispensed,
    );
    final String dispenseId = await _repository.recordDispense(
      PharmacyDispense.eventRow(
        tenantId: item.tenantId,
        prescriptionId: item.prescriptionId,
        itemId: item.id,
        dispensedBy: dispensedBy,
        quantityDispensed: quantityDispensed,
        batchNumber: batchNumber,
        note: note,
      ),
    );
    final bool complete =
        dispensedSoFar + quantityDispensed >= item.quantityPrescribed;
    await _repository.updateItem(
      item.id,
      PrescriptionItem.progressChanges(
        status: complete
            ? PrescriptionItemStatus.dispensed
            : PrescriptionItemStatus.partiallyDispensed,
      ),
    );
    return dispenseId;
  }
}

/// Records a bedside medication administration event.
final class RecordAdministrationUseCase {
  /// Creates the use case.
  RecordAdministrationUseCase({required this._repository});

  final PrescriptionRepository _repository;

  /// Records the event. Administration stays available offline by design:
  /// bedside actions happen where connectivity cannot be assumed.
  Future<String> call({
    required AuthorizationPolicy policy,
    required PrescriptionItem item,
    required String patientId,
    required String administeredBy,
    required String doseText,
    String? dispenseId,
    String? route,
    String? site,
    String? note,
  }) async {
    policy.require(NodexPermissions.medicationAdminister);
    return _repository.recordAdministration(
      MedicationAdministration.eventRow(
        tenantId: item.tenantId,
        patientId: patientId,
        prescriptionId: item.prescriptionId,
        itemId: item.id,
        administeredBy: administeredBy,
        doseText: doseText,
        dispenseId: dispenseId,
        route: route,
        site: site,
        note: note,
      ),
    );
  }
}
