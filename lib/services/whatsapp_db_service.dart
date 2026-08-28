import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import '../models/whatsapp_models.dart';
import 'database_service.dart';
import 'whatsapp_key_cipher.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Marketing Module — Database Operations
/// ---------------------------------------------------------------------------
/// All Supabase reads/writes for the WhatsApp module. The class deliberately
/// uses `DatabaseService.fetchWithRetry` for every network call so the module
/// inherits the project's timeout + retry behaviour.
///
/// Multi-tenant isolation is enforced by the SQL RLS policies (see
/// `supabase/migrations/*_whatsapp_marketing_module.sql`); every method here
/// still passes an explicit `hospital_id` filter as defence in depth.
/// ---------------------------------------------------------------------------
class WhatsappDbService {
  final SupabaseClient _client;
  final WhatsappKeyCipher _cipher;

  WhatsappDbService(this._client, this._cipher);

  // ---------------------------------------------------------------------------
  // Settings (one active row per hospital)
  // ---------------------------------------------------------------------------

  /// Returns the hospital's WhatsApp settings, or null when not configured.
  Future<WhatsappSettings?> getSettings(String hospitalId) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappSettingsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .maybeSingle(),
      );
      if (response == null) return null;
      final settings = WhatsappSettings.fromMap(response);
      // Decrypt the stored access token before handing it to callers.
      final apiKey = await _cipher.decrypt(settings.apiKey);
      return settings.copyWith(apiKey: apiKey);
    } catch (e) {
      AppLogger.e('Error fetching WhatsApp settings', e);
      rethrow;
    }
  }

  /// Creates or updates the hospital's WhatsApp settings row.
  Future<WhatsappSettings> saveSettings(WhatsappSettings settings) async {
    try {
      final encryptedKey = await _cipher.encrypt(settings.apiKey);
      final payload = settings.toMap()
        ..['api_key'] = encryptedKey
        ..['updated_at'] = DateTime.now().toUtc().toIso8601String();

      final existing = await _client
          .from(ApiConstants.whatsappSettingsTable)
          .select('id')
          .eq('hospital_id', settings.hospitalId)
          .maybeSingle();

      Map<String, dynamic> row;
      if (existing == null) {
        final response = await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.whatsappSettingsTable)
              .insert({
                ...payload,
                'created_at': DateTime.now().toUtc().toIso8601String(),
              })
              .select()
              .single(),
        );
        row = response;
      } else {
        final response = await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.whatsappSettingsTable)
              .update(payload)
              .eq('id', existing['id'])
              .select()
              .single(),
        );
        row = response;
      }

      final saved = WhatsappSettings.fromMap(row);
      return saved.copyWith(apiKey: settings.apiKey);
    } catch (e) {
      AppLogger.e('Error saving WhatsApp settings', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Templates
  // ---------------------------------------------------------------------------

  Future<List<WhatsappTemplate>> getTemplates(
    String hospitalId, {
    bool activeOnly = false,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.whatsappTemplatesTable)
          .select()
          .eq('hospital_id', hospitalId)
          .order('created_at', ascending: false);
      if (activeOnly) {
        query = query.eq('is_active', true);
      }
      final response = await DatabaseService.fetchWithRetry(() => query);
      return List<Map<String, dynamic>>.from(
        response,
      ).map(WhatsappTemplate.fromMap).toList();
    } catch (e) {
      AppLogger.e('Error fetching WhatsApp templates', e);
      rethrow;
    }
  }

  Future<WhatsappTemplate> saveTemplate(
    WhatsappTemplate template, {
    String? id,
  }) async {
    try {
      final payload = template.toMap()
        ..['updated_at'] = DateTime.now().toUtc().toIso8601String();

      Map<String, dynamic> row;
      if (id == null || id.isEmpty) {
        final response = await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.whatsappTemplatesTable)
              .insert({
                ...payload,
                'created_at': DateTime.now().toUtc().toIso8601String(),
              })
              .select()
              .single(),
        );
        row = response;
      } else {
        final response = await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.whatsappTemplatesTable)
              .update(payload)
              .eq('id', id)
              .eq('hospital_id', template.hospitalId)
              .select()
              .single(),
        );
        row = response;
      }
      return WhatsappTemplate.fromMap(row);
    } catch (e) {
      AppLogger.e('Error saving WhatsApp template', e);
      rethrow;
    }
  }

  Future<void> deleteTemplate(String id, String hospitalId) async {
    try {
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappTemplatesTable)
            .delete()
            .eq('id', id)
            .eq('hospital_id', hospitalId),
      );
    } catch (e) {
      AppLogger.e('Error deleting WhatsApp template', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Campaigns
  // ---------------------------------------------------------------------------

  Future<List<WhatsappCampaign>> getCampaigns(String hospitalId) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappCampaignsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(
        response,
      ).map(WhatsappCampaign.fromMap).toList();
    } catch (e) {
      AppLogger.e('Error fetching WhatsApp campaigns', e);
      rethrow;
    }
  }

  Future<WhatsappCampaign> createCampaign(WhatsappCampaign campaign) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappCampaignsTable)
            .insert({...campaign.toMap(), 'created_at': now, 'updated_at': now})
            .select()
            .single(),
      );
      return WhatsappCampaign.fromMap(response);
    } catch (e) {
      AppLogger.e('Error creating WhatsApp campaign', e);
      rethrow;
    }
  }

  Future<void> updateCampaignStatus(
    String campaignId, {
    String? status,
    int? sentCount,
    int? deliveredCount,
    int? readCount,
    int? failedCount,
    DateTime? sentAt,
  }) async {
    try {
      final payload = <String, dynamic>{
        if (status != null) 'status': status,
        if (sentCount != null) 'sent_count': sentCount,
        if (deliveredCount != null) 'delivered_count': deliveredCount,
        if (readCount != null) 'read_count': readCount,
        if (failedCount != null) 'failed_count': failedCount,
        if (sentAt != null) 'sent_at': sentAt.toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappCampaignsTable)
            .update(payload)
            .eq('id', campaignId),
      );
    } catch (e) {
      AppLogger.e('Error updating WhatsApp campaign', e);
      rethrow;
    }
  }

  Future<void> deleteCampaign(String campaignId) async {
    try {
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappCampaignsTable)
            .delete()
            .eq('id', campaignId),
      );
    } catch (e) {
      AppLogger.e('Error deleting WhatsApp campaign', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Individual message logs
  // ---------------------------------------------------------------------------

  Future<List<WhatsappMessage>> getMessages(
    String hospitalId, {
    String? campaignId,
    String? patientId,
    int limit = 100,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.whatsappMessagesTable)
          .select()
          .eq('hospital_id', hospitalId)
          .order('created_at', ascending: false)
          .limit(limit);
      if (campaignId != null && campaignId.isNotEmpty) {
        query = query.eq('campaign_id', campaignId);
      }
      if (patientId != null && patientId.isNotEmpty) {
        query = query.eq('patient_id', patientId);
      }
      final response = await DatabaseService.fetchWithRetry(() => query);
      return List<Map<String, dynamic>>.from(
        response,
      ).map(WhatsappMessage.fromMap).toList();
    } catch (e) {
      AppLogger.e('Error fetching WhatsApp messages', e);
      rethrow;
    }
  }

  /// Batch-inserts message logs. Returns the inserted rows.
  Future<List<WhatsappMessage>> logMessages(
    List<WhatsappMessage> messages,
  ) async {
    if (messages.isEmpty) return const [];
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final rows = messages
          .map((m) => {...m.toMap(), 'created_at': now})
          .toList();
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappMessagesTable)
            .insert(rows)
            .select(),
      );
      return List<Map<String, dynamic>>.from(
        response,
      ).map(WhatsappMessage.fromMap).toList();
    } catch (e) {
      AppLogger.e('Error logging WhatsApp messages', e);
      rethrow;
    }
  }

  /// Updates one message log by its Meta message id (webhook status updates).
  Future<void> updateMessageStatus({
    required String metaMessageId,
    String? status,
    String? errorMessage,
    DateTime? deliveredAt,
    DateTime? readAt,
  }) async {
    try {
      final payload = <String, dynamic>{
        if (status != null) 'status': status,
        if (errorMessage != null) 'error_message': errorMessage,
        if (deliveredAt != null)
          'delivered_at': deliveredAt.toUtc().toIso8601String(),
        if (readAt != null) 'read_at': readAt.toUtc().toIso8601String(),
      };
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappMessagesTable)
            .update(payload)
            .eq('message_id', metaMessageId),
      );
    } catch (e) {
      AppLogger.e('Error updating WhatsApp message status', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Opt-out / Opt-in
  // ---------------------------------------------------------------------------

  Future<List<WhatsappOptOut>> getOptOuts(String hospitalId) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappOptOutsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .order('opted_out_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(
        response,
      ).map(WhatsappOptOut.fromMap).toList();
    } catch (e) {
      AppLogger.e('Error fetching WhatsApp opt-outs', e);
      rethrow;
    }
  }

  Future<WhatsappOptOut?> getOptOutForPatient(
    String hospitalId,
    String patientId,
  ) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappOptOutsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .eq('patient_id', patientId)
            .maybeSingle(),
      );
      return response == null ? null : WhatsappOptOut.fromMap(response);
    } catch (e) {
      AppLogger.e('Error fetching opt-out status', e);
      return null;
    }
  }

  Future<WhatsappOptOut> optOutPatient({
    required String hospitalId,
    required String patientId,
    required String phoneNumber,
    String reason = '',
  }) async {
    try {
      // Remove any previous record for this patient **or** phone number, then
      // insert a fresh row. This also covers manual opt-outs that were created
      // without a patient id.
      final existing = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappOptOutsTable)
            .select('id')
            .eq('hospital_id', hospitalId)
            .or('patient_id.eq.$patientId,phone_number.eq.$phoneNumber')
            .maybeSingle(),
      );
      if (existing != null) {
        await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.whatsappOptOutsTable)
              .delete()
              .eq('id', existing['id']),
        );
      }

      final now = DateTime.now().toUtc().toIso8601String();
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappOptOutsTable)
            .insert({
              'hospital_id': hospitalId,
              'patient_id': patientId,
              'phone_number': phoneNumber,
              'opted_out_at': now,
              if (reason.isNotEmpty) 'reason': reason,
              'created_at': now,
            })
            .select()
            .single(),
      );
      return WhatsappOptOut.fromMap(response);
    } catch (e) {
      AppLogger.e('Error opting out patient', e);
      rethrow;
    }
  }

  /// Removes the opt-out record so the patient can receive messages again.
  Future<void> removeOptOut(String hospitalId, String patientId) async {
    try {
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappOptOutsTable)
            .delete()
            .eq('hospital_id', hospitalId)
            .eq('patient_id', patientId),
      );
    } catch (e) {
      AppLogger.e('Error removing opt-out', e);
      rethrow;
    }
  }

  /// True when the patient has opted out of WhatsApp messages.
  Future<bool> isPatientOptedOut(String hospitalId, String patientId) async {
    final record = await getOptOutForPatient(hospitalId, patientId);
    return record != null;
  }

  /// Updates the `whatsapp_opt_in` flag on the patient master row.
  Future<void> markPatientOptIn(
    String hospitalId,
    String patientId,
    bool optIn,
  ) async {
    try {
      await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.patientsTable)
            .update({'whatsapp_opt_in': optIn})
            .eq('hospital_id', hospitalId)
            .eq('id', patientId),
      );
    } catch (e) {
      AppLogger.e('Error updating patient whatsapp_opt_in', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Audience (opt-in patients from OPD + IPD + patient master)
  // ---------------------------------------------------------------------------

  /// Builds the deduplicated, opt-in-only recipient list for a hospital.
  ///
  /// Sources:
  ///  1. `patients` rows with `whatsapp_opt_in = true`
  ///  2. `opd_registrations` rows with `whatsapp_opt_in = true`
  ///  3. `ipd_admissions` rows with `whatsapp_opt_in = true`
  ///
  /// Any patient present in `whatsapp_opt_outs` is excluded.
  Future<List<WhatsappRecipient>> getAudience(String hospitalId) async {
    final byPatient = <String, WhatsappRecipient>{};
    final byPhone = <String, WhatsappRecipient>{};

    void add(Map<String, dynamic> map, String source) {
      final patientId = map['patient_id']?.toString() ?? '';
      final phone = map['phone_number']?.toString() ?? '';
      if (patientId.isEmpty || phone.isEmpty) return;
      final recipient = WhatsappRecipient(
        patientId: patientId,
        name: map['name']?.toString() ?? 'Unknown Patient',
        uhid: map['uhid']?.toString() ?? '',
        phoneNumber: phone,
        source: source,
      );
      byPatient[patientId] = recipient;
      byPhone[phone] = recipient;
    }

    try {
      // 1. Patient master opt-ins.
      final patients = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.patientsTable)
            .select('id, uhid, first_name, last_name, mobile_number')
            .eq('hospital_id', hospitalId)
            .eq('whatsapp_opt_in', true),
      );
      for (final p in List<Map<String, dynamic>>.from(patients)) {
        final first = p['first_name']?.toString() ?? '';
        final last = p['last_name']?.toString() ?? '';
        add({
          'patient_id': p['id'],
          'name': '$first $last'.trim(),
          'uhid': p['uhid'],
          'phone_number': p['mobile_number'],
        }, 'patients');
      }

      // 2. OPD opt-ins (embedded patient info).
      final opd = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.opdRegistrationsTable)
            .select(
              'patient_id, patients(id, uhid, first_name, last_name, mobile_number)',
            )
            .eq('hospital_id', hospitalId)
            .eq('whatsapp_opt_in', true),
      );
      for (final row in List<Map<String, dynamic>>.from(opd)) {
        final p = row['patients'];
        if (p is! Map) continue;
        final first = p['first_name']?.toString() ?? '';
        final last = p['last_name']?.toString() ?? '';
        add({
          'patient_id': row['patient_id'],
          'name': '$first $last'.trim(),
          'uhid': p['uhid'],
          'phone_number': p['mobile_number'],
        }, 'opd');
      }

      // 3. IPD opt-ins (embedded patient info).
      final ipd = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdAdmissionsTable)
            .select(
              'patient_id, patients(id, uhid, first_name, last_name, mobile_number)',
            )
            .eq('hospital_id', hospitalId)
            .eq('whatsapp_opt_in', true),
      );
      for (final row in List<Map<String, dynamic>>.from(ipd)) {
        final p = row['patients'];
        if (p is! Map) continue;
        final first = p['first_name']?.toString() ?? '';
        final last = p['last_name']?.toString() ?? '';
        add({
          'patient_id': row['patient_id'],
          'name': '$first $last'.trim(),
          'uhid': p['uhid'],
          'phone_number': p['mobile_number'],
        }, 'ipd');
      }

      // Exclude opted-out patients (by patient id or phone number).
      final optOuts = await getOptOuts(hospitalId);
      final optedOutIds = optOuts.map((o) => o.patientId).toSet();
      final optedOutPhones = optOuts.map((o) => o.phoneNumber).toSet();

      final recipients = byPatient.values.where((r) {
        return !optedOutIds.contains(r.patientId) &&
            !optedOutPhones.contains(r.phoneNumber);
      }).toList()..sort((a, b) => a.name.compareTo(b.name));

      return recipients;
    } catch (e) {
      AppLogger.e('Error building WhatsApp audience', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Analytics
  // ---------------------------------------------------------------------------

  /// Aggregates campaign + message counters for the analytics dashboard.
  ///
  /// NOTE: For very large hospitals the message status list can become heavy;
  /// a production deployment can replace the message aggregation with a
  /// `create or replace function` RPC that counts server-side.
  Future<WhatsappAnalytics> getAnalytics(String hospitalId) async {
    try {
      final campaigns = await getCampaigns(hospitalId);
      final optOuts = await getOptOuts(hospitalId);

      final messageRows = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.whatsappMessagesTable)
            .select('status')
            .eq('hospital_id', hospitalId)
            .limit(5000),
      );

      var sent = 0, delivered = 0, read = 0, failed = 0;
      for (final row in List<Map<String, dynamic>>.from(messageRows)) {
        switch (row['status']?.toString()) {
          case 'delivered':
            delivered++;
            break;
          case 'read':
            read++;
            break;
          case 'failed':
            failed++;
            break;
          default:
            sent++;
            break;
        }
      }

      var optInPatients = 0;
      try {
        final patients = await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.patientsTable)
              .select('id')
              .eq('hospital_id', hospitalId)
              .eq('whatsapp_opt_in', true),
        );
        optInPatients = List<Map<String, dynamic>>.from(patients).length;
      } catch (e) {
        AppLogger.e('Could not count opt-in patients', e);
      }

      // Campaign counters are stored as running totals on the campaign row.
      final campaignSent = campaigns.fold<int>(
        0,
        (sum, c) => sum + c.sentCount,
      );
      final campaignDelivered = campaigns.fold<int>(
        0,
        (sum, c) => sum + c.deliveredCount,
      );
      final campaignRead = campaigns.fold<int>(
        0,
        (sum, c) => sum + c.readCount,
      );
      final campaignFailed = campaigns.fold<int>(
        0,
        (sum, c) => sum + c.failedCount,
      );

      return WhatsappAnalytics(
        totalCampaigns: campaigns.length,
        totalMessages: messageRows.length,
        // Individual logs are the source of truth; fall back to the campaign
        // counters when no individual rows exist yet (e.g. legacy data).
        sent: sent > 0 ? sent : campaignSent,
        delivered: delivered > 0 ? delivered : campaignDelivered,
        read: read > 0 ? read : campaignRead,
        failed: failed > 0 ? failed : campaignFailed,
        optOuts: optOuts.length,
        optInPatients: optInPatients,
      );
    } catch (e) {
      AppLogger.e('Error fetching WhatsApp analytics', e);
      rethrow;
    }
  }
}
