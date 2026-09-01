import '../models/marketing_models.dart';

/// Focused persistence contract for the REFERRAL DOCTOR master.
///
/// Referral doctors are a completely separate domain from hospital doctors.
/// This repository never touches the `doctors` table.
///
/// ISP: referral-doctor CRUD only. Analytics/geofence logic does NOT belong
/// here (see MarketingAnalyticsService / GeoFenceService).
abstract class ReferralDoctorRepository {
  Future<List<ReferralDoctor>> getReferralDoctors({
    required String hospitalId,
    String? areaId,
    bool activeOnly = false,
  });

  Future<ReferralDoctor?> getReferralDoctorById({
    required String hospitalId,
    required String id,
  });

  Future<ReferralDoctor> createReferralDoctor({
    required String hospitalId,
    required ReferralDoctor doctor,
  });

  Future<ReferralDoctor> updateReferralDoctor({
    required String hospitalId,
    required ReferralDoctor doctor,
  });
}
