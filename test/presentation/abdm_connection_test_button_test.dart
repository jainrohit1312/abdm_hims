import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/core/enums/user_role.dart';
import 'package:abdm_hims/presentation/screens/abha/abdm_connection_test_button.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeAbdmService extends AbdmService {
  _FakeAbdmService({required this.onTest})
    : super(
        supabaseClient: SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        mockModeOverride: false,
      );

  final Future<Map<String, dynamic>> Function() onTest;

  @override
  Future<Map<String, dynamic>> testSandboxConnection() => onTest();
}

Widget _wrap(
  Widget child, {
  required String role,
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
  group('AbdmConnectionTestButton', () {
    testWidgets('is hidden for non-owner roles', (tester) async {
      final service = _FakeAbdmService(
        onTest: () async => fail('non-owner must not be able to test'),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmConnectionTestButton(),
          role: 'doctor',
          service: service,
        ),
      );

      expect(find.text('Test ABDM Connection'), findsNothing);
      expect(find.byType(AbdmConnectionTestButton), findsOneWidget);
    });

    testWidgets('shows sanitized success information for owners', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onTest: () async => {
          'status': 'connected',
          'baseUrl': 'https://sandbox.abdm.gov.in',
          'clientId': 'test****id',
          'sessionValidForSeconds': 120,
          'note':
              'ABDM session established server-side. '
              'The raw token is never returned.',
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmConnectionTestButton(),
          role: 'super_admin',
          service: service,
        ),
      );

      expect(find.text('Test ABDM Connection'), findsOneWidget);

      await tester.tap(find.text('Test ABDM Connection'));
      await tester.pumpAndSettle();

      expect(find.text('ABDM Sandbox connected successfully.'), findsOneWidget);
      expect(find.text('Gateway reachable'), findsOneWidget);
      expect(find.text('Authenticated'), findsOneWidget);
      expect(find.text('Session valid for'), findsOneWidget);
      expect(find.textContaining('accessToken'), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
    });

    testWidgets('shows "Please log in again." when no session exists', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onTest: () async => throw const AbdmException(
          'Please log in again.',
          code: 'NO_SESSION',
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmConnectionTestButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Test ABDM Connection'));
      await tester.pumpAndSettle();

      expect(find.text('Please log in again.'), findsOneWidget);
    });

    testWidgets('prevents duplicate clicks while a test is in flight', (
      tester,
    ) async {
      var calls = 0;
      final completer = Completer<Map<String, dynamic>>();
      final service = _FakeAbdmService(
        onTest: () {
          calls += 1;
          return completer.future;
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmConnectionTestButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Test ABDM Connection'));
      await tester.pump();
      await tester.tap(find.text('Testing...'));
      await tester.pump();

      expect(calls, 1);
      expect(find.text('Testing...'), findsOneWidget);

      completer.complete({'status': 'connected', 'sessionValidForSeconds': 60});
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  group('abdmConnectionFailureMessage', () {
    test('maps no-session and HTTP failures to sanitized messages', () {
      expect(
        abdmConnectionFailureMessage(
          const AbdmException('Please log in again.', code: 'NO_SESSION'),
        ),
        'Please log in again.',
      );

      expect(
        abdmConnectionFailureMessage(
          const AbdmException(
            'Invalid or expired user session',
            statusCode: 401,
          ),
        ),
        'Supabase login expired',
      );

      expect(
        abdmConnectionFailureMessage(
          const AbdmException(
            'Owner / super-admin role required for this action',
            statusCode: 403,
          ),
        ),
        'Owner/super-admin access required',
      );

      expect(
        abdmConnectionFailureMessage(
          const AbdmException('Not found', statusCode: 404),
        ),
        'ABDM session endpoint may need v0.5 override',
      );

      expect(
        abdmConnectionFailureMessage(
          const AbdmException('Method not allowed', statusCode: 405),
        ),
        'ABDM session endpoint may need v0.5 override',
      );
    });

    test('maps ABDM auth rejection and gateway unavailability', () {
      expect(
        abdmConnectionFailureMessage(
          const AbdmException(
            'ABDM authentication rejected: verify Client ID/rotated Client Secret',
            statusCode: 502,
          ),
        ),
        'ABDM authentication rejected: verify Client ID/rotated Client Secret',
      );

      expect(
        abdmConnectionFailureMessage(
          const AbdmException(
            'ABDM gateway unavailable. Check network connectivity and try again.',
            statusCode: 502,
          ),
        ),
        'Network timeout or ABDM gateway unavailable.',
      );

      expect(
        abdmConnectionFailureMessage(
          const AbdmException(
            'Could not reach the ABDM gateway function: timeout',
          ),
        ),
        'Network timeout or ABDM gateway unavailable.',
      );
    });

    test('never echoes raw JWT or ABDM tokens', () {
      const rawJwt = 'eyJhbGciOiJIUzI1NiJ9.owner-jwt-payload.signature';
      const rawAbdmToken = 'abdm-access-token-value';

      final jwtError = abdmConnectionFailureMessage(
        AbdmException('Failed with token $rawJwt'),
      );
      expect(jwtError.contains(rawJwt), isFalse);

      final abdmError = abdmConnectionFailureMessage(
        const AbdmException(
          'ABDM authentication rejected: verify Client ID/rotated Client Secret',
          statusCode: 502,
          payload: {'accessToken': rawAbdmToken},
        ),
      );
      expect(abdmError.contains(rawAbdmToken), isFalse);
      expect(abdmError.contains('accessToken'), isFalse);
    });
  });

  group('UserRole.isOwnerOrSuperAdmin (canonical owner-level roles)', () {
    test('accepts only admin and super_admin', () {
      expect(UserRole.isOwnerOrSuperAdmin('admin'), isTrue);
      expect(UserRole.isOwnerOrSuperAdmin('super_admin'), isTrue);
      expect(UserRole.isOwnerOrSuperAdmin('ADMIN'), isTrue);
      expect(UserRole.isOwnerOrSuperAdmin('Super_Admin'), isTrue);

      // No other role value — including any invented `owner` role — is
      // owner-level in this project.
      expect(UserRole.isOwnerOrSuperAdmin('owner'), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin('doctor'), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin('nurse'), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin('staff'), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin('billing_staff'), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin('lab_technician'), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin(''), isFalse);
      expect(UserRole.isOwnerOrSuperAdmin(null), isFalse);
    });
  });
}
