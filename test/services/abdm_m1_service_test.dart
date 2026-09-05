import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/abdm_service.dart';

void main() {
  setUpAll(() => AppLogger.init());

  Session session() => Session(
    accessToken: 'user-jwt',
    tokenType: 'bearer',
    user: User(
      id: 'auth-owner',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: '2026-09-04T00:00:00.000Z',
    ),
  );

  AbdmService realService({
    required Future<http.Response> Function(http.Request) handler,
  }) {
    final client = SupabaseClient(
      'http://localhost',
      'anon-key',
      httpClient: MockClient(handler),
      accessToken: () async => 'user-jwt',
    );
    return AbdmService(
      supabaseClient: client,
      mockModeOverride: false,
      currentSessionReader: session,
    );
  }

  group('AbdmService M1 real-mode Edge Function contract', () {
    test(
      'every M1 method sends exactly {"action": ..., "payload": ...}',
      () async {
        final calls = <http.Request>[];
        final service = realService(
          handler: (request) async {
            calls.add(request);
            return http.Response(
              jsonEncode({
                'status': 'ok',
                'payload': {
                  'txnId': 'txn-1',
                  'profile': {
                    'healthId': '91-1234-5678-9012',
                    'healthIdNumber': '91-1234-5678-9012',
                    'abhaAddress': 'rahul9012@abdm',
                    'name': 'Rahul Sharma',
                  },
                  'profiles': [
                    {
                      'healthId': '91-1234-5678-9012',
                      'healthIdNumber': '91-1234-5678-9012',
                      'abhaAddress': 'rahul9012@abdm',
                      'name': 'Rahul Sharma',
                    },
                  ],
                  'cardBase64':
                      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          },
        );

        await service.generateAadhaarOtp('123456789012');
        await service.verifyAadhaarOtp(txnId: 'txn-1', otp: '123456');
        await service.createAbhaId(txnId: 'txn-1');
        await service.searchAbhaId('91-1234-5678-9012');
        await service.searchAbhaByMobile('9999999999');
        await service.verifyAbhaAddress('rahul9012@abdm');
        await service.getAbhaCard('rahul9012@abdm');
        await service.downloadAbhaCardPng('rahul9012@abdm');
        await service.getAbhaQrCode('rahul9012@abdm');

        final actions = calls
            .map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['action'])
            .toList();
        expect(actions, [
          'm1GenerateAadhaarOtp',
          'm1VerifyAadhaarOtp',
          'm1CreateAbha',
          'm1GetProfile',
          'm1SearchByMobile',
          'm1VerifyAbhaAddress',
          'm1GetAbhaCard',
          'm1GetAbhaCard',
          'm1GetAbhaQr',
        ]);

        for (final request in calls) {
          expect(request.method.toUpperCase(), 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('action'), isTrue);
          expect(body.containsKey('payload'), isTrue);
          expect(body['payload'], isA<Map<String, dynamic>>());
        }

        final otpPayload =
            (jsonDecode(calls[1].body) as Map<String, dynamic>)['payload']
                as Map<String, dynamic>;
        expect(otpPayload['otp'], '123456');
        expect(otpPayload['txnId'], 'txn-1');
      },
    );

    test('no session throws NO_SESSION before any network call', () async {
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
        service.generateAadhaarOtp('123456789012'),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.code, 'code', 'NO_SESSION')
              .having((e) => e.message, 'message', 'Please log in again.'),
        ),
      );
    });

    test(
      'invalid Aadhaar fails client-side without any network call',
      () async {
        final service = realService(
          handler: (request) async {
            fail('invalid input must never reach the Edge Function');
          },
        );
        await expectLater(
          service.generateAadhaarOtp('123'),
          throwsA(
            isA<AbdmException>().having(
              (e) => e.message,
              'message',
              contains('12-digit Aadhaar'),
            ),
          ),
        );
      },
    );

    test('structured M1 error codes are preserved end-to-end', () async {
      final service = realService(
        handler: (request) async {
          return http.Response(
            jsonEncode({
              'error': 'OTP must be exactly 6 digits.',
              'code': 'ABDM_M1_INVALID_INPUT',
              'supportReference': 'req_1',
            }),
            400,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      await expectLater(
        service.verifyAadhaarOtp(txnId: 'txn-1', otp: '123456'),
        throwsA(
          isA<AbdmException>()
              .having((e) => e.code, 'code', 'ABDM_M1_INVALID_INPUT')
              .having((e) => e.statusCode, 'statusCode', 400)
              .having(
                (e) => e.payload?['supportReference'],
                'supportReference',
                'req_1',
              ),
        ),
      );
    });

    test('sensitive values never appear in exception messages', () async {
      final service = realService(
        handler: (request) async {
          return http.Response(
            jsonEncode({
              'error':
                  'M1 operation "m1VerifyAadhaarOtp" is blocked: the official '
                  'ABDM Sandbox M1/ABHA contract for this client has not been '
                  'confirmed.',
              'code': 'ABDM_M1_CONTRACT_UNCONFIRMED',
            }),
            501,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      try {
        await service.verifyAadhaarOtp(txnId: 'txn-1', otp: '654321');
        fail('expected AbdmException');
      } on AbdmException catch (e) {
        expect(e.toString().contains('654321'), isFalse);
        expect(e.toString().contains('txn-1'), isFalse);
      }
    });

    test('mobile search parses multiple ABHA accounts', () async {
      final service = realService(
        handler: (request) async {
          return http.Response(
            jsonEncode({
              'payload': {
                'state': 'multiple_accounts',
                'profiles': [
                  {
                    'healthId': '91-1111-2222-3333',
                    'abhaAddress': 'rahul3333@abdm',
                    'name': 'Rahul First',
                    'mobileNumber': 'XXXXXX9999',
                  },
                  {
                    'healthId': '91-4444-5555-6666',
                    'abhaAddress': 'rahul6666@abdm',
                    'name': 'Rahul Second',
                    'mobileNumber': 'XXXXXX9999',
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      final result = await service.searchAbhaByMobile('9999999999');

      expect(result.state, AbdmM1State.multipleAccounts);
      expect(result.accounts.length, 2);
      expect(result.accounts.first.abhaAddress, 'rahul3333@abdm');
    });

    test('binary card payloads are decoded from sanitized base64', () async {
      final pngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
          'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      final service = realService(
        handler: (request) async {
          return http.Response(
            jsonEncode({
              'payload': {'contentType': 'image/png', 'base64': pngBase64},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      final bytes = await service.downloadAbhaCardPng('rahul9012@abdm');
      expect(bytes, isNotEmpty);
      expect(base64Encode(bytes), pngBase64);
    });
  });

  group('AbdmService M1 mock mode', () {
    AbdmService mockService() => AbdmService(
      supabaseClient: SupabaseClient(
        'http://localhost',
        'anon-key',
        httpClient: MockClient((request) async {
          fail('mock mode must not make HTTP calls');
        }),
      ),
      mockModeOverride: true,
    );

    test('OTP generation returns a mock transaction id', () async {
      final txn = await mockService().generateAadhaarOtp('123456789012');
      expect(txn.txnId, startsWith('mock-txn-'));
    });

    test(
      'OTP verification returns a fixture profile without requiring OTP',
      () async {
        final profile = await mockService().verifyAadhaarOtp(
          txnId: 'mock-txn-1',
          otp: '123456',
        );
        expect(profile.name, 'Rahul Sharma');
        expect(profile.mobileNumber, 'XXXXXX9999');
      },
    );

    test('search results are clearly labelled as mock', () async {
      final result = await mockService().searchAbhaId('91-1234-5678-9012');
      expect(result.state, AbdmM1State.found);
      expect(result.isMock, isTrue);
      expect(result.profile?.abhaAddress, 'rahul9012@abdm');
    });

    test('create ABHA honours a preferred ABHA Address in mock mode', () async {
      final profile = await mockService().createAbhaId(
        txnId: 'mock-txn-1',
        preferredAbhaAddress: 'rahul9012@abdm',
      );
      expect(profile.isNew, isTrue);
      expect(profile.abhaAddress, 'rahul9012@abdm');
    });
  });
}
