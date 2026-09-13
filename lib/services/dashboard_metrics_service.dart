import 'package:flutter/foundation.dart';

import '../core/utils/logger.dart';
import 'database_service.dart';
import 'local_db.dart';

/// How trustworthy one dashboard metric is right now.
///
/// A failed query is never rendered as `0`: [MetricStatus.unavailable] means no
/// reliable value exists, and [MetricStatus.stale] means a previously computed
/// value is being shown with the "as of" time it was observed.
enum MetricStatus { available, stale, unavailable }

/// One dashboard metric together with its provenance.
@immutable
class MetricValue {
  const MetricValue._(this.status, this.value, this.asOf, this.reason);

  /// A freshly computed value.
  const MetricValue.available(num value, {DateTime? asOf})
    : this._(MetricStatus.available, value, asOf, null);

  /// A cached value shown after a failed refresh, clearly dated via [asOf].
  const MetricValue.stale(num value, {required DateTime asOf})
    : this._(MetricStatus.stale, value, asOf, null);

  /// No reliable value could be produced.
  const MetricValue.unavailable([String? reason])
    : this._(MetricStatus.unavailable, null, null, reason);

  final MetricStatus status;
  final num? value;
  final DateTime? asOf;
  final String? reason;

  /// True when [value] is a real measurement (fresh or cached), false when the
  /// metric is unavailable.
  bool get isAvailable => status != MetricStatus.unavailable;

  bool get isStale => status == MetricStatus.stale;

  @override
  String toString() => switch (status) {
    MetricStatus.available => 'MetricValue.available($value)',
    MetricStatus.stale => 'MetricValue.stale($value asOf $asOf)',
    MetricStatus.unavailable => 'MetricValue.unavailable($reason)',
  };
}

/// The four "Today's Overview" metrics for the authenticated hospital.
@immutable
class DashboardMetrics {
  const DashboardMetrics({
    required this.opdToday,
    required this.ipdToday,
    required this.bedsAvailable,
    required this.collectionsToday,
  });

  /// Count of today's valid OPD visits, computed from the durable local mirror
  /// (offline-capable). Excludes cancelled and soft-deleted visits.
  final MetricValue opdToday;

  /// Count of today's valid IPD admissions (online-only — IPD is deliberately
  /// not part of the offline mirror).
  final MetricValue ipdToday;

  /// Count of currently allocatable beds for the hospital (online-only; beds
  /// are not mirrored).
  final MetricValue bedsAvailable;

  /// Money actually collected today from the unified payment ledger
  /// (`payment_logs`), online-only.
  final MetricValue collectionsToday;
}

/// Computes the dashboard "Today's Overview" metrics.
///
/// Metric definitions (all hospital-scoped):
///
/// * **OPD Today** — distinct OPD visits whose date-only `visit_date` is today,
///   excluding `cancelled` and soft-deleted rows. Read from the durable local
///   mirror so it works offline and counts an offline-created visit exactly
///   once after it syncs.
/// * **IPD Today** — admissions whose date-only `admission_date` is today,
///   excluding `cancelled` and soft-deleted rows. Online-only.
/// * **Beds Available** — active beds with `status = 'available'`, the same
///   rule the ward screen and `getWardStats` use. Online-only.
/// * **Collections Today** — sum of `payment_logs.amount_paid` whose
///   timestamp `payment_date` falls in the hospital-local day, excluding
///   soft-deleted logs and logs of soft-deleted/refunded/waived bills. This is
///   the money actually received, NOT billed charges and NOT the lifetime
///   `billing.paid_amount` mirror, so nothing is double counted.
///
/// Date boundaries: the hospital-local day is derived from the device clock
/// (the app has no per-hospital timezone), and the SAME boundaries are applied
/// to every metric so the cards always agree.
class DashboardMetricsService {
  DashboardMetricsService({required this.dbService, required this.localDb});

  final DatabaseService dbService;
  final LocalDatabase localDb;

  /// Last successfully computed online value per metric, keyed by
  /// hospital + metric (+ local day for day-scoped metrics). Used only to show
  /// a clearly dated cached value when a refresh fails.
  final Map<String, _CachedMetric> _cache = {};

  Future<DashboardMetrics> load({required String hospitalId, DateTime? now}) async {
    final current = (now ?? DateTime.now()).toLocal();
    final dayStart = DateTime(current.year, current.month, current.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final todayIso = _dateOnly(dayStart);

    return DashboardMetrics(
      opdToday: await _loadOpdToday(
        hospitalId: hospitalId,
        todayIso: todayIso,
      ),
      ipdToday: await _loadOnline(
        cacheKey: 'ipd:$hospitalId:$todayIso',
        label: 'IPD admissions',
        observedAt: current,
        fetch: () => dbService.countIpdAdmissionsOn(
          dayStart,
          hospitalId: hospitalId,
        ),
      ),
      bedsAvailable: await _loadOnline(
        cacheKey: 'beds:$hospitalId',
        label: 'Beds available',
        observedAt: current,
        fetch: () => dbService.countAvailableBeds(hospitalId),
      ),
      collectionsToday: await _loadOnline(
        cacheKey: 'collections:$hospitalId:$todayIso',
        label: 'Collections',
        observedAt: current,
        fetch: () =>
            dbService.sumCollectionsBetween(dayStart, dayEnd, hospitalId: hospitalId),
      ),
    );
  }

  /// Offline-capable OPD count from the durable local mirror.
  Future<MetricValue> _loadOpdToday({
    required String hospitalId,
    required String todayIso,
  }) async {
    try {
      await localDb.init();
      final provisioned = await dbService.isDatasetProvisioned(
        LocalTables.opdRegistrations,
      );
      final rows = await localDb.getRecords(
        table: LocalTables.opdRegistrations,
      );

      final seen = <String>{};
      var count = 0;
      var sawHospitalRow = false;
      for (final row in rows) {
        if (row['hospital_id']?.toString() != hospitalId) continue;
        sawHospitalRow = true;
        if (row['deleted_at'] != null) continue;
        if ((row['status']?.toString() ?? '').toLowerCase() == 'cancelled') {
          continue;
        }
        if (_dateOnlyOf(row['visit_date']) != todayIso) continue;
        // Count each business record once, even if an offline row and its
        // synced mirror were ever stored under different local keys.
        final businessId = (row['id'] ?? row['offline_id'])?.toString() ?? '';
        if (businessId.isEmpty || !seen.add(businessId)) continue;
        count++;
      }

      // With no downloaded dataset AND no local row for this hospital at all,
      // an empty mirror cannot be told apart from a genuinely empty hospital,
      // so do not claim a number. Once the hospital has any local OPD row (or
      // the dataset was downloaded), a zero is a real empty day.
      if (count == 0 && !provisioned && !sawHospitalRow) {
        return const MetricValue.unavailable('OPD data not downloaded yet');
      }
      return MetricValue.available(count);
    } catch (e) {
      AppLogger.e('Dashboard OPD count failed', e);
      return const MetricValue.unavailable('OPD count unavailable');
    }
  }

  Future<MetricValue> _loadOnline({
    required String cacheKey,
    required String label,
    required DateTime observedAt,
    required Future<num> Function() fetch,
  }) async {
    try {
      final value = await fetch();
      _cache[cacheKey] = _CachedMetric(value, observedAt);
      return MetricValue.available(value, asOf: observedAt);
    } catch (e) {
      AppLogger.w('Dashboard metric "$label" unavailable: $e');
      final cached = _cache[cacheKey];
      if (cached != null) {
        return MetricValue.stale(cached.value, asOf: cached.asOf);
      }
      return MetricValue.unavailable('$label unavailable');
    }
  }

  static String _dateOnly(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// First 10 characters of a date-only value or timestamp (`YYYY-MM-DD`).
  static String _dateOnlyOf(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.length >= 10 ? text.substring(0, 10) : '';
  }
}

class _CachedMetric {
  const _CachedMetric(this.value, this.asOf);

  final num value;
  final DateTime asOf;
}
