import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abha_verify_screen.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeVerifyAbdmService extends AbdmService {
  _FakeVerifyAbdmService({
    required this.mockMode,
    required this.onVerifyAbhaId,
    required this.onSearchByMobile,
    required this.onVerifyAddress,
  }) : super(
         supabaseClient: SupabaseClient(
           'http://localhost',
           'anon-key',
           httpClient: MockClient((_) async => http.Response('{}', 200)),
           authOptions: const AuthClientOptions(autoRefreshToken: false),
         ),
         mockModeOverride: mockMode,
       );

  final bool mockMode;
  final Future<AbdmM1Response> Function(String abhaId) onVerifyAbhaId;
  final Future<AbdmM1Response> Function(String mobile) onSearchByMobile;
  final Future<AbdmM1Response> Function(String address) onVerifyAddress;

  @override
  bool get isMockMode => mockMode;

  @override
  Future<AbdmM1Response> verifyAbhaId(String abhaId) => onVerifyAbhaId(abhaId);

  @override
  Future<AbdmM1Response> searchAbhaByMobile(String mobile) =>
      onSearchByMobile(mobile);

  @override
  Future<AbdmM1Response> verifyAbhaAddress(String abhaAddress) =>
      onVerifyAddress(abhaAddress);
}

const _profile1 = AbdmM1Profile(
  healthId: '91-1234-5678-9012',
  healthIdNumber: '91-1234-5678-9012',
  abhaAddress: 'rahul9012@abdm',
  name: 'Rahul Sharma',
  gender: 'M',
);

const _profile2 = AbdmM1Profile(
  healthId: '91-4444-5555-6666',
  healthIdNumber: '91-4444-5555-6666',
  abhaAddress: 'rahul6666@abdm',
  name: 'Rahul Second',
  gender: 'M',
);

Widget _wrap(Widget child, AbdmService service) {
  return ProviderScope(
    overrides: [
      abdmServiceProvider.overrideWithValue(service),
      currentUserRoleProvider.overrideWithValue('receptionist'),
      supabaseClientProvider.overrideWithValue(
        SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      ),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  Future<void> pumpVerify(WidgetTester tester, AbdmService service) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_wrap(const ABHAVerifyScreen(), service));
    await tester.pump();
  }

  group('ABHAVerifyScreen', () {
    testWidgets('shows mock mode clearly and no optional OTP field', (
      tester,
    ) async {
      final service = _FakeVerifyAbdmService(
        mockMode: true,
        onVerifyAbhaId: (id) async => const AbdmM1Response(
          state: AbdmM1State.found,
          profile: _profile1,
          isMock: true,
        ),
        onSearchByMobile: (m) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onVerifyAddress: (a) async => const AbdmM1Response(
          state: AbdmM1State.verified,
          profile: _profile1,
          isMock: true,
        ),
      );

      await pumpVerify(tester, service);

      expect(find.textContaining('Mock/demo mode'), findsOneWidget);
      expect(find.text('OTP (optional)'), findsNothing);
    });

    testWidgets('labels ABHA ID search results as found, not verified', (
      tester,
    ) async {
      final service = _FakeVerifyAbdmService(
        mockMode: true,
        onVerifyAbhaId: (id) async => const AbdmM1Response(
          state: AbdmM1State.found,
          profile: _profile1,
          isMock: true,
        ),
        onSearchByMobile: (m) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onVerifyAddress: (a) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
      );

      await pumpVerify(tester, service);
      await tester.enterText(
        find.widgetWithText(TextField, 'ABHA Health ID'),
        '91-1234-5678-9012',
      );
      await tester.tap(find.text('Verify / Search'));
      await tester.pumpAndSettle();

      expect(find.text('ABHA Found'), findsWidgets);
      expect(find.text('ABHA Verified'), findsNothing);
      expect(find.text('Rahul Sharma'), findsWidgets);
    });

    testWidgets('labels ABHA address verification results as verified', (
      tester,
    ) async {
      final service = _FakeVerifyAbdmService(
        mockMode: true,
        onVerifyAbhaId: (id) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onSearchByMobile: (m) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onVerifyAddress: (a) async => const AbdmM1Response(
          state: AbdmM1State.verified,
          profile: _profile1,
          isMock: true,
        ),
      );

      await pumpVerify(tester, service);
      await tester.tap(find.text('ABHA Address'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'ABHA Address'),
        'rahul9012@abdm',
      );
      await tester.tap(find.text('Verify / Search'));
      await tester.pumpAndSettle();

      expect(find.text('ABHA Verified'), findsWidgets);
      expect(find.text('ABHA Not Found'), findsNothing);
    });

    testWidgets('shows a distinct not-found state', (tester) async {
      final service = _FakeVerifyAbdmService(
        mockMode: true,
        onVerifyAbhaId: (id) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onSearchByMobile: (m) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onVerifyAddress: (a) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
      );

      await pumpVerify(tester, service);
      await tester.enterText(
        find.widgetWithText(TextField, 'ABHA Health ID'),
        '91-0000-0000-0000',
      );
      await tester.tap(find.text('Verify / Search'));
      await tester.pumpAndSettle();

      expect(find.text('ABHA Not Found'), findsWidgets);
      expect(find.text('ABHA verified'), findsNothing);
    });

    testWidgets('handles multiple mobile accounts with a selection UI', (
      tester,
    ) async {
      final service = _FakeVerifyAbdmService(
        mockMode: true,
        onVerifyAbhaId: (id) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onSearchByMobile: (m) async => const AbdmM1Response(
          state: AbdmM1State.multipleAccounts,
          accounts: [_profile1, _profile2],
          isMock: true,
        ),
        onVerifyAddress: (a) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
      );

      await pumpVerify(tester, service);
      await tester.tap(find.text('Mobile'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Mobile Number'),
        '9999999999',
      );
      await tester.tap(find.text('Verify / Search'));
      await tester.pumpAndSettle();

      expect(find.text('Multiple ABHA Accounts Found'), findsOneWidget);
      expect(find.text('Rahul Sharma'), findsWidgets);
      expect(find.text('Rahul Second'), findsWidgets);

      await tester.tap(find.text('Rahul Second'));
      await tester.pumpAndSettle();

      expect(find.text('Rahul Second'), findsWidgets);
      expect(find.textContaining('91-4444-5555-6666'), findsWidgets);
    });

    testWidgets('shows sanitized failures without raw values', (tester) async {
      final service = _FakeVerifyAbdmService(
        mockMode: true,
        onVerifyAbhaId: (id) async {
          throw const AbdmException(
            'M1 contract unconfirmed',
            code: 'ABDM_M1_CONTRACT_UNCONFIRMED',
          );
        },
        onSearchByMobile: (m) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
        onVerifyAddress: (a) async =>
            const AbdmM1Response(state: AbdmM1State.notFound, isMock: true),
      );

      await pumpVerify(tester, service);
      await tester.enterText(
        find.widgetWithText(TextField, 'ABHA Health ID'),
        '91-1234-5678-9012',
      );
      await tester.tap(find.text('Verify / Search'));
      await tester.pumpAndSettle();

      expect(find.text('M1 contract unconfirmed'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('91-1234-5678-9012'),
        ),
        findsNothing,
      );
    });
  });
}
