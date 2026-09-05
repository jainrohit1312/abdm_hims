import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/presentation/screens/abha/abha_create_screen.dart';
import 'package:abdm_hims/services/abdm_service.dart';

class _FakeCreateAbdmService extends AbdmService {
  _FakeCreateAbdmService({
    required this.mockMode,
    required this.onGenerateOtp,
    required this.onVerifyOtp,
    required this.onCreateAbha,
    this.onRecordConsent,
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
  final Future<AbdmM1Txn> Function(String aadhaar) onGenerateOtp;
  final Future<AbdmM1Profile> Function(String txnId, String otp) onVerifyOtp;
  final Future<AbdmM1Profile> Function(String txnId) onCreateAbha;
  final Future<void> Function({
    required String purpose,
    required String consentText,
    required String consentVersion,
    String? patientId,
    String? abdmTransactionId,
  })?
  onRecordConsent;

  @override
  bool get isMockMode => mockMode;

  @override
  Future<AbdmM1Txn> generateAadhaarOtp(String aadhaarNumber) =>
      onGenerateOtp(aadhaarNumber);

  @override
  Future<AbdmM1Profile> verifyAadhaarOtp({
    required String txnId,
    required String otp,
  }) => onVerifyOtp(txnId, otp);

  @override
  Future<AbdmM1Profile> createAbhaId({
    required String txnId,
    String? preferredAbhaAddress,
    String? email,
  }) => onCreateAbha(txnId);

  @override
  Future<void> recordAbhaConsentEvidence({
    required String purpose,
    required String consentText,
    required String consentVersion,
    String? patientId,
    String? abdmTransactionId,
  }) async {
    await onRecordConsent?.call(
      purpose: purpose,
      consentText: consentText,
      consentVersion: consentVersion,
      patientId: patientId,
      abdmTransactionId: abdmTransactionId,
    );
  }
}

const _profile = AbdmM1Profile(
  healthId: '91-1234-5678-9012',
  healthIdNumber: '91-1234-5678-9012',
  abhaAddress: 'rahul9012@abdm',
  name: 'Rahul Sharma',
  gender: 'M',
  dateOfBirth: '1990-05-15',
  mobileNumber: 'XXXXXX9999',
  isNew: true,
);

Widget _wrap(Widget child, AbdmService service) {
  return ProviderScope(
    overrides: [abdmServiceProvider.overrideWithValue(service)],
    child: MaterialApp(home: child),
  );
}

void main() {
  Future<void> pumpCreate(
    WidgetTester tester,
    _FakeCreateAbdmService service,
  ) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_wrap(const ABHACreateScreen(), service));
    await tester.pump();
  }

  group('ABHACreateScreen', () {
    testWidgets('walks through the creation steps and shows the result', (
      tester,
    ) async {
      final service = _FakeCreateAbdmService(
        mockMode: true,
        onGenerateOtp: (aadhaar) async => const AbdmM1Txn('txn-1'),
        onVerifyOtp: (txnId, otp) async => _profile,
        onCreateAbha: (txnId) async => _profile,
      );

      await pumpCreate(tester, service);
      expect(find.text('Generate OTP').hitTestable().first, findsOneWidget);
      expect(find.textContaining('Mock/demo mode'), findsOneWidget);
      expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 0);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Aadhaar Number'),
        '123456789012',
      );
      await tester.tap(find.text('Generate OTP').hitTestable().first);
      await tester.pumpAndSettle();

      expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 1);
      expect(find.textContaining('Aadhaar ending 9012'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'OTP'),
        '123456',
      );
      await tester.tap(find.text('Verify OTP').hitTestable().first);
      await tester.pumpAndSettle();

      expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 2);
      expect(find.text('Preferred ABHA Address (optional)'), findsOneWidget);
      expect(find.text('Preferred ABHA Number (optional)'), findsNothing);

      await tester.tap(
        find.text('I consent to the creation of ABHA Health ID'),
      );
      await tester.pump();
      await tester.tap(find.text('Create ABHA').hitTestable().first);
      await tester.pumpAndSettle();

      expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 3);
      expect(find.text('91-1234-5678-9012'), findsOneWidget);
      expect(find.text('rahul9012@abdm'), findsOneWidget);
      expect(find.textContaining('Mock/demo result'), findsOneWidget);
    });

    testWidgets('guards against duplicate OTP generation clicks', (
      tester,
    ) async {
      var calls = 0;
      final completer = Completer<AbdmM1Txn>();
      final service = _FakeCreateAbdmService(
        mockMode: true,
        onGenerateOtp: (aadhaar) {
          calls += 1;
          return completer.future;
        },
        onVerifyOtp: (txnId, otp) async => _profile,
        onCreateAbha: (txnId) async => _profile,
      );

      await pumpCreate(tester, service);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Aadhaar Number'),
        '123456789012',
      );
      await tester.tap(find.byType(ElevatedButton).hitTestable().first);
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton).hitTestable().first);
      await tester.pump();

      expect(calls, 1);
      completer.complete(const AbdmM1Txn('txn-1'));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('clears Aadhaar and OTP after successful creation', (
      tester,
    ) async {
      final service = _FakeCreateAbdmService(
        mockMode: true,
        onGenerateOtp: (aadhaar) async => const AbdmM1Txn('txn-1'),
        onVerifyOtp: (txnId, otp) async => _profile,
        onCreateAbha: (txnId) async => _profile,
      );

      await pumpCreate(tester, service);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Aadhaar Number'),
        '123456789012',
      );
      await tester.tap(find.text('Generate OTP').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'OTP'),
        '123456',
      );
      await tester.tap(find.text('Verify OTP').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('I consent to the creation of ABHA Health ID'),
      );
      await tester.pump();
      await tester.tap(find.text('Create ABHA').hitTestable().first);
      await tester.pumpAndSettle();

      expect(find.text('123456789012'), findsNothing);
      expect(find.text('123456'), findsNothing);
    });

    testWidgets('records non-sensitive consent evidence before creation', (
      tester,
    ) async {
      String? capturedPurpose;
      String? capturedVersion;
      String? capturedTxnId;
      final service = _FakeCreateAbdmService(
        mockMode: true,
        onGenerateOtp: (aadhaar) async => const AbdmM1Txn('txn-1'),
        onVerifyOtp: (txnId, otp) async => _profile,
        onCreateAbha: (txnId) async => _profile,
        onRecordConsent:
            ({
              required purpose,
              required consentText,
              required consentVersion,
              patientId,
              abdmTransactionId,
            }) async {
              capturedPurpose = purpose;
              capturedVersion = consentVersion;
              capturedTxnId = abdmTransactionId;
            },
      );

      await pumpCreate(tester, service);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Aadhaar Number'),
        '123456789012',
      );
      await tester.tap(find.text('Generate OTP').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'OTP'),
        '123456',
      );
      await tester.tap(find.text('Verify OTP').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('I consent to the creation of ABHA Health ID'),
      );
      await tester.pump();
      await tester.tap(find.text('Create ABHA').hitTestable().first);
      await tester.pumpAndSettle();

      expect(capturedPurpose, 'ABHA_CREATION');
      expect(capturedVersion, '1.0');
      expect(capturedTxnId, 'txn-1');
    });

    testWidgets('shows sanitized failures and never raw Aadhaar', (
      tester,
    ) async {
      final service = _FakeCreateAbdmService(
        mockMode: true,
        onGenerateOtp: (aadhaar) async {
          throw const AbdmException(
            'ABDM M1 error',
            code: 'ABDM_M1_CONTRACT_UNCONFIRMED',
          );
        },
        onVerifyOtp: (txnId, otp) async => _profile,
        onCreateAbha: (txnId) async => _profile,
      );

      await pumpCreate(tester, service);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Aadhaar Number'),
        '123456789012',
      );
      await tester.tap(find.text('Generate OTP').hitTestable().first);
      await tester.pumpAndSettle();

      expect(find.text('ABDM M1 error'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('123456789012'),
        ),
        findsNothing,
      );
    });

    testWidgets('returns the created profile to the caller via pop', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox()),
          GoRoute(path: '/create', builder: (_, _) => const ABHACreateScreen()),
        ],
      );
      final service = _FakeCreateAbdmService(
        mockMode: true,
        onGenerateOtp: (aadhaar) async => const AbdmM1Txn('txn-1'),
        onVerifyOtp: (txnId, otp) async => _profile,
        onCreateAbha: (txnId) async => _profile,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [abdmServiceProvider.overrideWithValue(service)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      router.push('/create');
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Aadhaar Number'),
        '123456789012',
      );
      await tester.tap(find.text('Generate OTP').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'OTP'),
        '123456',
      );
      await tester.tap(find.text('Verify OTP').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('I consent to the creation of ABHA Health ID'),
      );
      await tester.pump();
      await tester.tap(find.text('Create ABHA').hitTestable().first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use this ABHA for Registration'));
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    });
  });
}
