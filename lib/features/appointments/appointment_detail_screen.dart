/// Appointment detail and visit actions (Module 07).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/encounters/encounter.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/appointments/appointment_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Detail screen for one booking.
class AppointmentDetailScreen extends ConsumerWidget {
  /// Creates the screen.
  const AppointmentDetailScreen({required this.appointmentId, super.key});

  /// Local appointment id.
  final String appointmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Appointment> detail = ref.watch(
      appointmentDetailProvider(appointmentId),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Appointment')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => _ApptError(
          error: error,
          onRetry: () =>
              ref.invalidate(appointmentDetailProvider(appointmentId)),
        ),
        data: (Appointment value) => _ApptBody(value: value),
      ),
    );
  }
}

class _ApptBody extends ConsumerWidget {
  const _ApptBody({required this.value});

  final Appointment value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final SessionState session = ref.watch(sessionProvider);
    final bool canWrite = session.authorization.can(
      NodexPermissions.appointmentWrite,
    );
    final bool canStartEncounter = session.authorization.can(
      NodexPermissions.encounterWrite,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(value.appointmentCode, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                _ApptFact(
                  label: 'When',
                  value:
                      '${_formatWhen(value.scheduledStart)} – ${_formatWhen(value.scheduledEnd)}',
                ),
                _ApptFact(label: 'Status', value: value.status.wireValue),
                _ApptFact(label: 'Visit', value: value.visitType.label),
                _ApptFact(label: 'Priority', value: value.priority.label),
                if (value.reason != null)
                  _ApptFact(label: 'Reason', value: value.reason!),
                if (value.cancelReason != null)
                  _ApptFact(label: 'Cancel reason', value: value.cancelReason!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (canWrite && !value.status.isTerminal)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (value.status == AppointmentStatus.booked)
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Confirm'),
                  onPressed: () =>
                      _transition(context, ref, AppointmentStatus.confirmed),
                ),
              if (value.status == AppointmentStatus.booked ||
                  value.status == AppointmentStatus.confirmed)
                FilledButton.icon(
                  icon: const Icon(Icons.login),
                  label: const Text('Check in'),
                  onPressed: () =>
                      _transition(context, ref, AppointmentStatus.checkedIn),
                ),
              if (value.status == AppointmentStatus.checkedIn)
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start visit'),
                  onPressed: () =>
                      _transition(context, ref, AppointmentStatus.inProgress),
                ),
              if (value.status == AppointmentStatus.inProgress)
                FilledButton.icon(
                  icon: const Icon(Icons.done_all),
                  label: const Text('Complete'),
                  onPressed: () =>
                      _transition(context, ref, AppointmentStatus.completed),
                ),
              if (value.status == AppointmentStatus.checkedIn)
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_off_outlined),
                  label: const Text('No-show'),
                  onPressed: () =>
                      _transition(context, ref, AppointmentStatus.noShow),
                ),
              if (value.status.isSchedulable)
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('Reschedule'),
                  onPressed: () => _reschedule(context, ref),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
                onPressed: () => _cancel(context, ref),
              ),
            ],
          ),
        if (canStartEncounter &&
            value.status == AppointmentStatus.inProgress &&
            value.encounterId == null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton.icon(
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('Start encounter'),
              onPressed: () => _startEncounter(context, ref),
            ),
          ),
        if (value.encounterId != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.chevron_right),
              label: const Text('Open linked encounter'),
              onPressed: () => context.go(
                '/patients/${value.patientId}/encounters/${value.encounterId}',
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _transition(
    BuildContext context,
    WidgetRef ref,
    AppointmentStatus status,
  ) async {
    String? reason;
    if (status == AppointmentStatus.cancelled) {
      reason = await _askReason(context);
      if (reason == null) return;
    }
    final SessionState session = ref.read(sessionProvider);
    try {
      await ref
          .read(transitionAppointmentUseCaseProvider)
          .call(
            policy: session.authorization,
            appointment: value,
            status: status,
            cancelReason: reason,
          );
      ref.invalidate(appointmentDetailProvider(value.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _reschedule(BuildContext context, WidgetRef ref) async {
    final DateTime? day = await showDatePicker(
      context: context,
      initialDate: value.scheduledStart,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (day == null || !context.mounted) return;
    final TimeOfDay? start = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value.scheduledStart),
    );
    if (start == null || !context.mounted) return;
    final Duration length = value.scheduledEnd.difference(value.scheduledStart);
    final DateTime newStart = DateTime(
      day.year,
      day.month,
      day.day,
      start.hour,
      start.minute,
    );
    final SessionState session = ref.read(sessionProvider);
    try {
      await ref
          .read(rescheduleAppointmentUseCaseProvider)
          .call(
            policy: session.authorization,
            appointment: value,
            scheduledStart: newStart,
            scheduledEnd: newStart.add(length),
          );
      ref.invalidate(appointmentDetailProvider(value.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    await _transition(context, ref, AppointmentStatus.cancelled);
  }

  Future<void> _startEncounter(BuildContext context, WidgetRef ref) async {
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    final String? tenantId = session.tenantId;
    if (userId == null || tenantId == null) return;
    try {
      final String encounterId = await ref
          .read(startEncounterUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: tenantId,
            patientId: value.patientId,
            attendingPhysicianId: value.providerId,
            encounterType: EncounterType.outpatient,
            createdBy: userId,
          );
      await ref
          .read(linkEncounterAppointmentUseCaseProvider)
          .call(
            policy: session.authorization,
            appointment: value,
            encounterId: encounterId,
          );
      ref.invalidate(appointmentDetailProvider(value.id));
      if (context.mounted) {
        context.go('/patients/${value.patientId}/encounters/$encounterId');
      }
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<String?> _askReason(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    try {
      return await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext context) {
          final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
          return Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + keyboard),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'Cancel reason required',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(labelText: 'Reason *'),
                  autofocus: true,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    if (controller.text.trim().isEmpty) return;
                    Navigator.pop(context, controller.text.trim());
                  },
                  child: const Text('Confirm'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static String _formatWhen(DateTime when) {
    final DateTime local = when.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _ApptFact extends StatelessWidget {
  const _ApptFact({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: <Widget>[
        Expanded(child: Text(label)),
        Text(value),
      ],
    ),
  );
}

class _ApptError extends StatelessWidget {
  const _ApptError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          error is NodexError
              ? (error as NodexError).message
              : 'Appointment unavailable',
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
