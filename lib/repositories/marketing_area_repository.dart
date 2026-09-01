import '../models/marketing_models.dart';

/// Focused persistence contract for marketing areas.
///
/// Implementations must obey the same contract (LSP): the same inputs always
/// produce the same shape of result and failures surface as
/// [MarketingRepositoryException], never as raw Supabase errors.
///
/// ISP: this interface covers marketing-area CRUD only. Referral doctors,
/// visits and patient referrals each have their own interface.
abstract class MarketingAreaRepository {
  Future<List<MarketingArea>> getAreas({required String hospitalId});

  Future<MarketingArea?> getAreaById({
    required String hospitalId,
    required String id,
  });

  Future<MarketingArea> createArea({
    required String hospitalId,
    required MarketingArea area,
  });

  Future<MarketingArea> updateArea({
    required String hospitalId,
    required MarketingArea area,
  });
}

/// Base exception for marketing persistence failures.
class MarketingRepositoryException implements Exception {
  const MarketingRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}
