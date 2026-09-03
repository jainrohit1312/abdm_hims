import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/config/app_config.dart';
import 'package:abdm_hims/services/abdm_service.dart';

void main() {
  group('AbdmService secure backend routing', () {
    test(
      'checkGatewaySession calls the abdm-gateway Edge Function and returns sanitized data',
      () async {
        late http.Request captured;
        final mockHttp = MockClient((request) async {
          captured = request;
          expect(
            request.url.toString(),
            contains('/functions/v1/abdm-gateway'),
          );
          return http.Response(
            jsonEncode({
              'status': 'connected',
              'baseUrl': 'https://sandbox.abdm.gov.in',
              'clientId': 'test****id',
              'sessionValidForSeconds': 3400,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: mockHttp,
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
        );

        final result = await service.checkGatewaySession();

        expect(result['status'], 'connected');
        expect(result['clientId'], isNot(contains('secret')));
        expect(result.containsKey('accessToken'), isFalse);
        expect(captured.method.toUpperCase(), 'POST');
        final sentBody = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(sentBody['action'], 'session');
      },
    );

    test(
      'getRegisteredAbdmServices uses GET with the action query parameter',
      () async {
        late http.Request captured;
        final mockHttp = MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({'status': 'services_fetched', 'gateway': <dynamic>[]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: mockHttp,
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
        );

        final result = await service.getRegisteredAbdmServices();

        expect(result['status'], 'services_fetched');
        expect(captured.method.toUpperCase(), 'GET');
        expect(captured.url.queryParameters['action'], 'services');
      },
    );

    test('Edge Function errors are surfaced as typed AbdmException', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': 'Owner / super-admin role required for this action',
          }),
          403,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = SupabaseClient(
        'http://localhost',
        'anon-key',
        httpClient: mockHttp,
      );
      final service = AbdmService(
        supabaseClient: client,
        mockModeOverride: false,
      );

      await expectLater(
        service.updateBridgeCallbackUrl('https://callback.example/abdm'),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'EDGE_403'),
        ),
      );
    });

    test(
      'real mode returns a clear typed error for M1 gateway operations not yet relayed',
      () async {
        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((request) async {
            fail('real mode must not call the gateway directly');
          }),
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
        );

        await expectLater(
          service.generateAadhaarOtp('123456789012'),
          throwsA(
            isA<AbdmException>().having(
              (e) => e.code,
              'code',
              'ABDM_REAL_MODE_NOT_AVAILABLE',
            ),
          ),
        );
      },
    );

    test('mock mode remains available for local UI development', () async {
      final client = SupabaseClient(
        'http://localhost',
        'anon-key',
        httpClient: MockClient((request) async {
          fail('mock mode must not make HTTP calls');
        }),
      );
      final service = AbdmService(
        supabaseClient: client,
        mockModeOverride: true,
      );

      final txnId = await service.generateAadhaarOtp('123456789012');
      expect(txnId, startsWith('mock-txn-'));
    });
  });

  group('client-side secret hygiene', () {
    test('AppConfig exposes no ABDM client id or secret', () {
      expect(AppConfig.abdmRealModeEnabled, isFalse);
      expect(AppConfig.abdmMockMode, isTrue);
      expect(AppConfig.isAbdmConfigured, isFalse);
      expect(const bool.hasEnvironment('ABDM_CLIENT_SECRET'), isFalse);
    });

    test(
      'no ABDM client secret is present in client source or web output',
      () async {
        // Field names / placeholder values that must never appear again.
        final forbidden = ['abdmClientSecret', 'YOUR_ABDM_CLIENT_SECRET'];

        // A secret *assignment* pattern (comments that merely document the
        // Edge Function secret name are allowed and desirable).
        final assignmentPattern = RegExp("ABDM_CLIENT_SECRET\\s*[:=]\\s*['\"]");

        final files = [
          File('lib/config/app_config.dart'),
          File('lib/services/abdm_service.dart'),
          File('lib/core/constants/api_constants.dart'),
          File('web/env.js'),
        ];

        for (final file in files) {
          expect(
            file.existsSync(),
            isTrue,
            reason: '${file.path} should exist',
          );
          final content = await file.readAsString();
          for (final token in forbidden) {
            expect(
              content.contains(token),
              isFalse,
              reason: '${file.path} must not contain "$token"',
            );
          }
          expect(
            assignmentPattern.hasMatch(content),
            isFalse,
            reason:
                '${file.path} must not assign a value to ABDM_CLIENT_SECRET',
          );
        }
      },
    );

    test(
      'ABDM migrations replace broad ABDM RLS policies with hospital-scoped policies',
      () async {
        final callbacksMigration = File(
          'supabase/migrations/20260904000000_abdm_gateway_callbacks.sql',
        );
        final rlsMigration = File(
          'supabase/migrations/20260904000001_abdm_multi_tenant_rls.sql',
        );

        expect(callbacksMigration.existsSync(), isTrue);
        expect(rlsMigration.existsSync(), isTrue);

        final callbacks = await callbacksMigration.readAsString();
        expect(callbacks, contains('enable row level security'));
        expect(callbacks, contains('uq_abdm_gateway_callbacks_request_path'));
        expect(callbacks, contains('public.current_user_hospital_id()'));

        final rls = await rlsMigration.readAsString();
        for (final table in [
          'abha_profiles',
          'care_contexts',
          'consent_artefacts',
          'data_flow_logs',
          'fhir_records',
          'abha_linking_logs',
        ]) {
          expect(
            rls,
            contains('"$table tenant select"'),
            reason: 'hospital-scoped select policy missing for $table',
          );
          expect(
            rls,
            contains('"$table tenant insert"'),
            reason: 'hospital-scoped insert policy missing for $table',
          );
        }
        // The legacy broad policies must be dropped.
        expect(
          rls,
          contains(
            'drop policy if exists "Enable all access for authenticated users on care_contexts"',
          ),
        );
        expect(
          rls,
          contains(
            'drop policy if exists "Enable all access for authenticated users on data_flow_logs"',
          ),
        );
      },
    );
  });
}
