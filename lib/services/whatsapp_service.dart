import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Marketing Module — Meta WhatsApp Cloud API Service
/// ---------------------------------------------------------------------------
/// Thin, typed client for the Meta WhatsApp Business Platform (Cloud API):
///
///   * POST /{phone-number-id}/messages                    — send a message
///   * GET  /{waba-id}/phone_numbers                       — list senders
///   * GET  /{waba-id}/message_templates                   — list templates
///   * POST /{waba-id}/message_templates                   — create template
///   * DELETE /{waba-id}/message_templates?name=...        — delete template
///
/// Webhook helpers (verification + HMAC signature validation + status parsing)
/// live here as well so an Edge Function can reuse the same semantics.
/// ---------------------------------------------------------------------------

/// Friendly, user-displayable API error.
class WhatsappApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? errorCode;
  final String? metaErrorType;
  final bool isRateLimited;
  final Duration? retryAfter;

  const WhatsappApiException({
    required this.message,
    this.statusCode,
    this.errorCode,
    this.metaErrorType,
    this.isRateLimited = false,
    this.retryAfter,
  });

  @override
  String toString() =>
      'WhatsappApiException($statusCode/$errorCode/$metaErrorType): $message';
}

/// One parsed status update from a Meta webhook payload.
class WhatsappWebhookStatus {
  final String messageId; // Meta `wamid`
  final String status; // sent | delivered | read | failed
  final String phoneNumber; // recipient, E.164
  final DateTime? timestamp;
  final String? errorCode;

  const WhatsappWebhookStatus({
    required this.messageId,
    required this.status,
    required this.phoneNumber,
    this.timestamp,
    this.errorCode,
  });

  Map<String, dynamic> toMap() => {
    'message_id': messageId,
    'status': status,
    'phone_number': phoneNumber,
    if (timestamp != null) 'timestamp': timestamp!.toUtc().toIso8601String(),
    if (errorCode != null) 'error_code': errorCode,
  };
}

class WhatsappService {
  WhatsappService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 30);

  String get _graphBase =>
      '${ApiConstants.whatsappGraphBaseUrl}/${ApiConstants.whatsappApiVersion}';

  // ---------------------------------------------------------------------------
  // Phone number helpers
  // ---------------------------------------------------------------------------

  /// Normalizes an Indian-style phone number to E.164 (`91XXXXXXXXXX`).
  ///
  /// Rules:
  ///  * Strip everything that is not a digit.
  ///  * 10 digits starting with 7/8/9 → prefix `91`.
  ///  * Leading `0` + 10 digits → prefix `91`.
  ///  * Already has a country code → returned as-is (digits only).
  static String normalizePhoneNumber(String phone) {
    var digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0')) digits = digits.substring(1);
    if (digits.length == 10 && RegExp(r'^[6-9]').hasMatch(digits)) {
      return '91$digits';
    }
    return digits;
  }

  /// True when [phone] normalizes to a plausible international number.
  static bool isValidPhone(String phone) {
    final normalized = normalizePhoneNumber(phone);
    return normalized.length >= 11 && normalized.length <= 15;
  }

  // ---------------------------------------------------------------------------
  // Meta API calls
  // ---------------------------------------------------------------------------

  /// GET /{waba-id}/phone_numbers — senders connected to a WABA.
  Future<List<Map<String, dynamic>>> getPhoneNumbers({
    required String accessToken,
    required String businessAccountId,
  }) async {
    final data = await _get(
      '$_graphBase/${Uri.encodeComponent(businessAccountId)}/phone_numbers',
      accessToken,
    );
    final list = data['data'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// GET /{phone-number-id} — basic info for one sender (used to test a
  /// credential pair when the WABA id is not configured).
  Future<Map<String, dynamic>> getPhoneNumberInfo({
    required String accessToken,
    required String phoneNumberId,
  }) {
    return _get(
      '$_graphBase/${Uri.encodeComponent(phoneNumberId)}',
      accessToken,
    );
  }

  /// GET /{waba-id}/message_templates — Meta pre-approved templates.
  Future<List<Map<String, dynamic>>> getTemplates({
    required String accessToken,
    required String wabaId,
    int limit = 100,
  }) async {
    final data = await _get(
      '$_graphBase/${Uri.encodeComponent(wabaId)}/message_templates?limit=$limit',
      accessToken,
    );
    final list = data['data'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// POST /{waba-id}/message_templates — creates a template in Meta.
  ///
  /// Meta needs the template in its `components` format:
  /// ```json
  /// {
  ///   "name": "appointment_reminder",
  ///   "language": "en",
  ///   "category": "UTILITY",
  ///   "components": [
  ///     {"type": "HEADER", "format": "TEXT", "text": "..."},
  ///     {"type": "BODY", "text": "..."},
  ///     {"type": "FOOTER", "text": "..."},
  ///     {"type": "BUTTONS", "buttons": [...]}
  ///   ]
  /// }
  /// ```
  Future<Map<String, dynamic>> createTemplate({
    required String accessToken,
    required String wabaId,
    required String name,
    required String language,
    required String category,
    required String body,
    String headerType = 'none',
    String headerText = '',
    String footerText = '',
    List<Map<String, dynamic>> buttons = const [],
  }) async {
    final components = <Map<String, dynamic>>[];
    if (headerType != 'none' && headerText.isNotEmpty) {
      components.add({
        'type': 'HEADER',
        'format': headerType.toUpperCase() == 'TEXT' ? 'TEXT' : 'TEXT',
        'text': headerText,
      });
    }
    components.add({'type': 'BODY', 'text': body});
    if (footerText.isNotEmpty) {
      components.add({'type': 'FOOTER', 'text': footerText});
    }
    if (buttons.isNotEmpty) {
      components.add({'type': 'BUTTONS', 'buttons': buttons});
    }

    return _post(
      '$_graphBase/${Uri.encodeComponent(wabaId)}/message_templates',
      accessToken,
      {
        'name': name,
        'language': language,
        'category': category,
        'components': components,
      },
    );
  }

  /// DELETE /{waba-id}/message_templates?name={template_name}
  Future<Map<String, dynamic>> deleteTemplate({
    required String accessToken,
    required String wabaId,
    required String templateName,
  }) async {
    final uri = Uri.parse(
      '$_graphBase/${Uri.encodeComponent(wabaId)}/message_templates',
    ).replace(queryParameters: {'name': templateName});
    return _delete(uri.toString(), accessToken);
  }

  /// POST /{phone-number-id}/messages — send a pre-approved template message.
  ///
  /// Returns the Meta response containing `messages[0].id` (the `wamid`).
  Future<Map<String, dynamic>> sendTemplateMessage({
    required String accessToken,
    required String phoneNumberId,
    required String to,
    required String templateName,
    String languageCode = 'en',
    List<Map<String, dynamic>> components = const [],
  }) async {
    return _sendMessage(
      accessToken: accessToken,
      phoneNumberId: phoneNumberId,
      payload: {
        'messaging_product': 'whatsapp',
        'to': normalizePhoneNumber(to),
        'type': 'template',
        'template': {
          'name': templateName,
          'language': {'code': languageCode},
          if (components.isNotEmpty) 'components': components,
        },
      },
    );
  }

  /// POST /{phone-number-id}/messages — send a free-form text message.
  ///
  /// NOTE: only valid inside a 24-hour customer-service window.
  Future<Map<String, dynamic>> sendTextMessage({
    required String accessToken,
    required String phoneNumberId,
    required String to,
    required String body,
  }) async {
    return _sendMessage(
      accessToken: accessToken,
      phoneNumberId: phoneNumberId,
      payload: {
        'messaging_product': 'whatsapp',
        'to': normalizePhoneNumber(to),
        'type': 'text',
        'text': {'preview_url': false, 'body': body},
      },
    );
  }

  Future<Map<String, dynamic>> _sendMessage({
    required String accessToken,
    required String phoneNumberId,
    required Map<String, dynamic> payload,
  }) {
    return _post(
      '$_graphBase/${Uri.encodeComponent(phoneNumberId)}/messages',
      accessToken,
      payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Webhook helpers
  // ---------------------------------------------------------------------------

  /// GET /webhook/whatsapp verification step.
  ///
  /// Meta sends `hub.mode=subscribe`, `hub.verify_token` and `hub.challenge`.
  /// Return the challenge when the token matches, otherwise null.
  String? verifyWebhook({
    required String hubMode,
    required String hubVerifyToken,
    required String hubChallenge,
    required String configuredToken,
  }) {
    if (hubMode != 'subscribe') return null;
    if (configuredToken.isEmpty) return null;
    if (hubVerifyToken != configuredToken) return null;
    return hubChallenge;
  }

  /// Validates `X-Hub-Signature-256` (sha256 HMAC of the **raw** body using
  /// the Meta App Secret).
  bool isValidWebhookSignature({
    required String rawBody,
    required String signatureHeader,
    required String appSecret,
  }) {
    try {
      const prefix = 'sha256=';
      if (!signatureHeader.startsWith(prefix)) return false;
      final expected = signatureHeader.substring(prefix.length);
      final digest = Hmac(
        sha256,
        utf8.encode(appSecret),
      ).convert(utf8.encode(rawBody)).toString();
      // Constant-time-ish comparison to avoid simple timing leaks.
      var diff = 0;
      final a = digest.codeUnits;
      final b = expected.codeUnits;
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        diff |= a[i] ^ b[i];
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }

  /// Parses Meta `messages` status updates from a webhook payload.
  ///
  /// Expected shape (simplified):
  /// ```json
  /// {"entry": [{"changes": [{"value": {"statuses": [
  ///   {"id": "wamid...", "status": "delivered", "timestamp": "...",
  ///    "recipient_id": "9198...", "errors": [{"code": 131026}]}
  /// ]}}]}]}
  /// ```
  List<WhatsappWebhookStatus> parseWebhookStatuses(
    Map<String, dynamic> payload,
  ) {
    final statuses = <WhatsappWebhookStatus>[];
    try {
      final entries = payload['entry'];
      if (entries is! List) return statuses;

      for (final entry in entries.whereType<Map>()) {
        final changes = entry['changes'];
        if (changes is! List) continue;
        for (final change in changes.whereType<Map>()) {
          final value = change['value'];
          if (value is! Map) continue;

          // Message-level statuses.
          final rawStatuses = value['statuses'];
          if (rawStatuses is List) {
            for (final s in rawStatuses.whereType<Map>()) {
              final errors = s['errors'];
              String? errorCode;
              if (errors is List && errors.isNotEmpty && errors.first is Map) {
                errorCode = (errors.first as Map)['code']?.toString();
              }
              statuses.add(
                WhatsappWebhookStatus(
                  messageId: s['id']?.toString() ?? '',
                  status: s['status']?.toString() ?? 'sent',
                  phoneNumber: s['recipient_id']?.toString() ?? '',
                  timestamp: DateTime.tryParse(
                    s['timestamp']?.toString() ?? '',
                  ),
                  errorCode: errorCode,
                ),
              );
            }
          }

          // A `messages` entry with errors but no status means the send
          // itself failed — surface it as a failed status.
          final messages = value['messages'];
          if (messages is List) {
            for (final m in messages.whereType<Map>()) {
              final errors = m['errors'];
              if (errors is List && errors.isNotEmpty) {
                statuses.add(
                  WhatsappWebhookStatus(
                    messageId: m['id']?.toString() ?? '',
                    status: 'failed',
                    phoneNumber: m['from']?.toString() ?? '',
                    timestamp: DateTime.tryParse(
                      m['timestamp']?.toString() ?? '',
                    ),
                    errorCode: errors.first is Map
                        ? (errors.first as Map)['code']?.toString()
                        : null,
                  ),
                );
              }
            }
          }
        }
      }
    } catch (e) {
      AppLogger.e('Error parsing WhatsApp webhook payload', e);
    }
    return statuses;
  }

  // ---------------------------------------------------------------------------
  // HTTP plumbing
  // ---------------------------------------------------------------------------

  Map<String, String> _headers(String accessToken) => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> _get(String url, String accessToken) async {
    return _guard(() async {
      final response = await _client
          .get(Uri.parse(url), headers: _headers(accessToken))
          .timeout(_timeout);
      return _parseResponse(response);
    });
  }

  Future<Map<String, dynamic>> _post(
    String url,
    String accessToken,
    Map<String, dynamic> body,
  ) async {
    return _guard(() async {
      final response = await _client
          .post(
            Uri.parse(url),
            headers: _headers(accessToken),
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      return _parseResponse(response);
    });
  }

  Future<Map<String, dynamic>> _delete(String url, String accessToken) async {
    return _guard(() async {
      final response = await _client
          .delete(Uri.parse(url), headers: _headers(accessToken))
          .timeout(_timeout);
      return _parseResponse(response);
    });
  }

  /// Maps network + Graph-API errors into [WhatsappApiException] and applies a
  /// single automatic retry when Meta rate-limits the call.
  Future<Map<String, dynamic>> _guard(
    Future<Map<String, dynamic>> Function() call,
  ) async {
    try {
      final result = await call();
      return result;
    } on WhatsappApiException catch (e) {
      if (e.isRateLimited && e.retryAfter != null) {
        AppLogger.w(
          'WhatsApp API rate-limited — retrying after ${e.retryAfter!.inSeconds}s',
        );
        await Future.delayed(e.retryAfter!);
        return call();
      }
      rethrow;
    } on TimeoutException {
      throw const WhatsappApiException(
        message: 'WhatsApp API request timed out. Please try again.',
        errorCode: 'TIMEOUT',
      );
    } catch (e) {
      AppLogger.e('WhatsApp API network error', e);
      throw WhatsappApiException(
        message:
            'Could not reach WhatsApp API. Check your internet connection.',
        errorCode: 'NETWORK',
      );
    }
  }

  Map<String, dynamic> _parseResponse(http.Response response) {
    final text = response.body.isEmpty ? '{}' : response.body;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      json = const {};
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) return json;

    final error = json['error'];
    final errorMap = error is Map ? Map<String, dynamic>.from(error) : const {};
    final errorCode = errorMap['code']?.toString();
    final errorType = errorMap['type']?.toString();
    final message =
        errorMap['message']?.toString() ??
        errorMap['error_user_msg']?.toString() ??
        'WhatsApp API returned HTTP $status';

    if (status == 429) {
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      throw WhatsappApiException(
        message: 'WhatsApp rate limit reached. Please try again shortly.',
        statusCode: status,
        errorCode: errorCode ?? '429',
        metaErrorType: errorType,
        isRateLimited: true,
        retryAfter: retryAfter ?? const Duration(seconds: 5),
      );
    }

    // Friendly messages for the most common errors.
    var friendly = message;
    switch (errorCode) {
      case '190':
        friendly = 'Invalid WhatsApp access token. Please update your API key.';
        break;
      case '100':
        friendly = 'Invalid parameter sent to WhatsApp API: $message';
        break;
      case '131030':
      case '131026':
        friendly =
            'This message template is not approved or is paused by Meta.';
        break;
      default:
        break;
    }

    throw WhatsappApiException(
      message: friendly,
      statusCode: status,
      errorCode: errorCode,
      metaErrorType: errorType,
    );
  }

  Duration? _parseRetryAfter(String? value) {
    final seconds = int.tryParse(value ?? '');
    if (seconds == null) return null;
    return Duration(seconds: seconds.clamp(1, 60));
  }
}
