/// Bed presentation providers (Module 11).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/domain/beds/bed_repository.dart';

/// Wards in the local scope, for the census picker.
final censusWardsProvider = FutureProvider.autoDispose<List<WardInfo>>((
  Ref ref,
) async {
  return ref.watch(bedRepositoryProvider).listWards();
});

/// One ward's beds with their live occupants.
final wardCensusProvider = FutureProvider.autoDispose
    .family<List<BedCensusEntry>, String>((Ref ref, String wardId) async {
      final BedRepository repository = ref.watch(bedRepositoryProvider);
      final List<BedCensusEntry> entries = <BedCensusEntry>[];
      for (final bed in await repository.listBedsForWard(wardId)) {
        entries.add(
          BedCensusEntry(
            bed: bed,
            assignment: await repository.activeAssignmentForBed(bed.id),
          ),
        );
      }
      return entries;
    });

/// A patient's active stay, or null when not admitted.
final patientStayProvider = FutureProvider.autoDispose.family((
  Ref ref,
  String patientId,
) async {
  return ref.watch(bedRepositoryProvider).activeAssignmentForPatient(patientId);
});

/// Display name for an occupant, falling back to the id prefix.
final bedOccupantNameProvider = FutureProvider.autoDispose
    .family<String, String>((Ref ref, String patientId) async {
      final patient = await ref
          .watch(patientRepositoryProvider)
          .getPatient(patientId);
      if (patient == null) return patientId.substring(0, 8);
      return patient.displayName;
    });
