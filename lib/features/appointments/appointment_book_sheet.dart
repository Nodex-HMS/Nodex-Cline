/// Shared appointment booking sheet (Module 07).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/domain/appointments/appointment.dart';
import 'package:nodex_hms/domain/appointments/appointment_repository.dart';
import 'package:nodex_hms/features/appointments/appointment_controller.dart';

/// Draft captured by the booking sheet.
class AppointmentDraft {
  /// Creates a draft.
  const AppointmentDraft({
    required this.patientId,
    required this.providerId,
    required this.appointmentCode,
    required this.visitType,
    required this.priority,
    required this.scheduledStart,
    required this.scheduledEnd,
    this.reason,
  });

  /// Patient identifier.
  final String patientId;

  /// Responsible clinician.
  final String providerId;

  /// Tenant-scoped booking code.
  final String appointmentCode;

  /// Visit type.
  final VisitType visitType;

  /// Scheduling priority.
  final AppointmentPriority priority;

  /// Scheduled start.
  final DateTime scheduledStart;

  /// Scheduled end.
  final DateTime scheduledEnd;

  /// Booking reason.
  final String? reason;
}

/// Opens the booking sheet. When [patientId] is null the sheet asks for it.
Future<AppointmentDraft?> showAppointmentBookSheet(
  BuildContext context, {
  String? patientId,
}) => showModalBottomSheet<AppointmentDraft>(
  context: context,
  isScrollControlled: true,
  builder: (BuildContext context) => _BookSheet(patientId: patientId),
);

class _BookSheet extends ConsumerStatefulWidget {
  const _BookSheet({this.patientId});
  final String? patientId;
  @override
  ConsumerState<_BookSheet> createState() => _BookSheetState();
}

class _BookSheetState extends ConsumerState<_BookSheet> {
  final TextEditingController _patientId = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  VisitType _visitType = VisitType.outpatient;
  AppointmentPriority _priority = AppointmentPriority.routine;
  DateTime _day = DateTime.now();
  TimeOfDay _start = const TimeOfDay(hour: 9, minute: 0);
  int _durationMinutes = 30;
  String? _providerId;

  @override
  void initState() {
    super.initState();
    if (widget.patientId != null) _patientId.text = widget.patientId!;
  }

  @override
  void dispose() {
    _patientId.dispose();
    _code.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<StaffMember>> providers = ref.watch(
      appointmentProvidersProvider,
    );
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Book appointment',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (widget.patientId == null)
            TextField(
              controller: _patientId,
              decoration: const InputDecoration(labelText: 'Patient ID *'),
            ),
          if (widget.patientId == null) const SizedBox(height: 12),
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Booking code *'),
          ),
          const SizedBox(height: 12),
          providers.when(
            loading: () => const LinearProgressIndicator(),
            error: (Object _, StackTrace _) =>
                const Text('Provider directory unavailable.'),
            data: (List<StaffMember> values) => DropdownButtonFormField<String>(
              initialValue: _providerId,
              decoration: const InputDecoration(labelText: 'Provider *'),
              items: values
                  .map(
                    (StaffMember member) => DropdownMenuItem<String>(
                      value: member.id,
                      child: Text(member.displayName),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (String? value) => setState(() => _providerId = value),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<VisitType>(
                  initialValue: _visitType,
                  decoration: const InputDecoration(labelText: 'Visit type'),
                  items: VisitType.values
                      .map(
                        (VisitType t) => DropdownMenuItem<VisitType>(
                          value: t,
                          child: Text(t.label),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (VisitType? value) {
                    if (value != null) setState(() => _visitType = value);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<AppointmentPriority>(
                  initialValue: _priority,
                  decoration: const InputDecoration(labelText: 'Priority'),
                  items: AppointmentPriority.values
                      .map(
                        (AppointmentPriority p) =>
                            DropdownMenuItem<AppointmentPriority>(
                              value: p,
                              child: Text(p.label),
                            ),
                      )
                      .toList(growable: false),
                  onChanged: (AppointmentPriority? value) {
                    if (value != null) setState(() => _priority = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final DateTime? day = await showDatePicker(
                      context: context,
                      initialDate: _day,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 1),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (day != null) setState(() => _day = day);
                  },
                  child: Text(
                    '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final TimeOfDay? start = await showTimePicker(
                      context: context,
                      initialTime: _start,
                    );
                    if (start != null) setState(() => _start = start);
                  },
                  child: Text(_start.format(context)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _durationMinutes,
                  decoration: const InputDecoration(labelText: 'Minutes'),
                  items: const <int>[15, 30, 45, 60, 90]
                      .map(
                        (int m) =>
                            DropdownMenuItem<int>(value: m, child: Text('$m')),
                      )
                      .toList(growable: false),
                  onChanged: (int? value) {
                    if (value != null) setState(() => _durationMinutes = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Reason (optional)'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              final String patientId = _patientId.text.trim();
              if (patientId.isEmpty ||
                  _code.text.trim().isEmpty ||
                  _providerId == null) {
                return;
              }
              final DateTime start = DateTime(
                _day.year,
                _day.month,
                _day.day,
                _start.hour,
                _start.minute,
              );
              Navigator.pop(
                context,
                AppointmentDraft(
                  patientId: patientId,
                  providerId: _providerId!,
                  appointmentCode: _code.text.trim(),
                  visitType: _visitType,
                  priority: _priority,
                  scheduledStart: start,
                  scheduledEnd: start.add(Duration(minutes: _durationMinutes)),
                  reason: _reason.text.trim().isEmpty
                      ? null
                      : _reason.text.trim(),
                ),
              );
            },
            child: const Text('Book visit'),
          ),
        ],
      ),
    );
  }
}
