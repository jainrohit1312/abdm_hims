import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../models/employee_model.dart';
import '../../../models/marketing_models.dart';
import '../../widgets/app_footer.dart';
import '../../widgets/app_ui.dart';
import 'marketing_widgets.dart';

/// Referrals tab — event/visit based patient referral history.
///
/// Shows date, patient, UHID, referral doctor, clinic, area, marketing
/// employee and the optional OPD/IPD link. Filters are applied client-side
/// over a single date-range fetch.
class MarketingReferralsTab extends ConsumerStatefulWidget {
  const MarketingReferralsTab({super.key, required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<MarketingReferralsTab> createState() =>
      _MarketingReferralsTabState();
}

class _MarketingReferralsTabState extends ConsumerState<MarketingReferralsTab> {
  late DateTime _from;
  late DateTime _to;
  String? _areaFilter;
  String? _employeeFilter;
  String? _doctorFilter;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month, now.day);
  }

  DateTime get _toExclusive => DateTime(_to.year, _to.month, _to.day + 1);

  @override
  Widget build(BuildContext context) {
    final params = PatientReferralRangeParams(
      hospitalId: widget.hospitalId,
      from: _from,
      to: _toExclusive,
    );
    final referralsAsync = ref.watch(patientReferralsProvider(params));
    final doctorsAsync = ref.watch(referralDoctorsProvider(widget.hospitalId));
    final areasAsync = ref.watch(marketingAreasProvider(widget.hospitalId));
    final employeesAsync = ref.watch(employeesProvider(widget.hospitalId));

    final doctors = doctorsAsync.valueOrNull ?? const <ReferralDoctor>[];
    final areas = areasAsync.valueOrNull ?? const <MarketingArea>[];
    final employees = employeesAsync.valueOrNull ?? const <Employee>[];

    final doctorById = {for (final d in doctors) d.id: d};
    final employeeById = {for (final e in employees) e.id: e};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickRange(context),
                      icon: const Icon(Icons.date_range_outlined, size: 16),
                      label: Text(
                        _from == _to
                            ? DateFormat('dd MMM yyyy').format(_from)
                            : '${DateFormat('dd MMM yyyy').format(_from)} - '
                                  '${DateFormat('dd MMM yyyy').format(_to)}',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      final now = DateTime.now();
                      _from = DateTime(now.year, now.month, 1);
                      _to = DateTime(now.year, now.month, now.day);
                    }),
                    child: const Text('This Month'),
                  ),
                ],
              ),
              AppGap.sm,
              AppFieldRow(
                children: [
                  _dropdown(
                    label: 'Area',
                    value: _areaFilter,
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
                  _dropdown(
                    label: 'Marketing Employee',
                    value: _employeeFilter,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All Employees'),
                      ),
                      for (final employee in employees)
                        DropdownMenuItem<String?>(
                          value: employee.id,
                          child: Text(employee.fullName),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _employeeFilter = value),
                  ),
                  _dropdown(
                    label: 'Referral Doctor',
                    value: _doctorFilter,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All Referral Doctors'),
                      ),
                      for (final doctor in doctors)
                        DropdownMenuItem<String?>(
                          value: doctor.id,
                          child: Text(doctor.name),
                        ),
                    ],
                    onChanged: (value) => setState(() => _doctorFilter = value),
                  ),
                ],
              ),
              AppGap.sm,
              Row(
                children: [
                  Expanded(
                    child: Text(
                      referralsAsync.maybeWhen(
                        data: (referrals) =>
                            '${_filter(referrals, doctorById).length} referral(s)',
                        orElse: () => 'Referrals',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => context.push('/marketing/referrals/new'),
                    icon: const Icon(Icons.person_add_alt, size: 18),
                    label: const Text('Add Referral'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: referralsAsync.when(
            data: (referrals) {
              final filtered = _filter(referrals, doctorById);
              if (filtered.isEmpty) {
                return const MarketingEmptyState(
                  message: 'No referrals found for the selected range.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(patientReferralsProvider(params)),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: filtered.length + 1,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    if (index == filtered.length) {
                      return const AppFooter();
                    }
                    final referral = filtered[index];
                    final doctor = doctorById[referral.referralDoctorId];
                    return _ReferralCard(
                      referral: referral,
                      doctor: doctor,
                      employee: employeeById[referral.marketingEmployeeId],
                      areaName: _areaName(doctor, doctor?.areaId, areas),
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => MarketingErrorRetry(
              message: 'Failed to load referrals',
              error: error,
              onRetry: () => ref.invalidate(patientReferralsProvider(params)),
            ),
          ),
        ),
      ],
    );
  }

  String _areaName(
    ReferralDoctor? doctor,
    String? areaId,
    List<MarketingArea> areas,
  ) {
    if (doctor != null &&
        doctor.areaName != null &&
        doctor.areaName!.isNotEmpty) {
      return doctor.areaName!;
    }
    if (areaId == null) return '—';
    for (final area in areas) {
      if (area.id == areaId) return area.name;
    }
    return '—';
  }

  DropdownButtonFormField<String?> _dropdown({
    required String label,
    required String? value,
    required List<DropdownMenuItem<String?>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: items,
      onChanged: onChanged,
    );
  }

  Future<void> _pickRange(BuildContext context) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (range != null && mounted) {
      setState(() {
        _from = DateTime(range.start.year, range.start.month, range.start.day);
        _to = DateTime(range.end.year, range.end.month, range.end.day);
      });
    }
  }

  List<PatientReferral> _filter(
    List<PatientReferral> referrals,
    Map<String, ReferralDoctor> doctorById,
  ) {
    return referrals.where((referral) {
      final doctorAreaId = doctorById[referral.referralDoctorId]?.areaId;
      final matchesArea = _areaFilter == null || doctorAreaId == _areaFilter;
      final matchesEmployee = _employeeFilter == null ||
          referral.marketingEmployeeId == _employeeFilter;
      final matchesDoctor = _doctorFilter == null ||
          referral.referralDoctorId == _doctorFilter;
      return matchesArea && matchesEmployee && matchesDoctor;
    }).toList();
  }
}

class _ReferralCard extends StatelessWidget {
  const _ReferralCard({
    required this.referral,
    this.doctor,
    this.employee,
    required this.areaName,
  });

  final PatientReferral referral;
  final ReferralDoctor? doctor;
  final Employee? employee;
  final String areaName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = referral.opdRegistrationId != null
        ? 'OPD'
        : referral.ipdAdmissionId != null
            ? 'IPD'
            : null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    referral.patientName ?? 'Patient',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatMarketingDate(referral.referralDate),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (referral.patientUhid != null)
              Text(
                'UHID: ${referral.patientUhid}',
                style: theme.textTheme.bodySmall,
              ),
            Text(
              [
                'Referred By: ${doctor?.name ?? 'Referral Doctor'}',
                doctor?.clinicName ?? '',
                areaName,
              ].where((e) => e.isNotEmpty).join(' • '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                MarketingMetric(
                  label: 'Marketing Employee',
                  value: employee?.fullName ?? '—',
                ),
                if (link != null)
                  MarketingMetric(label: 'Visit Link', value: link),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
