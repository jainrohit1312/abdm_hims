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
        currentSessionReader: () => Session(
          accessToken: 'owner-jwt-raw-token',
          tokenType: 'bearer',
          user: User(
            id: 'auth-owner',
            appMetadata: const {},
            userMetadata: const {},
            aud: 'authenticated',
            createdAt: '2026-09-04T00:00:00.000Z',
          ),
        ),
      );

      await expectLater(
        service.configureBridge(),
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

  group('AbdmService testSandboxConnection (owner session)', () {
    Session ownerSession() => Session(
      accessToken: 'owner-jwt-raw-token',
      tokenType: 'bearer',
      user: User(
        id: 'auth-owner',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-09-04T00:00:00.000Z',
      ),
    );

    test(
      'throws "Please log in again." when there is no current session',
      () async {
        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((request) async {
            fail('the Edge Function must not be called without a session');
          }),
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
          currentSessionReader: () => null,
        );

        await expectLater(
          service.testSandboxConnection(),
          throwsA(
            isA<AbdmException>()
                .having((e) => e.code, 'code', 'NO_SESSION')
                .having((e) => e.message, 'message', 'Please log in again.'),
          ),
        );
      },
    );

    test(
      'valid owner session posts action=session and returns sanitized data',
      () async {
        late http.Request captured;
        final session = ownerSession();
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
              'note':
                  'ABDM session established server-side. '
                  'The raw token is never returned.',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: mockHttp,
          // Simulates the Supabase Functions client attaching the current
          // session's access token internally (AuthHttpClient).
          accessToken: () async => session.accessToken,
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
          currentSessionReader: () => session,
        );

        final result = await service.testSandboxConnection();

        expect(result['status'], 'connected');
        expect(result['sessionValidForSeconds'], 3400);
        expect(result.containsKey('accessToken'), isFalse);
        expect(result.containsKey('token'), isFalse);
        expect(jsonEncode(result).contains('owner-jwt-raw-token'), isFalse);

        expect(captured.method.toUpperCase(), 'POST');
        final sentBody = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(sentBody['action'], 'session');
        // The owner JWT is attached internally as a Bearer header and is never
        // echoed back in the response body.
        expect(captured.headers['Authorization'], 'Bearer owner-jwt-raw-token');
        expect(captured.body.contains('owner-jwt-raw-token'), isFalse);
      },
    );

    test('expired/invalid JWT surfaces a 401 typed AbdmException', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'Invalid or expired user session'}),
          401,
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
        currentSessionReader: () => ownerSession(),
      );

      await expectLater(
        service.testSandboxConnection(),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'EDGE_401'),
        ),
      );
    });

    test('non-owner receives a 403 typed AbdmException', () async {
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
        currentSessionReader: () => ownerSession(),
      );

      await expectLater(
        service.testSandboxConnection(),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'EDGE_403'),
        ),
      );
    });
  });

  group('AbdmService configureBridge (owner session)', () {
    Session ownerSession() => Session(
      accessToken: 'owner-jwt-raw-token',
      tokenType: 'bearer',
      user: User(
        id: 'auth-owner',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-09-04T00:00:00.000Z',
      ),
    );

    test(
      'throws "Please log in again." when there is no current session',
      () async {
        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: MockClient((request) async {
            fail('the Edge Function must not be called without a session');
          }),
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
          currentSessionReader: () => null,
        );

        await expectLater(
          service.configureBridge(),
          throwsA(
            isA<AbdmException>()
                .having((e) => e.code, 'code', 'NO_SESSION')
                .having((e) => e.message, 'message', 'Please log in again.'),
          ),
        );
      },
    );

    test(
      'valid owner session sends exactly {"action":"bridge"} with POST',
      () async {
        late http.Request captured;
        final session = ownerSession();
        final mockHttp = MockClient((request) async {
          captured = request;
          expect(
            request.url.toString(),
            contains('/functions/v1/abdm-gateway'),
          );
          return http.Response(
            jsonEncode({
              'status': 'bridge_configured',
              'baseUrl': 'https://dev.abdm.gov.in',
              'callbackUrl':
                  'https://example.supabase.co/functions/v1/abdm-gateway',
              'gateway': {'ok': true},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final client = SupabaseClient(
          'http://localhost',
          'anon-key',
          httpClient: mockHttp,
          // Simulates the Supabase Functions client attaching the current
          // session's access token internally (AuthHttpClient).
          accessToken: () async => session.accessToken,
        );
        final service = AbdmService(
          supabaseClient: client,
          mockModeOverride: false,
          currentSessionReader: () => session,
        );

        final result = await service.configureBridge();

        expect(result['status'], 'bridge_configured');
        expect(
          result['callbackUrl'],
          'https://example.supabase.co/functions/v1/abdm-gateway',
        );
        expect(result.containsKey('accessToken'), isFalse);
        expect(result.containsKey('clientSecret'), isFalse);
        expect(jsonEncode(result).contains('owner-jwt-raw-token'), isFalse);

        expect(captured.method.toUpperCase(), 'POST');
        final sentBody = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(sentBody, {'action': 'bridge'});
        expect(sentBody.containsKey('callbackUrl'), isFalse);
        expect(sentBody.containsKey('url'), isFalse);
        expect(captured.headers['Authorization'], 'Bearer owner-jwt-raw-token');
        expect(captured.body.contains('owner-jwt-raw-token'), isFalse);
      },
    );

    test('expired/invalid JWT surfaces a 401 typed AbdmException', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'Invalid or expired user session'}),
          401,
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
        currentSessionReader: () => ownerSession(),
      );

      await expectLater(
        service.configureBridge(),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'EDGE_401'),
        ),
      );
    });

    test('non-owner receives a 403 typed AbdmException', () async {
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
        currentSessionReader: () => ownerSession(),
      );

      await expectLater(
        service.configureBridge(),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.code, 'code', 'EDGE_403'),
        ),
      );
    });

    test(
      'preserves the server ABDM_BRIDGE_* diagnostic code from a 502',
      () async {
        final mockHttp = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'error': 'ABDM Bridge update failed (HTTP 400): bad request',
              'code': 'ABDM_BRIDGE_400',
              'upstreamStatus': 400,
            }),
            502,
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
          currentSessionReader: () => ownerSession(),
        );

        await expectLater(
          service.configureBridge(),
          throwsA(
            isA<AbdmException>()
                .having((e) => e.statusCode, 'statusCode', 502)
                .having((e) => e.code, 'code', 'ABDM_BRIDGE_400')
                .having(
                  (e) => e.payload?['upstreamStatus'],
                  'upstreamStatus',
                  400,
                ),
          ),
        );
      },
    );
  });

  group('client-side secret hygiene', () {
    test('AppConfig exposes no ABDM client id or secret', () {
      expect(AppConfig.abdmRealModeEnabled, isFalse);
      expect(AppConfig.abdmMockMode, isTrue);
      expect(AppConfig.isAbdmConfigured, isFalse);
      expect(const bool.hasEnvironment('ABDM_CLIENT_SECRET'), isFalse);
    });

    test(
      'package.json passes ABDM_REAL_MODE dart-define with a safe false default',
      () async {
        final packageJson = File('package.json');
        expect(packageJson.existsSync(), isTrue);
        final content = await packageJson.readAsString();

        expect(
          content.contains(
            r'--dart-define=ABDM_REAL_MODE=\"${ABDM_REAL_MODE:-false}\"',
          ),
          isTrue,
          reason:
              'vercel-build must pass ABDM_REAL_MODE as a dart-define '
              'with a safe default of false',
        );

        // ABDM credentials must never be passed into the Flutter web build.
        for (final secret in [
          'ABDM_CLIENT_ID',
          'ABDM_CLIENT_SECRET',
          'ABDM_BRIDGE_ID',
          'ABDM_HIP_ID',
          'ABDM_HIU_ID',
        ]) {
          expect(
            content.contains(secret),
            isFalse,
            reason: 'package.json must not pass $secret into Flutter web',
          );
        }

        final envExample = File('.env.example');
        expect(envExample.existsSync(), isTrue);
        final envContent = await envExample.readAsString();
        expect(envContent.contains('ABDM_REAL_MODE=false'), isTrue);
        expect(
          envContent.toLowerCase().contains('vercel production'),
          isTrue,
          reason:
              '.env.example must explain when Vercel Production should '
              'enable ABDM_REAL_MODE',
        );
      },
    );

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
