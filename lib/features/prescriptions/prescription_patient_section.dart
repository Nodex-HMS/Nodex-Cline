/// Prescription section embedded in the patient detail screen (Module 25).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/prescriptions/prescription_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Shows prescriptions and the draft entry point for a patient.
class PrescriptionPatientSection extends ConsumerWidget {
  /// Creates the section.
  const PrescriptionPatientSection({required this.patientId, super.key});

  /// Patient identifier.
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Prescription>> orders = ref.watch(
      prescriptionsForPatientProvider(patientId),
    );
    final SessionState session = ref.watch(sessionProvider);
    final bool canDraft = session.authorization.can(
      NodexPermissions.prescriptionDraft,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Prescriptions', style: theme.textTheme.titleMedium),
            ),
            if (canDraft)
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Prescribe'),
                onPressed: () => _showDraftSheet(context, ref),
              ),
          ],
        ),
        orders.when(
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
                    : 'Prescription history unavailable.',
              ),
            ),
          ),
          data: (List<Prescription> values) => values.isEmpty
              ? const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No prescriptions recorded.'),
                  ),
                )
              : Column(
                  children: values
                      .map(
                        (Prescription order) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(
                              order.priority == PrescriptionPriority.stat
                                  ? Icons.priority_high
                                  : Icons.medication_outlined,
                            ),
                            title: Text(
                              '${order.prescriptionCode} · v${order.version}',
                            ),
                            subtitle: Text(
                              '${order.priority.label} · ${order.status.wireValue}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.go(
                              '/patients/$patientId/rx/${order.id}',
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
    final _PrescriptionDraft? draft =
        await showModalBottomSheet<_PrescriptionDraft>(
          context: context,
          isScrollControlled: true,
          builder: (BuildContext context) => const _DraftSheet(),
        );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    final String? tenantId = session.tenantId;
    if (userId == null || tenantId == null) return;
    try {
      final String id = await ref
          .read(draftPrescriptionUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: tenantId,
            patientId: patientId,
            prescribedBy: userId,
            prescriptionCode: draft.orderCode,
            priority: draft.priority,
            indication: draft.indication,
          );
      ref.invalidate(prescriptionsForPatientProvider(patientId));
      if (context.mounted) context.go('/patients/$patientId/rx/$id');
    } on NodexError catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}

class _PrescriptionDraft {
  const _PrescriptionDraft({
    required this.orderCode,
    required this.priority,
    this.indication,
  });
  final String orderCode;
  final PrescriptionPriority priority;
  final String? indication;
}

class _DraftSheet extends StatefulWidget {
  const _DraftSheet();
  @override
  State<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<_DraftSheet> {
  final TextEditingController _orderCode = TextEditingController();
  final TextEditingController _indication = TextEditingController();
  PrescriptionPriority _priority = PrescriptionPriority.routine;

  @override
  void dispose() {
    _orderCode.dispose();
    _indication.dispose();
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
            'Draft prescription',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _orderCode,
            decoration: const InputDecoration(labelText: 'Prescription code *'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<PrescriptionPriority>(
            initialValue: _priority,
            decoration: const InputDecoration(labelText: 'Priority'),
            items: PrescriptionPriority.values
                .map(
                  (PrescriptionPriority p) =>
                      DropdownMenuItem<PrescriptionPriority>(
                        value: p,
                        child: Text(p.label),
                      ),
                )
                .toList(growable: false),
            onChanged: (PrescriptionPriority? value) {
              if (value != null) setState(() => _priority = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _indication,
            decoration: const InputDecoration(
              labelText: 'Indication (optional)',
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_orderCode.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                _PrescriptionDraft(
                  orderCode: _orderCode.text.trim(),
                  priority: _priority,
                  indication: _indication.text.trim().isEmpty
                      ? null
                      : _indication.text.trim(),
                ),
              );
            },
            child: const Text('Draft order'),
          ),
        ],
      ),
    );
  }
}
