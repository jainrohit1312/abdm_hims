import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abdm_bridge_configure_button.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeAbdmService extends AbdmService {
  _FakeAbdmService({required this.onConfigure})
    : super(
        supabaseClient: SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        mockModeOverride: false,
      );

  final Future<Map<String, dynamic>> Function() onConfigure;

  @override
  Future<Map<String, dynamic>> configureBridge() => onConfigure();
}

Widget _wrap(
  Widget child, {
  required String? role,
  required AbdmService service,
}) {
  return ProviderScope(
    overrides: [
      currentUserRoleProvider.overrideWithValue(role),
      abdmServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('AbdmBridgeConfigureButton', () {
    testWidgets('is hidden for non-owner roles', (tester) async {
      final service = _FakeAbdmService(
        onConfigure: () async =>
            fail('non-owner must not be able to configure'),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmBridgeConfigureButton(),
          role: 'doctor',
          service: service,
        ),
      );

      expect(find.text('Configure Bridge'), findsNothing);
      expect(find.byType(AbdmBridgeConfigureButton), findsOneWidget);
    });

    testWidgets('is hidden when no role is available', (tester) async {
      final service = _FakeAbdmService(
        onConfigure: () async =>
            fail('a missing role must not allow configuring'),
      );

      await tester.pumpWidget(
        _wrap(const AbdmBridgeConfigureButton(), role: null, service: service),
      );

      expect(find.text('Configure Bridge'), findsNothing);
    });

    testWidgets('asks for confirmation before updating the Bridge', (
      tester,
    ) async {
      var calls = 0;
      final service = _FakeAbdmService(
        onConfigure: () async {
          calls += 1;
          return {
            'status': 'bridge_configured',
            'baseUrl': 'https://dev.abdm.gov.in',
            'callbackUrl':
                'https://example.supabase.co/functions/v1/abdm-gateway',
          };
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmBridgeConfigureButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Configure Bridge'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This will register the MediFlux secure callback endpoint with '
          'ABDM Sandbox. Continue?',
        ),
        findsOneWidget,
      );

      // Cancelling must not call the service.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);

      // Confirming must call the service exactly once.
      await tester.tap(find.text('Configure Bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('shows sanitized success information for owners', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onConfigure: () async => {
          'status': 'bridge_configured',
          'baseUrl': 'https://dev.abdm.gov.in',
          'callbackUrl':
              'https://example.supabase.co/functions/v1/abdm-gateway',
          'gateway': {'ok': true},
          'accessToken': 'must-never-be-shown',
          'clientSecret': 'must-never-be-shown',
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmBridgeConfigureButton(),
          role: 'super_admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Configure Bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('ABDM Bridge configured successfully.'), findsOneWidget);
      expect(find.text('Callback URL'), findsOneWidget);
      expect(
        find.text('https://example.supabase.co/functions/v1/abdm-gateway'),
        findsOneWidget,
      );
      expect(find.text('Gateway environment'), findsOneWidget);
      expect(find.text('Configuration status'), findsOneWidget);
      expect(find.text('bridge_configured'), findsOneWidget);

      expect(find.textContaining('must-never-be-shown'), findsNothing);
      expect(find.textContaining('accessToken'), findsNothing);
      expect(find.textContaining('clientSecret'), findsNothing);
    });

    testWidgets('shows "Please log in again." when the session is absent', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onConfigure: () async => throw const AbdmException(
          'Please log in again.',
          code: 'NO_SESSION',
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmBridgeConfigureButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Configure Bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Please log in again.'), findsOneWidget);
    });

    testWidgets('shows "Supabase login expired" for an expired session', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onConfigure: () async => throw const AbdmException(
          'Invalid or expired user session',
          statusCode: 401,
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmBridgeConfigureButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Configure Bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Supabase login expired'), findsOneWidget);
    });

    testWidgets('prevents duplicate clicks while configuring', (tester) async {
      var calls = 0;
      final completer = Completer<Map<String, dynamic>>();
      final service = _FakeAbdmService(
        onConfigure: () {
          calls += 1;
          return completer.future;
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmBridgeConfigureButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Configure Bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(calls, 1);
      expect(find.text('Configuring...'), findsOneWidget);

      // The button is disabled while a configuration is in flight.
      await tester.tap(find.text('Configuring...'));
      await tester.pump();
      expect(calls, 1);

      completer.complete({
        'status': 'bridge_configured',
        'baseUrl': 'https://dev.abdm.gov.in',
        'callbackUrl': 'https://example.supabase.co/functions/v1/abdm-gateway',
      });
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  group('abdmBridgeFailureMessage', () {
    test('maps session, role and sanitized server failures', () {
      expect(
        abdmBridgeFailureMessage(
          const AbdmException('Please log in again.', code: 'NO_SESSION'),
        ),
        'Please log in again.',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'Invalid or expired user session',
            statusCode: 401,
          ),
        ),
        'Supabase login expired',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'Owner / super-admin role required for this action',
            statusCode: 403,
          ),
        ),
        'Owner/super-admin access required',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'Missing ABDM_CALLBACK_BASE_URL Edge Function secret',
            statusCode: 500,
          ),
        ),
        'Missing ABDM callback secret. Configure ABDM_CALLBACK_BASE_URL '
        'in the Edge Function.',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM_CALLBACK_BASE_URL must use HTTPS',
            statusCode: 400,
          ),
        ),
        'Invalid ABDM callback URL. Configure a valid HTTPS '
        'ABDM_CALLBACK_BASE_URL.',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM_CALLBACK_BASE_URL must not use localhost or a private/local IP address',
            statusCode: 400,
          ),
        ),
        'Invalid ABDM callback URL. Configure a valid HTTPS '
        'ABDM_CALLBACK_BASE_URL.',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM bridge update failed (404)',
            statusCode: 404,
          ),
        ),
        'ABDM Gateway endpoint rejected the Bridge update. Verify '
        'ABDM_BRIDGE_PATH.',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM authentication rejected: verify Client ID/rotated Client Secret',
            statusCode: 502,
          ),
        ),
        'ABDM authentication rejected: verify Client ID/rotated Client Secret',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM gateway unavailable. Check network connectivity and try again.',
            statusCode: 502,
          ),
        ),
        'Network timeout or ABDM gateway unavailable.',
      );
    });

    test('never echoes raw JWT or ABDM tokens', () {
      const rawJwt = 'eyJhbGciOiJIUzI1NiJ9.owner-jwt-payload.signature';
      const rawAbdmToken = 'abdm-access-token-value';

      final jwtError = abdmBridgeFailureMessage(
        AbdmException('Failed with token $rawJwt'),
      );
      expect(jwtError.contains(rawJwt), isFalse);

      final abdmError = abdmBridgeFailureMessage(
        const AbdmException(
          'Unexpected ABDM failure',
          statusCode: 502,
          payload: {'accessToken': rawAbdmToken},
        ),
      );
      expect(abdmError.contains(rawAbdmToken), isFalse);
      expect(abdmError.contains('accessToken'), isFalse);
    });

    test('shows structured ABDM_BRIDGE_* diagnostic codes', () {
      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM Bridge update failed (HTTP 400): bad request',
            code: 'ABDM_BRIDGE_400',
            statusCode: 502,
            payload: {'upstreamStatus': 400},
          ),
        ),
        'ABDM_BRIDGE_400: ABDM Bridge update failed (HTTP 400): bad request',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM Bridge update failed (HTTP 401): unauthorized',
            code: 'ABDM_BRIDGE_401',
            statusCode: 502,
            payload: {'upstreamStatus': 401},
          ),
        ),
        'ABDM_BRIDGE_401: ABDM Bridge update failed (HTTP 401): unauthorized',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM Bridge update timed out before receiving a response.',
            code: 'ABDM_BRIDGE_TIMEOUT',
            statusCode: 502,
          ),
        ),
        'ABDM_BRIDGE_TIMEOUT: '
        'ABDM Bridge update timed out before receiving a response.',
      );

      expect(
        abdmBridgeFailureMessage(
          const AbdmException(
            'ABDM Bridge update failed: the ABDM gateway is unreachable.',
            code: 'ABDM_BRIDGE_NETWORK',
            statusCode: 502,
          ),
        ),
        'ABDM_BRIDGE_NETWORK: '
        'ABDM Bridge update failed: the ABDM gateway is unreachable.',
      );
    });
  });
}
