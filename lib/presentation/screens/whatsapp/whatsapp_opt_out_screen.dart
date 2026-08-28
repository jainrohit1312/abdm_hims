import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/whatsapp_providers.dart';
import '../../../models/whatsapp_models.dart';
import '../../widgets/smart_navigation.dart';
import 'whatsapp_ui.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Opt-Out Screen (`/whatsapp/opt-outs`)
/// ---------------------------------------------------------------------------
/// DND list management: patients who opted out of WhatsApp marketing can be
/// re-added (opt back in) here, and new opt-outs can be recorded manually.
/// ---------------------------------------------------------------------------
class WhatsappOptOutScreen extends ConsumerWidget {
  const WhatsappOptOutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('WhatsApp Opt-Outs'),
        isRootPage: false,
      ),
      floatingActionButton: hospitalId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOptOut(context, ref, hospitalId),
              icon: const Icon(Icons.block),
              label: const Text('Add Opt-Out'),
            ),
      body: hospitalId == null
          ? const Center(child: Text('Hospital not assigned to this user.'))
          : ref
                .watch(whatsappOptOutsProvider(hospitalId))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to load opt-outs: $error'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => ref.invalidate(
                            whatsappOptOutsProvider(hospitalId),
                          ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (optOuts) {
                    if (optOuts.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No opt-outs recorded.\nPatients can opt out from their profile or you can add one here.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: optOuts.length,
                      itemBuilder: (context, index) {
                        final optOut = optOuts[index];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.block, color: Colors.red),
                            title: Text(optOut.phoneNumber),
                            subtitle: Text(
                              'Patient: ${optOut.patientId.isEmpty ? 'N/A' : optOut.patientId}\n'
                              'Reason: ${optOut.reason.isEmpty ? '—' : optOut.reason}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            isThreeLine: true,
                            trailing: TextButton.icon(
                              onPressed: () => _removeOptOut(
                                context,
                                ref,
                                hospitalId,
                                optOut,
                              ),
                              icon: const Icon(Icons.restore, size: 18),
                              label: const Text('Opt Back In'),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }

  Future<void> _addOptOut(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
  ) async {
    List<WhatsappRecipient> audience;
    try {
      audience = await ref.read(whatsappAudienceProvider(hospitalId).future);
    } catch (_) {
      audience = const [];
    }

    if (!context.mounted) return;
    if (audience.isEmpty) {
      showWhatsappError(context, 'No patients available to opt out.');
      return;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _OptOutFormDialog(recipients: audience),
    );
    if (result == null) return;

    try {
      final recipient = result['recipient'] as WhatsappRecipient;
      final reason = result['reason'] as String;
      await ref
          .read(whatsappDbServiceProvider)
          .optOutPatient(
            hospitalId: hospitalId,
            patientId: recipient.patientId,
            phoneNumber: recipient.phoneNumber,
            reason: reason,
          );
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (context.mounted) {
        showWhatsappSuccess(
          context,
          '${recipient.name} opted out of WhatsApp messages.',
        );
      }
    } catch (e) {
      if (context.mounted) showWhatsappError(context, e);
    }
  }

  Future<void> _removeOptOut(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
    WhatsappOptOut optOut,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Opt Back In'),
        content: Text(
          'Allow ${optOut.phoneNumber} to receive WhatsApp messages again?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref
          .read(whatsappDbServiceProvider)
          .removeOptOut(hospitalId, optOut.patientId);
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);
      if (context.mounted) {
        showWhatsappSuccess(context, 'Patient can receive messages again.');
      }
    } catch (e) {
      if (context.mounted) showWhatsappError(context, e);
    }
  }
}

class _OptOutFormDialog extends StatefulWidget {
  final List<WhatsappRecipient> recipients;
  const _OptOutFormDialog({required this.recipients});

  @override
  State<_OptOutFormDialog> createState() => _OptOutFormDialogState();
}

class _OptOutFormDialogState extends State<_OptOutFormDialog> {
  WhatsappRecipient? _selected;
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Opt-Out'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<WhatsappRecipient>(
              initialValue: _selected,
              decoration: const InputDecoration(labelText: 'Patient'),
              items: widget.recipients
                  .map(
                    (r) => DropdownMenuItem(
                      value: r,
                      child: Text('${r.name} • ${r.phoneNumber}'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _selected = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. Patient requested DND',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_selected == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Select a patient.')),
              );
              return;
            }
            Navigator.pop(context, {
              'recipient': _selected,
              'reason': _reasonController.text.trim(),
            });
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
