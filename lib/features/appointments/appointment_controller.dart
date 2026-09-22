/// Appointment presentation providers (Module 07).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/appointments/appointment_repository.dart';

/// Upcoming bookings scope-wide, earliest first.
final upcomingAppointmentsProvider = FutureProvider.autoDispose
    .family<List<Appointment>, DateTime>((Ref ref, DateTime from) async {
      return ref.watch(appointmentRepositoryProvider).listUpcoming(from: from);
    });

/// Bookings for one patient, newest first.
final appointmentsForPatientProvider = FutureProvider.autoDispose
    .family<List<Appointment>, String>((Ref ref, String patientId) async {
      return ref.watch(appointmentRepositoryProvider).listForPatient(patientId);
    });

/// One booking by id.
final appointmentDetailProvider = FutureProvider.autoDispose
    .family<Appointment, String>((Ref ref, String appointmentId) async {
      final Appointment? appointment = await ref
          .watch(appointmentRepositoryProvider)
          .getAppointment(appointmentId);
      if (appointment == null) {
        throw const PersistenceError(
          message: 'This appointment is not available on this device.',
          code: 'appointment_not_found_locally',
        );
      }
      return appointment;
    });

/// Staff directory for the provider picker.
final appointmentProvidersProvider =
    FutureProvider.autoDispose<List<StaffMember>>((Ref ref) async {
      return ref.watch(appointmentRepositoryProvider).listProviders();
    });
