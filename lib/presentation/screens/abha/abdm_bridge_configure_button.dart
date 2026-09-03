import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../config/app_config.dart';
import '../../../core/enums/user_role.dart';
import '../../../services/abdm_service.dart';
import 'abdm_connection_test_button.dart';

/// Owner/super-admin-only "Configure ABDM Bridge" action.
///
/// The button is hidden for non-owner roles (server-side enforcement still
/// happens inside the `abdm-gateway` Edge Function). On tap it shows a
/// confirmation dialog, then delegates to [AbdmService.configureBridge], which
/// reads the current authenticated Supabase session internally and routes
/// through the secure Edge Function with exactly `{"action": "bridge"}`.
///
/// SECURITY: the raw Supabase JWT, the raw ABDM access token and the Client
/// Secret are never displayed, logged, persisted, copied to the clipboard or
/// returned by this widget or by [AbdmService]. The callback URL shown in the
/// success dialog comes from the sanitized Edge Function response.
class AbdmBridgeConfigureButton extends ConsumerStatefulWidget {
  const AbdmBridgeConfigureButton({super.key});

  @override
  ConsumerState<AbdmBridgeConfigureButton> createState() =>
      _AbdmBridgeConfigureButtonState();
}

class _AbdmBridgeConfigureButtonState
    extends ConsumerState<AbdmBridgeConfigureButton> {
  bool _isConfiguring = false;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (!UserRole.isOwnerOrSuperAdmin(role)) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _isConfiguring ? null : _confirmAndConfigure,
      icon: _isConfiguring
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.settings_ethernet),
      label: Text(_isConfiguring ? 'Configuring...' : 'Configure Bridge'),
    );
  }

  Future<void> _confirmAndConfigure() async {
    // Prevent duplicate clicks while a configuration is already in flight.
    if (_isConfiguring) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Configure ABDM Bridge?'),
        content: const Text(
          'This will register the MediFlux secure callback endpoint with '
          'ABDM Sandbox. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isConfiguring = true);

    try {
      final result = await ref.read(abdmServiceProvider).configureBridge();
      if (!mounted) return;
      setState(() => _isConfiguring = false);
      await _showSuccessDialog(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isConfiguring = false);
      _showFailureSnackBar(error);
    }
  }

  Future<void> _showSuccessDialog(Map<String, dynamic> result) async {
    final callbackUrl = result['callbackUrl']?.toString().trim() ?? '';
    final baseUrl = result['baseUrl']?.toString().trim() ?? '';
    final status = result['status']?.toString().trim() ?? 'bridge_configured';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ABDM Bridge configured successfully.'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Callback URL', callbackUrl),
            _infoRow(
              'Gateway environment',
              baseUrl.isNotEmpty ? baseUrl : AppConfig.abdmEnvironment,
            ),
            _infoRow('Configuration status', status),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label)),
          const Text(': '),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showFailureSnackBar(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(abdmBridgeFailureMessage(error)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

/// Maps any Bridge-configure failure to a short, sanitized message for the UI.
///
/// Never echoes the raw Supabase JWT, the raw ABDM access token or the Client
/// Secret — the input [error] is either a typed [AbdmException] produced by the
/// secure routing layer or a generic transport failure.
String abdmBridgeFailureMessage(Object error) {
  if (error is AbdmException) {
    final code = error.code;
    if (code != null && code.startsWith('ABDM_BRIDGE_')) {
      return abdmBridgeDiagnosticMessage(code, error);
    }
    if (code == 'NO_SESSION') return 'Please log in again.';

    final status = error.statusCode;
    if (status == 401) return 'Supabase login expired';
    if (status == 403) return 'Owner/super-admin access required';

    final message = error.message;
    final lower = message.toLowerCase();

    if (lower.contains('missing') && lower.contains('abdm_callback_base_url')) {
      return 'Missing ABDM callback secret. Configure ABDM_CALLBACK_BASE_URL '
          'in the Edge Function.';
    }
    if (lower.contains('callback_base_url') ||
        lower.contains('callback url') ||
        lower.contains('callbackurl')) {
      return 'Invalid ABDM callback URL. Configure a valid HTTPS '
          'ABDM_CALLBACK_BASE_URL.';
    }
    if (status == 404 || status == 405) {
      return 'ABDM Gateway endpoint rejected the Bridge update. Verify '
          'ABDM_BRIDGE_PATH.';
    }
    if (lower.contains('authentication rejected') ||
        lower.contains('verify client id')) {
      return 'ABDM authentication rejected: verify Client ID/rotated Client Secret';
    }
    if (lower.contains('unavailable') ||
        lower.contains('unreachable') ||
        lower.contains('could not reach') ||
        lower.contains('timeout')) {
      return 'Network timeout or ABDM gateway unavailable.';
    }
    return redactTokenLike(message);
  }
  return 'Network timeout or ABDM gateway unavailable.';
}

/// Renders a structured `ABDM_BRIDGE_*` diagnostic from the Edge Function as
/// a useful, still-sanitized UI message that includes the machine-readable code.
String abdmBridgeDiagnosticMessage(String code, AbdmException error) {
  final serverMessage = redactTokenLike(error.message.trim());
  if (serverMessage.isNotEmpty) return '$code: $serverMessage';

  switch (code) {
    case 'ABDM_BRIDGE_TIMEOUT':
      return '$code: ABDM Bridge update timed out.';
    case 'ABDM_BRIDGE_NETWORK':
      return '$code: ABDM gateway unreachable.';
    default:
      return '$code: ABDM Bridge update failed.';
  }
}
