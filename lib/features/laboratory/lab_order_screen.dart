/// Laboratory order detail and workflow actions (Module 17).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/laboratory/lab.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/laboratory/laboratory_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Detail screen for one laboratory order.
class LabOrderScreen extends ConsumerWidget {
  /// Creates the screen.
  const LabOrderScreen({required this.orderId, super.key});

  /// Local order id.
  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LabOrderDetail> detail = ref.watch(
      labOrderDetailProvider(orderId),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Laboratory order')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => _LabError(
          error: error,
          onRetry: () => ref.invalidate(labOrderDetailProvider(orderId)),
        ),
        data: (LabOrderDetail value) => _LabOrderBody(value: value),
      ),
    );
  }
}

class _LabOrderBody extends ConsumerWidget {
  const _LabOrderBody({required this.value});

  final LabOrderDetail value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final SessionState session = ref.watch(sessionProvider);
    final bool canEnter = session.authorization.can(
      NodexPermissions.labResultEnter,
    );
    final bool canVerify = session.authorization.can(
      NodexPermissions.labResultVerify,
    );
    final LabOrder order = value.order;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(order.orderCode, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                _LabFact(label: 'Priority', value: order.priority.label),
                _LabFact(label: 'Status', value: order.status.wireValue),
                _LabFact(
                  label: 'Tests',
                  value: '${order.tests.length} requested',
                ),
                if (order.clinicalIndication != null)
                  _LabFact(
                    label: 'Indication',
                    value: order.clinicalIndication!,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Specimens', style: theme.textTheme.titleMedium),
            ),
            if (canEnter)
              TextButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Collect'),
                onPressed: () => _showCollection(context, ref),
              ),
          ],
        ),
        if (value.specimens.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No specimens registered yet.'),
            ),
          )
        else
          ...value.specimens.map(
            (LabSpecimen specimen) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.qr_code_2),
                title: Text(specimen.accessionBarcode),
                subtitle: Text(
                  '${specimen.specimenType} · ${specimen.status.wireValue}',
                ),
                trailing:
                    specimen.status == LabSpecimenStatus.pending && canEnter
                    ? IconButton(
                        icon: const Icon(Icons.check_circle_outline),
                        tooltip: 'Mark collected',
                        onPressed: () => _collect(context, ref, specimen),
                      )
                    : null,
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Results', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (value.results.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No results entered yet.'),
            ),
          )
        else
          ...value.results.map(
            (LabResult result) => _ResultCard(
              result: result,
              canVerify: canVerify,
              onVerify: () => _verify(context, ref, result),
            ),
          ),
        if (canEnter &&
            value.specimens.any(
              (LabSpecimen s) => s.status == LabSpecimenStatus.collected,
            ))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(
              icon: const Icon(Icons.add_chart),
              label: const Text('Enter result'),
              onPressed: () => _showResultEntry(context, ref),
            ),
          ),
      ],
    );
  }

  Future<void> _showCollection(BuildContext context, WidgetRef ref) async {
    final _SpecimenDraft? draft = await showModalBottomSheet<_SpecimenDraft>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => const _SpecimenSheet(),
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    try {
      await ref
          .read(registerSpecimenUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: session.tenantId!,
            labOrderId: value.order.id,
            accessionBarcode: draft.barcode,
            specimenType: draft.type,
          );
      ref.invalidate(labOrderDetailProvider(value.order.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _collect(
    BuildContext context,
    WidgetRef ref,
    LabSpecimen specimen,
  ) async {
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    if (userId == null) return;
    try {
      await ref
          .read(collectSpecimenUseCaseProvider)
          .call(
            policy: session.authorization,
            specimenId: specimen.id,
            collectorId: userId,
          );
      ref.invalidate(labOrderDetailProvider(value.order.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _showResultEntry(BuildContext context, WidgetRef ref) async {
    final _ResultDraft? draft = await showModalBottomSheet<_ResultDraft>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => const _ResultSheet(),
    );
    if (draft == null) return;
    final SessionState session = ref.read(sessionProvider);
    final LabSpecimen specimen = value.specimens.firstWhere(
      (LabSpecimen s) => s.status == LabSpecimenStatus.collected,
    );
    try {
      await ref
          .read(enterLabResultUseCaseProvider)
          .call(
            policy: session.authorization,
            tenantId: session.tenantId!,
            labOrderId: value.order.id,
            specimenId: specimen.id,
            analyteCode: draft.code,
            analyteName: draft.name,
            enteredBy: session.user!.userId,
            valueText: draft.value,
            unit: draft.unit,
          );
      ref.invalidate(labOrderDetailProvider(value.order.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  Future<void> _verify(
    BuildContext context,
    WidgetRef ref,
    LabResult result,
  ) async {
    final SessionState session = ref.read(sessionProvider);
    final String? userId = session.user?.userId;
    if (userId == null) return;
    try {
      await ref
          .read(verifyLabResultUseCaseProvider)
          .call(
            policy: session.authorization,
            result: result,
            verifierId: userId,
          );
      ref.invalidate(labOrderDetailProvider(value.order.id));
    } on NodexError catch (error) {
      if (context.mounted) _snack(context, error.message);
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LabFact extends StatelessWidget {
  const _LabFact({required this.label, required this.value});
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

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.canVerify,
    required this.onVerify,
  });
  final LabResult result;
  final bool canVerify;
  final VoidCallback onVerify;
  @override
  Widget build(BuildContext context) {
    final bool verified = result.status != LabResultStatus.entered;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          verified ? Icons.verified_outlined : Icons.pending_outlined,
        ),
        title: Text('${result.analyteName} (${result.analyteCode})'),
        subtitle: Text(
          '${result.valueText ?? result.valueNumeric} ${result.unit ?? ''} · ${result.status.wireValue}',
        ),
        trailing: result.status == LabResultStatus.entered && canVerify
            ? IconButton(
                icon: const Icon(Icons.check_circle),
                tooltip: 'Verify result',
                onPressed: onVerify,
              )
            : null,
        isThreeLine: false,
      ),
    );
  }
}

class _SpecimenDraft {
  const _SpecimenDraft({required this.barcode, required this.type});
  final String barcode;
  final String type;
}

class _SpecimenSheet extends StatefulWidget {
  const _SpecimenSheet();
  @override
  State<_SpecimenSheet> createState() => _SpecimenSheetState();
}

class _SpecimenSheetState extends State<_SpecimenSheet> {
  final TextEditingController _barcode = TextEditingController();
  final TextEditingController _type = TextEditingController(text: 'blood');
  @override
  void dispose() {
    _barcode.dispose();
    _type.dispose();
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
            'Register specimen',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _barcode,
            decoration: const InputDecoration(labelText: 'Accession barcode *'),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _type,
            decoration: const InputDecoration(labelText: 'Specimen type *'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_barcode.text.trim().isEmpty || _type.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(
                context,
                _SpecimenDraft(
                  barcode: _barcode.text.trim(),
                  type: _type.text.trim(),
                ),
              );
            },
            child: const Text('Register'),
          ),
        ],
      ),
    );
  }
}

class _ResultDraft {
  const _ResultDraft({
    required this.code,
    required this.name,
    required this.value,
    this.unit,
  });
  final String code;
  final String name;
  final String value;
  final String? unit;
}

class _ResultSheet extends StatefulWidget {
  const _ResultSheet();
  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _value = TextEditingController();
  final TextEditingController _unit = TextEditingController();
  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _value.dispose();
    _unit.dispose();
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
            'Enter laboratory result',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Analyte code *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Analyte name *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            decoration: const InputDecoration(labelText: 'Value *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _unit,
            decoration: const InputDecoration(labelText: 'Unit'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (_code.text.trim().isEmpty ||
                  _name.text.trim().isEmpty ||
                  _value.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(
                context,
                _ResultDraft(
                  code: _code.text.trim(),
                  name: _name.text.trim(),
                  value: _value.text.trim(),
                  unit: _unit.text.trim().isEmpty ? null : _unit.text.trim(),
                ),
              );
            },
            child: const Text('Save entered result'),
          ),
        ],
      ),
    );
  }
}

class _LabError extends StatelessWidget {
  const _LabError({required this.error, required this.onRetry});
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
              : 'Laboratory order unavailable',
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
