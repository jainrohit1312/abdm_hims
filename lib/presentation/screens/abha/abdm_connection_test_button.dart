import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../config/app_config.dart';
import '../../../core/enums/user_role.dart';
import '../../../services/abdm_service.dart';

/// Owner/super-admin-only "Test ABDM Connection" action.
///
/// The button is hidden for non-owner roles (server-side enforcement still
/// happens inside the `abdm-gateway` Edge Function). On tap it delegates to
/// [AbdmService.testSandboxConnection], which reads the current authenticated
/// Supabase session internally and routes through the secure Edge Function with
/// `{"action": "session"}`.
///
/// SECURITY: the raw Supabase JWT and the raw ABDM access token are never
/// displayed, logged, persisted, copied to the clipboard or returned by this
/// widget or by [AbdmService].
class AbdmConnectionTestButton extends ConsumerStatefulWidget {
  const AbdmConnectionTestButton({super.key});

  @override
  ConsumerState<AbdmConnectionTestButton> createState() =>
      _AbdmConnectionTestButtonState();
}

class _AbdmConnectionTestButtonState
    extends ConsumerState<AbdmConnectionTestButton> {
  bool _isTesting = false;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (!UserRole.isOwnerOrSuperAdmin(role)) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _isTesting ? null : _testConnection,
      icon: _isTesting
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.cable),
      label: Text(_isTesting ? 'Testing...' : 'Test ABDM Connection'),
    );
  }

  Future<void> _testConnection() async {
    // Prevent duplicate clicks while a test is already in flight.
    if (_isTesting) return;
    setState(() => _isTesting = true);

    try {
      final result = await ref
          .read(abdmServiceProvider)
          .testSandboxConnection();
      if (!mounted) return;
      setState(() => _isTesting = false);
      await _showSuccessDialog(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isTesting = false);
      _showFailureSnackBar(error);
    }
  }

  Future<void> _showSuccessDialog(Map<String, dynamic> result) async {
    final sessionValidForSeconds = result['sessionValidForSeconds'];
    final validForText = sessionValidForSeconds is num
        ? _formatDuration(sessionValidForSeconds.toInt())
        : null;
    final baseUrl = result['baseUrl']?.toString().trim() ?? '';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ABDM Sandbox connected successfully.'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Environment', AppConfig.abdmEnvironment),
            _infoRow('Gateway reachable', 'Yes'),
            _infoRow('Authenticated', 'Yes'),
            if (baseUrl.isNotEmpty) _infoRow('Gateway URL', baseUrl),
            if (validForText != null)
              _infoRow('Session valid for', validForText),
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
        content: Text(abdmConnectionFailureMessage(error)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

/// Maps any connection-test failure to a short, sanitized message for the UI.
///
/// Never echoes the raw Supabase JWT or the raw ABDM access token — the input
/// [error] is either a typed [AbdmException] produced by the secure routing
/// layer or a generic transport failure.
String abdmConnectionFailureMessage(Object error) {
  if (error is AbdmException) {
    if (error.code == 'NO_SESSION') return 'Please log in again.';

    final status = error.statusCode;
    if (status == 401) return 'Supabase login expired';
    if (status == 403) return 'Owner/super-admin access required';
    if (status == 404 || status == 405) {
      return 'ABDM session endpoint may need v0.5 override';
    }

    final message = error.message;
    final lower = message.toLowerCase();
    if (lower.contains('authentication rejected') ||
        lower.contains('verify client id')) {
      return 'ABDM authentication rejected: verify Client ID/rotated Client Secret';
    }
    if (lower.contains('unavailable') ||
        lower.contains('unreachable') ||
        lower.contains('could not reach')) {
      return 'Network timeout or ABDM gateway unavailable.';
    }
    return _redactTokenLike(message);
  }
  return 'Network timeout or ABDM gateway unavailable.';
}

/// Defensive fallback redaction for any message that reaches the UI through an
/// unexpected path. JWT-shaped strings (`eyJ...`) and long `Bearer <token>`
/// values are replaced before display.
String _redactTokenLike(String message) {
  var redacted = message;
  redacted = redacted.replaceAll(
    RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
    '[REDACTED]',
  );
  redacted = redacted.replaceAll(
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{16,}'),
    'Bearer [REDACTED]',
  );
  return redacted;
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return 'expired';
  if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (remainingMinutes == 0) return '$hours hour${hours == 1 ? '' : 's'}';
  return '$hours hour${hours == 1 ? '' : 's'} $remainingMinutes min';
}
