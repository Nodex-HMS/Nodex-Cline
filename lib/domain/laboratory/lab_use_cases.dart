/// Laboratory workflow use cases (Module 17).
library;

import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/laboratory/lab.dart';
import 'package:nodex_hms/domain/laboratory/lab_repository.dart';

/// Creates a laboratory order.
final class CreateLabOrderUseCase {
  /// Creates the use case.
  CreateLabOrderUseCase({required this._repository});

  final LabRepository _repository;

  /// Creates an order locally.
  Future<String> call({
    required AuthorizationPolicy policy,
    required String tenantId,
    required String patientId,
    required String orderedBy,
    required String orderCode,
    required LabPriority priority,
    required List<LabTestRequest> tests,
    String? encounterId,
    String? clinicalIndication,
  }) async {
    policy.require(NodexPermissions.labOrderWrite);
    return _repository.createOrder(
      LabOrder.orderRow(
        tenantId: tenantId,
        patientId: patientId,
        orderedBy: orderedBy,
        orderCode: orderCode,
        priority: priority,
        tests: tests,
        encounterId: encounterId,
        clinicalIndication: clinicalIndication,
      ),
    );
  }
}

/// Registers a specimen and its accession barcode.
final class RegisterSpecimenUseCase {
  /// Creates the use case.
  RegisterSpecimenUseCase({required this._repository});

  final LabRepository _repository;

  /// Creates the pending specimen.
  Future<String> call({
    required AuthorizationPolicy policy,
    required String tenantId,
    required String labOrderId,
    required String accessionBarcode,
    required String specimenType,
  }) async {
    policy.require(NodexPermissions.labResultEnter);
    return _repository.createSpecimen(
      LabSpecimen.pendingRow(
        tenantId: tenantId,
        labOrderId: labOrderId,
        accessionBarcode: accessionBarcode,
        specimenType: specimenType,
      ),
    );
  }
}

/// Records the collection event for a specimen.
final class CollectSpecimenUseCase {
  /// Creates the use case.
  CollectSpecimenUseCase({required this._repository});

  final LabRepository _repository;

  /// Marks the specimen collected by [collectorId].
  Future<void> call({
    required AuthorizationPolicy policy,
    required String specimenId,
    required String collectorId,
  }) async {
    policy.require(NodexPermissions.labResultEnter);
    await _repository.collectSpecimen(
      specimenId,
      LabSpecimen.collectChanges(collectorId: collectorId),
    );
  }
}

/// Enters an unverified laboratory result.
final class EnterLabResultUseCase {
  /// Creates the use case.
  EnterLabResultUseCase({required this._repository});

  final LabRepository _repository;

  /// Enters a result for later verification.
  Future<String> call({
    required AuthorizationPolicy policy,
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
  }) async {
    policy.require(NodexPermissions.labResultEnter);
    return _repository.enterResult(
      LabResult.enteredRow(
        tenantId: tenantId,
        labOrderId: labOrderId,
        specimenId: specimenId,
        analyteCode: analyteCode,
        analyteName: analyteName,
        enteredBy: enteredBy,
        valueText: valueText,
        valueNumeric: valueNumeric,
        unit: unit,
        referenceRange: referenceRange,
        abnormalFlag: abnormalFlag,
      ),
    );
  }
}

/// Verifies a result and makes it immutable.
final class VerifyLabResultUseCase {
  /// Creates the use case.
  VerifyLabResultUseCase({required this._repository});

  final LabRepository _repository;

  /// Verifies [result], refusing a result that is not still entered.
  Future<void> call({
    required AuthorizationPolicy policy,
    required LabResult result,
    required String verifierId,
  }) async {
    policy.require(NodexPermissions.labResultVerify);
    if (!result.status.isEditable) {
      throw const AuthorizationError(
        message: 'This laboratory result is already immutable.',
        code: 'lab_result_immutable',
      );
    }
    await _repository.verifyResult(
      result.id,
      LabResult.verifyChanges(verifierId: verifierId),
    );
  }
}

/// Creates an explicit correction row for a verified result.
final class CorrectLabResultUseCase {
  /// Creates the use case.
  CorrectLabResultUseCase({required this._repository});

  final LabRepository _repository;

  /// Creates a new corrected result linked to [original].
  Future<String> call({
    required AuthorizationPolicy policy,
    required LabResult original,
    required String enteredBy,
    required String valueText,
    required String reason,
  }) async {
    policy.require(NodexPermissions.labResultEnter);
    if (reason.trim().isEmpty) {
      throw const ValidationError(
        message: 'A laboratory correction requires a reason.',
        fieldErrors: <String, String>{'reason': 'Enter the correction reason.'},
        code: 'lab_correction_reason_required',
      );
    }
    if (!original.status.isSignedLike) {
      throw const AuthorizationError(
        message: 'Only a verified result can receive a correction.',
        code: 'lab_result_not_verified',
      );
    }

    final String now = DateTime.now().toUtc().toIso8601String();
    return _repository.correctResult(<String, Object?>{
      'tenant_id': original.tenantId,
      'lab_order_id': original.labOrderId,
      'specimen_id': original.specimenId,
      'analyte_code': original.analyteCode,
      'analyte_name': original.analyteName,
      'value_text': valueText.trim(),
      'value_numeric': null,
      'unit': original.unit,
      'reference_range': original.referenceRange,
      'abnormal_flag': original.abnormalFlag,
      'status': LabResultStatus.corrected.wireValue,
      'entered_by': enteredBy,
      'verified_by': enteredBy,
      'entered_at': now,
      'verified_at': now,
      'correction_of': original.id,
      'correction_reason': reason.trim(),
      'created_at': now,
    });
  }
}

extension on LabResultStatus {
  /// Whether the result has reached an immutable clinical state.
  bool get isSignedLike =>
      this == LabResultStatus.verified || this == LabResultStatus.corrected;
}
