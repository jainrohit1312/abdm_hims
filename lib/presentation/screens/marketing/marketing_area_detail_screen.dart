import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../models/marketing_models.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/smart_navigation.dart';
import 'marketing_widgets.dart';

/// Area detail screen — referral doctors ONLY from one marketing area.
class MarketingAreaDetailScreen extends ConsumerWidget {
  const MarketingAreaDetailScreen({super.key, required this.areaId});

  final String areaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Marketing Area')),
        body: const Center(
          child: Text('Hospital not assigned to this user.'),
        ),
      );
    }

    final now = DateTime.now();
    final month = DateTime(now.year, now.month, 1);
    final areaActivityAsync = ref.watch(
      marketingAreaActivityProvider(
        MarketingAreaActivityParams(
          hospitalId: hospitalId,
          areaId: areaId,
          month: month,
        ),
      ),
    );
    final doctorsAsync = ref.watch(referralDoctorsProvider(hospitalId));
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    final visitsAsync = ref.watch(
      marketingVisitsProvider(
        MarketingVisitRangeParams(
          hospitalId: hospitalId,
          from: monthStart,
          to: nextMonth,
        ),
      ),
    );
    final referralsAsync = ref.watch(
      patientReferralsProvider(
        PatientReferralRangeParams(
          hospitalId: hospitalId,
          from: monthStart,
          to: nextMonth,
        ),
      ),
    );

    final doctors = doctorsAsync.valueOrNull ?? const <ReferralDoctor>[];
    final areaDoctors = doctors
        .where((doctor) => doctor.areaId == areaId)
        .toList();
    final summaries = ref
        .read(marketingAnalyticsServiceProvider)
        .referralDoctorSummaries(
          doctors: areaDoctors,
          visits: visitsAsync.valueOrNull ?? const <MarketingVisit>[],
          referrals: referralsAsync.valueOrNull ?? const <PatientReferral>[],
          now: now,
        );
    final summariesById = {
      for (final summary in summaries) summary.referralDoctorId: summary,
    };

    final areaName = areaActivityAsync.valueOrNull?.areaName ?? 'Marketing Area';

    return Scaffold(
      appBar: SmartAppBar(title: Text(areaName)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: areaActivityAsync.maybeWhen(
              data: (area) => Wrap(
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
              orElse: () => const SizedBox.shrink(),
            ),
          ),
          Expanded(
            child: doctorsAsync.when(
              data: (_) {
                if (areaDoctors.isEmpty) {
                  return const MarketingEmptyState(
                    message: 'No referral doctors in this area yet.',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(
                    referralDoctorsProvider(hospitalId),
                  ),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: areaDoctors.length,
                    separatorBuilder: (_, _) => AppGap.xs,
                    itemBuilder: (context, index) {
                      final doctor = areaDoctors[index];
                      final summary = summariesById[doctor.id];
                      return Card(
                        margin: EdgeInsets.zero,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => context.push(
                            '/marketing/referral-doctors/${doctor.id}',
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        doctor.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    GeoVerifiedChip(
                                      verified: doctor.locationVerified,
                                    ),
                                  ],
                                ),
                                if (doctor.clinicName != null &&
                                    doctor.clinicName!.isNotEmpty)
                                  Text(
                                    doctor.clinicName!,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 4,
                                  children: [
                                    MarketingMetric(
                                      label: 'Last Visit',
                                      value: formatMarketingDate(
                                        summary?.lastVisit,
                                      ),
                                    ),
                                    MarketingMetric(
                                      label: 'Visits This Month',
                                      value: '${summary?.visitsThisMonth ?? 0}',
                                    ),
                                    MarketingMetric(
                                      label: 'Referrals This Month',
                                      value:
                                          '${summary?.referralsThisMonth ?? 0}',
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => MarketingErrorRetry(
                message: 'Failed to load referral doctors',
                error: error,
                onRetry: () =>
                    ref.invalidate(referralDoctorsProvider(hospitalId)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
