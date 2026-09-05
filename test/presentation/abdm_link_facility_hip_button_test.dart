import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abdm_link_facility_hip_button.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeAbdmService extends AbdmService {
  _FakeAbdmService({required this.onLink})
    : super(
        supabaseClient: SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        mockModeOverride: false,
      );

  final Future<Map<String, dynamic>> Function() onLink;

  @override
  Future<Map<String, dynamic>> linkFacilityHip() => onLink();
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

Map<String, dynamic> _verifiedResult() => {
  'status': 'linkage_verified',
  'code': 'HFR_LINKAGE_OK',
  'message': 'HFR facility/HIP linkage accepted and verified.',
  'facilityId': 'IN2810014366',
  'bridgeId': 'bridge-1',
  'verification': {
    'byId': {
      'serviceIdMatches': true,
      'bridgeIdMatches': true,
      'isHip': true,
      'active': true,
    },
    'bridgeServices': {
      'containsFacility': true,
      'containsHipType': true,
      'active': true,
    },
    'byIdUpstreamStatus': 200,
    'servicesUpstreamStatus': 200,
  },
  'supportReference': 'req_123',
};

Map<String, dynamic> _pendingResult() => {
  'status': 'linkage_accepted_verification_pending',
  'code': 'HFR_LINKAGE_PENDING',
  'message':
      'HFR facility/HIP linkage accepted; verification pending ABDM propagation.',
  'facilityId': 'IN2810014366',
  'bridgeId': 'bridge-1',
  'verification': {
    'byId': {
      'serviceIdMatches': false,
      'bridgeIdMatches': null,
      'isHip': false,
      'active': false,
    },
    'bridgeServices': {
      'containsFacility': false,
      'containsHipType': false,
      'active': false,
    },
    'byIdUpstreamStatus': 404,
    'servicesUpstreamStatus': 200,
  },
  'supportReference': 'req_456',
};

void main() {
  group('AbdmLinkFacilityHipButton', () {
    testWidgets('is visible for owners and hidden for non-owners', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onLink: () async => fail('non-owner must not run the linkage'),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'doctor',
          service: service,
        ),
      );
      expect(find.text('Link Facility/HIP'), findsNothing);
      expect(find.byType(AbdmLinkFacilityHipButton), findsOneWidget);

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );
      expect(find.text('Link Facility/HIP'), findsOneWidget);
    });

    testWidgets('calls AbdmService.linkFacilityHip exactly once', (
      tester,
    ) async {
      var calls = 0;
      final service = _FakeAbdmService(
        onLink: () async {
          calls++;
          return _verifiedResult();
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Link Facility/HIP'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('Facility/HIP linked successfully.'), findsWidgets);
    });

    testWidgets('shows loading state and prevents duplicate linkage requests', (
      tester,
    ) async {
      final completer = Completer<Map<String, dynamic>>();
      var calls = 0;
      final service = _FakeAbdmService(
        onLink: () {
          calls++;
          return completer.future;
        },
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Link Facility/HIP'));
      await tester.pump();

      expect(find.text('Linking...'), findsOneWidget);
      expect(calls, 1);

      // Button is disabled while running; a second tap must not re-enter.
      await tester.tap(find.byType(TextButton), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      completer.complete(_verifiedResult());
      await tester.pumpAndSettle();

      expect(find.text('Facility/HIP linked successfully.'), findsWidgets);
      expect(calls, 1);
    });

    testWidgets('verified success shows sanitized verification fields', (
      tester,
    ) async {
      final service = _FakeAbdmService(onLink: () async => _verifiedResult());

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Link Facility/HIP'));
      await tester.pumpAndSettle();

      expect(find.text('Facility/HIP linked successfully.'), findsWidgets);
      expect(find.text('HFR_LINKAGE_OK'), findsOneWidget);
      expect(find.text('IN2810014366'), findsOneWidget);
      expect(find.text('bridge-1'), findsOneWidget);
      expect(find.text('serviceId matches'), findsOneWidget);
      expect(find.text('bridgeId matches'), findsOneWidget);
      expect(find.text('isHip'), findsOneWidget);
      expect(find.text('contains facility'), findsOneWidget);
      expect(find.text('contains HIP type'), findsOneWidget);
      expect(find.text('req_123'), findsOneWidget);
    });

    testWidgets('verification-pending response does not claim success', (
      tester,
    ) async {
      final service = _FakeAbdmService(onLink: () async => _pendingResult());

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Link Facility/HIP'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Facility/HIP linkage was accepted, but ABDM verification is still pending.',
        ),
        findsOneWidget,
      );
      expect(find.text('HFR_LINKAGE_PENDING'), findsOneWidget);
      expect(find.text('Facility/HIP linked successfully.'), findsNothing);
    });

    testWidgets('sanitized bridge mismatch error is shown without secrets', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onLink: () async => throw const AbdmException(
          'Configured ABDM_BRIDGE_ID does not match the live ABDM bridge.id; HFR linkage was not attempted.',
          code: 'ABDM_BRIDGE_ID_MISMATCH',
          statusCode: 502,
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Link Facility/HIP'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ABDM_BRIDGE_ID_MISMATCH'), findsOneWidget);
      expect(find.textContaining('accessToken'), findsNothing);
      expect(find.textContaining('clientSecret'), findsNothing);
    });

    testWidgets('shows "Please log in again." when the session is absent', (
      tester,
    ) async {
      final service = _FakeAbdmService(
        onLink: () async => throw const AbdmException(
          'Please log in again.',
          code: 'NO_SESSION',
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const AbdmLinkFacilityHipButton(),
          role: 'admin',
          service: service,
        ),
      );

      await tester.tap(find.text('Link Facility/HIP'));
      await tester.pumpAndSettle();

      expect(find.text('Please log in again.'), findsOneWidget);
    });
  });

  group('abdmLinkFacilityHipFailureMessage', () {
    test('maps structured backend codes', () {
      expect(
        abdmLinkFacilityHipFailureMessage(
          const AbdmException('mismatch', code: 'ABDM_BRIDGE_ID_MISMATCH'),
        ),
        contains('ABDM_BRIDGE_ID_MISMATCH'),
      );
      expect(
        abdmLinkFacilityHipFailureMessage(
          const AbdmException(
            'unavailable',
            code: 'ABDM_BRIDGE_ID_UNAVAILABLE',
          ),
        ),
        contains('ABDM_BRIDGE_ID_UNAVAILABLE'),
      );
      expect(
        abdmLinkFacilityHipFailureMessage(
          const AbdmException('rejected', code: 'HFR_AUTH_REJECTED'),
        ),
        contains('HFR_AUTH_REJECTED'),
      );
      expect(
        abdmLinkFacilityHipFailureMessage(
          const AbdmException('Please log in again.', code: 'NO_SESSION'),
        ),
        'Please log in again.',
      );
    });

    test('never echoes raw JWT or bearer tokens', () {
      final rawJwt = 'eyJhbGciOiJIUzI1NiJ9.owner-jwt-payload.signature';

      final jwtError = abdmLinkFacilityHipFailureMessage(
        AbdmException('Failed with token $rawJwt'),
      );
      expect(jwtError.contains(rawJwt), isFalse);

      final bearerError = abdmLinkFacilityHipFailureMessage(
        const AbdmException('Failed with Bearer abcdefghijklmnopqrstuvwxyz'),
      );
      expect(bearerError.contains('abcdefghijklmnopqrstuvwxyz'), isFalse);
    });
  });
}
