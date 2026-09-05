import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../config/app_config.dart';
import '../../../core/enums/user_role.dart';
import '../../../services/abdm_service.dart';
import 'abdm_connection_test_button.dart';

/// Owner/super-admin-only "Inspect V3 Bridge" read-only action.
///
/// The button is hidden for non-owner roles (server-side enforcement still
/// happens inside the `abdm-gateway` Edge Function). On tap it delegates to
/// [AbdmService.inspectV3Bridge], which posts exactly
/// `{"action":"inspectV3Bridge"}` to the existing Edge Function. The Edge
/// Function reuses the isolated V3 session + GET bridge-services flow and
/// returns only a sanitized, shape-level description of the real
/// bridge-services response. No ABDM mutation is performed.
///
/// SECURITY: the raw Supabase JWT, the raw ABDM V3 access token and the Client
/// Secret are never displayed, logged, persisted, copied to the clipboard or
/// returned by this widget or by [AbdmService].
class AbdmV3BridgeInspectButton extends ConsumerStatefulWidget {
  const AbdmV3BridgeInspectButton({super.key});

  @override
  ConsumerState<AbdmV3BridgeInspectButton> createState() =>
      _AbdmV3BridgeInspectButtonState();
}

class _AbdmV3BridgeInspectButtonState
    extends ConsumerState<AbdmV3BridgeInspectButton> {
  bool _isRunning = false;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (!UserRole.isOwnerOrSuperAdmin(role)) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _isRunning ? null : _runInspection,
      icon: _isRunning
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.manage_search_outlined),
      label: Text(_isRunning ? 'Inspecting...' : 'Inspect V3 Bridge'),
    );
  }

  Future<void> _runInspection() async {
    // Prevent duplicate clicks while an inspection is already in flight.
    if (_isRunning) return;
    setState(() => _isRunning = true);

    try {
      final result = await ref.read(abdmServiceProvider).inspectV3Bridge();
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

    final rawEnvelope = result['envelope'];
    final envelope = rawEnvelope is Map
        ? Map<String, dynamic>.from(rawEnvelope)
        : const <String, dynamic>{};
    final topLevelType = _safeText(envelope['topLevelType']);
    final topLevelFields = _stringList(envelope['topLevelFieldNames']);
    final rawBridge = envelope['bridge'];
    final bridge = rawBridge is Map
        ? Map<String, dynamic>.from(rawBridge)
        : const <String, dynamic>{};
    final bridgeExists = bridge['exists'] == true;
    final bridgeFields = _stringList(bridge['fieldNames']);
    final rawBridgeUrl = envelope['bridgeUrl'];
    final bridgeUrl = rawBridgeUrl is Map
        ? Map<String, dynamic>.from(rawBridgeUrl)
        : const <String, dynamic>{};
    final bridgeUrlExists = bridgeUrl['exists'] == true;
    final bridgeUrlValue = redactTokenLike(_safeText(bridgeUrl['value']));
    final rawServices = envelope['services'];
    final services = rawServices is Map
        ? Map<String, dynamic>.from(rawServices)
        : const <String, dynamic>{};
    final servicesExists = services['exists'] == true;
    final servicesLength = _optionalNumberText(services['length']);
    final unknownEnvelopeFields = _stringList(
      envelope['unknownEnvelopeFieldNames'],
    );
    final serviceRows = _sanitizeServiceRows(services['items']);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          succeeded
              ? 'V3 Bridge inspected.'
              : 'V3 Bridge inspection incomplete.',
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
                    'V3 Bridge inspection succeeded.\n'
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
                if (topLevelType.isNotEmpty)
                  _infoRow('Top-level type', topLevelType),
                if (topLevelFields.isNotEmpty)
                  _infoRow('Top-level fields', topLevelFields.join(', ')),
                _infoRow('Bridge object', bridgeExists ? 'Yes' : 'No'),
                if (bridgeFields.isNotEmpty)
                  _infoRow('Bridge fields', bridgeFields.join(', ')),
                _infoRow('Bridge URL field', bridgeUrlExists ? 'Yes' : 'No'),
                if (bridgeUrlValue.isNotEmpty)
                  _infoRow('Bridge URL', bridgeUrlValue),
                _infoRow('Services field', servicesExists ? 'Yes' : 'No'),
                if (servicesLength != null)
                  _infoRow('Services length', servicesLength),
                if (unknownEnvelopeFields.isNotEmpty)
                  _infoRow(
                    'Unknown envelope fields',
                    unknownEnvelopeFields.join(', '),
                  ),
                if (stage.isNotEmpty) _infoRow('Stage', stage),
                if (supportReference.isNotEmpty)
                  _infoRow('Reference', supportReference),
                if (serviceRows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Services',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: serviceRows.length,
                      itemBuilder: (context, index) {
                        final service = serviceRows[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            '• ${service['id']!.isNotEmpty ? service['id'] : '(no id)'}'
                            ' — '
                            '${service['name']!.isNotEmpty ? service['name'] : '(no name)'}'
                            ' ['
                            '${service['type']!.isNotEmpty ? service['type'] : '?'}'
                            ']'
                            '${service['active'] == 'true' ? '' : ' (inactive)'}',
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
  List<Map<String, String>> _sanitizeServiceRows(Object? raw) {
    if (raw is! List) return const [];
    final rows = <Map<String, String>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final row = <String, String>{};
      for (final key in const ['id', 'name', 'type']) {
        final value = entry[key];
        if (value is String && value.trim().isNotEmpty) {
          row[key] = redactTokenLike(value.trim());
        }
      }
      final active = entry['active'];
      if (active is bool) row['active'] = active ? 'true' : 'false';
      rows.add(row);
    }
    return rows;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((entry) => redactTokenLike(entry.trim()))
        .where((entry) => entry.isNotEmpty)
        .toList();
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
          SizedBox(width: 170, child: Text(label)),
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
        content: Text(abdmV3BridgeInspectFailureMessage(error)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

/// Maps any V3 bridge-inspection invocation failure to a short, sanitized
/// message for the UI. Never echoes the raw Supabase JWT, the raw ABDM V3
/// access token or the Client Secret.
String abdmV3BridgeInspectFailureMessage(Object error) {
  if (error is AbdmException) {
    if (error.code == 'NO_SESSION') return 'Please log in again.';

    final status = error.statusCode;
    if (status == 401) return 'Supabase login expired';
    if (status == 403) return 'Owner/super-admin access required';
    if (status == 429) {
      return 'Too many V3 bridge inspections. Please wait a moment and try again.';
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
