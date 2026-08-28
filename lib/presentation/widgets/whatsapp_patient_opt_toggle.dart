import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/whatsapp_providers.dart';
import '../../core/utils/logger.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Patient Opt-In Toggle
/// ---------------------------------------------------------------------------
/// Drop-in widget for the patient profile screen. Shows the patient's current
/// WhatsApp marketing opt-in status and lets staff opt the patient in/out.
/// ---------------------------------------------------------------------------
class WhatsappPatientOptToggle extends ConsumerStatefulWidget {
  final String patientId;
  final String phoneNumber;

  const WhatsappPatientOptToggle({
    super.key,
    required this.patientId,
    required this.phoneNumber,
  });

  @override
  ConsumerState<WhatsappPatientOptToggle> createState() =>
      _WhatsappPatientOptToggleState();
}

class _WhatsappPatientOptToggleState
    extends ConsumerState<WhatsappPatientOptToggle> {
  bool _busy = false;

  Future<void> _toggle(bool optIn) async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) return;

    setState(() => _busy = true);
    final db = ref.read(whatsappDbServiceProvider);
    try {
      if (optIn) {
        await db.removeOptOut(hospitalId, widget.patientId);
        // Also record the consent on the patient master row.
        await db.markPatientOptIn(hospitalId, widget.patientId, true);
      } else {
        await db.optOutPatient(
          hospitalId: hospitalId,
          patientId: widget.patientId,
          phoneNumber: widget.phoneNumber,
          reason: 'Opted out from patient profile',
        );
        await db.markPatientOptIn(hospitalId, widget.patientId, false);
      }

      final params = WhatsappPatientOptInParams(
        hospitalId: hospitalId,
        patientId: widget.patientId,
        phoneNumber: widget.phoneNumber,
      );
      ref.invalidate(whatsappPatientOptOutProvider(params));
      invalidateWhatsappProviders(ref, hospitalId: hospitalId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              optIn
                  ? 'Patient opted in to WhatsApp messages.'
                  : 'Patient opted out of WhatsApp messages.',
            ),
            backgroundColor: optIn ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      AppLogger.e('Failed to update WhatsApp opt-in', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not update opt-in status: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return const SizedBox.shrink();
    }

    final params = WhatsappPatientOptInParams(
      hospitalId: hospitalId,
      patientId: widget.patientId,
      phoneNumber: widget.phoneNumber,
    );
    final optOutAsync = ref.watch(whatsappPatientOptOutProvider(params));
    final optedOut = optOutAsync.valueOrNull ?? false;

    return Card(
      child: SwitchListTile(
        value: !optedOut,
        onChanged: _busy ? null : (v) => _toggle(v),
        secondary: Icon(
          optedOut ? Icons.block : Icons.chat_outlined,
          color: optedOut ? theme.colorScheme.error : theme.colorScheme.primary,
        ),
        title: const Text('WhatsApp Marketing Messages'),
        subtitle: Text(
          optedOut
              ? 'Patient has opted out. They will not receive broadcasts.'
              : 'Patient is opted in and can receive WhatsApp broadcasts.',
        ),
      ),
    );
  }
}
