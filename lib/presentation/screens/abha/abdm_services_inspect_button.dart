import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums/user_role.dart';
import '../../../services/abdm_service.dart';
import 'abdm_connection_test_button.dart';

/// Owner/super-admin-only "Inspect ABDM Services" action.
///
/// The button is hidden for non-owner roles (server-side enforcement still
/// happens inside the `abdm-gateway` Edge Function). On tap it delegates to
/// [AbdmService.inspectAbdmServices], which reads the current authenticated
/// Supabase session internally and routes through the secure Edge Function
/// with exactly `{"action": "getServices"}` using POST. The Edge Function
/// then calls the official ABDM contract as an uppercase GET to
/// `/gateway/v1/bridges/getServices`.
///
/// SECURITY: the raw Supabase JWT, the raw ABDM access token and the Client
/// Secret are never displayed, logged, persisted, copied to the clipboard or
/// returned by this widget or by [AbdmService]. Only the sanitized service
/// list and diagnostic metadata returned by the Edge Function are shown.
class AbdmServicesInspectButton extends ConsumerStatefulWidget {
  const AbdmServicesInspectButton({super.key});

  @override
  ConsumerState<AbdmServicesInspectButton> createState() =>
      _AbdmServicesInspectButtonState();
}

class _AbdmServicesInspectButtonState
    extends ConsumerState<AbdmServicesInspectButton> {
  bool _isInspecting = false;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (!UserRole.isOwnerOrSuperAdmin(role)) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _isInspecting ? null : _inspectServices,
      icon: _isInspecting
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.fact_check_outlined),
      label: Text(_isInspecting ? 'Inspecting...' : 'Inspect ABDM Services'),
    );
  }

  Future<void> _inspectServices() async {
    if (_isInspecting) return;
    setState(() => _isInspecting = true);

    try {
      final result = await ref.read(abdmServiceProvider).inspectAbdmServices();
      if (!mounted) return;
      setState(() => _isInspecting = false);
      await _showSuccessDialog(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isInspecting = false);
      _showFailureSnackBar(error);
    }
  }

  Future<void> _showSuccessDialog(Map<String, dynamic> result) async {
    final status = result['status']?.toString().trim() ?? 'services_fetched';
    final upstreamStatus = result['upstreamStatus']?.toString().trim() ?? '';
    final serviceCount = result['serviceCount']?.toString().trim() ?? '0';
    final rawServices = result['services'];
    final services = rawServices is List ? rawServices : const [];

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ABDM Services inspected.'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow('Status', status),
              _infoRow('Upstream status', upstreamStatus),
              _infoRow('Service count', serviceCount),
              const SizedBox(height: 8),
              const Text(
                'Services',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              if (services.isEmpty)
                const Text('No services returned.')
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: services.length,
                    itemBuilder: (context, index) {
                      final service = services[index];
                      final map = service is Map ? service : const {};
                      final id = map['id']?.toString().trim() ?? '';
                      final name = map['name']?.toString().trim() ?? '';
                      final type = map['type']?.toString().trim() ?? '';
                      final active = map['active']?.toString() ?? '';
                      final endpoints = map['endpoints'];
                      final addressLines = endpoints is List
                          ? endpoints
                                .whereType<Map>()
                                .map(
                                  (e) => e['address']?.toString().trim() ?? '',
                                )
                                .where((a) => a.isNotEmpty)
                                .toList()
                          : const <String>[];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          '• ${id.isNotEmpty ? id : '(no id)'} — '
                          '${name.isNotEmpty ? name : '(no name)'} '
                          '[${type.isNotEmpty ? type : '?'}]'
                          '${active == 'true' ? '' : ' (inactive)'}'
                          '${addressLines.isEmpty ? '' : '\n    ${addressLines.join('\n    ')}'}',
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
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
        content: Text(abdmServicesFailureMessage(error)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

/// Maps any getServices-inspect failure to a short, sanitized message for the
/// UI. Never echoes the raw Supabase JWT, the raw ABDM access token or the
/// Client Secret.
String abdmServicesFailureMessage(Object error) {
  if (error is AbdmException) {
    final code = error.code;
    if (code != null && code.startsWith('ABDM_GET_SERVICES_')) {
      final serverMessage = redactTokenLike(error.message.trim());
      if (serverMessage.isNotEmpty) return '$code: $serverMessage';
      return '$code: ABDM getServices failed.';
    }
    if (code == 'NO_SESSION') return 'Please log in again.';

    final status = error.statusCode;
    if (status == 401) return 'Supabase login expired';
    if (status == 403) return 'Owner/super-admin access required';

    final message = error.message;
    final lower = message.toLowerCase();
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
