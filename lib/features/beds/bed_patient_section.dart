/// Current stay section embedded in the patient detail screen (Module 11).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nodex_hms/app/providers.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/beds/bed.dart';
import 'package:nodex_hms/domain/session/session_state.dart';
import 'package:nodex_hms/features/beds/bed_controller.dart';
import 'package:nodex_hms/features/session/session_controller.dart';

/// Shows the patient's active stay with release, if admitted.
class BedPatientSection extends ConsumerWidget {
  /// Creates the section.
  const BedPatientSection({required this.patientId, super.key});

  /// Patient identifier.
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<BedAssignment?> stay = ref.watch(
      patientStayProvider(patientId),
    );
    final SessionState session = ref.watch(sessionProvider);
    final bool canAssign = session.authorization.can(
      NodexPermissions.bedAssign,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Inpatient stay', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        stay.when(
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
                error is NodexError ? error.message : 'Stay unavailable.',
              ),
            ),
          ),
          data: (BedAssignment? value) => value == null
              ? const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Not admitted. Allocate from the ward census.'),
                  ),
                )
              : Card(
                  child: ListTile(
                    leading: const Icon(Icons.single_bed),
                    title: const Text('Admitted'),
                    subtitle: Text(
                      'Since ${value.admittedAt.toLocal().toString()}',
                    ),
                    trailing: canAssign
                        ? IconButton(
                            icon: const Icon(Icons.logout_outlined),
                            tooltip: 'Release bed',
                            onPressed: () => _release(context, ref, value),
                          )
                        : null,
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _release(
    BuildContext context,
    WidgetRef ref,
    BedAssignment assignment,
  ) async {
    final TextEditingController controller = TextEditingController();
    final String? reason = await showModalBottomSheet<String>(
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
                'Release reason required',
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
                child: const Text('Release'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (reason == null) return;
    final SessionState session = ref.read(sessionProvider);
    try {
      await ref
          .read(releaseBedUseCaseProvider)
          .call(
            policy: session.authorization,
            assignment: assignment,
            reason: reason,
          );
      ref.invalidate(patientStayProvider(patientId));
    } on NodexError catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}
