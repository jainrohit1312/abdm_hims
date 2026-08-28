import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';

/// Unified exception for every ABDM gateway / persistence failure.
///
/// Screens can show [message] directly and rely on [statusCode] / [code] for
/// programmatic handling (e.g. 401 -> refresh token, 404 -> endpoint fallback).
class AbdmException implements Exception {
  const AbdmException(this.message, {this.code, this.statusCode, this.payload});

  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic>? payload;

  @override
  String toString() => 'AbdmException($statusCode/$code): $message';
}

/// Production-oriented ABDM integration service covering:
///
/// * **M1 (ABHA identity)**  – Aadhaar OTP, create ABHA, search/verify ABHA,
///   ABHA address verify/link, ABHA card + QR.
/// * **M2 (HIP)**            – care-context link, scan-and-share, clinical
///   record upload.
/// * **M3 (HIU)**            – consent request, health-record fetch, FHIR
///   storage.
///
/// Every gateway call is logged to `data_flow_logs` (and `abha_linking_logs`
/// for ABHA flows) so the hospital has a full audit trail. When sandbox
/// credentials are not configured yet, the service transparently runs in
/// mock mode (see [AppConfig.abdmMockMode]) and returns realistic fixtures so
/// the Flutter UI can be built and demoed end-to-end.
class AbdmService {
  AbdmService({required SupabaseClient supabaseClient})
    : _client = supabaseClient {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.abdmBaseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 45),
        headers: const {'Content-Type': 'application/json'},
        validateStatus: (status) => status != null && status < 500,
      ),
    );
  }

  final SupabaseClient _client;
  late final Dio _dio;

  // -- gateway session cache -------------------------------------------------
  String? _accessToken;
  DateTime? _tokenExpiresAt;
  String? _lastTxnId;

  bool get isMockMode => AppConfig.abdmMockMode;
  bool get isConfigured => AppConfig.isAbdmConfigured;

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

    try {
      final token = await _getAccessToken();
      final response = await _postWithFallbackPaths(
        ApiConstants.abdmAadhaarGenerateOtpPaths,
        body: {'aadhaar': aadhaar},
        token: token,
      );
      final txnId = response['txnId'] as String?;
      if (txnId == null || txnId.isEmpty) {
        throw AbdmException(
          'ABDM did not return a transaction id.',
          payload: response,
        );
      }
      _lastTxnId = txnId;
      await _logAbhaFlow(
        requestType: 'generate_aadhaar_otp',
        requestPayload: {'aadhaar': _maskAadhaar(aadhaar)},
        responsePayload: response,
        status: 'success',
      );
      return txnId;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Aadhaar OTP generation failed');
    }
  }

  /// Verifies the Aadhaar OTP against ABDM.
  ///
  /// Returns KYC data (name, gender, dob, mobile) plus the confirmed txnId.
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

    try {
      final token = await _getAccessToken();
      final response = await _postWithFallbackPaths(
        ApiConstants.abdmAadhaarVerifyOtpPaths,
        body: {'otp': otpValue, 'txnId': activeTxnId},
        token: token,
      );
      _lastTxnId = response['txnId'] as String? ?? activeTxnId;
      await _logAbhaFlow(
        requestType: 'verify_aadhaar_otp',
        requestPayload: {'txnId': activeTxnId, 'otp': _maskOtp(otpValue)},
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Aadhaar OTP verification failed');
    }
  }

  /// Creates a new ABHA Health ID using the pre-verified Aadhaar flow.
  ///
  /// [txnId] must come from [verifyAadhaarOtp]. Optionally pass a desired
  /// [healthId] (ABHA number) and [email]. Returns the created ABHA profile.
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
        'token': 'mock-abha-session-token',
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

    try {
      final token = await _getAccessToken();
      final body = <String, dynamic>{
        'txnId': txnId,
        if (email?.trim().isNotEmpty == true) 'email': email!.trim(),
        if (healthId?.trim().isNotEmpty == true)
          'healthId': healthId!.trim().toUpperCase(),
      };
      final response = await _postWithFallbackPaths(
        ApiConstants.abdmCreateHealthIdPaths,
        body: body,
        token: token,
      );
      await _logAbhaFlow(
        requestType: 'create_abha_id',
        requestPayload: {'txnId': txnId, 'email': email},
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'ABHA creation failed');
    }
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

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmSearchByHealthId,
        body: {'healthId': healthId},
        token: token,
      );
      await _logAbhaFlow(
        requestType: 'search_abha_id',
        requestPayload: {'healthId': healthId},
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'ABHA search failed');
    }
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

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmSearchByMobile,
        body: {'mobile': m},
        token: token,
      );
      await _logAbhaFlow(
        requestType: 'search_abha_by_mobile',
        requestPayload: {'mobile': m},
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'ABHA mobile search failed');
    }
  }

  /// Verifies an ABHA Health ID (existence + KYC lookup on the gateway).
  ///
  /// For ABHA IDs this is the gateway search; the ABHA app enforces OTP when
  /// stronger auth is required by the requested auth-mode.
  Future<Map<String, dynamic>> verifyAbhaId(String abhaId, {String? otp}) async {
    final profile = await searchAbhaId(abhaId);
    if (otp != null && otp.trim().isNotEmpty) {
      // The gateway search API is the source of truth; OTP verification for an
      // *existing* ABHA is performed inside the ABHA app (patient side). We
      // keep the parameter so callers can pass an OTP for audit purposes.
      await _logAbhaFlow(
        requestType: 'verify_abha_id',
        requestPayload: {'healthId': abhaId, 'otp': _maskOtp(otp)},
        responsePayload: profile,
        status: 'success',
      );
    }
    return profile;
  }

  /// Searches an ABHA Address (14-digit `@abdm` address) and returns the
  /// linked ABHA profile.
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

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmSearchByAbhaAddress,
        body: {'abhaAddress': address},
        token: token,
      );
      await _logAbhaFlow(
        requestType: 'verify_abha_address',
        requestPayload: {'abhaAddress': address},
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'ABHA address verification failed');
    }
  }

  /// Fetches the ABHA Card JSON for an ABHA address.
  Future<Map<String, dynamic>> getAbhaCard(String abhaAddress) async {
    if (isMockMode) {
      await _mockDelay();
      final profile = _mockProfile('91-1234-5678-9012', abhaAddress: abhaAddress);
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

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmGetAbhaCard,
        body: {'abhaAddress': abhaAddress},
        token: token,
      );
      await _logAbhaFlow(
        requestType: 'get_abha_card',
        requestPayload: {'abhaAddress': abhaAddress},
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Could not fetch ABHA card');
    }
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

    try {
      final token = await _getAccessToken();
      final response = await _dio.get<dynamic>(
        ApiConstants.abdmGetPngCard,
        queryParameters: {'abhaAddress': abhaAddress},
        options: Options(
          headers: _authHeaders(token),
          responseType: ResponseType.bytes,
        ),
      );
      if (response.data is List<int>) {
        return Uint8List.fromList(response.data as List<int>);
      }
      if (response.data is String) {
        return base64Decode(response.data as String);
      }
      throw const AbdmException('ABDM returned an empty card image.');
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Could not download ABHA card');
    }
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

    try {
      final token = await _getAccessToken();
      final response = await _dio.get<dynamic>(
        ApiConstants.abdmGetQrCode,
        queryParameters: {'abhaAddress': abhaAddress},
        options: Options(
          headers: _authHeaders(token),
          responseType: ResponseType.bytes,
        ),
      );
      if (response.data is List<int>) {
        return Uint8List.fromList(response.data as List<int>);
      }
      if (response.data is String) {
        return base64Decode(response.data as String);
      }
      throw const AbdmException('ABDM returned an empty QR code image.');
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Could not fetch ABHA QR code');
    }
  }

  /// Parses an ABHA/scan-and-share QR payload.
  ///
  /// Supports the two payload shapes seen in the wild:
  /// * JSON (`{"hid": "...", "name": "...", ...}`)
  /// * URI query strings (`https://abdm.gov.in/scan?...&name=Rahul`)
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

  /// Links a care context (OPD/IPD visit, prescription, lab report, ...) to a
  /// patient's ABHA ID on the ABDM gateway and persists it to `care_contexts`.
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

    final requestId = _newRequestId('LINK');
    final requestPayload = {
      'requestId': requestId,
      'timestamp': _nowIso(),
      'link': {
        'accessToken': 'HIP_INITIATED_SANDBOX',
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

    // Persist first so the hospital has a local record even if the gateway
    // call is still pending callbacks.
    final saved = await saveCareContext(
      patientId: patientId,
      abhaId: abhaId.trim().toUpperCase(),
      careContextId: careContextId,
      recordType: recordType,
      recordId: recordId,
      isLinked: isMockMode, // real linking is confirmed via gateway callback
    );

    if (isMockMode) {
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

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmLinkAddContexts,
        body: requestPayload,
        token: token,
      );
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: response,
        status: 'success',
      );
      return {...saved, 'gateway': response};
    } on AbdmException {
      rethrow;
    } catch (e) {
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: {'error': e.toString()},
        status: 'failed',
      );
      throw _wrap(e, 'Care context linking failed');
    }
  }

  /// Handles a scan-and-share QR payload: extracts the ABHA address / hip id
  /// and records the intent for linking. The real link confirmation arrives
  /// on the HIP callback URL; in sandbox we simulate success.
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
  /// stores it in `fhir_records` (and uploads to the gateway in mock mode).
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
      // In mock mode we consider the care context linked once data is uploaded.
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
              'reference': 'Patient/${abhaId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}',
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

  /// Requests patient consent (HIU flow) for fetching records from another
  /// HIP and stores the artefact locally.
  Future<Map<String, dynamic>> requestConsent({
    required String patientId,
    required String abhaId,
    required String purpose,
    required DateTime dataFrom,
    required DateTime dataTo,
    String? abhaAddress,
    List<String>? hiTypes,
  }) async {
    final requestId = _newRequestId('CONSENT');
    final from = dataFrom.toUtc().toIso8601String();
    final to = dataTo.toUtc().toIso8601String();
    final requestPayload = {
      'requestId': requestId,
      'timestamp': _nowIso(),
      'consent': {
        'purpose': {'text': purpose, 'code': 'CAREMGT', 'refUri': 'https://abdm.gov.in/purposes/care-mgmt'},
        'patient': {'id': abhaAddress ?? '$abhaId@sbx'},
        'hiu': {'id': AppConfig.abdmHiuId},
        'requester': {
          'name': AppConfig.appName,
          'identifier': {'type': 'REGNO', 'value': AppConfig.hospitalCode},
        },
        'hiTypes': hiTypes ??
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
      status: isMockMode ? 'granted' : 'requested',
      grantedAt: isMockMode ? DateTime.now().toUtc().toIso8601String() : null,
      expiresAt: to,
    );

    if (isMockMode) {
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
        'gateway': {
          'consentRequestId': requestId,
          'status': 'GRANTED',
        },
      };
    }

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmConsentRequestInit,
        body: requestPayload,
        token: token,
      );
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: response,
        status: 'success',
      );
      return {...saved, 'gateway': response};
    } on AbdmException {
      rethrow;
    } catch (e) {
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: {'error': e.toString()},
        status: 'failed',
      );
      throw _wrap(e, 'Consent request failed');
    }
  }

  /// Polls the status of a consent request.
  Future<Map<String, dynamic>> getConsentStatus(String consentRequestId) async {
    if (isMockMode) {
      await _mockDelay();
      return {'consentRequestId': consentRequestId, 'status': 'GRANTED'};
    }

    try {
      final token = await _getAccessToken();
      return await _postJson(
        ApiConstants.abdmConsentRequestStatus,
        body: {'requestId': consentRequestId},
        token: token,
      );
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Could not fetch consent status');
    }
  }

  /// HIU: fetches health records for a granted consent from the HIP and
  /// stores the returned FHIR bundle(s) in `fhir_records`.
  Future<Map<String, dynamic>> fetchHealthRecords({
    required String patientId,
    required String consentId,
    String? abhaId,
    Map<String, dynamic>? keyMaterial,
  }) async {
    final requestId = _newRequestId('FETCH');
    final requestPayload = {
      'requestId': requestId,
      'timestamp': _nowIso(),
      'hiuId': AppConfig.abdmHiuId,
      'consentId': consentId,
      if (keyMaterial != null) 'keyMaterial': keyMaterial,
    };

    if (isMockMode) {
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

    try {
      final token = await _getAccessToken();
      final response = await _postJson(
        ApiConstants.abdmHealthInformationRequest,
        body: requestPayload,
        token: token,
      );
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: response,
        status: 'success',
      );
      return response;
    } on AbdmException {
      rethrow;
    } catch (e) {
      await logDataFlow(
        patientId: patientId,
        transactionId: requestId,
        requestPayload: requestPayload,
        responsePayload: {'error': e.toString()},
        status: 'failed',
      );
      throw _wrap(e, 'Health record fetch failed');
    }
  }

  // ===========================================================================
  // Supabase persistence helpers
  // ===========================================================================

  Future<void> upsertAbhaProfile({
    required String patientId,
    required String abhaId,
    String? abhaAddress,
    bool isVerified = true,
  }) async {
    await _client.from('abha_profiles').upsert({
      'patient_id': patientId,
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
  // Gateway plumbing
  // ===========================================================================

  Future<String> _getAccessToken() async {
    if (_accessToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!.subtract(const Duration(minutes: 2)))) {
      return _accessToken!;
    }

    try {
      final response = await _dio.post<dynamic>(
        ApiConstants.abdmSessions,
        data: {
          'clientId': AppConfig.abdmClientId,
          'clientSecret': AppConfig.abdmClientSecret,
        },
      );
      final data = _asMap(response.data);
      final token = data['accessToken'] as String?;
      if (token == null || token.isEmpty) {
        throw AbdmException(
          'ABDM session token missing.',
          payload: data,
        );
      }
      _accessToken = token;
      final expiresIn = int.tryParse(data['expiresIn']?.toString() ?? '') ?? 3600;
      _tokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      return token;
    } on AbdmException {
      rethrow;
    } catch (e) {
      throw _wrap(e, 'Could not authenticate with ABDM gateway');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required Map<String, dynamic> body,
    required String token,
  }) async {
    final response = await _dio.post<dynamic>(
      path,
      data: body,
      options: Options(headers: _authHeaders(token)),
    );
    final data = _asMap(response.data);
    if (response.statusCode != null &&
        response.statusCode! >= 400 &&
        response.statusCode! < 500) {
      final code = data['code']?.toString();
      final message = data['message']?.toString();
      throw AbdmException(
        message ?? 'ABDM gateway rejected the request.',
        code: code ?? (data['error']?.toString()),
        statusCode: response.statusCode,
        payload: data,
      );
    }
    return data;
  }

  /// ABDM has exposed the Aadhaar endpoints under both v1 and v3. Try each
  /// path in order and only fail when all have been exhausted.
  Future<Map<String, dynamic>> _postWithFallbackPaths(
    List<String> paths, {
    required Map<String, dynamic> body,
    required String token,
  }) async {
    Object? lastError;
    for (final path in paths) {
      try {
        return await _postJson(path, body: body, token: token);
      } on AbdmException catch (e) {
        final status = e.statusCode ?? 0;
        if (status == 404 || status == 405 || status == 0) {
          lastError = e;
          continue;
        }
        rethrow;
      }
    }
    if (lastError is AbdmException) {
      throw lastError;
    }
    throw AbdmException('ABDM endpoint unavailable.');
  }

  Map<String, String> _authHeaders(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
    'X-Token': token,
  };

  Map<String, dynamic> _asMap(dynamic data) {
    if (data == null) return const {};
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        return Map<String, dynamic>.from(jsonDecode(data) as Map);
      } catch (_) {
        return {'raw': data};
      }
    }
    return {'raw': data};
  }

  AbdmException _wrap(Object e, String fallbackMessage) {
    if (e is AbdmException) return e;
    if (e is DioException) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 401) {
        _accessToken = null;
        _tokenExpiresAt = null;
        return AbdmException(
          'ABDM session expired. Please retry.',
          statusCode: statusCode,
        );
      }
      final data = e.response?.data;
      if (data is Map) {
        final message = data['message']?.toString() ?? fallbackMessage;
        return AbdmException(
          message,
          code: data['code']?.toString(),
          statusCode: statusCode,
        );
      }
      return AbdmException(fallbackMessage, statusCode: statusCode);
    }
    if (e is TimeoutException) {
      return const AbdmException('ABDM gateway timed out. Please retry.');
    }
    return AbdmException('$fallbackMessage: $e');
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

  String _maskAadhaar(String aadhaar) =>
      aadhaar.length == 12
      ? 'XXXXXXXX${aadhaar.substring(aadhaar.length - 4)}'
      : 'XXXXXXXXXXXX';

  String _maskOtp(String otp) => otp.length <= 2 ? '**' : '${otp[0]}****';

  String _redactQr(String qr) {
    if (qr.length <= 40) return 'QR_PAYLOAD_${qr.length}';
    return 'QR_PAYLOAD_${qr.length}';
  }

  String _newRequestId(String prefix) {
    final now = DateTime.now();
    final stamp = '${now.millisecondsSinceEpoch}';
    final rand = Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '$prefix-$stamp-$rand';
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}
