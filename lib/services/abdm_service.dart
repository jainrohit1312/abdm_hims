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
///   * `NO_SESSION`                   — an operation was requested without a
///                                     Supabase session.
///   * `ABDM_MOCK_MODE`              — an admin/backend operation was requested
///                                     while the app is still running in mock mode.
///   * `EDGE_<http-status>`          — the secure Edge Function rejected the
///                                     request without a structured code.
///   * `ABDM_M1_*`                   — structured M1 error contract returned by
///                                     the Edge Function (see docs).
class AbdmException implements Exception {
  const AbdmException(this.message, {this.code, this.statusCode, this.payload});

  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic>? payload;

  @override
  String toString() => 'AbdmException($statusCode/$code): $message';
}

/// Distinct UI states for M1 search/verify/create results. Screens must label
/// the result from this state and never claim success unless ABDM returned an
/// actual successful profile/verification.
enum AbdmM1State {
  /// ABDM returned a profile for the searched identity.
  found,

  /// ABDM returned a successful verification result.
  verified,

  /// ABDM created a new ABHA identity.
  created,

  /// The operation requires an OTP-generation transaction first.
  otpRequired,

  /// Mobile search returned more than one ABHA account.
  multipleAccounts,

  /// ABDM has no record for the searched identity.
  notFound,

  /// ABDM provisioning is unavailable (Bridge/services not yet approved).
  provisioningUnavailable,

  /// The operation failed with a sanitized error.
  failed,
}

/// Typed, normalized ABHA profile returned by the M1 layer.
class AbdmM1Profile {
  const AbdmM1Profile({
    this.healthId,
    this.healthIdNumber,
    this.abhaAddress,
    this.name,
    this.firstName,
    this.lastName,
    this.gender,
    this.dateOfBirth,
    this.yearOfBirth,
    this.mobileNumber,
    this.email,
    this.state,
    this.district,
    this.status,
    this.isNew = false,
  });

  final String? healthId;
  final String? healthIdNumber;
  final String? abhaAddress;
  final String? name;
  final String? firstName;
  final String? lastName;
  final String? gender;
  final String? dateOfBirth;
  final String? yearOfBirth;
  final String? mobileNumber;
  final String? email;
  final String? state;
  final String? district;
  final String? status;
  final bool isNew;

  String? get abhaNumber => healthIdNumber ?? healthId;

  factory AbdmM1Profile.fromMap(Map<String, dynamic> map) {
    return AbdmM1Profile(
      healthId: map['healthId']?.toString(),
      healthIdNumber: map['healthIdNumber']?.toString(),
      abhaAddress: map['abhaAddress']?.toString(),
      name: map['name']?.toString(),
      firstName: map['firstName']?.toString(),
      lastName: map['lastName']?.toString(),
      gender: map['gender']?.toString(),
      dateOfBirth: map['dateOfBirth']?.toString(),
      yearOfBirth: map['yearOfBirth']?.toString(),
      mobileNumber: map['mobileNumber']?.toString(),
      email: map['email']?.toString(),
      state: map['state']?.toString(),
      district: map['district']?.toString(),
      status: map['status']?.toString(),
      isNew: map['isNew'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
    'healthId': healthId,
    'healthIdNumber': healthIdNumber,
    'abhaAddress': abhaAddress,
    'name': name,
    'firstName': firstName,
    'lastName': lastName,
    'gender': gender,
    'dateOfBirth': dateOfBirth,
    'yearOfBirth': yearOfBirth,
    'mobileNumber': mobileNumber,
    'email': email,
    'state': state,
    'district': district,
    'status': status,
    'isNew': isNew,
  };

  /// Populates patient-registration fields from this profile.
  String get displayName {
    final n = name?.trim() ?? '';
    return n.isNotEmpty ? n : '${firstName ?? ''} ${lastName ?? ''}'.trim();
  }
}

/// A server-issued M1 transaction id (continuation handle).
class AbdmM1Txn {
  const AbdmM1Txn(this.txnId, {this.expiresAt});

  final String txnId;
  final DateTime? expiresAt;
}

/// Normalized M1 operation result consumed by the screens.
class AbdmM1Response {
  const AbdmM1Response({
    required this.state,
    this.message,
    this.profile,
    this.accounts = const [],
    this.txnId,
    this.isMock = false,
  });

  final AbdmM1State state;
  final String? message;
  final AbdmM1Profile? profile;
  final List<AbdmM1Profile> accounts;
  final String? txnId;
  final bool isMock;

  /// Builds a response from the sanitized Edge Function payload. The Edge
  /// Function is the only source of real ABDM data — never the raw upstream.
  factory AbdmM1Response.fromEdgePayload(Map<String, dynamic> data) {
    final rawPayload = data['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : Map<String, dynamic>.from(data);

    final profiles = <AbdmM1Profile>[];
    final rawProfiles = payload['profiles'] ?? payload['accounts'];
    if (rawProfiles is List) {
      for (final entry in rawProfiles) {
        if (entry is Map) {
          profiles.add(AbdmM1Profile.fromMap(Map<String, dynamic>.from(entry)));
        }
      }
    }
    final rawProfile = payload['profile'];
    if (profiles.isEmpty && rawProfile is Map) {
      profiles.add(
        AbdmM1Profile.fromMap(Map<String, dynamic>.from(rawProfile)),
      );
    }

    final stateRaw = (payload['state'] ?? data['state'])?.toString();
    final state =
        _stateFromName(stateRaw) ??
        (profiles.length > 1
            ? AbdmM1State.multipleAccounts
            : profiles.length == 1
            ? AbdmM1State.found
            : AbdmM1State.notFound);

    return AbdmM1Response(
      state: state,
      message: payload['message']?.toString(),
      profile: profiles.isEmpty ? null : profiles.first,
      accounts: profiles,
      txnId: payload['txnId']?.toString() ?? data['txnId']?.toString(),
    );
  }

  static AbdmM1State? _stateFromName(String? name) {
    switch (name?.toLowerCase()) {
      case 'found':
        return AbdmM1State.found;
      case 'verified':
        return AbdmM1State.verified;
      case 'created':
        return AbdmM1State.created;
      case 'otp_required':
      case 'otprequired':
        return AbdmM1State.otpRequired;
      case 'multiple_accounts':
      case 'multipleaccounts':
        return AbdmM1State.multipleAccounts;
      case 'not_found':
      case 'notfound':
        return AbdmM1State.notFound;
      case 'provisioning_unavailable':
      case 'provisioningunavailable':
        return AbdmM1State.provisioningUnavailable;
      case 'failed':
        return AbdmM1State.failed;
      default:
        return null;
    }
  }
}

/// ABDM integration service.
///
/// SECURITY MODEL
/// ---------------
/// * The ABDM Client Secret (and Client ID) live ONLY as Supabase Edge
///   Function secrets. This class never reads or transmits them.
/// * All privileged ABDM calls (session, Bridge, service management and the
///   M1 identity operations) go through the `abdm-gateway` Supabase Edge
///   Function. The raw ABDM access token is kept server-side and is never
///   returned to Flutter.
/// * Mock mode (`AppConfig.abdmRealModeEnabled == false`) keeps the existing
///   M1/M2/M3 UI fixtures for local development without any network access.
/// * Real M1 calls are contract-gated in the Edge Function: until the official
///   client-supplied Sandbox M1/ABHA contract is configured, they return
///   `ABDM_M1_CONTRACT_UNCONFIRMED` instead of any invented call.
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
  /// The Flutter client sends ONLY `{"action": "bridge"}` to the secure Edge
  /// Function using **POST**. The callback URL is resolved exclusively from
  /// the `ABDM_CALLBACK_BASE_URL` secret server-side.
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

  /// Owner/super-admin-only facility/HIP registration through the official HFR
  /// Multiple HRP API.
  ///
  /// The Flutter client sends only `{"action": "services"}` to the secure Edge
  /// Function. facilityId, facilityName, bridgeId and hipName are all resolved
  /// server-side (hospitals table + ABDM_BRIDGE_ID secret) and are never
  /// accepted from the client.
  Future<Map<String, dynamic>> linkFacilityHip() async {
    _requireBackendEnabled('HFR facility/HIP linkage');
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    return _invokeEdge('services');
  }

  /// Legacy service-definition upload. Kept for backwards source compatibility
  /// only; the production path is now [linkFacilityHip] (HFR Multiple HRP).
  @Deprecated('Use linkFacilityHip(); legacy addUpdateServices is no longer the production path.')
  Future<Map<String, dynamic>> addOrUpdateAbdmServices({
    List<Map<String, dynamic>>? services,
  }) {
    return linkFacilityHip();
  }

  /// Lists services currently registered with the ABDM gateway.
  Future<Map<String, dynamic>> getRegisteredAbdmServices() async {
    _requireBackendEnabled('getServices');
    return _invokeEdge('services', method: HttpMethod.get);
  }

  /// Owner/super-admin-only "Inspect ABDM Services" action.
  Future<Map<String, dynamic>> inspectAbdmServices() async {
    _requireBackendEnabled('ABDM getServices inspection');
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    return _invokeEdge('getServices');
  }

  /// Owner/super-admin-only "Test V3 Gateway" diagnostic action.
  ///
  /// Posts exactly `{"action":"diagnoseV3Gateway"}` to the existing
  /// `abdm-gateway` Edge Function. The Edge Function performs an isolated V3
  /// session POST + bridge-services GET against the fixed Sandbox origin
  /// `https://dev.abdm.gov.in` and returns only allow-listed diagnostic
  /// metadata. The raw V3 token never leaves the Edge Function and is never
  /// read, displayed, logged or persisted by this client.
  Future<Map<String, dynamic>> diagnoseV3Gateway() async {
    _requireBackendEnabled('V3 gateway diagnostic');
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    return _invokeEdge('diagnoseV3Gateway');
  }

  /// Owner/super-admin-only "Inspect V3 Bridge" read-only action.
  ///
  /// Posts exactly `{"action":"inspectV3Bridge"}` to the existing
  /// `abdm-gateway` Edge Function. The Edge Function reuses the isolated V3
  /// session + GET bridge-services flow and returns only a sanitized,
  /// shape-level description of the real bridge-services response (top-level
  /// type, safe field names, bridge/URL presence, sanitized services). It
  /// never performs PATCH /bridge/url, addUpdateServices or any mutation.
  Future<Map<String, dynamic>> inspectV3Bridge() async {
    _requireBackendEnabled('V3 bridge inspection');
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    return _invokeEdge('inspectV3Bridge');
  }

  // ===========================================================================
  // M1 – ABHA identity layer
  // ===========================================================================

  /// Validates a 12-digit Aadhaar number and requests an OTP from ABDM.
  ///
  /// The raw Aadhaar is sent ONLY to the Edge Function over the authenticated
  /// Supabase channel. It is never stored, logged or returned.
  Future<AbdmM1Txn> generateAadhaarOtp(String aadhaarNumber) async {
    final aadhaar = aadhaarNumber.trim();
    if (!RegExp(r'^\d{12}$').hasMatch(aadhaar)) {
      throw const AbdmException('Enter a valid 12-digit Aadhaar number.');
    }

    if (isMockMode) {
      await _mockDelay();
      final txnId = 'mock-txn-${DateTime.now().millisecondsSinceEpoch}';
      return AbdmM1Txn(txnId);
    }

    final data = await _invokeM1('m1GenerateAadhaarOtp', {
      'aadhaarNumber': aadhaar,
    });
    final txnId =
        _firstString(data['payload'], 'txnId') ?? _firstString(data, 'txnId');
    if (txnId == null || txnId.isEmpty) {
      throw const AbdmException(
        'ABDM did not return a transaction id.',
        code: 'ABDM_M1_INVALID_INPUT',
      );
    }
    return AbdmM1Txn(txnId);
  }

  /// Verifies the Aadhaar OTP against ABDM and returns the sanitized eKYC
  /// profile. The OTP is sent only to the Edge Function and never persisted.
  Future<AbdmM1Profile> verifyAadhaarOtp({
    required String txnId,
    required String otp,
  }) async {
    final otpValue = otp.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(otpValue)) {
      throw const AbdmException('Enter the 6-digit OTP.');
    }
    final activeTxnId = txnId.trim();
    if (activeTxnId.isEmpty) {
      throw const AbdmException(
        'Transaction id missing. Please generate OTP again.',
      );
    }

    if (isMockMode) {
      await _mockDelay();
      final profile = const AbdmM1Profile(
        healthId: '91-1234-5678-9012',
        healthIdNumber: '91-1234-5678-9012',
        abhaAddress: 'rahul9012@abdm',
        name: 'Rahul Sharma',
        firstName: 'Rahul',
        lastName: 'Sharma',
        gender: 'M',
        dateOfBirth: '1990-05-15',
        yearOfBirth: '1990',
        mobileNumber: 'XXXXXX9999',
      );
      // SECURITY: the OTP value is never logged, even masked.
      await _logAbhaFlow(
        requestType: 'verify_aadhaar_otp',
        requestPayload: {'txnId': activeTxnId},
        responsePayload: {'name': profile.name, 'isMock': true},
        status: 'success',
      );
      return profile;
    }

    final data = await _invokeM1('m1VerifyAadhaarOtp', {
      'txnId': activeTxnId,
      'otp': otpValue,
    });
    final profile = _profileFromEdge(data);
    if (profile == null) {
      throw const AbdmException(
        'ABDM did not return a verified profile.',
        code: 'ABDM_M1_INVALID_INPUT',
      );
    }
    return profile;
  }

  /// Creates a new ABHA identity using the pre-verified Aadhaar flow.
  ///
  /// [preferredAbhaAddress] is only honoured when the official contract allows
  /// choosing an ABHA Address. Choosing an ABHA Number is intentionally NOT
  /// offered — the official contract must explicitly permit it first.
  Future<AbdmM1Profile> createAbhaId({
    required String txnId,
    String? preferredAbhaAddress,
    String? email,
  }) async {
    if (isMockMode) {
      await _mockDelay();
      final address = (preferredAbhaAddress?.trim().isNotEmpty ?? false)
          ? preferredAbhaAddress!.trim().toLowerCase()
          : 'rahul9012@abdm';
      final profile = AbdmM1Profile(
        healthId: '91-1234-5678-9012',
        healthIdNumber: '91-1234-5678-9012',
        abhaAddress: address,
        name: 'Rahul Sharma',
        gender: 'M',
        dateOfBirth: '1990-05-15',
        mobileNumber: 'XXXXXX9999',
        email: email,
        isNew: true,
        status: 'ACTIVE',
      );
      await _logAbhaFlow(
        requestType: 'create_abha_id',
        requestPayload: {'txnId': txnId},
        responsePayload: {'abhaAddress': address, 'isMock': true},
        status: 'success',
      );
      return profile;
    }

    final data = await _invokeM1('m1CreateAbha', {
      'txnId': txnId,
      if (preferredAbhaAddress != null && preferredAbhaAddress.isNotEmpty)
        'preferredAbhaAddress': preferredAbhaAddress,
      if (email != null && email.isNotEmpty) 'email': email,
    });
    final profile = _profileFromEdge(data);
    if (profile == null) {
      throw const AbdmException(
        'ABDM did not return the created ABHA profile.',
        code: 'ABDM_M1_INVALID_INPUT',
      );
    }
    return profile;
  }

  /// Searches an ABHA Health ID (ABHA number) on the gateway.
  Future<AbdmM1Response> searchAbhaId(String abhaId) async {
    final healthId = abhaId.trim().toUpperCase();
    if (healthId.isEmpty) {
      throw const AbdmException('Enter an ABHA Health ID.');
    }

    if (isMockMode) {
      await _mockDelay();
      return AbdmM1Response(
        state: AbdmM1State.found,
        profile: _mockProfile(healthId),
        accounts: [_mockProfile(healthId)],
        isMock: true,
      );
    }

    final data = await _invokeM1('m1GetProfile', {'abhaNumber': healthId});
    return AbdmM1Response.fromEdgePayload(data);
  }

  /// Searches ABHA profiles by mobile number on the gateway.
  ///
  /// Mobile search may return MULTIPLE ABHA accounts; the UI must show a
  /// selection instead of assuming a single profile.
  Future<AbdmM1Response> searchAbhaByMobile(String mobile) async {
    final m = mobile.trim();
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(m)) {
      throw const AbdmException('Enter a valid 10-digit mobile number.');
    }

    if (isMockMode) {
      await _mockDelay();
      final profile = _mockProfile('91-1234-5678-9012');
      return AbdmM1Response(
        state: AbdmM1State.found,
        profile: profile,
        accounts: [profile],
        isMock: true,
      );
    }

    final data = await _invokeM1('m1SearchByMobile', {'mobile': m});
    return AbdmM1Response.fromEdgePayload(data);
  }

  /// Verifies an ABHA Health ID existence/profile on the gateway.
  ///
  /// NOTE: optional OTP has been removed — the official flow requires a
  /// separate OTP-generation transaction, so an OTP is never accepted here.
  Future<AbdmM1Response> verifyAbhaId(String abhaId) {
    return searchAbhaId(abhaId);
  }

  /// Searches/verifies an ABHA Address (e.g. `rahul9012@abdm`).
  Future<AbdmM1Response> verifyAbhaAddress(String abhaAddress) async {
    final address = abhaAddress.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}@[a-z0-9.-]+$').hasMatch(address)) {
      throw const AbdmException(
        'Enter a valid ABHA address (example: rahul9012@abdm).',
      );
    }

    if (isMockMode) {
      await _mockDelay();
      final profile = _mockProfile('91-1234-5678-9012', abhaAddress: address);
      return AbdmM1Response(
        state: AbdmM1State.verified,
        profile: profile,
        accounts: [profile],
        isMock: true,
      );
    }

    final data = await _invokeM1('m1VerifyAbhaAddress', {
      'abhaAddress': address,
    });
    return AbdmM1Response.fromEdgePayload(data);
  }

  /// Fetches the ABHA Card JSON for an ABHA address.
  Future<Map<String, dynamic>> getAbhaCard(String abhaAddress) async {
    final address = abhaAddress.trim().toLowerCase();
    if (isMockMode) {
      await _mockDelay();
      final profile = _mockProfile('91-1234-5678-9012', abhaAddress: address);
      final card = {
        'abhaAddress': profile.abhaAddress,
        'healthId': profile.healthId,
        'name': profile.name,
        'gender': profile.gender,
        'dateOfBirth': profile.dateOfBirth,
        'photo': null,
        'cardUrl': null,
        'isMock': true,
      };
      await _logAbhaFlow(
        requestType: 'get_abha_card',
        requestPayload: {'abhaAddress': address},
        responsePayload: {'isMock': true},
        status: 'success',
      );
      return card;
    }

    final data = await _invokeM1('m1GetAbhaCard', {'abhaAddress': address});
    return _payloadMap(data);
  }

  /// Downloads the PNG ABHA card. Returns raw PNG bytes for preview/save.
  Future<Uint8List> downloadAbhaCardPng(String abhaAddress) async {
    final address = abhaAddress.trim().toLowerCase();
    if (isMockMode) {
      await _mockDelay();
      // 1x1 transparent PNG so Image.memory never crashes in mock mode.
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      await _logAbhaFlow(
        requestType: 'download_abha_card_png',
        requestPayload: {'abhaAddress': address},
        responsePayload: {'bytes': bytes.length, 'isMock': true},
        status: 'success',
      );
      return bytes;
    }

    final data = await _invokeM1('m1GetAbhaCard', {
      'abhaAddress': address,
      'format': 'png',
    });
    return _binaryFromEdge(data, 'card');
  }

  /// Fetches the ABHA QR code image bytes.
  Future<Uint8List> getAbhaQrCode(String abhaAddress) async {
    final address = abhaAddress.trim().toLowerCase();
    if (isMockMode) {
      await _mockDelay();
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      await _logAbhaFlow(
        requestType: 'get_abha_qr',
        requestPayload: {'abhaAddress': address},
        responsePayload: {'bytes': bytes.length, 'isMock': true},
        status: 'success',
      );
      return bytes;
    }

    final data = await _invokeM1('m1GetAbhaQr', {'abhaAddress': address});
    return _binaryFromEdge(data, 'qr');
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

    throw const AbdmException(
      'The secure ABDM gateway relay for "Care context linking" is not '
      'enabled yet. This phase provides session, Bridge, service-management '
      'and M1 routing through the Edge Function.',
      code: 'ABDM_REAL_MODE_NOT_AVAILABLE',
    );
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

    throw const AbdmException(
      'The secure ABDM gateway relay for "Consent request" is not enabled '
      'yet. This phase provides session, Bridge, service-management and M1 '
      'routing through the Edge Function.',
      code: 'ABDM_REAL_MODE_NOT_AVAILABLE',
    );
  }

  /// Polls the status of a consent request.
  Future<Map<String, dynamic>> getConsentStatus(String consentRequestId) async {
    if (isMockMode) {
      await _mockDelay();
      return {'consentRequestId': consentRequestId, 'status': 'GRANTED'};
    }

    throw const AbdmException(
      'The secure ABDM gateway relay for "Consent status" is not enabled '
      'yet. This phase provides session, Bridge, service-management and M1 '
      'routing through the Edge Function.',
      code: 'ABDM_REAL_MODE_NOT_AVAILABLE',
    );
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

    throw const AbdmException(
      'The secure ABDM gateway relay for "Health record fetch" is not '
      'enabled yet. This phase provides session, Bridge, service-management '
      'and M1 routing through the Edge Function.',
      code: 'ABDM_REAL_MODE_NOT_AVAILABLE',
    );
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

  Future<String?> _currentUsersTableId() async {
    try {
      final authId = _client.auth.currentUser?.id;
      if (authId == null) return null;
      final row = await _client
          .from('users')
          .select('id')
          .eq('auth_id', authId)
          .maybeSingle();
      return row?['id']?.toString();
    } catch (e) {
      AppLogger.e('Could not resolve users table id for ABDM record', e);
      return null;
    }
  }

  /// Atomically links an ABHA identity to a patient via the hospital-scoped
  /// `link_abha_profile` database RPC:
  ///
  ///   1. upserts `abha_profiles` (hospital-scoped, patient unique),
  ///   2. updates `patients.abha_id` / `abha_address` / `abha_linked`,
  ///   3. writes an `abha_linking_logs` success row,
  ///
  /// all inside one database transaction that enforces hospital isolation.
  Future<Map<String, dynamic>> upsertAbhaProfile({
    required String patientId,
    required String abhaId,
    String? abhaAddress,
    bool isVerified = true,
    String verificationSource = 'abdm_m1',
    String? transactionId,
  }) async {
    final data = await _client.rpc(
      'link_abha_profile',
      params: {
        'p_patient_id': patientId,
        'p_abha_id': abhaId.trim().toUpperCase(),
        'p_abha_address': abhaAddress,
        'p_is_verified': isVerified,
        'p_verification_source': verificationSource,
        'p_transaction_id': transactionId,
      },
    );
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  Future<Map<String, dynamic>?> getAbhaProfile(String patientId) async {
    final response = await _client
        .from('abha_profiles')
        .select()
        .eq('patient_id', patientId)
        .maybeSingle();
    return response;
  }

  /// Records non-sensitive consent evidence for an M1 operation. Never stores
  /// Aadhaar, OTP or any ABDM KYC payload.
  Future<void> recordAbhaConsentEvidence({
    required String purpose,
    required String consentText,
    required String consentVersion,
    String? patientId,
    String? abdmTransactionId,
  }) async {
    final hospitalId = await _currentHospitalId();
    if (hospitalId == null || hospitalId.isEmpty) return;
    final userId = await _currentUsersTableId();
    if (userId == null || userId.isEmpty) return;

    try {
      await _client.from('abha_m1_consent_evidence').insert({
        'hospital_id': hospitalId,
        'user_id': userId,
        'patient_id': patientId,
        'consent_given': true,
        'consent_purpose': purpose,
        'consent_text': consentText,
        'consent_version': consentVersion,
        'abdm_transaction_id': abdmTransactionId,
      });
    } catch (e) {
      AppLogger.e('Failed to write abha_m1_consent_evidence', e);
    }
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

  /// Persists an ABDM request/response to `data_flow_logs` after stripping
  /// sensitive keys (Aadhaar, OTP, tokens, secrets).
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
        'request_payload': _sanitizeLogMap(requestPayload),
        'response_payload': _sanitizeLogMap(responsePayload),
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
        'request_payload': _sanitizeLogMap(requestPayload),
        'response_payload': _sanitizeLogMap(responsePayload),
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
          throw _edgeError(data);
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
      throw _functionException(e);
    } catch (e) {
      throw AbdmException('Could not reach the ABDM gateway function: $e');
    }
  }

  /// Invokes an M1 action with the Flutter contract:
  /// `{"action": "<M1 action>", "payload": {...}}` via POST.
  Future<Map<String, dynamic>> _invokeM1(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final session = _currentSessionReader();
    if (session == null) {
      throw const AbdmException(
        'Please log in again.',
        code: 'NO_SESSION',
        statusCode: 401,
      );
    }
    try {
      final response = await _client.functions.invoke(
        _edgeFunction,
        body: {'action': action, 'payload': payload},
        method: HttpMethod.post,
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        if (data['error'] != null) {
          throw _edgeError(data);
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
      throw _functionException(e);
    } catch (e) {
      throw AbdmException('Could not reach the ABDM gateway function: $e');
    }
  }

  AbdmException _edgeError(Map<String, dynamic> data) {
    return AbdmException(
      data['error'].toString(),
      code: data['code']?.toString(),
      statusCode: data['status'] is num
          ? (data['status'] as num).toInt()
          : null,
      payload: data,
    );
  }

  AbdmException _functionException(FunctionException e) {
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
    // Preserve structured server diagnostics (e.g. ABDM_BRIDGE_400 or the
    // ABDM_M1_* codes) when the Edge Function supplies them.
    final serverCode = payload?['code']?.toString();
    return AbdmException(
      message,
      code: (serverCode != null && serverCode.isNotEmpty)
          ? serverCode
          : 'EDGE_${e.status}',
      statusCode: e.status,
      payload: payload,
    );
  }

  // -- M1 response helpers ---------------------------------------------------

  AbdmM1Profile? _profileFromEdge(Map<String, dynamic> data) {
    final rawPayload = data['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : data;
    final rawProfile = payload['profile'];
    if (rawProfile is Map) {
      return AbdmM1Profile.fromMap(Map<String, dynamic>.from(rawProfile));
    }
    // Single-profile success payloads may be flattened.
    final healthId =
        _firstString(payload, 'healthId') ??
        _firstString(payload, 'healthIdNumber');
    if (healthId != null) {
      return AbdmM1Profile.fromMap(payload);
    }
    return null;
  }

  Map<String, dynamic> _payloadMap(Map<String, dynamic> data) {
    final rawPayload = data['payload'];
    return rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : Map<String, dynamic>.from(data);
  }

  Uint8List _binaryFromEdge(Map<String, dynamic> data, String kind) {
    final payload = _payloadMap(data);
    final base64Value =
        payload['base64'] ??
        payload['cardBase64'] ??
        payload['qrBase64'] ??
        payload['bytes'];
    if (base64Value is String && base64Value.isNotEmpty) {
      return base64Decode(base64Value);
    }
    throw AbdmException(
      'The ABDM $kind binary response format requires official confirmation.',
      code: 'ABDM_M1_CONTRACT_UNCONFIRMED',
    );
  }

  static String? _firstString(Object? value, String key) {
    if (value is Map) {
      final entry = value[key];
      return entry?.toString();
    }
    return null;
  }

  /// Strips Aadhaar / OTP / token / secret keys from any persisted map.
  Map<String, dynamic> _sanitizeLogMap(Map<String, dynamic> input) {
    const sensitiveKeyFragments = [
      'aadhaar',
      'otp',
      'token',
      'secret',
      'password',
      'authorization',
      'credential',
      'clientid',
      'clientsecret',
    ];
    final out = <String, dynamic>{};
    for (final entry in input.entries) {
      final key = entry.key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (sensitiveKeyFragments.any(key.contains)) continue;
      final value = entry.value;
      if (value is Map) {
        out[entry.key] = _sanitizeLogMap(Map<String, dynamic>.from(value));
      } else if (value is List) {
        out[entry.key] = value
            .map(
              (v) =>
                  v is Map ? _sanitizeLogMap(Map<String, dynamic>.from(v)) : v,
            )
            .toList();
      } else {
        out[entry.key] = value;
      }
    }
    return out;
  }

  // -- mock + helpers --------------------------------------------------------

  AbdmM1Profile _mockProfile(String healthId, {String? abhaAddress}) {
    final address = abhaAddress ?? 'rahul9012@abdm';
    return AbdmM1Profile(
      healthId: healthId,
      healthIdNumber: healthId,
      abhaAddress: address,
      name: 'Rahul Sharma',
      firstName: 'Rahul',
      lastName: 'Sharma',
      gender: 'M',
      dateOfBirth: '1990-05-15',
      yearOfBirth: '1990',
      mobileNumber: 'XXXXXX9999',
      email: 'rahul.sharma@example.com',
      state: 'Delhi',
      district: 'New Delhi',
      status: 'ACTIVE',
    );
  }

  Future<void> _mockDelay() async {
    await Future<void>.delayed(
      Duration(milliseconds: 500 + Random().nextInt(500)),
    );
  }

  String _redactQr(String qr) => 'QR_PAYLOAD_${qr.length}';

  String _newRequestId(String prefix) {
    final now = DateTime.now();
    final stamp = '${now.millisecondsSinceEpoch}';
    final rand = Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '$prefix-$stamp-$rand';
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}
