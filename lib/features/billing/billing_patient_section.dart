/// Billing section embedded in the patient detail screen (Module 31).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/billing/invoice.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/billing/billing_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Shows invoices and the draft entry point for a patient.
class BillingPatientSection extends ConsumerWidget {
  /// Creates the section.
  const BillingPatientSection({required this.patientId, super.key});

  /// Patient identifier.
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Invoice>> invoices = ref.watch(
      invoicesForPatientProvider(patientId),
    );
    final SessionState session = ref.watch(sessionProvider);
    final bool canDraft = session.authorization.can(
      NodexPermissions.billingSettle,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Invoices', style: theme.textTheme.titleMedium),
            ),
            if (canDraft)
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Draft'),
                onPressed: () => _showDraftSheet(context, ref),
              ),
          ],
        ),
        invoices.when(
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
                    : 'Invoice history unavailable.',
              ),
            ),
          ),
          data: (List<Invoice> values) => values.isEmpty
              ? const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No invoices recorded.'),
                  ),
                )
              : Column(
                  children: values
                      .map(
                        (Invoice invoice) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(
                              invoice.status == InvoiceStatus.settled
                                  ? Icons.verified_outlined
                                  : Icons.receipt_long_outlined,
                            ),
                            title: Text(invoice.invoiceCode),
                            subtitle: Text(
                              '${invoice.formatMinor(invoice.totalMinor)} · ${invoice.status.wireValue}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.go(
                              '/patients/$patientId/billing/${invoice.id}',
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
    final _InvoiceDraft? draft = await showModalBottomSheet<_InvoiceDraft>(
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
          .read(draftInvoiceUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: tenantId,
            patientId: patientId,
            createdBy: userId,
            invoiceCode: draft.invoiceCode,
            currency: draft.currency,
            encounterId: draft.encounterId,
            notes: draft.notes,
          );
      ref.invalidate(invoicesForPatientProvider(patientId));
      if (context.mounted) context.go('/patients/$patientId/billing/$id');
    } on NodexError catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}

class _InvoiceDraft {
  const _InvoiceDraft({
    required this.invoiceCode,
    this.currency = 'BDT',
    this.encounterId,
    this.notes,
  });
  final String invoiceCode;
  final String currency;
  final String? encounterId;
  final String? notes;
}

class _DraftSheet extends StatefulWidget {
  const _DraftSheet();
  @override
  State<_DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<_DraftSheet> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _currency = TextEditingController(text: 'BDT');
  final TextEditingController _encounterId = TextEditingController();
  final TextEditingController _notes = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    _currency.dispose();
    _encounterId.dispose();
    _notes.dispose();
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
            'Draft invoice',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Invoice code *'),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _currency,
            decoration: const InputDecoration(labelText: 'Currency (ISO-4217)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _encounterId,
            decoration: const InputDecoration(
              labelText: 'Encounter ID (optional)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
            maxLines: 3,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_code.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                _InvoiceDraft(
                  invoiceCode: _code.text.trim(),
                  currency: _currency.text.trim().isEmpty
                      ? 'BDT'
                      : _currency.text.trim().toUpperCase(),
                  encounterId: _encounterId.text.trim().isEmpty
                      ? null
                      : _encounterId.text.trim(),
                  notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                ),
              );
            },
            child: const Text('Draft invoice'),
          ),
        ],
      ),
    );
  }
}
