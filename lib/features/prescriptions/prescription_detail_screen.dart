/// Prescription detail and pharmacy workflow actions (Module 25).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/prescriptions/prescription_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Detail screen for one prescription version.
class PrescriptionDetailScreen extends ConsumerWidget {
  /// Creates the screen.
  const PrescriptionDetailScreen({required this.prescriptionId, super.key});

  /// Local prescription id.
  final String prescriptionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PrescriptionDetail> detail = ref.watch(
      prescriptionDetailProvider(prescriptionId),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Prescription')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => _RxError(
          error: error,
          onRetry: () =>
              ref.invalidate(prescriptionDetailProvider(prescriptionId)),
        ),
        data: (PrescriptionDetail value) => _RxBody(value: value),
      ),
    );
  }
}

class _RxBody extends ConsumerWidget {
  const _RxBody({required this.value});

  final PrescriptionDetail value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final SessionState session = ref.watch(sessionProvider);
    final bool canDraft = session.authorization.can(
      NodexPermissions.prescriptionDraft,
    );
    final bool canFinalize = session.authorization.can(
      NodexPermissions.prescriptionFinalize,
    );
    final bool canDispense = session.authorization.can(
      NodexPermissions.pharmacyDispense,
    );
    final bool canAdminister = session.authorization.can(
      NodexPermissions.medicationAdminister,
    );
    final Prescription order = value.prescription;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${order.prescriptionCode} · v${order.version}',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                _RxFact(label: 'Priority', value: order.priority.label),
                _RxFact(label: 'Status', value: order.status.wireValue),
                if (order.indication != null)
                  _RxFact(label: 'Indication', value: order.indication!),
                if (order.closureReason != null)
                  _RxFact(label: 'Closure reason', value: order.closureReason!),
                if (value.versions.length > 1)
                  _RxFact(
                    label: 'Versions',
                    value: value.versions
                        .map((Prescription v) => 'v${v.version}')
                        .join(', '),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: <Widget>[
            if (order.status == PrescriptionStatus.draft && canFinalize)
              FilledButton.icon(
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Finalize'),
                onPressed: () => _finalize(context, ref),
              ),
            if (order.status == PrescriptionStatus.finalized && canFinalize)
              FilledButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('New version'),
                onPressed: () => _newVersion(context, ref),
              ),
            if (!order.status.isTerminal &&
                (order.status == PrescriptionStatus.draft
                    ? canDraft
                    : canFinalize))
              OutlinedButton.icon(
                icon: const Icon(Icons.close),
                label: Text(
                  order.status == PrescriptionStatus.draft
                      ? 'Cancel'
                      : 'Discontinue',
                ),
                onPressed: () => _close(context, ref),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Medication lines',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (order.status.isEditable && canDraft)
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add line'),
                onPressed: () => _showLineSheet(context, ref),
              ),
          ],
        ),
        if (value.items.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No medication lines yet.'),
            ),
          )
        else
          ...value.items.map(
            (PrescriptionItem item) => _LineCard(
              item: item,
              canDispense: canDispense,
              onDispense: () => _showDispenseSheet(context, ref, item),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Administration record',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (canAdminister && value.items.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Record'),
                onPressed: () => _showAdminSheet(context, ref),
              ),
          ],
        ),
        if (value.administrations.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No administrations recorded.'),
            ),
          )
        else
          ...value.administrations.map(
            (MedicationAdministration event) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.medical_services_outlined),
                title: Text(event.doseText),
                subtitle: Text(event.administeredAt.toLocal().toString()),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _finalize(BuildContext context, WidgetRef ref) async {
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    if (userId == null) return;
    try {
      await ref
          .read(finalizePrescriptionUseCaseProvider)
          .call(
            policy: session.authorization,
            prescription: value.prescription,
            finalizerId: userId,
          );
      ref.invalidate(prescriptionDetailProvider(value.prescription.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _newVersion(BuildContext context, WidgetRef ref) async {
    final SessionState session = ref.read(sessionProvider);
    try {
      final String successorId = await ref
          .read(supersedePrescriptionUseCaseProvider)
          .call(
            policy: session.authorization,
            original: value.prescription,
            carriedLines: value.items,
            priority: value.prescription.priority,
          );
      ref.invalidate(prescriptionDetailProvider(value.prescription.id));
      if (context.mounted) {
        _snack(context, 'Drafted successor version ($successorId).');
      }
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _close(BuildContext context, WidgetRef ref) async {
    final String? reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => const _ReasonSheet(),
    );
    if (reason == null) return;
    final SessionState session = ref.read(sessionProvider);
    try {
      await ref
          .read(closePrescriptionUseCaseProvider)
          .call(
            policy: session.authorization,
            prescription: value.prescription,
            reason: reason,
          );
      ref.invalidate(prescriptionDetailProvider(value.prescription.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _showLineSheet(BuildContext context, WidgetRef ref) async {
    final _LineDraft? draft = await showModalBottomSheet<_LineDraft>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) =>
          _LineSheet(lineNumber: value.items.length + 1),
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    try {
      await ref
          .read(addPrescriptionItemUseCaseProvider)
          .call(
            policy: session.authorization,
            prescription: value.prescription,
            lineNumber: draft.lineNumber,
            drugCode: draft.drugCode,
            drugName: draft.drugName,
            dosageText: draft.dosageText,
            quantityPrescribed: draft.quantity,
            strength: draft.strength,
            route: draft.route,
            frequency: draft.frequency,
            durationDays: draft.durationDays,
          );
      ref.invalidate(prescriptionDetailProvider(value.prescription.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _showDispenseSheet(
    BuildContext context,
    WidgetRef ref,
    PrescriptionItem item,
  ) async {
    final _DispenseDraft? draft = await showModalBottomSheet<_DispenseDraft>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => const _DispenseSheet(),
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    if (userId == null) return;
    try {
      await ref
          .read(recordDispenseUseCaseProvider)
          .call(
            policy: session.authorization,
            item: item,
            dispensedBy: userId,
            quantityDispensed: draft.quantity,
            batchNumber: draft.batch,
            note: draft.note,
          );
      ref.invalidate(prescriptionDetailProvider(value.prescription.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _showAdminSheet(BuildContext context, WidgetRef ref) async {
    final _AdminDraft? draft = await showModalBottomSheet<_AdminDraft>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => _AdminSheet(items: value.items),
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    final String patientId = value.prescription.patientId;
    if (userId == null) return;
    try {
      await ref
          .read(recordAdministrationUseCaseProvider)
          .call(
            policy: session.authorization,
            item: draft.item,
            patientId: patientId,
            administeredBy: userId,
            doseText: draft.dose,
            route: draft.route,
            site: draft.site,
            note: draft.note,
          );
      ref.invalidate(prescriptionDetailProvider(value.prescription.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _RxFact extends StatelessWidget {
  const _RxFact({required this.label, required this.value});
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

class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.item,
    required this.canDispense,
    required this.onDispense,
  });
  final PrescriptionItem item;
  final bool canDispense;
  final VoidCallback onDispense;
  @override
  Widget build(BuildContext context) {
    final bool releasable =
        item.status == PrescriptionItemStatus.ordered ||
        item.status == PrescriptionItemStatus.partiallyDispensed;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.medication_outlined),
        title: Text('${item.drugName} (${item.drugCode})'),
        subtitle: Text(
          '${item.dosageText} · ${item.quantityPrescribed} · ${item.status.wireValue}',
        ),
        trailing: releasable && canDispense
            ? IconButton(
                icon: const Icon(Icons.point_of_sale_outlined),
                tooltip: 'Dispense',
                onPressed: onDispense,
              )
            : null,
      ),
    );
  }
}

class _ReasonSheet extends StatefulWidget {
  const _ReasonSheet();
  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  final TextEditingController _reason = TextEditingController();
  @override
  void dispose() {
    _reason.dispose();
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
            'Reason required',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Reason *'),
            autofocus: true,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_reason.text.trim().isEmpty) return;
              Navigator.pop(context, _reason.text.trim());
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }
}

class _LineDraft {
  const _LineDraft({
    required this.lineNumber,
    required this.drugCode,
    required this.drugName,
    required this.dosageText,
    required this.quantity,
    this.strength,
    this.route,
    this.frequency,
    this.durationDays,
  });
  final int lineNumber;
  final String drugCode;
  final String drugName;
  final String dosageText;
  final double quantity;
  final String? strength;
  final String? route;
  final String? frequency;
  final int? durationDays;
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.lineNumber});
  final int lineNumber;
  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  final TextEditingController _drugCode = TextEditingController();
  final TextEditingController _drugName = TextEditingController();
  final TextEditingController _dosage = TextEditingController();
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _strength = TextEditingController();
  final TextEditingController _route = TextEditingController();
  final TextEditingController _frequency = TextEditingController();
  final TextEditingController _duration = TextEditingController();
  @override
  void dispose() {
    _drugCode.dispose();
    _drugName.dispose();
    _dosage.dispose();
    _quantity.dispose();
    _strength.dispose();
    _route.dispose();
    _frequency.dispose();
    _duration.dispose();
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
            'Add medication line',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _drugCode,
                  decoration: const InputDecoration(labelText: 'Drug code *'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _drugName,
                  decoration: const InputDecoration(labelText: 'Drug name *'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dosage,
            decoration: const InputDecoration(labelText: 'Dosage *'),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _quantity,
                  decoration: const InputDecoration(labelText: 'Quantity *'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _strength,
                  decoration: const InputDecoration(labelText: 'Strength'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _route,
                  decoration: const InputDecoration(labelText: 'Route'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _frequency,
                  decoration: const InputDecoration(labelText: 'Frequency'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _duration,
            decoration: const InputDecoration(
              labelText: 'Duration days (optional)',
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              final double? quantity = double.tryParse(_quantity.text.trim());
              final int? duration = _duration.text.trim().isEmpty
                  ? null
                  : int.tryParse(_duration.text.trim());
              if (_drugCode.text.trim().isEmpty ||
                  _drugName.text.trim().isEmpty ||
                  _dosage.text.trim().isEmpty ||
                  quantity == null ||
                  (_duration.text.trim().isNotEmpty && duration == null)) {
                return;
              }
              Navigator.pop(
                context,
                _LineDraft(
                  lineNumber: widget.lineNumber,
                  drugCode: _drugCode.text.trim(),
                  drugName: _drugName.text.trim(),
                  dosageText: _dosage.text.trim(),
                  quantity: quantity,
                  strength: _strength.text.trim().isEmpty
                      ? null
                      : _strength.text.trim(),
                  route: _route.text.trim().isEmpty ? null : _route.text.trim(),
                  frequency: _frequency.text.trim().isEmpty
                      ? null
                      : _frequency.text.trim(),
                  durationDays: duration,
                ),
              );
            },
            child: const Text('Add line'),
          ),
        ],
      ),
    );
  }
}

class _DispenseDraft {
  const _DispenseDraft({required this.quantity, this.batch, this.note});
  final double quantity;
  final String? batch;
  final String? note;
}

class _DispenseSheet extends StatefulWidget {
  const _DispenseSheet();
  @override
  State<_DispenseSheet> createState() => _DispenseSheetState();
}

class _DispenseSheetState extends State<_DispenseSheet> {
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _batch = TextEditingController();
  final TextEditingController _note = TextEditingController();
  @override
  void dispose() {
    _quantity.dispose();
    _batch.dispose();
    _note.dispose();
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
            'Record dispense',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _quantity,
            decoration: const InputDecoration(
              labelText: 'Quantity dispensed *',
            ),
            keyboardType: TextInputType.number,
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _batch,
            decoration: const InputDecoration(labelText: 'Batch number'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              final double? quantity = double.tryParse(_quantity.text.trim());
              if (quantity == null) return;
              Navigator.pop(
                context,
                _DispenseDraft(
                  quantity: quantity,
                  batch: _batch.text.trim().isEmpty ? null : _batch.text.trim(),
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                ),
              );
            },
            child: const Text('Record dispense'),
          ),
        ],
      ),
    );
  }
}

class _AdminDraft {
  const _AdminDraft({
    required this.item,
    required this.dose,
    this.route,
    this.site,
    this.note,
  });
  final PrescriptionItem item;
  final String dose;
  final String? route;
  final String? site;
  final String? note;
}

class _AdminSheet extends StatefulWidget {
  const _AdminSheet({required this.items});
  final List<PrescriptionItem> items;
  @override
  State<_AdminSheet> createState() => _AdminSheetState();
}

class _AdminSheetState extends State<_AdminSheet> {
  late PrescriptionItem _item = widget.items.first;
  final TextEditingController _dose = TextEditingController();
  final TextEditingController _route = TextEditingController();
  final TextEditingController _site = TextEditingController();
  final TextEditingController _note = TextEditingController();
  @override
  void dispose() {
    _dose.dispose();
    _route.dispose();
    _site.dispose();
    _note.dispose();
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
            'Record administration',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<PrescriptionItem>(
            initialValue: _item,
            decoration: const InputDecoration(labelText: 'Medication line'),
            items: widget.items
                .map(
                  (PrescriptionItem item) => DropdownMenuItem<PrescriptionItem>(
                    value: item,
                    child: Text('${item.drugName} · ${item.dosageText}'),
                  ),
                )
                .toList(growable: false),
            onChanged: (PrescriptionItem? value) {
              if (value != null) setState(() => _item = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dose,
            decoration: const InputDecoration(labelText: 'Dose given *'),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _route,
                  decoration: const InputDecoration(labelText: 'Route'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _site,
                  decoration: const InputDecoration(labelText: 'Site'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_dose.text.trim().isEmpty) return;
              Navigator.pop(
                context,
                _AdminDraft(
                  item: _item,
                  dose: _dose.text.trim(),
                  route: _route.text.trim().isEmpty ? null : _route.text.trim(),
                  site: _site.text.trim().isEmpty ? null : _site.text.trim(),
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                ),
              );
            },
            child: const Text('Record administration'),
          ),
        ],
      ),
    );
  }
}

class _RxError extends StatelessWidget {
  const _RxError({required this.error, required this.onRetry});
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
              : 'Prescription unavailable',
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
