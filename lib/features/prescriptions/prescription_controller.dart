/// Prescription presentation providers (Module 25).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:nodex_hms/domain/prescriptions/prescription_repository.dart';

/// Order detail bundle for the prescription screen.
final class PrescriptionDetail {
  /// Creates a bundle.
  const PrescriptionDetail({
    required this.prescription,
    required this.items,
    required this.dispenses,
    required this.administrations,
    required this.versions,
  });

  /// The order version shown.
  final Prescription prescription;

  /// Medication lines in line order.
  final List<PrescriptionItem> items;

  /// Dispense events across the lines, oldest first.
  final List<PharmacyDispense> dispenses;

  /// Administration events across the lines, oldest first.
  final List<MedicationAdministration> administrations;

  /// All versions of the order series, oldest first.
  final List<Prescription> versions;
}

/// Prescriptions for one patient.
final prescriptionsForPatientProvider = FutureProvider.autoDispose
    .family<List<Prescription>, String>((Ref ref, String patientId) async {
      return ref
          .watch(prescriptionRepositoryProvider)
          .listPrescriptionsForPatient(patientId);
    });

/// One order version with lines, events and version history.
final prescriptionDetailProvider = FutureProvider.autoDispose
    .family<PrescriptionDetail, String>((Ref ref, String prescriptionId) async {
      final PrescriptionRepository repository = ref.watch(
        prescriptionRepositoryProvider,
      );
      final Prescription? prescription = await repository.getPrescription(
        prescriptionId,
      );
      if (prescription == null) {
        throw const PersistenceError(
          message: 'This prescription is not available on this device.',
          code: 'prescription_not_found_locally',
        );
      }
      final List<PrescriptionItem> items = await repository.listItems(
        prescriptionId,
      );
      final List<PharmacyDispense> dispenses = <PharmacyDispense>[];
      final List<MedicationAdministration> administrations =
          <MedicationAdministration>[];
      for (final PrescriptionItem item in items) {
        dispenses.addAll(await repository.listDispenses(item.id));
        administrations.addAll(await repository.listAdministrations(item.id));
      }
      return PrescriptionDetail(
        prescription: prescription,
        items: items,
        dispenses: dispenses,
        administrations: administrations,
        versions: await repository.listVersions(prescription.prescriptionCode),
      );
    });
