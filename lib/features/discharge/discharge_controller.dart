/// Discharge presentation providers (Module 23).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/discharge/discharge.dart';

/// Discharges for one patient, newest first.
final dischargesForPatientProvider = FutureProvider.autoDispose
    .family<List<Discharge>, String>((Ref ref, String patientId) async {
      return ref.watch(dischargeRepositoryProvider).listForPatient(patientId);
    });

/// One discharge by id.
final dischargeDetailProvider = FutureProvider.autoDispose
    .family<Discharge, String>((Ref ref, String dischargeId) async {
      final Discharge? discharge = await ref
          .watch(dischargeRepositoryProvider)
          .getDischarge(dischargeId);
      if (discharge == null) {
        throw const PersistenceError(
          message: 'This discharge is not available on this device.',
          code: 'discharge_not_found_locally',
        );
      }
      return discharge;
    });
