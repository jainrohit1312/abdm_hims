import '../models/marketing_models.dart';

/// Focused persistence contract for marketing visit punches.
///
/// A visit punch stores the employee's location ONCE (at punch time). There
/// are no continuous-tracking queries or tables in this interface.
///
/// ISP: visit-punch queries/creation only.
abstract class MarketingVisitRepository {
  /// Visits in `[from, to)` — `to` is exclusive. Newest first.
  Future<List<MarketingVisit>> getVisitsForRange({
    required String hospitalId,
    required DateTime from,
    required DateTime to,
  });

  /// Visits for one referral doctor in `[from, to)`, newest first. Used by the
  /// doctor detail screen so a bounded window can be loaded without N+1.
  Future<List<MarketingVisit>> getVisitsForDoctorRange({
    required String hospitalId,
    required String doctorId,
    required DateTime from,
    required DateTime to,
  });

  /// Lifetime visit count for one referral doctor (single count query).
  Future<int> countVisitsForDoctor({
    required String hospitalId,
    required String doctorId,
  });

  Future<MarketingVisit> createVisit({
    required String hospitalId,
    required MarketingVisit visit,
  });
}
