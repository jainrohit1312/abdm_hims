import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../models/marketing_models.dart';
import '../services/database_service.dart';
import 'referral_doctor_repository.dart';

/// Supabase implementation of [ReferralDoctorRepository].
///
/// This is the ONLY class in the marketing module that knows the Supabase
/// referral-doctor syntax. Every query is hospital scoped. The `doctors`
/// (hospital doctors) table is never touched.
class SupabaseReferralDoctorRepository implements ReferralDoctorRepository {
  SupabaseReferralDoctorRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<ReferralDoctor>> getReferralDoctors({
    required String hospitalId,
    String? areaId,
    bool activeOnly = false,
  }) async {
    final rows = await DatabaseService.fetchWithRetry(() {
      dynamic query = _client
          .from(ApiConstants.referralDoctorsTable)
          .select('*, marketing_areas(name)')
          .eq('hospital_id', hospitalId);
      if (areaId != null && areaId.isNotEmpty) {
        query = query.eq('area_id', areaId);
      }
      if (activeOnly) {
        query = query.eq('is_active', true);
      }
      return query.order('name', ascending: true);
    });
    return rows.map(ReferralDoctor.fromJson).toList();
  }

  @override
  Future<ReferralDoctor?> getReferralDoctorById({
    required String hospitalId,
    required String id,
  }) async {
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.referralDoctorsTable)
          .select('*, marketing_areas(name)')
          .eq('id', id)
          .eq('hospital_id', hospitalId)
          .maybeSingle(),
    );
    return row == null ? null : ReferralDoctor.fromJson(row);
  }

  @override
  Future<ReferralDoctor> createReferralDoctor({
    required String hospitalId,
    required ReferralDoctor doctor,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.referralDoctorsTable)
          .insert(_doctorPayload(doctor, hospitalId: hospitalId)
            ..['created_at'] = now
            ..['updated_at'] = now)
          .select()
          .single(),
    );
    return ReferralDoctor.fromJson(row);
  }

  @override
  Future<ReferralDoctor> updateReferralDoctor({
    required String hospitalId,
    required ReferralDoctor doctor,
  }) async {
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.referralDoctorsTable)
          .update(_doctorPayload(doctor, hospitalId: hospitalId)
            ..['updated_at'] = DateTime.now().toUtc().toIso8601String())
          .eq('id', doctor.id)
          .eq('hospital_id', hospitalId)
          .select()
          .single(),
    );
    return ReferralDoctor.fromJson(row);
  }

  /// Builds the insert/update column map for a referral doctor. `id` is never
  /// included; `created_at`/`updated_at` are set by the callers above.
  Map<String, dynamic> _doctorPayload(
    ReferralDoctor doctor, {
    required String hospitalId,
  }) {
    return {
      'hospital_id': hospitalId,
      'name': doctor.name,
      'clinic_name': doctor.clinicName,
      'practitioner_type': doctor.practitionerType,
      'registration_number': doctor.registrationNumber,
      'mobile_number': doctor.mobileNumber,
      'alternate_mobile': doctor.alternateMobile,
      'area_id': doctor.areaId,
      'village': doctor.village,
      'address': doctor.address,
      'city': doctor.city,
      'pincode': doctor.pincode,
      'latitude': doctor.latitude,
      'longitude': doctor.longitude,
      'geo_radius_meters': doctor.geoRadiusMeters,
      'location_verified': doctor.locationVerified,
      'location_verified_at': doctor.locationVerifiedAt?.toIso8601String(),
      'location_verified_by': doctor.locationVerifiedBy,
      'is_active': doctor.isActive,
      'notes': doctor.notes,
    };
  }
}
