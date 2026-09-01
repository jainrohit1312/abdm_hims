import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../models/employee_model.dart';
import '../../../models/marketing_models.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/smart_navigation.dart';
import 'marketing_widgets.dart';

/// Referral Doctor detail screen.
///
/// Shows master fields + bounded recent activity. Lifetime history rows are
/// NOT loaded — only recent visits/referrals (90 days) and cheap counts.
class ReferralDoctorDetailScreen extends ConsumerWidget {
  const ReferralDoctorDetailScreen({super.key, required this.doctorId});

  final String doctorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Referral Doctor')),
        body: const Center(
          child: Text('Hospital not assigned to this user.'),
        ),
      );
    }

    final now = DateTime.now();
    final params = ReferralDoctorDetailAnalyticsParams(
      hospitalId: hospitalId,
      doctorId: doctorId,
      now: DateTime(now.year, now.month, now.day),
    );
    final detailAsync = ref.watch(referralDoctorDetailProvider(params));
    final employeesAsync = ref.watch(employeesProvider(hospitalId));
    final employees = employeesAsync.valueOrNull ?? const <Employee>[];
    final employeeNames = {for (final e in employees) e.id: e.fullName};

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Referral Doctor')),
      body: detailAsync.when(
        data: (detail) {
          if (detail == null) {
            return const Center(child: Text('Referral doctor not found.'));
          }
          final doctor = detail.doctor;
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(referralDoctorDetailProvider(params)),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                _buildHeader(context, doctor),
                AppGap.md,
                _buildMasterCard(context, doctor),
                AppGap.md,
                _buildLocationCard(context, doctor),
                AppGap.md,
                _buildActivityCard(context, detail),
                AppGap.md,
                _buildRecentVisits(context, detail, employeeNames),
                AppGap.md,
                _buildRecentReferrals(context, detail),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => MarketingErrorRetry(
          message: 'Failed to load referral doctor',
          error: error,
          onRetry: () => ref.invalidate(referralDoctorDetailProvider(params)),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ReferralDoctor doctor) {
    final theme = Theme.of(context);
    return AppSectionCard(
      title: doctor.name,
      subtitle: doctor.clinicName ?? 'Referral Doctor',
      action: FilledButton.icon(
        onPressed: () => context.push(
          '/marketing/referral-doctors/${doctor.id}/edit',
        ),
        icon: const Icon(Icons.edit_outlined, size: 16),
        label: const Text('Edit'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            marketingPractitionerTypeLabel(doctor.practitionerType),
            style: theme.textTheme.bodyMedium,
          ),
          if (doctor.registrationNumber != null &&
              doctor.registrationNumber!.isNotEmpty)
            Text('Registration: ${doctor.registrationNumber}'),
          if (doctor.mobileNumber != null && doctor.mobileNumber!.isNotEmpty)
            Text('Mobile: ${doctor.mobileNumber}'),
        ],
      ),
    );
  }

  Widget _buildMasterCard(BuildContext context, ReferralDoctor doctor) {
    return AppSectionCard(
      title: 'Master Details',
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          MarketingMetric(label: 'Area', value: doctor.areaName ?? '—'),
          MarketingMetric(label: 'Village', value: doctor.village ?? '—'),
          MarketingMetric(label: 'Address', value: doctor.address ?? '—'),
          MarketingMetric(label: 'City', value: doctor.city ?? '—'),
          MarketingMetric(label: 'Pincode', value: doctor.pincode ?? '—'),
          MarketingMetric(
            label: 'Status',
            value: doctor.isActive ? 'Active' : 'Inactive',
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard(BuildContext context, ReferralDoctor doctor) {
    return AppSectionCard(
      title: 'Clinic Location (Geofence)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarketingMetric(
                      label: 'Latitude',
                      value: doctor.latitude?.toStringAsFixed(6) ?? '—',
                    ),
                    MarketingMetric(
                      label: 'Longitude',
                      value: doctor.longitude?.toStringAsFixed(6) ?? '—',
                    ),
                    MarketingMetric(
                      label: 'Geofence Radius',
                      value: '${doctor.geoRadiusMeters} m',
                    ),
                  ],
                ),
              ),
              GeoVerifiedChip(verified: doctor.locationVerified),
            ],
          ),
          if (doctor.locationVerifiedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Verified on ${formatMarketingDateTime(doctor.locationVerifiedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActivityCard(
    BuildContext context,
    ReferralDoctorDetail detail,
  ) {
    return AppSectionCard(
      title: 'Activity',
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          MarketingMetric(label: 'Last Visit', value: formatMarketingDate(detail.lastVisit)),
          MarketingMetric(label: 'Total Visits', value: '${detail.totalVisits}'),
          MarketingMetric(
            label: 'Visits This Month',
            value: '${detail.visitsThisMonth}',
          ),
          MarketingMetric(
            label: 'Patients Referred',
            value: '${detail.patientsReferred}',
          ),
          MarketingMetric(
            label: 'Patients Referred This Month',
            value: '${detail.patientsReferredThisMonth}',
          ),
        ],
      ),
    );
  }

  Widget _buildRecentVisits(
    BuildContext context,
    ReferralDoctorDetail detail,
    Map<String, String> employeeNames,
  ) {
    return AppSectionCard(
      title: 'Recent Visits',
      child: detail.recentVisits.isEmpty
          ? const Text('No recent visits.')
          : Column(
              children: [
                for (final visit in detail.recentVisits) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: GeoVerifiedChip(verified: visit.geoVerified),
                    title: Text(formatMarketingDateTime(visit.visitedAt)),
                    subtitle: Text(
                      [
                        employeeNames[visit.marketingEmployeeId] ?? '—',
                        formatMarketingDistance(
                          visit.distanceFromDoctorMeters,
                        ),
                      ].where((e) => e.isNotEmpty).join(' • '),
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ),
    );
  }

  Widget _buildRecentReferrals(
    BuildContext context,
    ReferralDoctorDetail detail,
  ) {
    return AppSectionCard(
      title: 'Recent Referrals',
      child: detail.recentReferrals.isEmpty
          ? const Text('No recent referrals.')
          : Column(
              children: [
                for (final referral in detail.recentReferrals) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(referral.patientName ?? 'Patient'),
                    subtitle: Text(
                      [
                        if (referral.patientUhid != null)
                          'UHID: ${referral.patientUhid}',
                        formatMarketingDate(referral.referralDate),
                      ].join(' • '),
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ],
            ),
    );
  }
}
