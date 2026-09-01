import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../models/marketing_models.dart';
import '../../../services/marketing_analytics_service.dart';
import '../../widgets/app_ui.dart';
import 'marketing_widgets.dart';

/// Referral Doctors tab.
///
/// Lists the REFERRAL DOCTOR master (a completely separate domain from
/// hospital doctors). Month activity is aggregated once from the cached
/// month visit/referral lists via [MarketingAnalyticsService] — never N+1.
class ReferralDoctorsTab extends ConsumerStatefulWidget {
  const ReferralDoctorsTab({super.key, required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<ReferralDoctorsTab> createState() => _ReferralDoctorsTabState();
}

class _ReferralDoctorsTabState extends ConsumerState<ReferralDoctorsTab> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _areaFilter;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doctorsAsync = ref.watch(referralDoctorsProvider(widget.hospitalId));
    final areasAsync = ref.watch(marketingAreasProvider(widget.hospitalId));

    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    final visitsAsync = ref.watch(
      marketingVisitsProvider(
        MarketingVisitRangeParams(
          hospitalId: widget.hospitalId,
          from: monthStart,
          to: nextMonth,
        ),
      ),
    );
    final referralsAsync = ref.watch(
      patientReferralsProvider(
        PatientReferralRangeParams(
          hospitalId: widget.hospitalId,
          from: monthStart,
          to: nextMonth,
        ),
      ),
    );

    final doctors = doctorsAsync.valueOrNull ?? const <ReferralDoctor>[];
    final areas = areasAsync.valueOrNull ?? const <MarketingArea>[];
    final summaries = ref
        .read(marketingAnalyticsServiceProvider)
        .referralDoctorSummaries(
          doctors: doctors,
          visits: visitsAsync.valueOrNull ?? const <MarketingVisit>[],
          referrals: referralsAsync.valueOrNull ?? const <PatientReferral>[],
          now: now,
        );
    final summariesById = {for (final s in summaries) s.referralDoctorId: s};

    final filtered = doctors.where((doctor) {
      final matchesQuery =
          _query.isEmpty ||
          doctor.name.toLowerCase().contains(_query) ||
          (doctor.clinicName?.toLowerCase().contains(_query) ?? false) ||
          (doctor.mobileNumber?.contains(_query) ?? false) ||
          (doctor.city?.toLowerCase().contains(_query) ?? false);
      final matchesArea =
          _areaFilter == null || doctor.areaId == _areaFilter;
      return matchesQuery && matchesArea;
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search by referral doctor / clinic / mobile / city',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
              ),
              AppGap.sm,
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _areaFilter,
                      decoration: const InputDecoration(
                        labelText: 'Area',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('All Areas'),
                        ),
                        for (final area in areas)
                          DropdownMenuItem<String?>(
                            value: area.id,
                            child: Text(area.name),
                          ),
                      ],
                      onChanged: (value) => setState(() => _areaFilter = value),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () =>
                        context.push('/marketing/referral-doctors/new'),
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('Add Referral Doctor'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: doctorsAsync.when(
            data: (_) {
              if (filtered.isEmpty) {
                return const MarketingEmptyState(
                  message: 'No referral doctors found.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(referralDoctorsProvider(widget.hospitalId));
                },
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    final doctor = filtered[index];
                    final summary = summariesById[doctor.id];
                    return _ReferralDoctorCard(
                      doctor: doctor,
                      summary: summary,
                      areaName: _areaName(doctor, areas),
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
                  ref.invalidate(referralDoctorsProvider(widget.hospitalId)),
            ),
          ),
        ),
      ],
    );
  }

  String _areaName(ReferralDoctor doctor, List<MarketingArea> areas) {
    if (doctor.areaName != null && doctor.areaName!.isNotEmpty) {
      return doctor.areaName!;
    }
    if (doctor.areaId == null) return '—';
    for (final area in areas) {
      if (area.id == doctor.areaId) return area.name;
    }
    return '—';
  }
}

class _ReferralDoctorCard extends StatelessWidget {
  const _ReferralDoctorCard({
    required this.doctor,
    required this.summary,
    required this.areaName,
  });

  final ReferralDoctor doctor;
  final ReferralDoctorSummary? summary;
  final String areaName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final subtitleParts = [
      doctor.clinicName ?? '',
      areaName,
      marketingPractitionerTypeLabel(doctor.practitionerType),
    ].where((e) => e.isNotEmpty).join(' • ');

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            context.push('/marketing/referral-doctors/${doctor.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      doctor.name.isEmpty ? 'Unknown' : doctor.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GeoVerifiedChip(verified: doctor.locationVerified),
                ],
              ),
              const SizedBox(height: 2),
              if (subtitleParts.isNotEmpty)
                Text(
                  subtitleParts,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              if (doctor.mobileNumber != null &&
                  doctor.mobileNumber!.isNotEmpty)
                Text(
                  'Mobile: ${doctor.mobileNumber}',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  MarketingMetric(
                    label: 'Last Visit',
                    value: formatMarketingDate(summary?.lastVisit),
                  ),
                  MarketingMetric(
                    label: 'Visits This Month',
                    value: '${summary?.visitsThisMonth ?? 0}',
                  ),
                  MarketingMetric(
                    label: 'Referrals This Month',
                    value: '${summary?.referralsThisMonth ?? 0}',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
