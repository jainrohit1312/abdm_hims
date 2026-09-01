import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../models/marketing_models.dart';
import '../services/database_service.dart';
import 'marketing_visit_repository.dart';

/// Supabase implementation of [MarketingVisitRepository].
///
/// This is the ONLY class in the marketing module that knows the Supabase
/// visit syntax. Every query is hospital scoped. There is intentionally NO
/// live-location/streaming query here — only range fetches and one insert.
class SupabaseMarketingVisitRepository implements MarketingVisitRepository {
  SupabaseMarketingVisitRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<MarketingVisit>> getVisitsForRange({
    required String hospitalId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingVisitsTable)
          .select()
          .eq('hospital_id', hospitalId)
          .gte('visited_at', from.toUtc().toIso8601String())
          .lt('visited_at', to.toUtc().toIso8601String())
          .order('visited_at', ascending: false),
    );
    return rows.map(MarketingVisit.fromJson).toList();
  }

  @override
  Future<List<MarketingVisit>> getVisitsForDoctorRange({
    required String hospitalId,
    required String doctorId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingVisitsTable)
          .select()
          .eq('hospital_id', hospitalId)
          .eq('referral_doctor_id', doctorId)
          .gte('visited_at', from.toUtc().toIso8601String())
          .lt('visited_at', to.toUtc().toIso8601String())
          .order('visited_at', ascending: false),
    );
    return rows.map(MarketingVisit.fromJson).toList();
  }

  @override
  Future<int> countVisitsForDoctor({
    required String hospitalId,
    required String doctorId,
  }) async {
    final response = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingVisitsTable)
          .select('id')
          .eq('hospital_id', hospitalId)
          .eq('referral_doctor_id', doctorId)
          .count(CountOption.exact),
    );
    return response.count;
  }

  @override
  Future<MarketingVisit> createVisit({
    required String hospitalId,
    required MarketingVisit visit,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingVisitsTable)
          .insert(_visitPayload(visit, hospitalId: hospitalId)
            ..['created_at'] = now
            ..['updated_at'] = now)
          .select()
          .single(),
    );
    return MarketingVisit.fromJson(row);
  }

  Map<String, dynamic> _visitPayload(
    MarketingVisit visit, {
    required String hospitalId,
  }) {
    return {
      'hospital_id': hospitalId,
      'marketing_employee_id': visit.marketingEmployeeId,
      'referral_doctor_id': visit.referralDoctorId,
      'area_id': visit.areaId,
      'visited_at': visit.visitedAt.toUtc().toIso8601String(),
      'latitude': visit.latitude,
      'longitude': visit.longitude,
      'distance_from_doctor_meters': visit.distanceFromDoctorMeters,
      'geofence_radius_meters': visit.geofenceRadiusMeters,
      'geo_verified': visit.geoVerified,
      'visit_source': visit.visitSource,
      'visit_purpose': visit.visitPurpose,
      'visit_notes': visit.visitNotes,
      'next_follow_up_date': visit.nextFollowUpDate == null
          ? null
          : _dateOnly(visit.nextFollowUpDate!),
    };
  }

  String _dateOnly(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
