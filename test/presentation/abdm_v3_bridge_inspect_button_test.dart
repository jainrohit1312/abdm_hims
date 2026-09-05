import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abdm_v3_bridge_inspect_button.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeAbdmService extends AbdmService {
  _FakeAbdmService({required this.onInspect})
    : super(
        supabaseClient: SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        mockModeOverride: false,
      );

  final Future<Map<String, dynamic>> Function() onInspect;

  @override
  Future<Map<String, dynamic>> inspectV3Bridge() => onInspect();
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
  'operation': 'inspectV3Bridge',
  'environment': 'sandbox',
  'sessionSucceeded': true,
  'sessionUpstreamStatus': 200,
  'servicesSucceeded': true,
  'servicesUpstreamStatus': 200,
  'supportReference': 'req_123',
  'stage': 'complete',
  'code': 'ABDM_V3_OK',
  'message':
      'V3 Bridge inspection succeeded. '
      'Bridge URL configuration has not been changed.',
  'envelope': {
    'topLevelType': 'object',
    'topLevelFieldNames': ['bridge', 'services'],
    'bridge': {
      'exists': true,
      'fieldNames': ['url'],
    },
    'bridgeUrl': {'exists': true, 'value': 'https://cb.example/abdm'},
    'services': {
      'exists': true,
      'length': 1,
      'items': [
        {'id': 'hip-1', 'name': 'Demo HIP', 'type': 'HIP', 'active': true},
      ],
    },
    'unknownEnvelopeFieldNames': <dynamic>[],
  },
};

void main() {
  group('AbdmV3BridgeInspectButton', () {
    testWidgets('is hidden for non-owner roles', (tester) async {
      final service = _FakeAbdmService(
        onInspect: () async => fail('non-owner must not run the inspection'),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmV3BridgeInspectButton(),
          role: 'doctor',
          service: service,
        ),
      );

      expect(find.text('Inspect V3 Bridge'), findsNothing);
      expect(find.byType(AbdmV3BridgeInspectButton), findsOneWidget);
    });

    testWidgets('shows the sanitized envelope for owners', (tester) async {
      final service = _FakeAbdmService(onInspect: () async => _successResult());

      await tester.pumpWidget(
        _wrap(
          const AbdmV3BridgeInspectButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Inspect V3 Bridge'));
      await tester.pumpAndSettle();

      expect(find.text('V3 Bridge inspected.'), findsOneWidget);
      expect(
        find.text(
          'V3 Bridge inspection succeeded.\n'
          'Bridge URL configuration has not been changed.',
        ),
        findsOneWidget,
      );
      expect(find.text('Top-level type'), findsOneWidget);
      expect(find.text('object'), findsOneWidget);
      expect(find.text('bridge, services'), findsOneWidget);
      expect(find.text('https://cb.example/abdm'), findsOneWidget);
      expect(find.textContaining('hip-1'), findsOneWidget);
      expect(find.textContaining('accessToken'), findsNothing);
      expect(find.textContaining('clientSecret'), findsNothing);
      expect(find.textContaining('owner-jwt-raw-token'), findsNothing);
    });

    testWidgets('shows loading state and prevents duplicate clicks', (
      tester,
    ) async {
      final completer = Completer<Map<String, dynamic>>();
      var calls = 0;
      final service = _FakeAbdmService(
        onInspect: () {
          calls++;
          return completer.future;
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmV3BridgeInspectButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Inspect V3 Bridge'));
      await tester.pump();

      expect(find.text('Inspecting...'), findsOneWidget);
      expect(calls, 1);

      // The button is disabled while running; a second tap must not re-enter.
      await tester.tap(find.byType(TextButton), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      completer.complete(_successResult());
      await tester.pumpAndSettle();

      expect(find.text('V3 Bridge inspected.'), findsOneWidget);
      expect(calls, 1);
    });

    testWidgets(
      'shows sanitized failure metadata for an incomplete inspection',
      (tester) async {
        final service = _FakeAbdmService(
          onInspect: () async => {
            'operation': 'inspectV3Bridge',
            'environment': 'sandbox',
            'sessionSucceeded': false,
            'sessionUpstreamStatus': 401,
            'servicesSucceeded': false,
            'supportReference': 'req_456',
            'stage': 'session',
            'code': 'ABDM_V3_SESSION_401',
            'message': 'V3 session was rejected by ABDM (HTTP 401).',
            'envelope': null,
            'accessToken': 'must-never-be-shown',
            'clientSecret': 'must-never-be-shown',
          },
        );

        await tester.pumpWidget(
          _wrap(
            const AbdmV3BridgeInspectButton(),
            role: 'admin',
            service: service,
          ),
        );

        await tester.tap(find.text('Inspect V3 Bridge'));
        await tester.pumpAndSettle();

        expect(find.text('V3 Bridge inspection incomplete.'), findsOneWidget);
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
        onInspect: () async => throw const AbdmException(
          'Please log in again.',
          code: 'NO_SESSION',
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmV3BridgeInspectButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Inspect V3 Bridge'));
      await tester.pumpAndSettle();

      expect(find.text('Please log in again.'), findsOneWidget);
    });
  });

  group('abdmV3BridgeInspectFailureMessage', () {
    test('maps session, role and rate-limit failures', () {
      expect(
        abdmV3BridgeInspectFailureMessage(
          const AbdmException('Please log in again.', code: 'NO_SESSION'),
        ),
        'Please log in again.',
      );

      expect(
        abdmV3BridgeInspectFailureMessage(
          const AbdmException(
            'Invalid or expired user session',
            statusCode: 401,
          ),
        ),
        'Supabase login expired',
      );

      expect(
        abdmV3BridgeInspectFailureMessage(
          const AbdmException(
            'Owner / super-admin role required for this action',
            statusCode: 403,
          ),
        ),
        'Owner/super-admin access required',
      );

      expect(
        abdmV3BridgeInspectFailureMessage(
          const AbdmException(
            'Too many V3 bridge inspections',
            statusCode: 429,
          ),
        ),
        'Too many V3 bridge inspections. Please wait a moment and try again.',
      );
    });

    test('never echoes raw JWT or ABDM tokens', () {
      const rawJwt = 'eyJhbGciOiJIUzI1NiJ9.owner-jwt-payload.signature';

      final jwtError = abdmV3BridgeInspectFailureMessage(
        AbdmException('Failed with token $rawJwt'),
      );
      expect(jwtError.contains(rawJwt), isFalse);

      final bearerError = abdmV3BridgeInspectFailureMessage(
        const AbdmException('Failed with Bearer abcdefghijklmnopqrstuvwxyz'),
      );
      expect(bearerError.contains('abcdefghijklmnopqrstuvwxyz'), isFalse);
    });
  });
}
