import 'dart:convert';

/// ---------------------------------------------------------------------------
/// WhatsApp Marketing Module — Data Models
/// ---------------------------------------------------------------------------
/// The rest of the HIMS codebase mostly passes `Map<String, dynamic>` around,
/// so these models are thin, JSON-safe value objects with `fromMap` / `toMap`
/// helpers. They keep the WhatsApp screens type-safe without introducing a
/// codegen dependency for the module.
/// ---------------------------------------------------------------------------

/// Converts a value that may be `List<dynamic>` (postgres `jsonb`) or a
/// JSON string into `List<Map<String, dynamic>>`.
List<Map<String, dynamic>> _toMapList(dynamic value) {
  if (value == null) return [];
  if (value is List) {
    return value
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {
      return [];
    }
  }
  return [];
}

int _toInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;

DateTime? _toDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

String _toString(dynamic value) => value?.toString() ?? '';

/// Hospital-wise Meta WhatsApp Cloud API credentials.
class WhatsappSettings {
  final String id;
  final String hospitalId;
  final String apiKey;
  final String phoneNumberId;
  final String businessAccountId;
  final String webhookVerifyToken;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WhatsappSettings({
    this.id = '',
    this.hospitalId = '',
    this.apiKey = '',
    this.phoneNumberId = '',
    this.businessAccountId = '',
    this.webhookVerifyToken = '',
    this.isActive = false,
    this.createdAt,
    this.updatedAt,
  });

  /// True when the minimum required Meta credentials are present.
  bool get isConfigured => apiKey.isNotEmpty && phoneNumberId.isNotEmpty;

  factory WhatsappSettings.fromMap(Map<String, dynamic> map) {
    return WhatsappSettings(
      id: _toString(map['id']),
      hospitalId: _toString(map['hospital_id']),
      apiKey: _toString(map['api_key']),
      phoneNumberId: _toString(map['phone_number_id']),
      businessAccountId: _toString(map['business_account_id']),
      webhookVerifyToken: _toString(map['webhook_verify_token']),
      isActive: map['is_active'] == true,
      createdAt: _toDate(map['created_at']),
      updatedAt: _toDate(map['updated_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'hospital_id': hospitalId,
      'api_key': apiKey,
      'phone_number_id': phoneNumberId,
      'business_account_id': businessAccountId,
      'webhook_verify_token': webhookVerifyToken,
      'is_active': isActive,
    };
  }

  WhatsappSettings copyWith({
    String? apiKey,
    String? phoneNumberId,
    String? businessAccountId,
    String? webhookVerifyToken,
    bool? isActive,
  }) {
    return WhatsappSettings(
      id: id,
      hospitalId: hospitalId,
      apiKey: apiKey ?? this.apiKey,
      phoneNumberId: phoneNumberId ?? this.phoneNumberId,
      businessAccountId: businessAccountId ?? this.businessAccountId,
      webhookVerifyToken: webhookVerifyToken ?? this.webhookVerifyToken,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// A Meta pre-approved message template stored locally for reuse.
class WhatsappTemplate {
  final String id;
  final String hospitalId;
  final String templateName;
  final String language;
  final String category;
  final String body;
  final String headerType; // none | text | image | video | document
  final String headerText;
  final String footerText;
  final List<Map<String, dynamic>> buttons; // quick_reply / url / phone_number
  final String status; // pending | approved | rejected | paused
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WhatsappTemplate({
    this.id = '',
    this.hospitalId = '',
    this.templateName = '',
    this.language = 'en',
    this.category = 'MARKETING',
    this.body = '',
    this.headerType = 'none',
    this.headerText = '',
    this.footerText = '',
    this.buttons = const [],
    this.status = 'pending',
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
  });

  factory WhatsappTemplate.fromMap(Map<String, dynamic> map) {
    return WhatsappTemplate(
      id: _toString(map['id']),
      hospitalId: _toString(map['hospital_id']),
      templateName: _toString(map['template_name']),
      language: _toString(map['language']).isEmpty
          ? 'en'
          : _toString(map['language']),
      category: _toString(map['category']).isEmpty
          ? 'MARKETING'
          : _toString(map['category']),
      body: _toString(map['body']),
      headerType: _toString(map['header_type']),
      headerText: _toString(map['header_text']),
      footerText: _toString(map['footer_text']),
      buttons: _toMapList(map['buttons']),
      status: _toString(map['status']).isEmpty
          ? 'pending'
          : _toString(map['status']),
      isActive: map['is_active'] != false,
      createdAt: _toDate(map['created_at']),
      updatedAt: _toDate(map['updated_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'hospital_id': hospitalId,
      'template_name': templateName,
      'language': language,
      'category': category,
      'body': body,
      'header_type': headerType,
      'header_text': headerText,
      'footer_text': footerText,
      'buttons': buttons,
      'status': status,
      'is_active': isActive,
    };
  }

  WhatsappTemplate copyWith({
    String? status,
    bool? isActive,
    String? templateName,
    String? language,
    String? category,
    String? body,
    String? headerType,
    String? headerText,
    String? footerText,
    List<Map<String, dynamic>>? buttons,
  }) {
    return WhatsappTemplate(
      id: id,
      hospitalId: hospitalId,
      templateName: templateName ?? this.templateName,
      language: language ?? this.language,
      category: category ?? this.category,
      body: body ?? this.body,
      headerType: headerType ?? this.headerType,
      headerText: headerText ?? this.headerText,
      footerText: footerText ?? this.footerText,
      buttons: buttons ?? this.buttons,
      status: status ?? this.status,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// A broadcast campaign targeting one or more opted-in patients.
class WhatsappCampaign {
  final String id;
  final String hospitalId;
  final String templateId;
  final String name;
  final String messageBody;
  final List<Map<String, dynamic>> recipients;
  final String
  status; // draft | scheduled | sending | sent | failed | cancelled
  final int sentCount;
  final int deliveredCount;
  final int readCount;
  final int failedCount;
  final DateTime? scheduledAt;
  final DateTime? sentAt;
  final String createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WhatsappCampaign({
    this.id = '',
    this.hospitalId = '',
    this.templateId = '',
    this.name = '',
    this.messageBody = '',
    this.recipients = const [],
    this.status = 'draft',
    this.sentCount = 0,
    this.deliveredCount = 0,
    this.readCount = 0,
    this.failedCount = 0,
    this.scheduledAt,
    this.sentAt,
    this.createdBy = '',
    this.createdAt,
    this.updatedAt,
  });

  int get totalCount => sentCount + deliveredCount + readCount + failedCount;

  factory WhatsappCampaign.fromMap(Map<String, dynamic> map) {
    return WhatsappCampaign(
      id: _toString(map['id']),
      hospitalId: _toString(map['hospital_id']),
      templateId: _toString(map['template_id']),
      name: _toString(map['name']),
      messageBody: _toString(map['message_body']),
      recipients: _toMapList(map['recipients']),
      status: _toString(map['status']).isEmpty
          ? 'draft'
          : _toString(map['status']),
      sentCount: _toInt(map['sent_count']),
      deliveredCount: _toInt(map['delivered_count']),
      readCount: _toInt(map['read_count']),
      failedCount: _toInt(map['failed_count']),
      scheduledAt: _toDate(map['scheduled_at']),
      sentAt: _toDate(map['sent_at']),
      createdBy: _toString(map['created_by']),
      createdAt: _toDate(map['created_at']),
      updatedAt: _toDate(map['updated_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'hospital_id': hospitalId,
      if (templateId.isNotEmpty) 'template_id': templateId,
      'name': name,
      'message_body': messageBody,
      'recipients': recipients,
      'status': status,
      'sent_count': sentCount,
      'delivered_count': deliveredCount,
      'read_count': readCount,
      'failed_count': failedCount,
      if (scheduledAt != null)
        'scheduled_at': scheduledAt!.toUtc().toIso8601String(),
      if (sentAt != null) 'sent_at': sentAt!.toUtc().toIso8601String(),
      if (createdBy.isNotEmpty) 'created_by': createdBy,
    };
  }
}

/// Individual WhatsApp message log.
class WhatsappMessage {
  final String id;
  final String hospitalId;
  final String campaignId;
  final String patientId;
  final String phoneNumber;
  final String templateId;
  final String messageBody;
  final String messageId; // Meta wamid
  final String status; // sent | delivered | read | failed
  final String errorMessage;
  final DateTime? sentAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final DateTime? createdAt;

  const WhatsappMessage({
    this.id = '',
    this.hospitalId = '',
    this.campaignId = '',
    this.patientId = '',
    this.phoneNumber = '',
    this.templateId = '',
    this.messageBody = '',
    this.messageId = '',
    this.status = 'sent',
    this.errorMessage = '',
    this.sentAt,
    this.deliveredAt,
    this.readAt,
    this.createdAt,
  });

  factory WhatsappMessage.fromMap(Map<String, dynamic> map) {
    return WhatsappMessage(
      id: _toString(map['id']),
      hospitalId: _toString(map['hospital_id']),
      campaignId: _toString(map['campaign_id']),
      patientId: _toString(map['patient_id']),
      phoneNumber: _toString(map['phone_number']),
      templateId: _toString(map['template_id']),
      messageBody: _toString(map['message_body']),
      messageId: _toString(map['message_id']),
      status: _toString(map['status']).isEmpty
          ? 'sent'
          : _toString(map['status']),
      errorMessage: _toString(map['error_message']),
      sentAt: _toDate(map['sent_at']),
      deliveredAt: _toDate(map['delivered_at']),
      readAt: _toDate(map['read_at']),
      createdAt: _toDate(map['created_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'hospital_id': hospitalId,
      if (campaignId.isNotEmpty) 'campaign_id': campaignId,
      if (patientId.isNotEmpty) 'patient_id': patientId,
      'phone_number': phoneNumber,
      if (templateId.isNotEmpty) 'template_id': templateId,
      'message_body': messageBody,
      if (messageId.isNotEmpty) 'message_id': messageId,
      'status': status,
      if (errorMessage.isNotEmpty) 'error_message': errorMessage,
      if (sentAt != null) 'sent_at': sentAt!.toUtc().toIso8601String(),
      if (deliveredAt != null)
        'delivered_at': deliveredAt!.toUtc().toIso8601String(),
      if (readAt != null) 'read_at': readAt!.toUtc().toIso8601String(),
    };
  }
}

/// Patient opt-out record (DND list for WhatsApp marketing).
class WhatsappOptOut {
  final String id;
  final String hospitalId;
  final String patientId;
  final String phoneNumber;
  final DateTime? optedOutAt;
  final String reason;
  final DateTime? createdAt;

  const WhatsappOptOut({
    this.id = '',
    this.hospitalId = '',
    this.patientId = '',
    this.phoneNumber = '',
    this.optedOutAt,
    this.reason = '',
    this.createdAt,
  });

  factory WhatsappOptOut.fromMap(Map<String, dynamic> map) {
    return WhatsappOptOut(
      id: _toString(map['id']),
      hospitalId: _toString(map['hospital_id']),
      patientId: _toString(map['patient_id']),
      phoneNumber: _toString(map['phone_number']),
      optedOutAt: _toDate(map['opted_out_at']),
      reason: _toString(map['reason']),
      createdAt: _toDate(map['created_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'hospital_id': hospitalId,
      if (patientId.isNotEmpty) 'patient_id': patientId,
      'phone_number': phoneNumber,
      if (optedOutAt != null)
        'opted_out_at': optedOutAt!.toUtc().toIso8601String(),
      if (reason.isNotEmpty) 'reason': reason,
    };
  }
}

/// A patient that can be targeted in a WhatsApp campaign.
class WhatsappRecipient {
  final String patientId;
  final String name;
  final String uhid;
  final String phoneNumber;
  final String source; // opd | ipd | patients

  const WhatsappRecipient({
    required this.patientId,
    required this.name,
    required this.uhid,
    required this.phoneNumber,
    required this.source,
  });

  factory WhatsappRecipient.fromMap(Map<String, dynamic> map) {
    return WhatsappRecipient(
      patientId: _toString(map['patient_id']),
      name: _toString(map['name']),
      uhid: _toString(map['uhid']),
      phoneNumber: _toString(map['phone_number']),
      source: _toString(map['source']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'patient_id': patientId,
      'name': name,
      'uhid': uhid,
      'phone_number': phoneNumber,
      'source': source,
    };
  }
}

/// Aggregated campaign analytics for the dashboard.
class WhatsappAnalytics {
  final int totalCampaigns;
  final int totalMessages;
  final int sent;
  final int delivered;
  final int read;
  final int failed;
  final int optOuts;
  final int optInPatients;

  const WhatsappAnalytics({
    this.totalCampaigns = 0,
    this.totalMessages = 0,
    this.sent = 0,
    this.delivered = 0,
    this.read = 0,
    this.failed = 0,
    this.optOuts = 0,
    this.optInPatients = 0,
  });

  double get deliveryRate => sent == 0 ? 0 : (delivered / sent).clamp(0.0, 1.0);

  double get readRate =>
      delivered == 0 ? 0 : (read / delivered).clamp(0.0, 1.0);

  factory WhatsappAnalytics.fromJson(Map<String, dynamic> json) {
    return WhatsappAnalytics(
      totalCampaigns: _toInt(json['total_campaigns']),
      totalMessages: _toInt(json['total_messages']),
      sent: _toInt(json['sent']),
      delivered: _toInt(json['delivered']),
      read: _toInt(json['read']),
      failed: _toInt(json['failed']),
      optOuts: _toInt(json['opt_outs']),
      optInPatients: _toInt(json['opt_in_patients']),
    );
  }
}
