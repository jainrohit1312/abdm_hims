import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../models/whatsapp_models.dart';
import '../services/whatsapp_db_service.dart';
import '../services/whatsapp_key_cipher.dart';
import '../services/whatsapp_service.dart';
import 'providers.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Marketing Module — Riverpod Providers
/// ---------------------------------------------------------------------------
/// Kept in a separate file so the already-large `providers.dart` stays
/// focused. Screens import this file for module-specific state and
/// `app/providers.dart` for the shared auth/database services.
/// ---------------------------------------------------------------------------

/// Ticking refresh counter — increment it to force every WhatsApp provider to
/// re-fetch (used by the analytics dashboard's refresh button).
final whatsappRefreshProvider = StateProvider<int>((ref) => 0);

/// Cipher used to encrypt/decrypt the Meta access token before it touches
/// Supabase. Backed by FlutterSecureStorage.
final whatsappKeyCipherProvider = Provider<WhatsappKeyCipher>((ref) {
  return WhatsappKeyCipher(AppConfig.secureStorage);
});

/// Database operations for the module.
final whatsappDbServiceProvider = Provider<WhatsappDbService>((ref) {
  return WhatsappDbService(
    ref.watch(supabaseClientProvider),
    ref.watch(whatsappKeyCipherProvider),
  );
});

/// Meta WhatsApp Cloud API client.
final whatsappServiceProvider = Provider<WhatsappService>((ref) {
  return WhatsappService();
});

// ---------------------------------------------------------------------------
// Data providers (family by hospital id / campaign id)
// ---------------------------------------------------------------------------

/// Hospital's WhatsApp settings (Meta API key, phone number id, ...).
final whatsappSettingsProvider =
    FutureProvider.family<WhatsappSettings?, String>((ref, hospitalId) async {
      ref.watch(whatsappRefreshProvider);
      return ref.read(whatsappDbServiceProvider).getSettings(hospitalId);
    });

/// Local WhatsApp templates for a hospital.
final whatsappTemplatesProvider =
    FutureProvider.family<List<WhatsappTemplate>, String>((ref, hospitalId) {
      ref.watch(whatsappRefreshProvider);
      return ref
          .read(whatsappDbServiceProvider)
          .getTemplates(hospitalId, activeOnly: false);
    });

/// Broadcast campaigns for a hospital (newest first).
final whatsappCampaignsProvider =
    FutureProvider.family<List<WhatsappCampaign>, String>((ref, hospitalId) {
      ref.watch(whatsappRefreshProvider);
      return ref.read(whatsappDbServiceProvider).getCampaigns(hospitalId);
    });

/// Message log for one campaign (newest first).
final whatsappCampaignMessagesProvider =
    FutureProvider.family<List<WhatsappMessage>, String>((ref, campaignId) {
      ref.watch(whatsappRefreshProvider);
      final hospitalId = ref.watch(authStateProvider).hospitalId ?? '';
      return ref
          .read(whatsappDbServiceProvider)
          .getMessages(hospitalId, campaignId: campaignId, limit: 200);
    });

/// All opt-out records for a hospital.
final whatsappOptOutsProvider =
    FutureProvider.family<List<WhatsappOptOut>, String>((ref, hospitalId) {
      ref.watch(whatsappRefreshProvider);
      return ref.read(whatsappDbServiceProvider).getOptOuts(hospitalId);
    });

/// Opt-in patient audience (OPD + IPD + patient master, deduped, excluding
/// opt-outs).
final whatsappAudienceProvider =
    FutureProvider.family<List<WhatsappRecipient>, String>((ref, hospitalId) {
      ref.watch(whatsappRefreshProvider);
      return ref.read(whatsappDbServiceProvider).getAudience(hospitalId);
    });

/// Dashboard analytics.
final whatsappAnalyticsProvider =
    FutureProvider.family<WhatsappAnalytics, String>((ref, hospitalId) {
      ref.watch(whatsappRefreshProvider);
      return ref.read(whatsappDbServiceProvider).getAnalytics(hospitalId);
    });

/// Equality-safe parameters for the per-patient opt-in provider.
class WhatsappPatientOptInParams {
  final String hospitalId;
  final String patientId;
  final String phoneNumber;

  const WhatsappPatientOptInParams({
    required this.hospitalId,
    required this.patientId,
    required this.phoneNumber,
  });

  @override
  bool operator ==(Object other) =>
      other is WhatsappPatientOptInParams &&
      other.hospitalId == hospitalId &&
      other.patientId == patientId &&
      other.phoneNumber == phoneNumber;

  @override
  int get hashCode => Object.hash(hospitalId, patientId, phoneNumber);
}

/// True when the patient is opted out of WhatsApp marketing.
final whatsappPatientOptOutProvider =
    FutureProvider.family<bool, WhatsappPatientOptInParams>((
      ref,
      params,
    ) async {
      ref.watch(whatsappRefreshProvider);
      return ref
          .read(whatsappDbServiceProvider)
          .isPatientOptedOut(params.hospitalId, params.patientId);
    });

/// Convenience: refreshes every module provider. Every WhatsApp FutureProvider
/// watches [whatsappRefreshProvider], so invalidating that single tick is
/// enough to force all open screens to re-fetch (no double work).
void invalidateWhatsappProviders(WidgetRef ref, {String? hospitalId}) {
  ref.invalidate(whatsappRefreshProvider);
}
