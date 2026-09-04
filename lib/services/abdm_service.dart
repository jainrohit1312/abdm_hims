import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/utils/logger.dart';

/// Reads the current Supabase session (injected for tests).
typedef CurrentSessionReader = Session? Function();

/// Unified exception for every ABDM gateway / persistence failure.
///
/// Screens can show [message] directly and rely on [statusCode] / [code] for
/// programmatic handling. Codes used by this service:
///   * `NO_SESSION`                   — the owner-only connection test was
///                                     requested without a Supabase session.
///   * `ABDM_MOCK_MODE`              — an admin/backend operation was requested
///                                     while the app is still running in mock mode.
///   * `ABDM_REAL_MODE_NOT_AVAILABLE` — the privileged gateway relay for that
///                                     M1/M2/M3 operation is not implemented in
///                                     the current backend-foundation phase.
///   * `EDGE_<http-status>`          — the secure Edge Function rejected the
///                                     request or the gateway call failed.
class AbdmException implements Exception {
  const AbdmException(this.message, {this.code, this.statusCode, this.payload});

  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic>? payload;

  @override
  String toString() => 'AbdmException($statusCode/$code): $message';
}

/// ABDM integration service.
///
/// SECURITY MODEL
/// ---------------
/// * The ABDM Client Secret (and Client ID) live ONLY as Supabase Edge
///   Function secrets. This class never reads or transmits them.
/// * All privileged ABDM calls (session, Bridge update, service management)
///   go through the `abdm-gateway` Supabase Edge Function. The raw ABDM
///   access token is kept server-side and is never returned to Flutter.
/// * Mock mode (`AppConfig.abdmRealModeEnabled == false`) keeps the existing
///   M1/M2/M3 UI fixtures for local development without any network access.
/// * The full M1/M2/M3 gateway relay is intentionally NOT implemented in this
///   phase — real mode returns a clear typed error for those operations.
class AbdmService {
  AbdmService({
    required SupabaseClient supabaseClient,
    this._mockModeOverride,
    CurrentSessionReader? currentSessionReader,
  }) : _client = supabaseClient,
       _currentSessionReader =
           currentSessionReader ?? (() => supabaseClient.auth.currentSession);

  static const String _edgeFunction = 'abdm-gateway';

  final SupabaseClient _client;
  final bool? _mockModeOverride;
  final CurrentSessionReader _currentSessionReader;

  // -- mock state ------------------------------------------------------------
  String? _lastTxnId;

  bool get isMockMode => _mockModeOverride ?? AppConfig.abdmMockMode;
  bool get isConfigured => !isMockMode;

  // ===========================================================================
  // Secure backend operations (Edge Function)
  // ===========================================================================

  /// Checks ABDM session connectivity through the secure Edge Function.
  /// Returns a sanitized status payload — never the raw ABDM token.
  Future<Map<String, dynamic>> checkGatewaySession() async {
    _requireBackendEnabled('Gateway session check');
    return _invokeEdge('session');
  }

  /// Owner/super-admin-only "Test ABDM Connection" action.
  ///
  /// Reads the current authenticated Supabase session first. When no session
  /// exists it throws [AbdmException] with code `NO_SESSION` so the UI can show
  /// "Please log in again." without making a network call.
  ///
  /// The Supabase Functions client attaches the session's access token as
  /// `Authorization: Bearer <owner-jwt>` on the outgoing request internally;
  /// this method never reads, logs, persists or returns the JWT value.
  Future<Map<String, dynamic>> testSandboxConnection() async {
    _requireBackendEnabled('ABDM connection test');
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    return _invokeEdge('session');
  }

  /// Owner/super-admin-only "Configure ABDM Bridge" action.
  ///
  /// Reads the current authenticated Supabase session first. When no session
  /// exists it throws [AbdmException] with code `NO_SESSION` so the UI can show
  /// "Please log in again." without making a network call.
  ///
  /// The Flutter client sends ONLY `{"action": "bridge"}` to the secure Edge
  /// Function using **POST** (the Supabase API gateway rejects a lowercase
  /// `patch` before the Edge Function can attach CORS headers). The callback
  /// URL is never supplied, logged, persisted or hard-coded by the client — the
  /// Edge Function resolves it exclusively from the `ABDM_CALLBACK_BASE_URL`
  /// secret and issues the ABDM call as an uppercase PATCH server-side.
  ///
  /// The Supabase Functions client attaches the session's access token as
  /// `Authorization: Bearer <owner-jwt>` on the outgoing request internally;
  /// this method never reads, logs, persists or returns the JWT value.
  Future<Map<String, dynamic>> configureBridge() async {
    _requireBackendEnabled('ABDM Bridge configuration');
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    return _invokeEdge('bridge');
  }

  /// Registers / updates HIP/HIU service definitions using the exact ABDM
  /// `addUpdateServices` array body:
  ///
  /// ```json
  /// [{
  ///   "id": "<service-id>",
  ///   "name": "<service-name>",
  ///   "type": "<official-service-type>",
  ///   "active": true,
  ///   "alias": ["<alias>"],
  ///   "endpoints": [
  ///     {"address": "<https-endpoint>", "connectionType": "https", "use": "<official-endpoint-use>"}
  ///   ]
  /// }]
  /// ```
  ///
  /// The service type, id, aliases and endpoint use must be supplied from the
  /// current ABDM Sandbox documentation — nothing is embedded here. Server-side
  /// validation enforces the official service-type allow-list.
  Future<Map<String, dynamic>> addOrUpdateAbdmServices({
    required List<Map<String, dynamic>> services,
  }) async {
    _requireBackendEnabled('Service registration');
    if (services.isEmpty) {
      throw const AbdmException(
        'At least one service definition is required.',
        code: 'INVALID_SERVICE_DEFINITION',
      );
    }
    for (final service in services) {
      final id = service['id']?.toString().trim() ?? '';
      final name = service['name']?.toString().trim() ?? '';
      final type = service['type']?.toString().trim().toUpperCase() ?? '';
      final active = service['active'];
      final alias = service['alias'];
      final endpoints = service['endpoints'];
      if (id.isEmpty || name.isEmpty || type.isEmpty) {
        throw const AbdmException(
          'Each service requires id, name and type.',
          code: 'INVALID_SERVICE_DEFINITION',
        );
      }
      if (active is! bool) {
        throw const AbdmException(
          'Each service requires a boolean "active" field.',
          code: 'INVALID_SERVICE_DEFINITION',
        );
      }
      if (alias is! List || alias.any((entry) => entry is! String)) {
        throw const AbdmException(
          'Each service requires an "alias" array of strings.',
          code: 'INVALID_SERVICE_DEFINITION',
        );
      }
      if (endpoints is! List || endpoints.isEmpty) {
        throw const AbdmException(
          'Each service requires a non-empty "endpoints" array.',
          code: 'INVALID_SERVICE_DEFINITION',
        );
      }
      for (final endpoint in endpoints) {
        if (endpoint is! Map) {
          throw const AbdmException(
            'Each endpoint must be an object.',
            code: 'INVALID_SERVICE_DEFINITION',
          );
        }
        final address = endpoint['address']?.toString().trim() ?? '';
        final connectionType =
            endpoint['connectionType']?.toString().trim() ?? '';
        final use = endpoint['use']?.toString().trim() ?? '';
        if (address.isEmpty || connectionType.isEmpty || use.isEmpty) {
          throw const AbdmException(
            'Each endpoint requires "address", "connectionType" and "use".',
            code: 'INVALID_SERVICE_DEFINITION',
          );
        }
      }
    }
    return _invokeEdge('services', body: {'services': services});
  }

  /// Lists services currently registered with the ABDM gateway.
  Future<Map<String, dynamic>> getRegisteredAbdmServices() async {
    _requireBackendEnabled('getServices');
    return _invokeEdge('services', method: HttpMethod.get);
  }

  // ===========================================================================
  // M1 – ABHA identity layer
  // ===========================================================================

  /// Validates a 12-digit Aadhaar number and requests an OTP from ABDM.
  ///
  /// Returns the `txnId` that must be passed to [verifyAadhaarOtp].
  Future<String> generateAadhaarOtp(String aadhaarNumber) async {
    final aadhaar = aadhaarNumber.trim();
    if (!RegExp(r'^\d{12}$').hasMatch(aadhaar)) {
      throw const AbdmException('Enter a valid 12-digit Aadhaar number.');
    }

    if (isMockMode) {
      await _mockDelay();
      final txnId = 'mock-txn-${DateTime.now().millisecondsSinceEpoch}';
      _lastTxnId = txnId;
      return txnId;
    }

    _ensureRealGatewayAvailable('Aadhaar OTP generation');
  }

  /// Verifies the Aadhaar OTP against ABDM.
  Future<Map<String, dynamic>> verifyAadhaarOtp(
    String otp, {
    String? txnId,
  }) async {
    final otpValue = otp.trim();
    if (!RegExp(r'^\d{4,8}$').hasMatch(otpValue)) {
      throw const AbdmException('Enter a valid OTP.');
    }
    final activeTxnId = (txnId ?? _lastTxnId)?.trim() ?? '';
    if (activeTxnId.isEmpty) {
      throw const AbdmException(
        'Transaction id missing. Please generate OTP again.',
      );
    }

    if (isMockMode) {
      await _mockDelay();
      final result = {
        'txnId': activeTxnId,
        'name': 'Rahul Sharma',
        'firstName': 'Rahul',
        'lastName': 'Sharma',
        'gender': 'M',
        'dateOfBirth': '1990-05-15',
        'yearOfBirth': '1990',
        'mobileNumber': '9999999999',
        'aadhaar': _maskAadhaar('123456789012'),
      };
      await _logAbhaFlow(
        requestType: 'verify_aadhaar_otp',
        requestPayload: {'txnId': activeTxnId, 'otp': _maskOtp(otpValue)},
        responsePayload: result,
        status: 'success',
      );
      return result;
    }

    _ensureRealGatewayAvailable('Aadhaar OTP verification');
  }

  /// Creates a new ABHA Health ID using the pre-verified Aadhaar flow.
  Future<Map<String, dynamic>> createAbhaId({
    required String txnId,
    String? healthId,
    String? email,
  }) async {
    if (isMockMode) {
      await _mockDelay();
      final abhaNumber = healthId?.trim().isNotEmpty == true
          ? healthId!.trim()
          : '91-1234-5678-9012';
      final result = {
        'txnId': txnId,
        'healthId': abhaNumber,
        'healthIdNumber': abhaNumber,
        'abhaAddress': 'rahul9012@abdm',
        'name': 'Rahul Sharma',
        'gender': 'M',
        'dateOfBirth': '1990-05-15',
        'mobileNumber': '9999999999',
        'email': email,
        'isNew': true,
      };
      await _logAbhaFlow(
        requestType: 'create_abha_id',
        requestPayload: {'txnId': txnId, 'email': email},
        responsePayload: result,
        status: 'success',
      );
      return result;
    }

    _ensureRealGatewayAvailable('ABHA creation');
  }

  /// Searches an ABHA Health ID on the gateway and returns its profile.
  Future<Map<String, dynamic>> searchAbhaId(String abhaId) async {
    final healthId = abhaId.trim().toUpperCase();
    if (healthId.isEmpty) {
      throw const AbdmException('Enter an ABHA Health ID.');
    }

    if (isMockMode) {
      await _mockDelay();
      return _mockProfile(healthId);
    }

    _ensureRealGatewayAvailable('ABHA search');
  }

  /// Searches ABHA profiles by mobile number on the gateway.
  Future<Map<String, dynamic>> searchAbhaByMobile(String mobile) async {
    final m = mobile.trim();
    if (!RegExp(r'^\d{10}$').hasMatch(m)) {
      throw const AbdmException('Enter a valid 10-digit mobile number.');
    }

    if (isMockMode) {
      await _mockDelay();
      return _mockProfile('91-1234-5678-9012');
    }

    _ensureRealGatewayAvailable('ABHA mobile search');
  }

  /// Verifies an ABHA Health ID (existence + KYC lookup on the gateway).
  Future<Map<String, dynamic>> verifyAbhaId(
    String abhaId, {
    String? otp,
  }) async {
    final profile = await searchAbhaId(abhaId);
    if (otp != null && otp.trim().isNotEmpty) {
      await _logAbhaFlow(
        requestType: 'verify_abha_id',
        requestPayload: {'healthId': abhaId, 'otp': _maskOtp(otp)},
        responsePayload: profile,
        status: 'success',
      );
    }
    return profile;
  }

  /// Searches an ABHA Address (14-digit `@abdm` address).
  Future<Map<String, dynamic>> verifyAbhaAddress(String abhaAddress) async {
    final address = abhaAddress.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9.\-_]{1,64}@abdm$').hasMatch(address)) {
      throw const AbdmException(
        'Enter a valid ABHA address (example: rahul9012@abdm).',
      );
    }

    if (isMockMode) {
      await _mockDelay();
      return _mockProfile('91-1234-5678-9012', abhaAddress: address);
    }

    _ensureRealGatewayAvailable('ABHA address verification');
  }

  /// Fetches the ABHA Card JSON for an ABHA address.
  Future<Map<String, dynamic>> getAbhaCard(String abhaAddress) async {
    if (isMockMode) {
      await _mockDelay();
      final profile = _mockProfile(
        '91-1234-5678-9012',
        abhaAddress: abhaAddress,
      );
      final card = {
        'abhaAddress': profile['abhaAddress'],
        'healthId': profile['healthId'],
        'name': profile['name'],
        'gender': profile['gender'],
        'dateOfBirth': profile['dateOfBirth'],
        'photo': null,
        'cardUrl': null,
      };
      await _logAbhaFlow(
        requestType: 'get_abha_card',
        requestPayload: {'abhaAddress': abhaAddress},
        responsePayload: card,
        status: 'success',
      );
      return card;
    }

    _ensureRealGatewayAvailable('ABHA card fetch');
  }

  /// Downloads the PNG ABHA card. Returns raw PNG bytes for preview/save.
  Future<Uint8List> downloadAbhaCardPng(String abhaAddress) async {
    if (isMockMode) {
      await _mockDelay();
      // 1x1 transparent PNG so Image.memory never crashes in mock mode.
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      await _logAbhaFlow(
        requestType: 'download_abha_card_png',
        requestPayload: {'abhaAddress': abhaAddress},
        responsePayload: {'bytes': bytes.length},
        status: 'success',
      );
      return bytes;
    }

    _ensureRealGatewayAvailable('ABHA card download');
  }

  /// Fetches the ABHA QR code image bytes.
  Future<Uint8List> getAbhaQrCode(String abhaAddress) async {
    if (isMockMode) {
      await _mockDelay();
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      await _logAbhaFlow(
        requestType: 'get_abha_qr',
        requestPayload: {'abhaAddress': abhaAddress},
        responsePayload: {'bytes': bytes.length},
        status: 'success',
      );
      return bytes;
    }

    _ensureRealGatewayAvailable('ABHA QR code fetch');
  }

  /// Parses an ABHA/scan-and-share QR payload (local operation, works in both
  /// modes).
  Future<Map<String, dynamic>> parseQrPayload(String rawQr) async {
    final data = rawQr.trim();
    if (data.isEmpty) {
      throw const AbdmException('QR code is empty.');
    }

    Map<String, dynamic> result = {};
    if (data.startsWith('{')) {
      try {
        result = Map<String, dynamic>.from(jsonDecode(data) as Map);
      } catch (_) {
        throw const AbdmException('Invalid JSON in QR code.');
      }
    } else {
      final uri = Uri.tryParse(data);
      if (uri != null && uri.hasQuery) {
        result = Map<String, dynamic>.from(uri.queryParameters);
      } else if (uri != null) {
        result = {'payload': data};
      } else {
        throw const AbdmException('Unrecognized QR code format.');
      }
    }

    await logDataFlow(
      patientId: null,
      transactionId: _newRequestId('QR'),
      requestPayload: {'qr': _redactQr(data)},
      responsePayload: result,
      status: 'success',
    );
    return result;
  }

  // ===========================================================================
  // M2 – HIP: care context linking & clinical data upload
  // ===========================================================================

  /// Generates a HIP-local care-context reference id.
  String buildCareContextId({
    required String recordType,
    required String recordId,
  }) {
    return '${AppConfig.hospitalCode}-$recordType-$recordId'.toUpperCase();
  }

  /// Links a care context to a patient's ABHA ID and persists it locally.
  Future<Map<String, dynamic>> linkCareContext({
    required String abhaId,
    required String careContextId,
    required String patientId,
    required String recordType,
    String? recordId,
    String? display,
    String? patientReference,
    String? patientDisplay,
  }) async {
    if (abhaId.trim().isEmpty) {
      throw const AbdmException('ABHA ID is required to link a care context.');
    }

    if (isMockMode) {
      final requestId = _newRequestId('LINK');
      final requestPayload = {
        'requestId': requestId,
        'timestamp': _nowIso(),
        'link': {
          'accessToken': 'SANDBOX_PLACEHOLDER',
          'patient': {
            'referenceNumber': patientReference ?? abhaId.trim().toUpperCase(),
            'display': patientDisplay ?? display ?? 'Patient',
            'careContexts': [
              {
                'referenceNumber': careContextId,
                'display': display ?? recordType,
              },
            ],
          },
        },
      };

      final saved = await saveCareContext(
        patientId: patientId,
        abhaId: abhaId.trim().toUpperCase(),
        careContextId: careContextId,
        recordType: recordType,
        recordId: recordId,
        isLinked: true,
      );
      await _mockDelay();
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: {'status': 'linked', 'careContextId': careContextId},
        status: 'success',
      );
      return {
        ...saved,
        'gateway': {'requestId': requestId, 'status': 'linked'},
      };
    }

    _ensureRealGatewayAvailable('Care context linking');
  }

  /// Handles a scan-and-share QR payload (local extraction + audit).
  Future<Map<String, dynamic>> processScanAndShare(
    String qrPayload, {
    String? patientId,
  }) async {
    final payload = await parseQrPayload(qrPayload);
    final abhaAddress =
        payload['abhaAddress'] ??
        payload['abha_address'] ??
        payload['hid'] ??
        payload['healthId'] ??
        payload['hipId'] ??
        '';
    if (abhaAddress.toString().trim().isEmpty) {
      throw const AbdmException(
        'QR code did not contain an ABHA address or HIP id.',
      );
    }

    final requestId = _newRequestId('SCAN');
    await logDataFlow(
      patientId: patientId,
      transactionId: requestId,
      requestPayload: {'qrPayload': _redactQr(qrPayload)},
      responsePayload: {'abhaAddress': abhaAddress, 'status': 'captured'},
      status: 'success',
    );
    return {
      'abhaAddress': abhaAddress,
      'requestId': requestId,
      'patient': payload,
    };
  }

  /// Builds a minimal ABDM-compliant FHIR Bundle for a clinical record and
  /// stores it in `fhir_records`. No gateway call is made in this phase.
  Future<Map<String, dynamic>> uploadClinicalRecord({
    required String patientId,
    required String abhaId,
    required String recordType,
    required String recordId,
    required String recordTitle,
    required Map<String, dynamic> clinicalData,
  }) async {
    final bundle = buildFhirBundle(
      abhaId: abhaId,
      recordType: recordType,
      recordId: recordId,
      recordTitle: recordTitle,
      clinicalData: clinicalData,
    );

    final requestId = _newRequestId('UPLOAD');
    final stored = await storeFhirRecord(
      patientId: patientId,
      abhaId: abhaId,
      recordType: recordType,
      recordId: recordId,
      fhirBundle: bundle,
    );

    await logDataFlow(
      patientId: patientId,
      transactionId: requestId,
      requestPayload: {'recordType': recordType, 'recordId': recordId},
      responsePayload: {
        'status': isMockMode ? 'uploaded' : 'queued_for_upload',
        'fhir_record_id': stored['id'],
      },
      status: 'success',
    );

    if (isMockMode) {
      await saveCareContext(
        patientId: patientId,
        abhaId: abhaId.trim().toUpperCase(),
        careContextId: buildCareContextId(
          recordType: recordType,
          recordId: recordId,
        ),
        recordType: recordType,
        recordId: recordId,
        isLinked: true,
      );
    }
    return {...stored, 'requestId': requestId};
  }

  /// Builds a simplified FHIR R4 Bundle (ABDM's exchange format).
  Map<String, dynamic> buildFhirBundle({
    required String abhaId,
    required String recordType,
    required String recordId,
    required String recordTitle,
    required Map<String, dynamic> clinicalData,
  }) {
    final now = _nowIso();
    return {
      'resourceType': 'Bundle',
      'type': 'document',
      'timestamp': now,
      'identifier': {'system': 'https://hims.local/fhir', 'value': recordId},
      'entry': [
        {
          'resource': {
            'resourceType': 'Patient',
            'id': abhaId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), ''),
            'identifier': [
              {'system': 'https://healthid.ndhm.gov.in', 'value': abhaId},
            ],
          },
        },
        {
          'resource': {
            'resourceType': _fhirResourceType(recordType),
            'id': recordId,
            'title': recordTitle,
            'status': 'final',
            'subject': {
              'reference':
                  'Patient/${abhaId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}',
            },
            'extension': [
              {
                'url': 'https://hims.local/fhir/record-type',
                'valueString': recordType,
              },
            ],
            ...clinicalData,
          },
        },
      ],
    };
  }

  String _fhirResourceType(String recordType) {
    switch (recordType.toLowerCase()) {
      case 'prescription':
        return 'MedicationRequest';
      case 'lab_report':
      case 'diagnostic_report':
        return 'DiagnosticReport';
      case 'discharge_summary':
        return 'DocumentReference';
      case 'ipd_admission':
      case 'opd_visit':
      case 'consultation':
        return 'Encounter';
      default:
        return 'DocumentReference';
    }
  }

  // ===========================================================================
  // M3 – HIU: consent request & health record fetch
  // ===========================================================================

  /// Requests patient consent (HIU flow) and stores the artefact locally.
  Future<Map<String, dynamic>> requestConsent({
    required String patientId,
    required String abhaId,
    required String purpose,
    required DateTime dataFrom,
    required DateTime dataTo,
    String? abhaAddress,
    List<String>? hiTypes,
  }) async {
    if (isMockMode) {
      final requestId = _newRequestId('CONSENT');
      final from = dataFrom.toUtc().toIso8601String();
      final to = dataTo.toUtc().toIso8601String();
      final requestPayload = {
        'requestId': requestId,
        'timestamp': _nowIso(),
        'consent': {
          'purpose': {
            'text': purpose,
            'code': 'CAREMGT',
            'refUri': 'https://abdm.gov.in/purposes/care-mgmt',
          },
          'patient': {'id': abhaAddress ?? '$abhaId@sbx'},
          'hiu': {'id': 'MOCK_HIU_ID'},
          'requester': {
            'name': AppConfig.appName,
            'identifier': {'type': 'REGNO', 'value': AppConfig.hospitalCode},
          },
          'hiTypes':
              hiTypes ??
              const [
                'DiagnosticReport',
                'Prescription',
                'DischargeSummary',
                'OPConsultation',
                'ImmunizationRecord',
                'HealthDocumentRecord',
                'WellnessRecord',
              ],
          'permission': {
            'accessMode': 'VIEW',
            'dateRange': {'from': from, 'to': to},
            'dataEraseAt': to,
            'frequency': {'unit': 'HOUR', 'value': 1, 'repeats': 0},
          },
        },
      };

      final saved = await saveConsentArtefact(
        patientId: patientId,
        abhaId: abhaId.trim().toUpperCase(),
        consentId: requestId,
        purpose: purpose,
        status: 'granted',
        grantedAt: DateTime.now().toUtc().toIso8601String(),
        expiresAt: to,
      );
      await _mockDelay();
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: {
          'consentRequestId': requestId,
          'status': 'GRANTED',
          'consentId': 'mock-consent-${DateTime.now().millisecondsSinceEpoch}',
        },
        status: 'success',
      );
      return {
        ...saved,
        'gateway': {'consentRequestId': requestId, 'status': 'GRANTED'},
      };
    }

    _ensureRealGatewayAvailable('Consent request');
  }

  /// Polls the status of a consent request.
  Future<Map<String, dynamic>> getConsentStatus(String consentRequestId) async {
    if (isMockMode) {
      await _mockDelay();
      return {'consentRequestId': consentRequestId, 'status': 'GRANTED'};
    }

    _ensureRealGatewayAvailable('Consent status');
  }

  /// HIU: fetches health records for a granted consent from the HIP.
  Future<Map<String, dynamic>> fetchHealthRecords({
    required String patientId,
    required String consentId,
    String? abhaId,
    Map<String, dynamic>? keyMaterial,
  }) async {
    if (isMockMode) {
      final requestId = _newRequestId('FETCH');
      final requestPayload = {
        'requestId': requestId,
        'timestamp': _nowIso(),
        'hiuId': 'MOCK_HIU_ID',
        'consentId': consentId,
        'keyMaterial': ?keyMaterial,
      };

      await _mockDelay();
      final records = await getFhirRecords(patientId);
      final mockBundle = buildFhirBundle(
        abhaId: abhaId ?? '91-1234-5678-9012',
        recordType: 'opd_visit',
        recordId: 'mock-fetch-$requestId',
        recordTitle: 'Fetched OPD record (mock)',
        clinicalData: {'chiefComplaint': 'Fever', 'diagnosis': 'Viral fever'},
      );
      if (records.isEmpty) {
        await storeFhirRecord(
          patientId: patientId,
          abhaId: abhaId ?? '91-1234-5678-9012',
          recordType: 'opd_visit',
          recordId: 'mock-fetch-$requestId',
          fhirBundle: mockBundle,
        );
      }
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: {'records': 1, 'status': 'success'},
        status: 'success',
      );
      return {
        'requestId': requestId,
        'status': 'success',
        'records': [mockBundle],
      };
    }

    _ensureRealGatewayAvailable('Health record fetch');
  }

  // ===========================================================================
  // Supabase persistence helpers (hospital-scoped for multi-tenant RLS)
  // ===========================================================================

  Future<String?> _currentHospitalId() async {
    try {
      final authId = _client.auth.currentUser?.id;
      if (authId == null) return null;
      final row = await _client
          .from('users')
          .select('hospital_id')
          .eq('auth_id', authId)
          .maybeSingle();
      return row?['hospital_id']?.toString();
    } catch (e) {
      AppLogger.e('Could not resolve hospital id for ABDM record', e);
      return null;
    }
  }

  Future<void> upsertAbhaProfile({
    required String patientId,
    required String abhaId,
    String? abhaAddress,
    bool isVerified = true,
  }) async {
    await _client.from('abha_profiles').upsert({
      'patient_id': patientId,
      'hospital_id': await _currentHospitalId(),
      'abha_id': abhaId.trim().toUpperCase(),
      'abha_address': abhaAddress,
      'is_verified': isVerified,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'patient_id');
  }

  Future<Map<String, dynamic>?> getAbhaProfile(String patientId) async {
    final response = await _client
        .from('abha_profiles')
        .select()
        .eq('patient_id', patientId)
        .maybeSingle();
    return response;
  }

  Future<Map<String, dynamic>> saveCareContext({
    required String patientId,
    required String abhaId,
    required String careContextId,
    required String recordType,
    String? recordId,
    bool isLinked = false,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final response = await _client
        .from('care_contexts')
        .upsert({
          'patient_id': patientId,
          'hospital_id': await _currentHospitalId(),
          'abha_id': abhaId,
          'care_context_id': careContextId,
          'record_type': recordType,
          'record_id': recordId,
          'is_linked': isLinked,
          'linked_at': isLinked ? now : null,
          'created_at': now,
        }, onConflict: 'patient_id,care_context_id')
        .select()
        .single();
    return response;
  }

  Future<List<Map<String, dynamic>>> getCareContexts(String patientId) async {
    final response = await _client
        .from('care_contexts')
        .select()
        .eq('patient_id', patientId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> saveConsentArtefact({
    required String patientId,
    required String abhaId,
    required String consentId,
    required String purpose,
    required String status,
    String? grantedAt,
    String? expiresAt,
  }) async {
    final response = await _client
        .from('consent_artefacts')
        .upsert({
          'patient_id': patientId,
          'hospital_id': await _currentHospitalId(),
          'abha_id': abhaId,
          'consent_id': consentId,
          'purpose': purpose,
          'status': status,
          'granted_at': grantedAt,
          'expires_at': expiresAt,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'consent_id')
        .select()
        .single();
    return response;
  }

  Future<List<Map<String, dynamic>>> getConsentArtefacts(
    String patientId,
  ) async {
    final response = await _client
        .from('consent_artefacts')
        .select()
        .eq('patient_id', patientId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<void> updateConsentArtefactStatus(
    String consentId,
    String status,
  ) async {
    await _client
        .from('consent_artefacts')
        .update({
          'status': status,
          'granted_at': status == 'granted'
              ? DateTime.now().toUtc().toIso8601String()
              : null,
        })
        .eq('consent_id', consentId);
  }

  Future<Map<String, dynamic>> storeFhirRecord({
    required String patientId,
    required String abhaId,
    required String recordType,
    required String recordId,
    required Map<String, dynamic> fhirBundle,
  }) async {
    final response = await _client
        .from('fhir_records')
        .upsert({
          'patient_id': patientId,
          'hospital_id': await _currentHospitalId(),
          'abha_id': abhaId,
          'record_type': recordType,
          'record_id': recordId,
          'fhir_bundle': fhirBundle,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'patient_id,record_type,record_id')
        .select()
        .single();
    return response;
  }

  Future<List<Map<String, dynamic>>> getFhirRecords(String patientId) async {
    final response = await _client
        .from('fhir_records')
        .select()
        .eq('patient_id', patientId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> getDataFlowLogs(String patientId) async {
    final response = await _client
        .from('data_flow_logs')
        .select()
        .eq('patient_id', patientId)
        .order('created_at', ascending: false)
        .limit(50);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Persists an ABDM request/response to `data_flow_logs`.
  Future<void> logDataFlow({
    required String? patientId,
    required String transactionId,
    required Map<String, dynamic> requestPayload,
    required Map<String, dynamic> responsePayload,
    required String status,
    String? errorMessage,
  }) async {
    try {
      await _client.from('data_flow_logs').insert({
        'patient_id': patientId,
        'hospital_id': await _currentHospitalId(),
        'transaction_id': transactionId,
        'request_payload': requestPayload,
        'response_payload': responsePayload,
        'status': status,
        'error_message': errorMessage,
      });
    } catch (e) {
      AppLogger.e('Failed to write data_flow_logs', e);
    }
  }

  Future<void> _logAbhaFlow({
    required String requestType,
    required Map<String, dynamic> requestPayload,
    required Map<String, dynamic> responsePayload,
    required String status,
  }) async {
    try {
      await _client.from('abha_linking_logs').insert({
        'hospital_id': await _currentHospitalId(),
        'request_type': requestType,
        'request_payload': requestPayload,
        'response_payload': responsePayload,
        'status': status,
        'transaction_id': _newRequestId('ABHA'),
      });
    } catch (e) {
      AppLogger.e('Failed to write abha_linking_logs', e);
    }
  }

  // ===========================================================================
  // Edge Function plumbing
  // ===========================================================================

  void _requireBackendEnabled(String operation) {
    if (isMockMode) {
      throw AbdmException(
        '$operation is only available when the ABDM backend is enabled.',
        code: 'ABDM_MOCK_MODE',
      );
    }
  }

  Never _ensureRealGatewayAvailable(String operation) {
    if (isMockMode) {
      // Should never happen (callers handle mock mode first), but keep a
      // defensive branch so a mock UI never accidentally reaches this.
      throw AbdmException(
        '$operation is not available in mock mode.',
        code: 'ABDM_MOCK_MODE',
      );
    }
    throw AbdmException(
      'The secure ABDM gateway relay for "$operation" is not enabled yet. '
      'This backend-foundation phase only provides session, Bridge and '
      'service-management operations through the Edge Function.',
      code: 'ABDM_REAL_MODE_NOT_AVAILABLE',
    );
  }

  Future<Map<String, dynamic>> _invokeEdge(
    String action, {
    Map<String, dynamic>? body,
    HttpMethod method = HttpMethod.post,
  }) async {
    final isGet = method == HttpMethod.get;
    try {
      final response = await _client.functions.invoke(
        _edgeFunction,
        body: isGet
            ? null
            : (body == null ? {'action': action} : {...body, 'action': action}),
        method: method,
        queryParameters: isGet ? {'action': action} : null,
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        if (data['error'] != null) {
          throw AbdmException(data['error'].toString(), payload: data);
        }
        return data;
      }
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const AbdmException(
        'Unexpected response from the ABDM gateway function.',
      );
    } on AbdmException {
      rethrow;
    } on FunctionException catch (e) {
      String message = 'ABDM gateway function failed (HTTP ${e.status})';
      Map<String, dynamic>? payload;
      final details = e.details;
      if (details is Map) {
        payload = Map<String, dynamic>.from(details);
        final serverMessage = payload['error']?.toString();
        if (serverMessage != null && serverMessage.isNotEmpty) {
          message = serverMessage;
        }
      } else if (details is String && details.trim().isNotEmpty) {
        message = details.trim();
      }
      // Preserve structured server diagnostics (e.g. ABDM_BRIDGE_400) when the
      // Edge Function supplies them; otherwise keep the legacy EDGE_<status>.
      final serverCode = payload?['code']?.toString();
      throw AbdmException(
        message,
        code: (serverCode != null && serverCode.isNotEmpty)
            ? serverCode
            : 'EDGE_${e.status}',
        statusCode: e.status,
        payload: payload,
      );
    } catch (e) {
      throw AbdmException('Could not reach the ABDM gateway function: $e');
    }
  }

  // -- mock + helpers --------------------------------------------------------

  Map<String, dynamic> _mockProfile(String healthId, {String? abhaAddress}) {
    final address = abhaAddress ?? 'rahul9012@abdm';
    return {
      'healthId': healthId,
      'healthIdNumber': healthId,
      'abhaAddress': address,
      'name': 'Rahul Sharma',
      'firstName': 'Rahul',
      'lastName': 'Sharma',
      'gender': 'M',
      'dateOfBirth': '1990-05-15',
      'yearOfBirth': '1990',
      'mobileNumber': '9999999999',
      'email': 'rahul.sharma@example.com',
      'address': 'New Delhi',
      'state': 'Delhi',
      'isVerified': true,
      'status': 'ACTIVE',
    };
  }

  Future<void> _mockDelay() async {
    await Future<void>.delayed(
      Duration(milliseconds: 500 + Random().nextInt(500)),
    );
  }

  String _maskAadhaar(String aadhaar) => aadhaar.length == 12
      ? 'XXXXXXXX${aadhaar.substring(aadhaar.length - 4)}'
      : 'XXXXXXXXXXXX';

  String _maskOtp(String otp) => otp.length <= 2 ? '**' : '${otp[0]}****';

  String _redactQr(String qr) => 'QR_PAYLOAD_${qr.length}';

  String _newRequestId(String prefix) {
    final now = DateTime.now();
    final stamp = '${now.millisecondsSinceEpoch}';
    final rand = Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '$prefix-$stamp-$rand';
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}
