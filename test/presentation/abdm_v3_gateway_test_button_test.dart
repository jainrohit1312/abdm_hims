import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abdm_v3_gateway_test_button.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeAbdmService extends AbdmService {
  _FakeAbdmService({required this.onDiagnose})
    : super(
        supabaseClient: SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        mockModeOverride: false,
      );

  final Future<Map<String, dynamic>> Function() onDiagnose;

  @override
  Future<Map<String, dynamic>> diagnoseV3Gateway() => onDiagnose();
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

Map<String, dynamic> _successResult() => {
  'operation': 'diagnoseV3Gateway',
  'environment': 'sandbox',
  'sessionSucceeded': true,
  'sessionUpstreamStatus': 200,
  'servicesSucceeded': true,
  'servicesUpstreamStatus': 200,
  'serviceCount': 1,
  'services': [
    {'id': 'hip-1', 'name': 'Demo HIP', 'type': 'HIP', 'active': true},
  ],
  'supportReference': 'req_123',
  'stage': 'complete',
  'code': 'ABDM_V3_OK',
  'message':
      'V3 session and services inspection succeeded. '
      'Bridge URL configuration has not been changed.',
};

void main() {
  group('AbdmV3GatewayTestButton', () {
    testWidgets('is hidden for non-owner roles', (tester) async {
      final service = _FakeAbdmService(
        onDiagnose: () async => fail('non-owner must not run the diagnostic'),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmV3GatewayTestButton(),
          role: 'doctor',
          service: service,
        ),
      );

      expect(find.text('Test V3 Gateway'), findsNothing);
      expect(find.byType(AbdmV3GatewayTestButton), findsOneWidget);
    });

    testWidgets('shows the safe success dialog with the required sentence', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onDiagnose: () async => _successResult(),
      );

      await tester.pumpWidget(
        _wrap(const AbdmV3GatewayTestButton(), role: 'admin', service: service),
      );

      await tester.tap(find.text('Test V3 Gateway'));
      await tester.pumpAndSettle();

      expect(find.text('V3 Gateway diagnostic succeeded.'), findsOneWidget);
      expect(
        find.text(
          'V3 session and services inspection succeeded.\n'
          'Bridge URL configuration has not been changed.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('hip-1'), findsOneWidget);
      expect(find.textContaining('accessToken'), findsNothing);
      expect(find.textContaining('owner-jwt-raw-token'), findsNothing);
    });

    testWidgets('shows loading state and prevents duplicate clicks', (
      tester,
    ) async {
      final completer = Completer<Map<String, dynamic>>();
      var calls = 0;
      final service = _FakeAbdmService(
        onDiagnose: () {
          calls++;
          return completer.future;
        },
      );

      await tester.pumpWidget(
        _wrap(const AbdmV3GatewayTestButton(), role: 'admin', service: service),
      );

      await tester.tap(find.text('Test V3 Gateway'));
      await tester.pump();

      expect(find.text('Testing...'), findsOneWidget);
      expect(calls, 1);

      // The button is disabled while running; a second tap must not re-enter.
      await tester.tap(find.byType(TextButton), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      completer.complete(_successResult());
      await tester.pumpAndSettle();

      expect(find.text('V3 Gateway diagnostic succeeded.'), findsOneWidget);
      expect(calls, 1);
    });

    testWidgets(
      'shows sanitized failure metadata for an incomplete diagnostic',
      (tester) async {
        final service = _FakeAbdmService(
          onDiagnose: () async => {
            'operation': 'diagnoseV3Gateway',
            'environment': 'sandbox',
            'sessionSucceeded': false,
            'sessionUpstreamStatus': 401,
            'servicesSucceeded': false,
            'serviceCount': null,
            'services': <dynamic>[],
            'supportReference': 'req_456',
            'stage': 'session',
            'code': 'ABDM_V3_SESSION_401',
            'message': 'V3 session was rejected by ABDM (HTTP 401).',
            'accessToken': 'must-never-be-shown',
            'clientSecret': 'must-never-be-shown',
          },
        );

        await tester.pumpWidget(
          _wrap(
            const AbdmV3GatewayTestButton(),
            role: 'admin',
            service: service,
          ),
        );

        await tester.tap(find.text('Test V3 Gateway'));
        await tester.pumpAndSettle();

        expect(find.text('V3 Gateway diagnostic incomplete.'), findsOneWidget);
        expect(find.text('ABDM_V3_SESSION_401'), findsOneWidget);
        expect(
          find.text('V3 session was rejected by ABDM (HTTP 401).'),
          findsOneWidget,
        );
        expect(find.textContaining('must-never-be-shown'), findsNothing);
        expect(find.textContaining('accessToken'), findsNothing);
        expect(find.textContaining('clientSecret'), findsNothing);
      },
    );

    testWidgets('shows "Please log in again." when the session is absent', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onDiagnose: () async => throw const AbdmException(
          'Please log in again.',
          code: 'NO_SESSION',
        ),
      );

      await tester.pumpWidget(
        _wrap(const AbdmV3GatewayTestButton(), role: 'admin', service: service),
      );

      await tester.tap(find.text('Test V3 Gateway'));
      await tester.pumpAndSettle();

      expect(find.text('Please log in again.'), findsOneWidget);
    });
  });

  group('abdmV3GatewayFailureMessage', () {
    test('maps session, role and rate-limit failures', () {
      expect(
        abdmV3GatewayFailureMessage(
          const AbdmException('Please log in again.', code: 'NO_SESSION'),
        ),
        'Please log in again.',
      );

      expect(
        abdmV3GatewayFailureMessage(
          const AbdmException(
            'Invalid or expired user session',
            statusCode: 401,
          ),
        ),
        'Supabase login expired',
      );

      expect(
        abdmV3GatewayFailureMessage(
          const AbdmException(
            'Owner / super-admin role required for this action',
            statusCode: 403,
          ),
        ),
        'Owner/super-admin access required',
      );

      expect(
        abdmV3GatewayFailureMessage(
          const AbdmException(
            'Too many V3 gateway diagnostics',
            statusCode: 429,
          ),
        ),
        'Too many V3 gateway diagnostics. Please wait a moment and try again.',
      );
    });

    test('never echoes raw JWT or ABDM tokens', () {
      const rawJwt = 'eyJhbGciOiJIUzI1NiJ9.owner-jwt-payload.signature';

      final jwtError = abdmV3GatewayFailureMessage(
        AbdmException('Failed with token $rawJwt'),
      );
      expect(jwtError.contains(rawJwt), isFalse);

      final bearerError = abdmV3GatewayFailureMessage(
        const AbdmException('Failed with Bearer abcdefghijklmnopqrstuvwxyz'),
      );
      expect(bearerError.contains('abcdefghijklmnopqrstuvwxyz'), isFalse);
    });
  });
}
