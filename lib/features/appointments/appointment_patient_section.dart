/// Appointment section embedded in the patient detail screen (Module 07).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/appointments/appointment_book_sheet.dart';
import 'package:nodex_hms/features/appointments/appointment_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Shows bookings for a patient and the booking entry point.
class AppointmentPatientSection extends ConsumerWidget {
  /// Creates the section.
  const AppointmentPatientSection({required this.patientId, super.key});

  /// Patient identifier.
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Appointment>> bookings = ref.watch(
      appointmentsForPatientProvider(patientId),
    );
    final SessionState session = ref.watch(sessionProvider);
    final bool canBook = session.authorization.can(
      NodexPermissions.appointmentWrite,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Appointments', style: theme.textTheme.titleMedium),
            ),
            if (canBook)
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Book'),
                onPressed: () => _book(context, ref),
              ),
          ],
        ),
        bookings.when(
          loading: () => const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (Object error, StackTrace _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error is NodexError
                    ? error.message
                    : 'Appointment history unavailable.',
              ),
            ),
          ),
          data: (List<Appointment> values) => values.isEmpty
              ? const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No appointments booked.'),
                  ),
                )
              : Column(
                  children: values
                      .map(
                        (Appointment booking) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.event_outlined),
                            title: Text(booking.appointmentCode),
                            subtitle: Text(
                              '${_formatWhen(booking.scheduledStart)} · ${booking.status.wireValue}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                context.go('/appointments/${booking.id}'),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
        ),
      ],
    );
  }

  Future<void> _book(BuildContext context, WidgetRef ref) async {
    final AppointmentDraft? draft = await showAppointmentBookSheet(
      context,
      patientId: patientId,
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    final String? tenantId = session.tenantId;
    if (userId == null || tenantId == null) return;
    try {
      final String id = await ref
          .read(bookAppointmentUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: tenantId,
            patientId: patientId,
            providerId: draft.providerId,
            bookedBy: userId,
            appointmentCode: draft.appointmentCode,
            visitType: draft.visitType,
            priority: draft.priority,
            scheduledStart: draft.scheduledStart,
            scheduledEnd: draft.scheduledEnd,
            reason: draft.reason,
          );
      ref.invalidate(appointmentsForPatientProvider(patientId));
      if (context.mounted) context.go('/appointments/$id');
    } on NodexError catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  static String _formatWhen(DateTime when) {
    final DateTime local = when.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
