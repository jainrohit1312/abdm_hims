import '../models/marketing_models.dart';

/// ---------------------------------------------------------------------------
/// Pure marketing analytics service.
///
/// Input:
///   * Referral Doctors
///   * Marketing Visits
///   * Patient Referrals
///   * (optional) Marketing Areas — when provided, zero-activity areas are
///     included in area-wise summaries with zero counts.
///
/// Output: dashboard summaries, area summaries and referral-doctor summaries.
///
/// NO Supabase queries happen inside this service. Providers fetch the three
/// lists once (never N+1 per doctor) and this class aggregates them in memory.
/// ---------------------------------------------------------------------------
class MarketingAnalyticsService {
  const MarketingAnalyticsService();

  MarketingDashboardSummary buildDashboard({
    required List<ReferralDoctor> doctors,
    required List<MarketingVisit> visits,
    required List<PatientReferral> referrals,
    List<MarketingArea> areas = const [],
    required DateTime now,
  }) {
    final day = DateTime(now.year, now.month, now.day);
    final tomorrow = day.add(const Duration(days: 1));

    final todayVisits = visits.where((v) => _inRange(v.visitedAt, day, tomorrow));
    final todayReferrals = referrals
        .where((r) => _inRange(r.referralDate, day, tomorrow))
        .toList();
    final monthReferrals =
        referrals.where((r) => _inMonth(r.referralDate, now)).toList();

    final today = todayVisits.toList();
    final doctorIdsVisitedToday = today
        .map((v) => v.referralDoctorId)
        .where((id) => id.isNotEmpty)
        .toSet();

    final doctorSummaries = referralDoctorSummaries(
      doctors: doctors,
      visits: visits,
      referrals: referrals,
      now: now,
    );

    final topDoctors = [...doctorSummaries]
      ..sort((a, b) {
        if (b.visitsThisMonth != a.visitsThisMonth) {
          return b.visitsThisMonth.compareTo(a.visitsThisMonth);
        }
        return b.totalReferrals.compareTo(a.totalReferrals);
      });

    final recentVisits = [...todayVisits]..sort(
        (a, b) => b.visitedAt.compareTo(a.visitedAt),
      );

    return MarketingDashboardSummary(
      todayVisits: today.length,
      geoVerifiedVisitsToday: today.where((v) => v.geoVerified).length,
      referralDoctorsVisitedToday: doctorIdsVisitedToday.length,
      referralsToday: todayReferrals.length,
      referralsThisMonth: monthReferrals.length,
      areaActivity: areaSummaries(
        doctors: doctors,
        visits: visits,
        referrals: referrals,
        areas: areas,
        now: now,
      ),
      topReferralDoctorsThisMonth: topDoctors.take(5).toList(),
      recentVisits: recentVisits.take(8).toList(),
    );
  }

  /// Area-wise activity: referral-doctor count, visited today, visited this
  /// month and patient referrals this month.
  List<AreaActivitySummary> areaSummaries({
    required List<ReferralDoctor> doctors,
    required List<MarketingVisit> visits,
    required List<PatientReferral> referrals,
    List<MarketingArea> areas = const [],
    required DateTime now,
  }) {
    final doctorsById = {for (final d in doctors) d.id: d};
    final day = DateTime(now.year, now.month, now.day);
    final tomorrow = day.add(const Duration(days: 1));

    final doctorsByArea = <String, List<ReferralDoctor>>{};
    for (final doctor in doctors) {
      final areaId = doctor.areaId ?? '';
      (doctorsByArea[areaId] ??= []).add(doctor);
    }

    final visitsTodayByArea = <String, int>{};
    final visitsMonthByArea = <String, int>{};
    for (final visit in visits) {
      final areaId = _visitAreaId(visit, doctorsById);
      if (_inRange(visit.visitedAt, day, tomorrow)) {
        visitsTodayByArea[areaId] = (visitsTodayByArea[areaId] ?? 0) + 1;
      }
      if (_inMonth(visit.visitedAt, now)) {
        visitsMonthByArea[areaId] = (visitsMonthByArea[areaId] ?? 0) + 1;
      }
    }

    final referralsMonthByArea = <String, int>{};
    for (final referral in referrals) {
      if (!_inMonth(referral.referralDate, now)) continue;
      final areaId = doctorsById[referral.referralDoctorId]?.areaId ?? '';
      referralsMonthByArea[areaId] =
          (referralsMonthByArea[areaId] ?? 0) + 1;
    }

    // Preserve a deterministic order: areas list first (when provided), then
    // any area ids discovered from doctors.
    final areaIds = {
      for (final area in areas) area.id,
      ...doctorsByArea.keys,
    }.toList();

    String areaNameFor(String areaId) {
      for (final area in areas) {
        if (area.id == areaId) return area.name;
      }
      final doctorsInArea = doctorsByArea[areaId] ?? const <ReferralDoctor>[];
      for (final doctor in doctorsInArea) {
        final name = doctor.areaName;
        if (name != null && name.isNotEmpty) return name;
      }
      return areaId;
    }

    return [
      for (final areaId in areaIds)
        AreaActivitySummary(
          areaId: areaId,
          areaName: areaNameFor(areaId),
          referralDoctorCount: doctorsByArea[areaId]?.length ?? 0,
          visitedToday: visitsTodayByArea[areaId] ?? 0,
          visitedThisMonth: visitsMonthByArea[areaId] ?? 0,
          referralsThisMonth: referralsMonthByArea[areaId] ?? 0,
        ),
    ];
  }

  /// Referral-doctor wise aggregation (window = whatever visits/referrals the
  /// provider passed in; the dashboard/area views pass the current month, the
  /// doctor-detail screen passes a bounded recent window).
  List<ReferralDoctorSummary> referralDoctorSummaries({
    required List<ReferralDoctor> doctors,
    required List<MarketingVisit> visits,
    required List<PatientReferral> referrals,
    required DateTime now,
  }) {
    final summaries = <ReferralDoctorSummary>[];

    for (final doctor in doctors) {
      final doctorVisits = visits
          .where((v) => v.referralDoctorId == doctor.id)
          .toList();
      final doctorReferrals = referrals
          .where((r) => r.referralDoctorId == doctor.id)
          .toList();

      DateTime? lastVisit;
      for (final visit in doctorVisits) {
        if (lastVisit == null || visit.visitedAt.isAfter(lastVisit)) {
          lastVisit = visit.visitedAt;
        }
      }

      summaries.add(
        ReferralDoctorSummary(
          referralDoctorId: doctor.id,
          referralDoctorName: doctor.name,
          clinicName: doctor.clinicName,
          areaId: doctor.areaId,
          areaName: doctor.areaName,
          totalVisits: doctorVisits.length,
          lastVisit: lastVisit,
          visitsThisMonth: doctorVisits
              .where((v) => _inMonth(v.visitedAt, now))
              .length,
          totalReferrals: doctorReferrals.length,
          referralsThisMonth: doctorReferrals
              .where((r) => _inMonth(r.referralDate, now))
              .length,
          locationVerified: doctor.locationVerified,
        ),
      );
    }

    return summaries;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _visitAreaId(
    MarketingVisit visit,
    Map<String, ReferralDoctor> doctorsById,
  ) {
    final direct = visit.areaId;
    if (direct != null && direct.isNotEmpty) return direct;
    return doctorsById[visit.referralDoctorId]?.areaId ?? '';
  }

  bool _inMonth(DateTime? date, DateTime now) {
    if (date == null) return false;
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    return _inRange(date, monthStart, nextMonth);
  }

  bool _inRange(DateTime? date, DateTime from, DateTime to) {
    if (date == null) return false;
    return !date.isBefore(from) && date.isBefore(to);
  }
}
