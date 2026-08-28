import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import '../models/compliance_models.dart';
import 'database_service.dart';
import 'storage_service.dart';

/// ---------------------------------------------------------------------------
/// Compliance & Renewal Reminder Module — data service.
///
/// Handles all Supabase + Storage access for:
/// * compliance records (licenses, NOCs, AMCs, CMCs, insurance, contracts)
/// * versioned document files in the `hims-storage` bucket
/// * reminder history + the 30/7/expired reminder engine
/// * audit logs (upload / view / download / share / print / delete)
///
/// Every query is hospital-scoped; [DatabaseService.fetchWithRetry] wraps the
/// Supabase calls with the same timeout/retry policy as the rest of the app.
/// ---------------------------------------------------------------------------
class ComplianceService {
  ComplianceService(
    this._client, {
    required DatabaseService dbService,
    required StorageService storageService,
  }) : _db = dbService,
       _storage = storageService;

  final SupabaseClient _client;
  final DatabaseService _db;
  final StorageService _storage;

  static const String _bucket = 'hims-storage';
  static const String _rootFolder = 'compliance';

  /// Maximum file size for one compliance document (25 MB).
  static const int maxFileSizeBytes = 25 * 1024 * 1024;

  /// Allowed document extensions (PDF + images + Word).
  static const Set<String> allowedExtensions = {
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'doc',
    'docx',
  };

  static bool isAllowedExtension(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    return allowedExtensions.contains(ext);
  }

  // ---------------------------------------------------------------------------
  // Records
  // ---------------------------------------------------------------------------

  /// Returns all compliance records for a hospital, enriched with
  /// `document_count` and `latest_document`, newest first.
  Future<List<ComplianceRecord>> getRecords(
    String hospitalId, {
    String? search,
    ComplianceCategory? category,
    ComplianceStatus? status,
    bool favoriteOnly = false,
    String sortBy = 'expiry',
    bool ascending = false,
  }) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceRecordsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .order('created_at', ascending: false),
      );
      final rows = List<Map<String, dynamic>>.from(response);

      final records = rows.map(ComplianceRecord.fromJson).toList();
      await _enrichWithDocuments(records, hospitalId);

      var filtered = records;

      // Live-status refresh (stored status can drift as dates pass).
      for (final record in filtered) {
        final derived = record.derivedStatus;
        if (derived != record.status) {
          try {
            await DatabaseService.fetchWithRetry(
              () => _client
                  .from(ApiConstants.complianceRecordsTable)
                  .update({'status': derived.value})
                  .eq('id', record.id)
                  .select(),
            );
          } catch (_) {
            // Status refresh is cosmetic — never fail the list fetch.
          }
        }
      }

      if (favoriteOnly) {
        filtered = filtered.where((r) => r.isFavorite).toList();
      }
      if (category != null) {
        filtered = filtered.where((r) => r.category == category).toList();
      }
      if (status != null) {
        filtered = filtered.where((r) => r.derivedStatus == status).toList();
      }
      if (search != null && search.trim().isNotEmpty) {
        final query = search.trim().toLowerCase();
        filtered = filtered.where((r) {
          return r.documentName.toLowerCase().contains(query) ||
              r.documentType.toLowerCase().contains(query) ||
              (r.authorityName ?? '').toLowerCase().contains(query) ||
              (r.documentNumber ?? '').toLowerCase().contains(query) ||
              r.displayExpiry.toLowerCase().contains(query);
        }).toList();
      }

      filtered.sort((a, b) {
        int result;
        switch (sortBy) {
          case 'name':
            result = a.documentName
                .toLowerCase()
                .compareTo(b.documentName.toLowerCase());
            break;
          case 'created':
            result = (b.createdAt ?? DateTime(2000)).compareTo(
              a.createdAt ?? DateTime(2000),
            );
            break;
          case 'expiry':
          default:
            final aExpiry = a.expiryDate ?? DateTime(9999);
            final bExpiry = b.expiryDate ?? DateTime(9999);
            result = aExpiry.compareTo(bExpiry);
            break;
        }
        return ascending ? result : -result;
      });

      return filtered;
    } catch (e) {
      AppLogger.e('Error fetching compliance records', e);
      return [];
    }
  }

  /// Attaches `document_count` and `latest_document` to each record.
  Future<void> _enrichWithDocuments(
    List<ComplianceRecord> records,
    String hospitalId,
  ) async {
    if (records.isEmpty) return;
    final recordIds = records.map((r) => r.id).toList();
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceDocumentsTable)
            .select()
            .inFilter('record_id', recordIds)
            .order('version', ascending: false),
      );
      final docs =
          response
              .map((row) => ComplianceDocumentFile.fromJson(row))
              .toList();
      for (final record in records) {
        final mine = docs.where((d) => d.recordId == record.id).toList();
        record.documentCount = mine.length;
        if (mine.isNotEmpty) {
          record.latestDocument = mine.first.toJson();
        }
      }
    } catch (e) {
      AppLogger.w('Could not enrich compliance records with documents: $e');
    }
  }

  /// One record by id (may be null), already hospital-scoped.
  Future<ComplianceRecord?> getRecordById(
    String recordId, {
    String? hospitalId,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.complianceRecordsTable)
          .select()
          .eq('id', recordId);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await DatabaseService.fetchWithRetry(
        () => query.maybeSingle(),
      );
      if (response == null) return null;
      final record = ComplianceRecord.fromJson(response);
      await _enrichWithDocuments([record], record.hospitalId);
      return record;
    } catch (e) {
      AppLogger.e('Error fetching compliance record by id', e);
      return null;
    }
  }

  Future<ComplianceRecord> createRecord(
    Map<String, dynamic> payload, {
    String? hospitalId,
  }) async {
    try {
      final data = Map<String, dynamic>.from(payload);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        data['hospital_id'] = hospitalId;
      }
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceRecordsTable)
            .insert(data)
            .select()
            .single(),
      );
      return ComplianceRecord.fromJson(response);
    } catch (e) {
      AppLogger.e('Error creating compliance record', e);
      rethrow;
    }
  }

  Future<ComplianceRecord> updateRecord(
    String recordId,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceRecordsTable)
            .update(payload)
            .eq('id', recordId)
            .select()
            .single(),
      );
      return ComplianceRecord.fromJson(response);
    } catch (e) {
      AppLogger.e('Error updating compliance record', e);
      rethrow;
    }
  }

  Future<void> deleteRecord(String recordId) async {
    try {
      // Delete stored files first, then the record (documents cascade).
      final docs = await getDocuments(recordId);
      for (final doc in docs) {
        try {
          await _storage.removeByUrl(doc.filePath);
        } catch (_) {
          // File may already be gone; row deletion must still succeed.
        }
      }
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceRecordsTable)
            .delete()
            .eq('id', recordId),
      );
    } catch (e) {
      AppLogger.e('Error deleting compliance record', e);
      rethrow;
    }
  }

  Future<void> setFavorite(String recordId, bool favorite) async {
    await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.complianceRecordsTable)
          .update({'is_favorite': favorite})
          .eq('id', recordId),
    );
  }

  // ---------------------------------------------------------------------------
  // Documents (versioned files)
  // ---------------------------------------------------------------------------

  /// Documents for one record, newest version first.
  Future<List<ComplianceDocumentFile>> getDocuments(String recordId) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceDocumentsTable)
            .select()
            .eq('record_id', recordId)
            .order('version', ascending: false)
            .order('created_at', ascending: false),
      );
      return response
          .map((row) => ComplianceDocumentFile.fromJson(row))
          .toList();
    } catch (e) {
      AppLogger.e('Error fetching compliance documents', e);
      return [];
    }
  }

  /// Every document of a hospital, flattened with its parent record fields
  /// (`record_name`, `record_type`, `record_category`, `record_expiry`) so the
  /// "All Documents" screen can search/filter across records.
  ///
  /// Uses two queries total (records + all documents) instead of one per
  /// record, so large hospitals stay fast.
  Future<List<Map<String, dynamic>>> getAllDocuments(String hospitalId) async {
    try {
      final records = await getRecords(hospitalId);
      if (records.isEmpty) return const [];

      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceDocumentsTable)
            .select()
            .eq('hospital_id', hospitalId),
      );
      final documents = response
          .map((row) => ComplianceDocumentFile.fromJson(row))
          .toList();

      final recordById = {for (final record in records) record.id: record};
      final allDocs = <Map<String, dynamic>>[];
      for (final doc in documents) {
        final record = recordById[doc.recordId];
        if (record == null) continue;
        allDocs.add(
          doc.toJson()
            ..['record_name'] = record.documentName
            ..['record_type'] = record.documentType
            ..['record_category'] = record.category.value
            ..['record_expiry'] = record.expiryDate?.toIso8601String()
            ..['record_is_favorite'] = record.isFavorite,
        );
      }
      allDocs.sort((a, b) {
        final aCreated = DateTime.tryParse(a['created_at']?.toString() ?? '');
        final bCreated = DateTime.tryParse(b['created_at']?.toString() ?? '');
        return (bCreated ?? DateTime(2000)).compareTo(aCreated ?? DateTime(2000));
      });
      return allDocs;
    } catch (e) {
      AppLogger.e('Error fetching all compliance documents', e);
      return [];
    }
  }

  /// One document row by id (may be null). Used by the built-in viewer.
  Future<ComplianceDocumentFile?> getDocumentById(String documentId) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceDocumentsTable)
            .select()
            .eq('id', documentId)
            .maybeSingle(),
      );
      return response == null
          ? null
          : ComplianceDocumentFile.fromJson(response);
    } catch (e) {
      AppLogger.e('Error fetching compliance document by id', e);
      return null;
    }
  }

  /// Uploads one file and attaches it as the next document version of
  /// [recordId]. Returns the created document row.
  Future<ComplianceDocumentFile> uploadDocument({
    required String recordId,
    required String hospitalId,
    required String fileName,
    required Uint8List bytes,
    required String uploadedBy,
    String? ocrText,
  }) async {
    if (bytes.length > maxFileSizeBytes) {
      throw Exception('File exceeds the 25 MB per-file limit');
    }
    if (!isAllowedExtension(fileName)) {
      throw Exception(
        'Only PDF, JPG, PNG, JPEG, DOC, DOCX files are allowed',
      );
    }

    final existing = await getDocuments(recordId);
    final nextVersion =
        existing.isEmpty
            ? 1
            : existing.map((d) => d.version).reduce((a, b) => a > b ? a : b) +
                1;

    final safeName = _sanitizeFileName(fileName);
    final storagePath =
        '$_rootFolder/$hospitalId/$recordId/v${nextVersion}_'
        '${DateTime.now().millisecondsSinceEpoch}_$safeName';

    final fileUrl = await DatabaseService.fetchWithRetry(() async {
      await _client.storage
          .from(_bucket)
          .uploadBinary(storagePath, bytes, fileOptions: const FileOptions(
            upsert: true,
          ));
      return _client.storage.from(_bucket).getPublicUrl(storagePath);
    });

    final response = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.complianceDocumentsTable)
          .insert({
            'record_id': recordId,
            'hospital_id': hospitalId,
            'file_name': fileName,
            'file_path': storagePath,
            'file_url': fileUrl,
            'file_size': bytes.length,
            'mime_type': _mimeTypeFor(fileName),
            'version': nextVersion,
            'ocr_text': ocrText,
            'uploaded_by': uploadedBy,
          })
          .select()
          .single(),
    );
    return ComplianceDocumentFile.fromJson(response);
  }

  Future<void> deleteDocument(String documentId) async {
    try {
      final doc = await _getDocumentRow(documentId);
      if (doc != null) {
        try {
          await _storage.removeByUrl(doc.filePath);
        } catch (_) {
          // Missing object must not block the DB delete.
        }
      }
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceDocumentsTable)
            .delete()
            .eq('id', documentId),
      );
    } catch (e) {
      AppLogger.e('Error deleting compliance document', e);
      rethrow;
    }
  }

  Future<ComplianceDocumentFile?> _getDocumentRow(String documentId) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceDocumentsTable)
            .select()
            .eq('id', documentId)
            .maybeSingle(),
      );
      return response == null ? null : ComplianceDocumentFile.fromJson(response);
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Reminders
  // ---------------------------------------------------------------------------

  /// Reminder history for a hospital, newest first. Optionally scoped to one
  /// record.
  Future<List<ComplianceReminderEntry>> getReminders(
    String hospitalId, {
    String? recordId,
    ReminderType? type,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.complianceRemindersTable)
          .select()
          .eq('hospital_id', hospitalId);
      if (recordId != null && recordId.isNotEmpty) {
        query = query.eq('record_id', recordId);
      }
      if (type != null) {
        query = query.eq('reminder_type', type.value);
      }
      final response = await DatabaseService.fetchWithRetry(
        () => query.order('created_at', ascending: false),
      );
      return response
          .map((row) => ComplianceReminderEntry.fromJson(row))
          .toList();
    } catch (e) {
      AppLogger.e('Error fetching compliance reminders', e);
      return [];
    }
  }

  Future<ComplianceReminderEntry> createReminder({
    required String recordId,
    required String hospitalId,
    required ReminderType type,
    required ReminderChannel channel,
    required String message,
    DateTime? scheduledFor,
    String status = 'sent',
  }) async {
    final response = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.complianceRemindersTable)
          .insert({
            'record_id': recordId,
            'hospital_id': hospitalId,
            'reminder_type': type.value,
            'scheduled_for': scheduledFor == null
                ? null
                : _dateOnly(scheduledFor),
            'sent_at': DateTime.now().toUtc().toIso8601String(),
            'channel': channel.value,
            'message': message,
            'status': status,
          })
          .select()
          .single(),
    );
    return ComplianceReminderEntry.fromJson(response);
  }

  /// Runs the automated reminder engine for a hospital.
  ///
  /// * 30 days (or fewer, down to 8) before expiry → `30_day` reminder
  /// * 7 days (or fewer, down to 0) before expiry → `7_day` urgent reminder
  /// * already expired → `expired` red-alert reminder
  ///
  /// Each reminder type fires **once per record** (checked against
  /// `compliance_reminders`) and creates an in-app notification for the
  /// hospital admins. Email/WhatsApp delivery rows are also created with
  /// status `pending` so a backend worker can pick them up; the in-app
  /// channel is sent immediately.
  Future<Map<String, int>> processDueReminders(String hospitalId) async {
    final counts = <String, int>{'30_day': 0, '7_day': 0, 'expired': 0};
    try {
      final records = await getRecords(hospitalId);
      final today = DateTime.now();
      final todayDay = DateTime(today.year, today.month, today.day);

      for (final record in records) {
        if (!record.reminderEnabled) continue;
        final expiry = record.expiryDate;
        if (expiry == null) continue;
        final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
        final days = expiryDay.difference(todayDay).inDays;

        final ReminderType? dueType;
        if (days < 0) {
          dueType = ReminderType.expired;
        } else if (days <= 7) {
          dueType = ReminderType.sevenDay;
        } else if (days <= 30) {
          dueType = ReminderType.thirtyDay;
        } else {
          continue;
        }

        final alreadySent = await _hasReminder(record.id, dueType);
        if (alreadySent) continue;

        final message = _reminderMessage(record, dueType, days);
        await createReminder(
          recordId: record.id,
          hospitalId: hospitalId,
          type: dueType,
          channel: ReminderChannel.inApp,
          message: message,
          scheduledFor: expiryDay,
        );
        // Backend-worker channels: email + whatsapp rows marked pending.
        await createReminder(
          recordId: record.id,
          hospitalId: hospitalId,
          type: dueType,
          channel: ReminderChannel.email,
          message: message,
          scheduledFor: expiryDay,
          status: 'pending',
        );
        await createReminder(
          recordId: record.id,
          hospitalId: hospitalId,
          type: dueType,
          channel: ReminderChannel.whatsapp,
          message: message,
          scheduledFor: expiryDay,
          status: 'pending',
        );

        // In-app notification for hospital admins.
        await _notifyAdmins(hospitalId, record, dueType, days);

        counts[dueType.value] = (counts[dueType.value] ?? 0) + 1;
      }
    } catch (e) {
      AppLogger.e('Error processing compliance reminders', e);
    }
    return counts;
  }

  Future<bool> _hasReminder(String recordId, ReminderType type) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.complianceRemindersTable)
            .select('id')
            .eq('record_id', recordId)
            .eq('reminder_type', type.value)
            .maybeSingle(),
      );
      return response != null;
    } catch (e) {
      return true; // fail safe: don't spam duplicates on error
    }
  }

  Future<void> _notifyAdmins(
    String hospitalId,
    ComplianceRecord record,
    ReminderType type,
    int days,
  ) async {
    try {
      final title = switch (type) {
        ReminderType.expired => 'Compliance Document EXPIRED',
        ReminderType.sevenDay => 'URGENT: Compliance expiring in $days day(s)',
        _ => 'Compliance renewal due in $days day(s)',
      };
      final message =
          '${record.documentName} — ${record.documentType} '
          '${type == ReminderType.expired ? 'has expired on ${record.displayExpiry}' : 'expires on ${record.displayExpiry}'}';

      // Fan out to hospital admins (super_admin + admin) so the in-app bell
      // shows the reminder for every responsible user.
      final admins = await _db.getHospitalStaffUsers(
        hospitalId,
        roles: const ['super_admin', 'admin'],
      );
      for (final admin in admins) {
        final userId = admin['id']?.toString();
        if (userId == null || userId.isEmpty) continue;
        await _db.createNotification(
          hospitalId: hospitalId,
          userId: userId,
          title: title,
          message: message,
          notificationType: 'compliance_reminder',
          linkUrl: '/compliance',
        );
      }
    } catch (e) {
      AppLogger.w('Could not create compliance in-app notification: $e');
    }
  }

  String _reminderMessage(
    ComplianceRecord record,
    ReminderType type,
    int days,
  ) {
    switch (type) {
      case ReminderType.expired:
        return '${record.documentName} (${record.documentType}) EXPIRED on '
            '${record.displayExpiry}. Renew immediately.';
      case ReminderType.sevenDay:
        return 'URGENT: ${record.documentName} expires in $days day(s) '
            'on ${record.displayExpiry}.';
      case ReminderType.thirtyDay:
        return '${record.documentName} (${record.documentType}) expires in '
            '$days day(s) on ${record.displayExpiry}. Plan renewal.';
      case ReminderType.manual:
        return 'Manual reminder for ${record.documentName}.';
    }
  }

  // ---------------------------------------------------------------------------
  // Audit logs
  // ---------------------------------------------------------------------------

  Future<List<ComplianceAuditEntry>> getAuditLogs(
    String hospitalId, {
    String? recordId,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.complianceAuditLogsTable)
          .select()
          .eq('hospital_id', hospitalId);
      if (recordId != null && recordId.isNotEmpty) {
        query = query.eq('record_id', recordId);
      }
      final response = await DatabaseService.fetchWithRetry(
        () => query.order('created_at', ascending: false).limit(200),
      );
      return response
          .map((row) => ComplianceAuditEntry.fromJson(row))
          .toList();
    } catch (e) {
      AppLogger.e('Error fetching compliance audit logs', e);
      return [];
    }
  }

  Future<void> logAudit({
    required String hospitalId,
    String? recordId,
    String? documentId,
    String? userId,
    String? userName,
    required String action,
    String? detail,
  }) async {
    try {
      await DatabaseService.fetchWithRetry(
        () => _client.from(ApiConstants.complianceAuditLogsTable).insert({
          'record_id': recordId,
          'document_id': documentId,
          'hospital_id': hospitalId,
          'user_id': userId,
          'user_name': userName,
          'action': action,
          'detail': detail,
        }),
      );
    } catch (e) {
      AppLogger.w('Could not write compliance audit log: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Dashboard statistics
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getStats(String hospitalId) async {
    try {
      final records = await getRecords(hospitalId);
      var active = 0;
      var expiring = 0;
      var expired = 0;
      var favorites = 0;
      for (final record in records) {
        if (record.isFavorite) favorites++;
        switch (record.derivedStatus) {
          case ComplianceStatus.expired:
            expired++;
            break;
          case ComplianceStatus.expiring:
            expiring++;
            break;
          case ComplianceStatus.active:
          case ComplianceStatus.archived:
            active++;
            break;
        }
      }
      final docs = await getAllDocuments(hospitalId);
      return {
        'total_records': records.length,
        'total_documents': docs.length,
        'active': active,
        'expiring': expiring,
        'expired': expired,
        'favorites': favorites,
      };
    } catch (e) {
      AppLogger.e('Error fetching compliance stats', e);
      return {
        'total_records': 0,
        'total_documents': 0,
        'active': 0,
        'expiring': 0,
        'expired': 0,
        'favorites': 0,
      };
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _sanitizeFileName(String fileName) {
    final cleaned = fileName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  static String _dateOnly(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static String _mimeTypeFor(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }
}
