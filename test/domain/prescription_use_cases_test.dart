/// Tests for the prescription use-case gates (Module 25).
///
/// Use cases pin the authorization boundaries: drafts need
/// `prescription.draft`, finalizing and versioning need the online-only
/// `prescription.finalize`, dispensing needs `pharmacy.dispense`, and bedside
/// administration needs `medication.administer`. Finalized orders never mutate.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/authorization_snapshot.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:nodex_hms/domain/prescriptions/prescription_repository.dart';
import 'package:nodex_hms/domain/prescriptions/prescription_use_cases.dart';

import 'prescription_repository_test.dart' show FakePrescriptionStore;

/// Builds a policy holding exactly [permissions].
AuthorizationPolicy policyWith(Set<String> permissions) {
  final DateTime issuedAt = DateTime.now().toUtc();
  return AuthorizationPolicy(
    snapshot: AuthorizationSnapshot(
      snapshotId: 'snapshot-1',
      tenantId: 'tenant-1',
      userId: 'doctor-1',
      deviceId: 'device-1',
      revision: 1,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(const Duration(days: 30)),
      payloadDigest: 'digest',
      roles: const <String>{NodexRoles.medicalOfficer},
      permissions: permissions,
      offlinePermissions: permissions,
      facilityIds: const <String>{},
      departmentIds: const <String>{},
      wardIds: const <String>{},
    ),
    connectivity: ConnectivityState.online,
  );
}

void main() {
  late FakePrescriptionStore store;
  late DefaultPrescriptionRepository repository;
  late DraftPrescriptionUseCase draft;
  late AddPrescriptionItemUseCase addLine;
  late FinalizePrescriptionUseCase finalize;
  late SupersedePrescriptionUseCase supersede;
  late ClosePrescriptionUseCase close;
  late RecordDispenseUseCase dispense;
  late RecordAdministrationUseCase administer;

  const Set<String> drafter = <String>{NodexPermissions.prescriptionDraft};
  const Set<String> finalizer = <String>{NodexPermissions.prescriptionFinalize};
  const Set<String> dispenser = <String>{NodexPermissions.pharmacyDispense};
  const Set<String> nurse = <String>{NodexPermissions.medicationAdminister};

  setUp(() {
    store = FakePrescriptionStore();
    repository = DefaultPrescriptionRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
    draft = DraftPrescriptionUseCase(repository: repository);
    addLine = AddPrescriptionItemUseCase(repository: repository);
    finalize = FinalizePrescriptionUseCase(repository: repository);
    supersede = SupersedePrescriptionUseCase(repository: repository);
    close = ClosePrescriptionUseCase(repository: repository);
    dispense = RecordDispenseUseCase(repository: repository);
    administer = RecordAdministrationUseCase(repository: repository);
  });

  Future<Prescription> seedDraft() async {
    final String id = await draft.call(
      policy: policyWith(drafter),
      tenantId: 'tenant-1',
      patientId: 'patient-1',
      prescribedBy: 'doctor-1',
      prescriptionCode: 'RX-001',
      priority: PrescriptionPriority.routine,
    );
    return (await repository.getPrescription(id))!;
  }

  Future<PrescriptionItem> seedLine(Prescription order) async {
    final String id = await addLine.call(
      policy: policyWith(drafter),
      prescription: order,
      lineNumber: 1,
      drugCode: 'PARA500',
      drugName: 'Paracetamol',
      dosageText: '500mg twice daily',
      quantityPrescribed: 20,
    );
    return (await repository.getItem(id))!;
  }

  group('authorization gates', () {
    test('drafting requires prescription.draft', () {
      expect(
        draft.call(
          policy: policyWith(finalizer),
          tenantId: 'tenant-1',
          patientId: 'patient-1',
          prescribedBy: 'doctor-1',
          prescriptionCode: 'RX-001',
          priority: PrescriptionPriority.routine,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('finalizing requires prescription.finalize', () async {
      final Prescription order = await seedDraft();
      await expectLater(
        finalize.call(
          policy: policyWith(drafter),
          prescription: order,
          finalizerId: 'doctor-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('dispensing requires pharmacy.dispense', () async {
      final Prescription order = await seedDraft();
      final PrescriptionItem line = await seedLine(order);
      await expectLater(
        dispense.call(
          policy: policyWith(drafter),
          item: line,
          dispensedBy: 'pharm-1',
          quantityDispensed: 20,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('administration requires medication.administer', () async {
      final Prescription order = await seedDraft();
      final PrescriptionItem line = await seedLine(order);
      await expectLater(
        administer.call(
          policy: policyWith(drafter),
          item: line,
          patientId: 'patient-1',
          administeredBy: 'nurse-1',
          doseText: '500mg',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });
  });

  group('lifecycle', () {
    test('draft, line, finalize, dispense, administer', () async {
      final Prescription order = await seedDraft();
      final PrescriptionItem line = await seedLine(order);

      await finalize.call(
        policy: policyWith(finalizer),
        prescription: order,
        finalizerId: 'doctor-1',
      );
      final Prescription released = (await repository.getPrescription(
        order.id,
      ))!;
      expect(released.status, PrescriptionStatus.finalized);
      // The fake store has no database triggers: apply the release cascade
      // the server performs on finalize so the line is dispensable.
      await repository.updateItem(
        line.id,
        PrescriptionItem.progressChanges(
          status: PrescriptionItemStatus.ordered,
        ),
      );

      final String dispenseId = await dispense.call(
        policy: policyWith(dispenser),
        item: (await repository.getItem(line.id))!,
        dispensedBy: 'pharm-1',
        quantityDispensed: 20,
      );
      expect(dispenseId.isNotEmpty, isTrue);
      final PrescriptionItem released2 = (await repository.getItem(line.id))!;
      expect(released2.status, PrescriptionItemStatus.dispensed);

      final String adminId = await administer.call(
        policy: policyWith(nurse),
        item: released2,
        patientId: 'patient-1',
        administeredBy: 'nurse-1',
        doseText: '500mg',
        dispenseId: dispenseId,
      );
      expect(adminId.isNotEmpty, isTrue);
    });

    test('partial dispense leaves the line partially dispensed', () async {
      final Prescription order = await seedDraft();
      final PrescriptionItem line = await seedLine(order);
      await finalize.call(
        policy: policyWith(finalizer),
        prescription: order,
        finalizerId: 'doctor-1',
      );
      await repository.updateItem(
        line.id,
        PrescriptionItem.progressChanges(
          status: PrescriptionItemStatus.ordered,
        ),
      );

      await dispense.call(
        policy: policyWith(dispenser),
        item: (await repository.getItem(line.id))!,
        dispensedBy: 'pharm-1',
        quantityDispensed: 8,
      );
      final PrescriptionItem partial = (await repository.getItem(line.id))!;
      expect(partial.status, PrescriptionItemStatus.partiallyDispensed);
    });

    test('a finalized order cannot be finalized again', () async {
      final Prescription order = await seedDraft();
      await finalize.call(
        policy: policyWith(finalizer),
        prescription: order,
        finalizerId: 'doctor-1',
      );
      final Prescription released = (await repository.getPrescription(
        order.id,
      ))!;
      await expectLater(
        finalize.call(
          policy: policyWith(finalizer),
          prescription: released,
          finalizerId: 'doctor-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('superseding carries lines and freezes the original', () async {
      final Prescription order = await seedDraft();
      await seedLine(order);
      await finalize.call(
        policy: policyWith(finalizer),
        prescription: order,
        finalizerId: 'doctor-1',
      );
      final Prescription released = (await repository.getPrescription(
        order.id,
      ))!;

      final String successorId = await supersede.call(
        policy: policyWith(finalizer),
        original: released,
        carriedLines: await repository.listItems(order.id),
        priority: PrescriptionPriority.urgent,
      );
      final Prescription successor = (await repository.getPrescription(
        successorId,
      ))!;
      expect(successor.version, 2);
      expect(successor.supersedes, order.id);
      expect(
        (await repository.listItems(successorId)).single.drugCode,
        'PARA500',
      );
      final Prescription frozen = (await repository.getPrescription(order.id))!;
      expect(frozen.status, PrescriptionStatus.superseded);
      expect(frozen.supersededBy, successorId);
    });

    test('closing a draft cancels, closing an order discontinues', () async {
      final Prescription order = await seedDraft();
      await close.call(
        policy: policyWith(drafter),
        prescription: order,
        reason: 'Duplicate',
      );
      expect(
        (await repository.getPrescription(order.id))!.status,
        PrescriptionStatus.cancelled,
      );

      final Prescription second = await seedDraft();
      await finalize.call(
        policy: policyWith(finalizer),
        prescription: second,
        finalizerId: 'doctor-1',
      );
      await close.call(
        policy: policyWith(finalizer),
        prescription: (await repository.getPrescription(second.id))!,
        reason: 'Adverse reaction',
      );
      expect(
        (await repository.getPrescription(second.id))!.status,
        PrescriptionStatus.discontinued,
      );
    });

    test('lines cannot be added once released', () async {
      final Prescription order = await seedDraft();
      await finalize.call(
        policy: policyWith(finalizer),
        prescription: order,
        finalizerId: 'doctor-1',
      );
      final Prescription released = (await repository.getPrescription(
        order.id,
      ))!;
      await expectLater(
        addLine.call(
          policy: policyWith(drafter),
          prescription: released,
          lineNumber: 1,
          drugCode: 'PARA500',
          drugName: 'Paracetamol',
          dosageText: '500mg twice daily',
          quantityPrescribed: 20,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });
  });
}
