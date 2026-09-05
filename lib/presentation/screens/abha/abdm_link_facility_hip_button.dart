import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums/user_role.dart';
import '../../../services/abdm_service.dart';
import 'abdm_connection_test_button.dart';

/// Owner/super-admin-only "Link Facility/HIP" action.
///
/// The button is hidden for non-owner roles (server-side enforcement still
/// happens inside the `abdm-gateway` Edge Function). On tap it delegates to
/// [AbdmService.linkFacilityHip], which posts exactly `{"action":"services"}`
/// to the existing Edge Function. facilityId, facilityName, bridgeId and
/// hipName are all resolved server-side from the hospital configuration and
/// Edge Function secrets — this widget never sends or displays them from
/// client input.
///
/// SECURITY: the raw Supabase JWT, the raw ABDM V3 access token, the Client
/// Secret and any Aadhaar/OTP/authorization values are never displayed,
/// logged, persisted, copied to the clipboard or returned by this widget or by
/// [AbdmService]. Only the sanitized backend response is shown.
class AbdmLinkFacilityHipButton extends ConsumerStatefulWidget {
  const AbdmLinkFacilityHipButton({super.key});

  @override
  ConsumerState<AbdmLinkFacilityHipButton> createState() =>
      _AbdmLinkFacilityHipButtonState();
}

class _AbdmLinkFacilityHipButtonState
    extends ConsumerState<AbdmLinkFacilityHipButton> {
  bool _isLinking = false;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (!UserRole.isOwnerOrSuperAdmin(role)) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _isLinking ? null : _runLinkage,
      icon: _isLinking
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.link_outlined),
      label: Text(_isLinking ? 'Linking...' : 'Link Facility/HIP'),
    );
  }

  Future<void> _runLinkage() async {
    // Prevent duplicate clicks / duplicate HFR linkage requests while a
    // linkage is already in flight.
    if (_isLinking) return;
    setState(() => _isLinking = true);

    try {
      final result = await ref.read(abdmServiceProvider).linkFacilityHip();
      if (!mounted) return;
      setState(() => _isLinking = false);
      await _showResultDialog(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLinking = false);
      _showFailureSnackBar(error);
    }
  }

  Future<void> _showResultDialog(Map<String, dynamic> result) async {
    final status = _safeText(result['status']);
    final code = redactTokenLike(_safeText(result['code']));
    final message = redactTokenLike(_safeText(result['message']));
    final supportReference = redactTokenLike(
      _safeText(result['supportReference']),
    );
    final facilityId = redactTokenLike(_safeText(result['facilityId']));
    final bridgeId = redactTokenLike(_safeText(result['bridgeId']));

    final rawVerification = result['verification'];
    final verification = rawVerification is Map
        ? Map<String, dynamic>.from(rawVerification)
        : const <String, dynamic>{};

    final rawById = verification['byId'];
    final byId = rawById is Map
        ? Map<String, dynamic>.from(rawById)
        : const <String, dynamic>{};
    final rawBridgeServices = verification['bridgeServices'];
    final bridgeServices = rawBridgeServices is Map
        ? Map<String, dynamic>.from(rawBridgeServices)
        : const <String, dynamic>{};

    final byIdServiceIdMatches = _boolText(byId['serviceIdMatches']);
    final byIdBridgeIdMatches = _nullableBoolText(byId['bridgeIdMatches']);
    final byIdIsHip = _boolText(byId['isHip']);
    final byIdActive = _boolText(byId['active']);
    final containsFacility = _boolText(bridgeServices['containsFacility']);
    final containsHipType = _boolText(bridgeServices['containsHipType']);
    final servicesActive = _boolText(bridgeServices['active']);

    final verified = status == 'linkage_verified';
    final pending = status == 'linkage_accepted_verification_pending';

    final title = verified
        ? 'Facility/HIP linked successfully.'
        : pending
        ? 'Facility/HIP linkage accepted'
        : 'Facility/HIP linkage result';
    final summary = verified
        ? 'Facility/HIP linked successfully.'
        : pending
        ? 'Facility/HIP linkage was accepted, but ABDM verification is still pending.'
        : (message.isNotEmpty
              ? message
              : 'Linkage completed with an unrecognized status.');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(summary),
                if (code.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow('Result code', code),
                ],
                if (facilityId.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow('Facility ID', facilityId),
                ],
                if (bridgeId.isNotEmpty) _infoRow('Bridge ID', bridgeId),
                if (byId.isNotEmpty || bridgeServices.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Verification',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
                if (byId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'By service ID',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (byIdServiceIdMatches != null)
                    _infoRow('serviceId matches', byIdServiceIdMatches),
                  if (byIdBridgeIdMatches != null)
                    _infoRow('bridgeId matches', byIdBridgeIdMatches),
                  if (byIdIsHip != null) _infoRow('isHip', byIdIsHip),
                  if (byIdActive != null) _infoRow('active', byIdActive),
                ],
                if (bridgeServices.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Bridge services',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (containsFacility != null)
                    _infoRow('contains facility', containsFacility),
                  if (containsHipType != null)
                    _infoRow('contains HIP type', containsHipType),
                  if (servicesActive != null)
                    _infoRow('active', servicesActive),
                ],
                if (supportReference.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _infoRow('Reference', supportReference),
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

  String _safeText(Object? value) => value?.toString().trim() ?? '';

  String? _boolText(Object? value) {
    if (value is bool) return value ? 'Yes' : 'No';
    return null;
  }

  String? _nullableBoolText(Object? value) {
    if (value is bool) return value ? 'Yes' : 'No';
    return 'Unknown';
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
        content: Text(abdmLinkFacilityHipFailureMessage(error)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

/// Maps any Link Facility/HIP failure to a short, sanitized message for the
/// UI. Structured backend codes are preserved; token-like values are always
/// redacted and Aadhaar/OTP/secrets are never echoed.
String abdmLinkFacilityHipFailureMessage(Object error) {
  if (error is AbdmException) {
    final code = error.code;
    switch (code) {
      case 'NO_SESSION':
        return 'Please log in again.';
      case 'ABDM_BRIDGE_ID_MISMATCH':
        return 'ABDM_BRIDGE_ID_MISMATCH: the configured ABDM bridge ID does '
            'not match the live ABDM bridge. Linkage was not attempted.';
      case 'ABDM_BRIDGE_ID_UNAVAILABLE':
        return 'ABDM_BRIDGE_ID_UNAVAILABLE: the live ABDM bridge ID could not '
            'be verified before linkage. Linkage was not attempted.';
      case 'HFR_AUTH_REJECTED':
        return 'HFR_AUTH_REJECTED: ABDM HFR rejected the linkage token.';
      case 'ABDM_MOCK_MODE':
        return error.message;
    }

    final status = error.statusCode;
    if (status == 401) return 'Supabase login expired';
    if (status == 403) return 'Owner/super-admin access required';
    if (status == 429) {
      return 'Too many ABDM requests. Please wait a moment and try again.';
    }

    final message = error.message;
    final lower = message.toLowerCase();
    if (lower.contains('facility id') ||
        lower.contains('hip name') ||
        lower.contains('bridge_id') ||
        lower.contains('facility name') ||
        lower.contains('not configured') ||
        lower.contains('settings')) {
      // Server-side validation / missing hospital HFR configuration.
      return redactTokenLike(message);
    }
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
