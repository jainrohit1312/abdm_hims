import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../models/marketing_models.dart';
import '../services/database_service.dart';
import 'marketing_area_repository.dart';

/// Supabase implementation of [MarketingAreaRepository].
///
/// This is the ONLY class in the marketing module that knows the Supabase
/// area syntax (table name, row mapping). Every query is hospital scoped.
class SupabaseMarketingAreaRepository implements MarketingAreaRepository {
  SupabaseMarketingAreaRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<MarketingArea>> getAreas({required String hospitalId}) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingAreasTable)
          .select()
          .eq('hospital_id', hospitalId)
          .order('name', ascending: true),
    );
    return rows.map(MarketingArea.fromJson).toList();
  }

  @override
  Future<MarketingArea?> getAreaById({
    required String hospitalId,
    required String id,
  }) async {
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingAreasTable)
          .select()
          .eq('id', id)
          .eq('hospital_id', hospitalId)
          .maybeSingle(),
    );
    return row == null ? null : MarketingArea.fromJson(row);
  }

  @override
  Future<MarketingArea> createArea({
    required String hospitalId,
    required MarketingArea area,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingAreasTable)
          .insert(_areaPayload(area, hospitalId: hospitalId)
            ..['created_at'] = now
            ..['updated_at'] = now)
          .select()
          .single(),
    );
    return MarketingArea.fromJson(row);
  }

  @override
  Future<MarketingArea> updateArea({
    required String hospitalId,
    required MarketingArea area,
  }) async {
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.marketingAreasTable)
          .update(_areaPayload(area, hospitalId: hospitalId)
            ..['updated_at'] = DateTime.now().toUtc().toIso8601String())
          .eq('id', area.id)
          .eq('hospital_id', hospitalId)
          .select()
          .single(),
    );
    return MarketingArea.fromJson(row);
  }

  Map<String, dynamic> _areaPayload(
    MarketingArea area, {
    required String hospitalId,
  }) {
    return {
      'hospital_id': hospitalId,
      'name': area.name,
      'code': area.code,
      'description': area.description,
      'is_active': area.isActive,
    };
  }
}
