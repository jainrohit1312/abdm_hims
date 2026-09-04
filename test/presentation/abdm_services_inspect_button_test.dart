import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abdm_services_inspect_button.dart';
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
  Future<Map<String, dynamic>> inspectAbdmServices() => onInspect();
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
  group('AbdmServicesInspectButton', () {
    testWidgets('is hidden for non-owner roles', (tester) async {
      final service = _FakeAbdmService(
        onInspect: () async => fail('non-owner must not be able to inspect'),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmServicesInspectButton(),
          role: 'doctor',
          service: service,
        ),
      );

      expect(find.text('Inspect ABDM Services'), findsNothing);
      expect(find.byType(AbdmServicesInspectButton), findsOneWidget);
    });

    testWidgets('shows sanitized service metadata for owners', (tester) async {
      final service = _FakeAbdmService(
        onInspect: () async => {
          'status': 'services_fetched',
          'upstreamStatus': 200,
          'serviceCount': 1,
          'services': [
            {
              'id': 'hip-1',
              'name': 'Demo HIP',
              'type': 'HIP',
              'active': true,
              'alias': ['Demo'],
              'endpoints': [
                {
                  'address':
                      'https://example.supabase.co/functions/v1/abdm-gateway',
                  'connectionType': 'https',
                  'use': 'PATIENT_STATUS_NOTIFY',
                },
              ],
            },
          ],
          'accessToken': 'must-never-be-shown',
          'clientSecret': 'must-never-be-shown',
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmServicesInspectButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Inspect ABDM Services'));
      await tester.pumpAndSettle();

      expect(find.text('ABDM Services inspected.'), findsOneWidget);
      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Upstream status'), findsOneWidget);
      expect(find.text('Service count'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.textContaining('hip-1'), findsOneWidget);
      expect(find.textContaining('Demo HIP'), findsOneWidget);

      expect(find.textContaining('must-never-be-shown'), findsNothing);
      expect(find.textContaining('accessToken'), findsNothing);
      expect(find.textContaining('clientSecret'), findsNothing);
    });

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
          const AbdmServicesInspectButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Inspect ABDM Services'));
      await tester.pumpAndSettle();

      expect(find.text('Please log in again.'), findsOneWidget);
    });
  });

  group('abdmServicesFailureMessage', () {
    test('maps session, role and structured diagnostic failures', () {
      expect(
        abdmServicesFailureMessage(
          const AbdmException('Please log in again.', code: 'NO_SESSION'),
        ),
        'Please log in again.',
      );

      expect(
        abdmServicesFailureMessage(
          const AbdmException(
            'Invalid or expired user session',
            statusCode: 401,
          ),
        ),
        'Supabase login expired',
      );

      expect(
        abdmServicesFailureMessage(
          const AbdmException(
            'Owner / super-admin role required for this action',
            statusCode: 403,
          ),
        ),
        'Owner/super-admin access required',
      );

      expect(
        abdmServicesFailureMessage(
          const AbdmException(
            'ABDM getServices failed (HTTP 403): Resource forbidden',
            code: 'ABDM_GET_SERVICES_403',
            statusCode: 502,
          ),
        ),
        'ABDM_GET_SERVICES_403: ABDM getServices failed (HTTP 403): '
        'Resource forbidden',
      );

      expect(
        abdmServicesFailureMessage(
          const AbdmException(
            'ABDM getServices timed out before receiving a response.',
            code: 'ABDM_GET_SERVICES_TIMEOUT',
            statusCode: 502,
          ),
        ),
        'ABDM_GET_SERVICES_TIMEOUT: '
        'ABDM getServices timed out before receiving a response.',
      );

      expect(
        abdmServicesFailureMessage(
          const AbdmException(
            'ABDM getServices failed: the ABDM gateway is unreachable.',
            code: 'ABDM_GET_SERVICES_NETWORK',
            statusCode: 502,
          ),
        ),
        'ABDM_GET_SERVICES_NETWORK: '
        'ABDM getServices failed: the ABDM gateway is unreachable.',
      );
    });

    test('never echoes raw JWT or ABDM tokens', () {
      const rawJwt = 'eyJhbGciOiJIUzI1NiJ9.owner-jwt-payload.signature';

      final jwtError = abdmServicesFailureMessage(
        AbdmException('Failed with token $rawJwt'),
      );
      expect(jwtError.contains(rawJwt), isFalse);
    });
  });
}
