/// Scope-wide visit schedule (Module 07).
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

/// Upcoming bookings across the device scope, earliest first.
class AppointmentScheduleScreen extends ConsumerWidget {
  /// Creates the screen.
  const AppointmentScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime from = DateTime.now().toUtc().subtract(
      const Duration(hours: 12),
    );
    final AsyncValue<List<Appointment>> upcoming = ref.watch(
      upcomingAppointmentsProvider(from),
    );
    final SessionState session = ref.watch(sessionProvider);
    final bool canBook = session.authorization.can(
      NodexPermissions.appointmentWrite,
    );
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appointments'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh schedule',
            onPressed: () => ref.invalidate(upcomingAppointmentsProvider(from)),
          ),
        ],
      ),
      floatingActionButton: canBook
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Book'),
              onPressed: () => _book(context, ref),
            )
          : null,
      body: upcoming.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => Center(
          child: Text(
            error is NodexError ? error.message : 'Schedule unavailable.',
          ),
        ),
        data: (List<Appointment> values) => values.isEmpty
            ? const Center(child: Text('No upcoming visits.'))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: values.length,
                itemBuilder: (BuildContext context, int index) {
                  final Appointment appointment = values[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                        appointment.priority == AppointmentPriority.stat
                            ? Icons.priority_high
                            : Icons.event_outlined,
                      ),
                      title: Text(appointment.appointmentCode),
                      subtitle: Text(
                        '${_formatWhen(appointment.scheduledStart)} · ${appointment.status.wireValue}',
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          context.go('/appointments/${appointment.id}'),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _book(BuildContext context, WidgetRef ref) async {
    final AppointmentDraft? draft = await showAppointmentBookSheet(context);
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
            patientId: draft.patientId,
            providerId: draft.providerId,
            bookedBy: userId,
            appointmentCode: draft.appointmentCode,
            visitType: draft.visitType,
            priority: draft.priority,
            scheduledStart: draft.scheduledStart,
            scheduledEnd: draft.scheduledEnd,
            reason: draft.reason,
          );
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
