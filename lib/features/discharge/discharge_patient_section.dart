/// Discharge section embedded in the patient detail screen (Module 23).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/discharge/discharge.dart';
import 'package:nodex_hms/domain/encounters/encounter.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/discharge/discharge_controller.dart';
import 'package:nodex_hms/features/encounters/encounters_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Shows discharges and the draft entry point for a patient.
class DischargePatientSection extends ConsumerWidget {
  /// Creates the section.
  const DischargePatientSection({required this.patientId, super.key});

  /// Patient identifier.
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Discharge>> records = ref.watch(
      dischargesForPatientProvider(patientId),
    );
    final SessionState session = ref.watch(sessionProvider);
    final bool canDraft = session.authorization.can(
      NodexPermissions.encounterWrite,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Discharge', style: theme.textTheme.titleMedium),
            ),
            if (canDraft)
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Draft'),
                onPressed: () => _showDraftSheet(context, ref),
              ),
          ],
        ),
        records.when(
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
                    : 'Discharge history unavailable.',
              ),
            ),
          ),
          data: (List<Discharge> values) => values.isEmpty
              ? const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No discharges recorded.'),
                  ),
                )
              : Column(
                  children: values
                      .map(
                        (Discharge record) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(
                              record.status == DischargeStatus.finalized
                                  ? Icons.verified_outlined
                                  : Icons.pending_outlined,
                            ),
                            title: Text(record.dischargeCode),
                            subtitle: Text(
                              '${record.dischargeType.label} · ${record.status.wireValue}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.go(
                              '/patients/$patientId/discharge/${record.id}',
                            ),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
        ),
      ],
    );
  }

  Future<void> _showDraftSheet(BuildContext context, WidgetRef ref) async {
    final List<ClinicalEncounter> options = ref
        .read(encountersForPatientProvider(patientId))
        .maybeWhen(
          data: (List<ClinicalEncounter> values) => values,
          orElse: () => const <ClinicalEncounter>[],
        );
    final _DischargeDraft? draft = await showModalBottomSheet<_DischargeDraft>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => _DraftSheet(encounters: options),
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    final String? tenantId = session.tenantId;
    if (userId == null || tenantId == null) return;
    try {
      final String id = await ref
          .read(draftDischargeUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: tenantId,
            patientId: patientId,
            encounterId: draft.encounterId,
            createdBy: userId,
            dischargeCode: draft.dischargeCode,
            dischargeType: draft.dischargeType,
            summary: draft.summary,
            followUpPlan: draft.followUpPlan,
          );
      ref.invalidate(dischargesForPatientProvider(patientId));
      if (context.mounted) context.go('/patients/$patientId/discharge/$id');
    } on NodexError catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}

class _DischargeDraft {
  const _DischargeDraft({
    required this.encounterId,
    required this.dischargeCode,
    required this.dischargeType,
    this.summary,
    this.followUpPlan,
  });
  final String encounterId;
  final String dischargeCode;
  final DischargeType dischargeType;
  final String? summary;
  final String? followUpPlan;
}

class _DraftSheet extends StatefulWidget {
  const _DraftSheet({required this.encounters});
  final List<ClinicalEncounter> encounters;
  @override
  State<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<_DraftSheet> {
  String? _encounterId;
  final TextEditingController _code = TextEditingController();
  final TextEditingController _summary = TextEditingController();
  final TextEditingController _followUp = TextEditingController();
  DischargeType _type = DischargeType.routine;

  @override
  void dispose() {
    _code.dispose();
    _summary.dispose();
    _followUp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Draft discharge',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _encounterId,
            decoration: const InputDecoration(labelText: 'Encounter *'),
            items: widget.encounters
                .map(
                  (ClinicalEncounter encounter) => DropdownMenuItem<String>(
                    value: encounter.id,
                    child: Text(encounter.id.substring(0, 8)),
                  ),
                )
                .toList(growable: false),
            onChanged: (String? value) => setState(() => _encounterId = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Discharge code *'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<DischargeType>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Disposition'),
            items: DischargeType.values
                .map(
                  (DischargeType t) => DropdownMenuItem<DischargeType>(
                    value: t,
                    child: Text(t.label),
                  ),
                )
                .toList(growable: false),
            onChanged: (DischargeType? value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _summary,
            decoration: const InputDecoration(labelText: 'Summary (optional)'),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _followUp,
            decoration: const InputDecoration(
              labelText: 'Follow-up plan (optional)',
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_encounterId == null || _code.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                _DischargeDraft(
                  encounterId: _encounterId!,
                  dischargeCode: _code.text.trim(),
                  dischargeType: _type,
                  summary: _summary.text.trim().isEmpty
                      ? null
                      : _summary.text.trim(),
                  followUpPlan: _followUp.text.trim().isEmpty
                      ? null
                      : _followUp.text.trim(),
                ),
              );
            },
            child: const Text('Draft discharge'),
          ),
        ],
      ),
    );
  }
}
