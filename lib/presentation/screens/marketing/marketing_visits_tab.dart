import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../models/employee_model.dart';
import '../../../models/marketing_models.dart';
import '../../widgets/app_ui.dart';
import 'marketing_widgets.dart';

/// Visits tab — defaults to Today.
///
/// Shows visit punches (newest first) with date/employee/doctor/clinic/area/
/// location/distance/geo-status. Filters are applied client-side over a
/// single date-range fetch.
class MarketingVisitsTab extends ConsumerStatefulWidget {
  const MarketingVisitsTab({super.key, required this.hospitalId});

  final String hospitalId;

  @override
  ConsumerState<MarketingVisitsTab> createState() => _MarketingVisitsTabState();
}

class _MarketingVisitsTabState extends ConsumerState<MarketingVisitsTab> {
  late DateTime _from;
  late DateTime _to;
  String? _areaFilter;
  String? _employeeFilter;
  String? _doctorFilter;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day);
    _to = _from;
  }

  DateTime get _toExclusive =>
      DateTime(_to.year, _to.month, _to.day + 1);

  @override
  Widget build(BuildContext context) {
    final params = MarketingVisitRangeParams(
      hospitalId: widget.hospitalId,
      from: _from,
      to: _toExclusive,
    );
    final visitsAsync = ref.watch(marketingVisitsProvider(params));
    final doctorsAsync = ref.watch(referralDoctorsProvider(widget.hospitalId));
    final areasAsync = ref.watch(marketingAreasProvider(widget.hospitalId));
    final employeesAsync = ref.watch(employeesProvider(widget.hospitalId));

    final doctors = doctorsAsync.valueOrNull ?? const <ReferralDoctor>[];
    final areas = areasAsync.valueOrNull ?? const <MarketingArea>[];
    final employees = employeesAsync.valueOrNull ?? const <Employee>[];

    final doctorById = {for (final d in doctors) d.id: d};
    final areaById = {for (final a in areas) a.id: a};
    final employeeById = {for (final e in employees) e.id: e};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDateRow(context),
              AppGap.sm,
              _buildFilters(context, areas, employees, doctors),
              AppGap.sm,
              Row(
                children: [
                  Expanded(
                    child: Text(
                      visitsAsync.maybeWhen(
                        data: (visits) => '${_filter(visits).length} visit(s)',
                        orElse: () => 'Visits',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => context.push('/marketing/visits/new'),
                    icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                    label: const Text('Add Visit'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: visitsAsync.when(
            data: (visits) {
              final filtered = _filter(visits);
              if (filtered.isEmpty) {
                return const MarketingEmptyState(
                  message: 'No visits found for the selected range.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async =>
                    ref.invalidate(marketingVisitsProvider(params)),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => AppGap.xs,
                  itemBuilder: (context, index) {
                    final visit = filtered[index];
                    return _VisitCard(
                      visit: visit,
                      doctor: doctorById[visit.referralDoctorId],
                      area: areaById[visit.areaId],
                      employee: employeeById[visit.marketingEmployeeId],
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => MarketingErrorRetry(
              message: 'Failed to load visits',
              error: error,
              onRetry: () => ref.invalidate(marketingVisitsProvider(params)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDateRow(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          onPressed: () => setState(() {
            _from = _from.subtract(const Duration(days: 1));
            _to = _from;
          }),
          icon: const Icon(Icons.chevron_left),
        ),
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
        IconButton(
          tooltip: 'Next day',
          onPressed: () => setState(() {
            _from = _from.add(const Duration(days: 1));
            _to = _from;
          }),
          icon: const Icon(Icons.chevron_right),
        ),
        TextButton(
          onPressed: () => setState(() {
            final now = DateTime.now();
            _from = DateTime(now.year, now.month, now.day);
            _to = _from;
          }),
          child: const Text('Today'),
        ),
      ],
    );
  }

  Widget _buildFilters(
    BuildContext context,
    List<MarketingArea> areas,
    List<Employee> employees,
    List<ReferralDoctor> doctors,
  ) {
    return Column(
      children: [
        AppFieldRow(
          children: [
            _dropdown<String?>(
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
            _dropdown<String?>(
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
              onChanged: (value) => setState(() => _employeeFilter = value),
            ),
            _dropdown<String?>(
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
      ],
    );
  }

  DropdownButtonFormField<String?> _dropdown<T>({
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

  List<MarketingVisit> _filter(List<MarketingVisit> visits) {
    return visits.where((visit) {
      final matchesArea =
          _areaFilter == null || visit.areaId == _areaFilter;
      final matchesEmployee = _employeeFilter == null ||
          visit.marketingEmployeeId == _employeeFilter;
      final matchesDoctor = _doctorFilter == null ||
          visit.referralDoctorId == _doctorFilter;
      return matchesArea && matchesEmployee && matchesDoctor;
    }).toList();
  }
}

class _VisitCard extends StatelessWidget {
  const _VisitCard({
    required this.visit,
    this.doctor,
    this.area,
    this.employee,
  });

  final MarketingVisit visit;
  final ReferralDoctor? doctor;
  final MarketingArea? area;
  final Employee? employee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locationText = (visit.latitude == null || visit.longitude == null)
        ? '—'
        : '${visit.latitude!.toStringAsFixed(6)}, '
              '${visit.longitude!.toStringAsFixed(6)}';

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
                    formatMarketingDateTime(visit.visitedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                GeoVerifiedChip(verified: visit.geoVerified),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              doctor?.name ?? 'Referral Doctor',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              [
                doctor?.clinicName ?? '',
                area?.name ?? '',
              ].where((e) => e.isNotEmpty).join(' • '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                MarketingMetric(
                  label: 'Employee',
                  value: employee?.fullName ?? '—',
                ),
                MarketingMetric(
                  label: 'Visit Location',
                  value: locationText,
                ),
                MarketingMetric(
                  label: 'Distance',
                  value: formatMarketingDistance(
                    visit.distanceFromDoctorMeters,
                  ),
                ),
              ],
            ),
            if (visit.visitNotes != null && visit.visitNotes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  visit.visitNotes!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
