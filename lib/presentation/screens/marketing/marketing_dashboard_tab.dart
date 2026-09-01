import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../models/employee_model.dart';
import '../../../models/marketing_models.dart';
import '../../widgets/app_ui.dart';
import 'marketing_widgets.dart';

/// Dashboard tab of the PRO / Marketing module.
///
/// Data comes from [marketingDashboardProvider]; employee/doctor/area names
/// are resolved from cached list providers (one fetch each — never N+1).
class MarketingDashboardTab extends ConsumerWidget {
  const MarketingDashboardTab({super.key, required this.hospitalId});

  final String hospitalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final params = MarketingDashboardParams(
      hospitalId: hospitalId,
      date: DateTime(now.year, now.month, now.day),
    );
    final summaryAsync = ref.watch(marketingDashboardProvider(params));
    final doctorsAsync = ref.watch(referralDoctorsProvider(hospitalId));
    final areasAsync = ref.watch(marketingAreasProvider(hospitalId));
    final employeesAsync = ref.watch(employeesProvider(hospitalId));

    final doctorNames = <String, ReferralDoctor>{
      for (final d in doctorsAsync.valueOrNull ?? const <ReferralDoctor>[])
        d.id: d,
    };
    final areaNames = <String, String>{
      for (final a in areasAsync.valueOrNull ?? const <MarketingArea>[])
        a.id: a.name,
    };
    final employeeNames = <String, String>{
      for (final e in employeesAsync.valueOrNull ?? const <Employee>[])
        e.id: e.fullName,
    };

    return summaryAsync.when(
      data: (summary) => RefreshIndicator(
        onRefresh: () async =>
            ref.invalidate(marketingDashboardProvider(params)),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _buildStatCards(context, summary),
            AppGap.lg,
            _buildAreaActivity(context, summary),
            AppGap.lg,
            _buildTopDoctors(context, summary),
            AppGap.lg,
            _buildRecentVisits(context, summary, doctorNames, areaNames, employeeNames),
          ],
        ),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => MarketingErrorRetry(
        message: 'Failed to load marketing dashboard',
        error: error,
        onRetry: () => ref.invalidate(marketingDashboardProvider(params)),
      ),
    );
  }

  Widget _buildStatCards(
    BuildContext context,
    MarketingDashboardSummary summary,
  ) {
    final theme = Theme.of(context);
    final cards = [
      (
        Icons.today_outlined,
        'Today\'s Visits',
        '${summary.todayVisits}',
        Colors.blue,
      ),
      (
        Icons.gps_fixed,
        'Geo Verified Visits',
        '${summary.geoVerifiedVisitsToday}',
        Colors.green,
      ),
      (
        Icons.medical_services_outlined,
        'Doctors Visited Today',
        '${summary.referralDoctorsVisitedToday}',
        Colors.orange,
      ),
      (
        Icons.people_outline,
        'Referrals Today',
        '${summary.referralsToday}',
        Colors.purple,
      ),
      (
        Icons.event_available_outlined,
        'Referrals This Month',
        '${summary.referralsThisMonth}',
        Colors.teal,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Today\'s Overview',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        AppGap.sm,
        AppResponsiveGrid(
          itemCount: cards.length,
          minItemWidth: 150,
          childAspectRatio: 1.5,
          itemBuilder: (context, index) {
            final card = cards[index];
            return Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(card.$1, color: card.$4, size: 22),
                    const SizedBox(height: 8),
                    Text(
                      card.$3,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      card.$2,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildAreaActivity(
    BuildContext context,
    MarketingDashboardSummary summary,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Area-wise Activity',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        AppGap.sm,
        if (summary.areaActivity.isEmpty)
          const MarketingEmptyState(message: 'No areas configured yet.')
        else
          for (final area in summary.areaActivity) ...[
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                title: Text(
                  area.areaName.isEmpty ? 'Unassigned' : area.areaName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    MarketingMetric(
                      label: 'Referral Doctors',
                      value: '${area.referralDoctorCount}',
                    ),
                    MarketingMetric(
                      label: 'Visited Today',
                      value: '${area.visitedToday}',
                    ),
                    MarketingMetric(
                      label: 'Visited This Month',
                      value: '${area.visitedThisMonth}',
                    ),
                    MarketingMetric(
                      label: 'Referrals This Month',
                      value: '${area.referralsThisMonth}',
                    ),
                  ],
                ),
              ),
            ),
            AppGap.xs,
          ],
      ],
    );
  }

  Widget _buildTopDoctors(
    BuildContext context,
    MarketingDashboardSummary summary,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Top Referral Doctors This Month',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        AppGap.sm,
        if (summary.topReferralDoctorsThisMonth.isEmpty)
          const MarketingEmptyState(message: 'No visits recorded this month.')
        else
          for (final doctor in summary.topReferralDoctorsThisMonth) ...[
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(_initials(doctor.referralDoctorName)),
                ),
                title: Text(
                  doctor.referralDoctorName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  [
                    doctor.clinicName ?? '',
                    doctor.areaName ?? '',
                  ].where((e) => e.isNotEmpty).join(' • '),
                ),
                trailing: Text(
                  '${doctor.visitsThisMonth} visits',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            AppGap.xs,
          ],
      ],
    );
  }

  Widget _buildRecentVisits(
    BuildContext context,
    MarketingDashboardSummary summary,
    Map<String, ReferralDoctor> doctorNames,
    Map<String, String> areaNames,
    Map<String, String> employeeNames,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent Visits',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        AppGap.sm,
        if (summary.recentVisits.isEmpty)
          const MarketingEmptyState(message: 'No visits recorded today.')
        else
          for (final visit in summary.recentVisits) ...[
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.directions_walk),
                title: Text(
                  doctorNames[visit.referralDoctorId]?.name ?? 'Referral Doctor',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatMarketingDateTime(visit.visitedAt),
                    ),
                    Text(
                      [
                        employeeNames[visit.marketingEmployeeId] ?? '—',
                        areaNames[visit.areaId] ??
                            doctorNames[visit.referralDoctorId]?.areaName ??
                            '',
                      ].where((e) => e.isNotEmpty).join(' • '),
                    ),
                  ],
                ),
                isThreeLine: true,
                trailing: GeoVerifiedChip(verified: visit.geoVerified),
              ),
            ),
            AppGap.xs,
          ],
        OverflowBar(
          alignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => context.go('/marketing'),
              child: const Text('Open Visits'),
            ),
          ],
        ),
      ],
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}
