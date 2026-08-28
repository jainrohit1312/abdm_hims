import 'package:intl/intl.dart';

/// ---------------------------------------------------------------------------
/// Compliance & Renewal Reminder Module — typed models.
///
/// The Supabase rows are plain JSON maps; these classes add type-safety,
/// status derivation and date helpers for the UI layer. All models keep
/// `fromJson`/`toJson` so they can round-trip through Supabase.
/// ---------------------------------------------------------------------------

/// Broad compliance category (mirrors the DB CHECK constraint).
enum ComplianceCategory {
  regulatory('regulatory', 'Regulatory & Licenses'),
  amc('amc', 'AMC'),
  cmc('cmc', 'CMC'),
  insurance('insurance', 'Insurance'),
  contracts('contracts', 'Contracts');

  const ComplianceCategory(this.value, this.label);

  final String value;
  final String label;

  static ComplianceCategory fromValue(String? value) {
    return ComplianceCategory.values.firstWhere(
      (c) => c.value == value,
      orElse: () => ComplianceCategory.regulatory,
    );
  }
}

/// Live status of a compliance record, derived from [expiryDate].
enum ComplianceStatus {
  active('active', 'Active'),
  expiring('expiring', 'Expiring Soon'),
  expired('expired', 'Expired'),
  archived('archived', 'Archived');

  const ComplianceStatus(this.value, this.label);

  final String value;
  final String label;

  static ComplianceStatus fromValue(String? value) {
    return ComplianceStatus.values.firstWhere(
      (s) => s.value == value,
      orElse: () => ComplianceStatus.active,
    );
  }

  /// Derives the compliance status from an expiry date.
  ///
  /// * within 30 days  -> [expiring]
  /// * in the past      -> [expired]
  /// * otherwise        -> [active]
  /// * no expiry date   -> [active]
  static ComplianceStatus fromExpiry(DateTime? expiry, {DateTime? now}) {
    if (expiry == null) return ComplianceStatus.active;
    final today = DateTime(
      (now ?? DateTime.now()).year,
      (now ?? DateTime.now()).month,
      (now ?? DateTime.now()).day,
    );
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    final days = expiryDay.difference(today).inDays;
    if (days < 0) return ComplianceStatus.expired;
    if (days <= 30) return ComplianceStatus.expiring;
    return ComplianceStatus.active;
  }
}

/// Reminder kinds persisted in `compliance_reminders.reminder_type`.
enum ReminderType {
  thirtyDay('30_day', '30 Days Before'),
  sevenDay('7_day', '7 Days Before'),
  expired('expired', 'Expired Alert'),
  manual('manual', 'Manual Reminder');

  const ReminderType(this.value, this.label);

  final String value;
  final String label;

  static ReminderType fromValue(String? value) {
    return ReminderType.values.firstWhere(
      (r) => r.value == value,
      orElse: () => ReminderType.manual,
    );
  }
}

/// Delivery channels tracked in reminder history.
enum ReminderChannel {
  inApp('in_app', 'In-App'),
  email('email', 'Email'),
  whatsapp('whatsapp', 'WhatsApp');

  const ReminderChannel(this.value, this.label);

  final String value;
  final String label;

  static ReminderChannel fromValue(String? value) {
    return ReminderChannel.values.firstWhere(
      (c) => c.value == value,
      orElse: () => ReminderChannel.inApp,
    );
  }
}

/// One compliance item (license / NOC / AMC / CMC / insurance / contract).
class ComplianceRecord {
  final String id;
  final String hospitalId;
  final String documentName;
  final String documentType;
  final ComplianceCategory category;
  final String? authorityName;
  final String? documentNumber;
  final DateTime? issueDate;
  final DateTime? expiryDate;
  final bool reminderEnabled;
  final ComplianceStatus status;
  final bool isFavorite;
  final String? notes;
  final List<String> tags;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Optional runtime value: how many document versions are attached.
  /// Mutable so the service can enrich fetched rows in-place.
  int? documentCount;

  /// Optional runtime value: the latest uploaded document (for previews).
  /// Mutable so the service can enrich fetched rows in-place.
  Map<String, dynamic>? latestDocument;

  ComplianceRecord({
    required this.id,
    required this.hospitalId,
    required this.documentName,
    required this.documentType,
    required this.category,
    this.authorityName,
    this.documentNumber,
    this.issueDate,
    this.expiryDate,
    this.reminderEnabled = true,
    required this.status,
    this.isFavorite = false,
    this.notes,
    this.tags = const [],
    this.createdBy,
    this.createdAt,
    this.updatedAt,
    this.documentCount,
    this.latestDocument,
  });

  factory ComplianceRecord.fromJson(Map<String, dynamic> json) {
    return ComplianceRecord(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      documentName: json['document_name']?.toString() ?? '',
      documentType: json['document_type']?.toString() ?? '',
      category: ComplianceCategory.fromValue(json['category']?.toString()),
      authorityName: json['authority_name']?.toString(),
      documentNumber: json['document_number']?.toString(),
      issueDate: _parseDate(json['issue_date']),
      expiryDate: _parseDate(json['expiry_date']),
      reminderEnabled: json['reminder_enabled'] != false,
      status: ComplianceStatus.fromValue(json['status']?.toString()),
      isFavorite: json['is_favorite'] == true,
      notes: json['notes']?.toString(),
      tags: _parseStringList(json['tags']),
      createdBy: json['created_by']?.toString(),
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
      documentCount: json['document_count'] is num
          ? (json['document_count'] as num).toInt()
          : null,
      latestDocument: json['latest_document'] is Map
          ? (json['latest_document'] as Map).cast<String, dynamic>()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id.isNotEmpty) 'id': id,
      'hospital_id': hospitalId,
      'document_name': documentName,
      'document_type': documentType,
      'category': category.value,
      'authority_name': authorityName,
      'document_number': documentNumber,
      'issue_date': _formatDate(issueDate),
      'expiry_date': _formatDate(expiryDate),
      'reminder_enabled': reminderEnabled,
      'status': status.value,
      'is_favorite': isFavorite,
      'notes': notes,
      'tags': tags,
      'created_by': createdBy,
    };
  }

  ComplianceRecord copyWith({
    String? documentName,
    String? documentType,
    ComplianceCategory? category,
    String? authorityName,
    String? documentNumber,
    DateTime? issueDate,
    DateTime? expiryDate,
    bool? reminderEnabled,
    ComplianceStatus? status,
    bool? isFavorite,
    String? notes,
    List<String>? tags,
    int? documentCount,
    Map<String, dynamic>? latestDocument,
  }) {
    return ComplianceRecord(
      id: id,
      hospitalId: hospitalId,
      documentName: documentName ?? this.documentName,
      documentType: documentType ?? this.documentType,
      category: category ?? this.category,
      authorityName: authorityName ?? this.authorityName,
      documentNumber: documentNumber ?? this.documentNumber,
      issueDate: issueDate ?? this.issueDate,
      expiryDate: expiryDate ?? this.expiryDate,
      reminderEnabled: reminderEnabled ?? this.reminderEnabled,
      status: status ?? this.status,
      isFavorite: isFavorite ?? this.isFavorite,
      notes: notes ?? this.notes,
      tags: tags ?? this.tags,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt,
      documentCount: documentCount ?? this.documentCount,
      latestDocument: latestDocument ?? this.latestDocument,
    );
  }

  /// Whole days until expiry. Negative = already expired; null = no expiry.
  int? get daysToExpiry {
    final expiry = expiryDate;
    if (expiry == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    return expiryDay.difference(today).inDays;
  }

  /// Live status derived from [expiryDate] (used to keep stored status fresh).
  ComplianceStatus get derivedStatus =>
      ComplianceStatus.fromExpiry(expiryDate);

  String get displayExpiry {
    final expiry = expiryDate;
    if (expiry == null) return 'No expiry';
    return DateFormat('dd MMM yyyy').format(expiry);
  }

  String get displayIssue {
    final issue = issueDate;
    if (issue == null) return '—';
    return DateFormat('dd MMM yyyy').format(issue);
  }
}

/// One versioned file attached to a [ComplianceRecord].
class ComplianceDocumentFile {
  final String id;
  final String recordId;
  final String hospitalId;
  final String fileName;
  final String filePath;
  final String? fileUrl;
  final int fileSize;
  final String? mimeType;
  final int version;
  final String? ocrText;
  final String? uploadedBy;
  final DateTime? createdAt;

  const ComplianceDocumentFile({
    required this.id,
    required this.recordId,
    required this.hospitalId,
    required this.fileName,
    required this.filePath,
    this.fileUrl,
    this.fileSize = 0,
    this.mimeType,
    this.version = 1,
    this.ocrText,
    this.uploadedBy,
    this.createdAt,
  });

  factory ComplianceDocumentFile.fromJson(Map<String, dynamic> json) {
    return ComplianceDocumentFile(
      id: json['id']?.toString() ?? '',
      recordId: json['record_id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      fileName: json['file_name']?.toString() ?? 'document',
      filePath: json['file_path']?.toString() ?? '',
      fileUrl: json['file_url']?.toString(),
      fileSize: (json['file_size'] is num)
          ? (json['file_size'] as num).toInt()
          : int.tryParse(json['file_size']?.toString() ?? '') ??
                0,
      mimeType: json['mime_type']?.toString(),
      version: (json['version'] is num)
          ? (json['version'] as num).toInt()
          : int.tryParse(json['version']?.toString() ?? '1') ??
                1,
      ocrText: json['ocr_text']?.toString(),
      uploadedBy: json['uploaded_by']?.toString(),
      createdAt: _parseDate(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'record_id': recordId,
      'hospital_id': hospitalId,
      'file_name': fileName,
      'file_path': filePath,
      'file_url': fileUrl,
      'file_size': fileSize,
      'mime_type': mimeType,
      'version': version,
      'ocr_text': ocrText,
      'uploaded_by': uploadedBy,
    };
  }

  String get extension {
    final name = fileName.toLowerCase();
    if (!name.contains('.')) return '';
    return name.split('.').last;
  }

  bool get isImage =>
      const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension);

  bool get isPdf => extension == 'pdf';

  bool get isWord => const ['doc', 'docx'].contains(extension);

  String get versionLabel => 'v$version';

  String get displaySize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// One reminder history entry.
class ComplianceReminderEntry {
  final String id;
  final String recordId;
  final String hospitalId;
  final ReminderType reminderType;
  final DateTime? scheduledFor;
  final DateTime? sentAt;
  final ReminderChannel channel;
  final String? message;
  final String status; // sent | pending | failed
  final DateTime? createdAt;

  const ComplianceReminderEntry({
    required this.id,
    required this.recordId,
    required this.hospitalId,
    required this.reminderType,
    this.scheduledFor,
    this.sentAt,
    this.channel = ReminderChannel.inApp,
    this.message,
    this.status = 'sent',
    this.createdAt,
  });

  factory ComplianceReminderEntry.fromJson(Map<String, dynamic> json) {
    return ComplianceReminderEntry(
      id: json['id']?.toString() ?? '',
      recordId: json['record_id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      reminderType: ReminderType.fromValue(json['reminder_type']?.toString()),
      scheduledFor: _parseDate(json['scheduled_for']),
      sentAt: _parseDate(json['sent_at']),
      channel: ReminderChannel.fromValue(json['channel']?.toString()),
      message: json['message']?.toString(),
      status: json['status']?.toString() ?? 'sent',
      createdAt: _parseDate(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'record_id': recordId,
      'hospital_id': hospitalId,
      'reminder_type': reminderType.value,
      'scheduled_for': _formatDate(scheduledFor),
      'sent_at': sentAt?.toUtc().toIso8601String(),
      'channel': channel.value,
      'message': message,
      'status': status,
    };
  }
}

/// One audit-log entry (who did what to a compliance record/document).
class ComplianceAuditEntry {
  final String id;
  final String? recordId;
  final String? documentId;
  final String? hospitalId;
  final String? userId;
  final String? userName;
  final String action;
  final String? detail;
  final DateTime? createdAt;

  const ComplianceAuditEntry({
    required this.id,
    this.recordId,
    this.documentId,
    this.hospitalId,
    this.userId,
    this.userName,
    required this.action,
    this.detail,
    this.createdAt,
  });

  factory ComplianceAuditEntry.fromJson(Map<String, dynamic> json) {
    return ComplianceAuditEntry(
      id: json['id']?.toString() ?? '',
      recordId: json['record_id']?.toString(),
      documentId: json['document_id']?.toString(),
      hospitalId: json['hospital_id']?.toString(),
      userId: json['user_id']?.toString(),
      userName: json['user_name']?.toString(),
      action: json['action']?.toString() ?? '',
      detail: json['detail']?.toString(),
      createdAt: _parseDate(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'record_id': recordId,
      'document_id': documentId,
      'hospital_id': hospitalId,
      'user_id': userId,
      'user_name': userName,
      'action': action,
      'detail': detail,
    };
  }
}

/// Built-in catalogue of every document type the module tracks, grouped by
/// [ComplianceCategory]. This is the single source of truth for the dropdown
/// on the entry form and for the dashboard filter chips.
class ComplianceDocumentTypeCatalog {
  ComplianceDocumentTypeCatalog._();

  static const Map<ComplianceCategory, List<String>> items = {
    ComplianceCategory.regulatory: [
      'Hospital Registration Certificate',
      'Pollution Control Certificate',
      'Fire NOC',
      'Biomedical Waste Authorization',
      'Clinical Establishment Registration',
      'Pharmacy License',
      'Radiation License',
      'Blood Bank License',
      'Nursing Home Registration',
      'Food Safety License (FSSAI)',
    ],
    ComplianceCategory.amc: [
      'Medical Equipment AMC (MRI)',
      'Medical Equipment AMC (CT Scan)',
      'Medical Equipment AMC (X-Ray)',
      'Medical Equipment AMC (Ultrasound)',
      'Medical Equipment AMC (Ventilator)',
      'HVAC / AC AMC',
      'Generator AMC',
      'Elevator / Lift AMC',
      'Fire Fighting System AMC',
      'CCTV / Security System AMC',
      'IT / Network AMC',
      'Water Purification AMC',
      'Medical Gas AMC',
      'Laundry Equipment AMC',
    ],
    ComplianceCategory.cmc: [
      'Medical Equipment CMC',
      'Building Maintenance CMC',
      'Electrical System CMC',
      'Plumbing System CMC',
      'Fire Safety System CMC',
    ],
    ComplianceCategory.insurance: [
      'Professional Indemnity Insurance',
      'Property Insurance',
      'Employee Insurance',
    ],
    ComplianceCategory.contracts: [
      'Security Services Contract',
      'Housekeeping / Laundry Contract',
      'Ambulance Services Contract',
      'Catering / Food Contract',
      'Waste Management Contract',
    ],
  };

  /// Flat list of `(type, category)` pairs for dropdowns.
  static List<MapEntry<ComplianceCategory, String>> get flat {
    return [
      for (final entry in items.entries)
        for (final type in entry.value) MapEntry(entry.key, type),
    ];
  }

  static ComplianceCategory categoryForType(String documentType) {
    for (final entry in items.entries) {
      if (entry.value.contains(documentType)) return entry.key;
    }
    return ComplianceCategory.regulatory;
  }
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

String? _formatDate(DateTime? date) {
  if (date == null) return null;
  return DateFormat('yyyy-MM-dd').format(date);
}

List<String> _parseStringList(dynamic value) {
  if (value is List) {
    return value.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
  }
  if (value is String && value.trim().isNotEmpty) {
    return value
        .replaceAll('{', '')
        .replaceAll('}', '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const [];
}
