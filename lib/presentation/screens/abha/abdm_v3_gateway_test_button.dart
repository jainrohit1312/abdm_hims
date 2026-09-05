import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../config/app_config.dart';
import '../../../core/enums/user_role.dart';
import '../../../services/abdm_service.dart';
import 'abdm_connection_test_button.dart';

/// Owner/super-admin-only "Test V3 Gateway" diagnostic action.
///
/// The button is hidden for non-owner roles (server-side enforcement still
/// happens inside the `abdm-gateway` Edge Function). On tap it delegates to
/// [AbdmService.diagnoseV3Gateway], which posts exactly
/// `{"action":"diagnoseV3Gateway"}` to the existing Edge Function. The Edge
/// Function performs an isolated V3 session POST + bridge-services GET against
/// the fixed Sandbox origin `https://dev.abdm.gov.in` and returns only
/// allow-listed diagnostic metadata.
///
/// SECURITY: the raw Supabase JWT, the raw ABDM V3 access token and the Client
/// Secret are never displayed, logged, persisted, copied to the clipboard or
/// returned by this widget or by [AbdmService].
class AbdmV3GatewayTestButton extends ConsumerStatefulWidget {
  const AbdmV3GatewayTestButton({super.key});

  @override
  ConsumerState<AbdmV3GatewayTestButton> createState() =>
      _AbdmV3GatewayTestButtonState();
}

class _AbdmV3GatewayTestButtonState
    extends ConsumerState<AbdmV3GatewayTestButton> {
  bool _isRunning = false;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (!UserRole.isOwnerOrSuperAdmin(role)) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _isRunning ? null : _runDiagnostic,
      icon: _isRunning
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.science_outlined),
      label: Text(_isRunning ? 'Testing...' : 'Test V3 Gateway'),
    );
  }

  Future<void> _runDiagnostic() async {
    // Prevent duplicate clicks while a diagnostic is already in flight.
    if (_isRunning) return;
    setState(() => _isRunning = true);

    try {
      final result = await ref.read(abdmServiceProvider).diagnoseV3Gateway();
      if (!mounted) return;
      setState(() => _isRunning = false);
      await _showResultDialog(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isRunning = false);
      _showFailureSnackBar(error);
    }
  }

  Future<void> _showResultDialog(Map<String, dynamic> result) async {
    final sessionSucceeded = result['sessionSucceeded'] == true;
    final servicesSucceeded = result['servicesSucceeded'] == true;
    final succeeded = sessionSucceeded && servicesSucceeded;

    final code = _safeText(result['code']);
    final message = redactTokenLike(_safeText(result['message']));
    final supportReference = _safeText(result['supportReference']);
    final stage = _safeText(result['stage']);
    final sessionUpstream = _optionalNumberText(
      result['sessionUpstreamStatus'],
    );
    final servicesUpstream = _optionalNumberText(
      result['servicesUpstreamStatus'],
    );
    final serviceCount = _optionalNumberText(result['serviceCount']);

    final rawServices = result['services'];
    final services = rawServices is List
        ? rawServices
              .whereType<Map>()
              .map(_sanitizeServiceRow)
              .where((row) => row.isNotEmpty)
              .toList()
        : const <Map<String, String>>[];

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          succeeded
              ? 'V3 Gateway diagnostic succeeded.'
              : 'V3 Gateway diagnostic incomplete.',
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (succeeded)
                  const Text(
                    'V3 session and services inspection succeeded.\n'
                    'Bridge URL configuration has not been changed.',
                  )
                else ...[
                  if (code.isNotEmpty) _infoRow('Result code', code),
                  if (message.isNotEmpty) _infoRow('Message', message),
                ],
                _infoRow('Environment', AppConfig.abdmEnvironment),
                _infoRow('Session succeeded', sessionSucceeded ? 'Yes' : 'No'),
                if (sessionUpstream != null)
                  _infoRow('Session upstream', sessionUpstream),
                _infoRow(
                  'Services succeeded',
                  servicesSucceeded ? 'Yes' : 'No',
                ),
                if (servicesUpstream != null)
                  _infoRow('Services upstream', servicesUpstream),
                if (serviceCount != null)
                  _infoRow('Service count', serviceCount),
                if (stage.isNotEmpty) _infoRow('Stage', stage),
                if (supportReference.isNotEmpty)
                  _infoRow('Reference', supportReference),
                if (services.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Services',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: services.length,
                      itemBuilder: (context, index) {
                        final service = services[index];
                        final id = service['id'] ?? '';
                        final name = service['name'] ?? '';
                        final type = service['type'] ?? '';
                        final active = service['active'];
                        final activeText = active == 'true'
                            ? ''
                            : ' (inactive)';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            '• ${id.isNotEmpty ? id : '(no id)'} — '
                            '${name.isNotEmpty ? name : '(no name)'} '
                            '[${type.isNotEmpty ? type : '?'}]$activeText',
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
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

  /// Keeps only the allow-listed service fields (id/name/type/active) and
  /// applies defensive token redaction to every string.
  Map<String, String> _sanitizeServiceRow(Map<dynamic, dynamic> raw) {
    final row = <String, String>{};
    for (final key in const ['id', 'name', 'type']) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) {
        row[key] = redactTokenLike(value.trim());
      }
    }
    final active = raw['active'];
    if (active is bool) row['active'] = active ? 'true' : 'false';
    return row;
  }

  String _safeText(Object? value) {
    return value?.toString().trim() ?? '';
  }

  String? _optionalNumberText(Object? value) {
    if (value is num) return value.toString();
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
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
        content: Text(abdmV3GatewayFailureMessage(error)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

/// Maps any V3-diagnostic invocation failure to a short, sanitized message for
/// the UI. Never echoes the raw Supabase JWT, the raw ABDM V3 access token or
/// the Client Secret.
String abdmV3GatewayFailureMessage(Object error) {
  if (error is AbdmException) {
    if (error.code == 'NO_SESSION') return 'Please log in again.';

    final status = error.statusCode;
    if (status == 401) return 'Supabase login expired';
    if (status == 403) return 'Owner/super-admin access required';
    if (status == 429) {
      return 'Too many V3 gateway diagnostics. Please wait a moment and try again.';
    }

    final message = error.message;
    final lower = message.toLowerCase();
    if (lower.contains('unreachable') ||
        lower.contains('unavailable') ||
        lower.contains('timeout') ||
        lower.contains('could not reach')) {
      return 'Network timeout or ABDM gateway unavailable.';
    }
    return redactTokenLike(message);
  }
  return 'Network timeout or ABDM gateway unavailable.';
}
