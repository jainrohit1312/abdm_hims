import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// ---------------------------------------------------------------------------
/// Combined Patient Search Screen
/// ---------------------------------------------------------------------------
/// Searches the patient master (UHID / name / mobile) and enriches every
/// match with that patient's OPD registrations and IPD admissions. This makes
/// it a single search across both registration types.
/// ---------------------------------------------------------------------------
class PatientCombinedSearchScreen extends ConsumerStatefulWidget {
  const PatientCombinedSearchScreen({super.key});

  @override
  ConsumerState<PatientCombinedSearchScreen> createState() =>
      _PatientCombinedSearchScreenState();
}

class _PatientCombinedSearchScreenState
    extends ConsumerState<PatientCombinedSearchScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Search OPD + IPD'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search by UHID, name or mobile...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                          setState(() {});
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                              ),
              onChanged: _onSearchChanged,
            ),
          ),
        ),
      ),
      body: _buildBody(theme, hospitalId),
    );
  }

  Widget _buildBody(ThemeData theme, String? hospitalId) {
    if (_query.isEmpty) {
      return _CenteredHint(
        icon: Icons.manage_search,
        title: 'Search across OPD & IPD',
        subtitle:
            'Results show patients from the patient master with their OPD '
            'visits and IPD admissions side by side.',
      );
    }

    final searchAsync = ref.watch(
      combinedPatientSearchProvider(
        CombinedPatientSearchParams(query: _query, hospitalId: hospitalId),
      ),
    );

    return searchAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _CenteredHint(
        icon: Icons.error_outline,
        title: 'Search failed',
        subtitle: error.toString(),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const _CenteredHint(
            icon: Icons.search_off,
            title: 'No patients found',
            subtitle: 'Try a different UHID, name or mobile number.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: results.length,
          itemBuilder: (context, index) =>
              _buildPatientCard(theme, results[index]),
        );
      },
    );
  }

  Widget _buildPatientCard(ThemeData theme, Map<String, dynamic> patient) {
    final firstName = patient['first_name']?.toString() ?? '';
    final lastName = patient['last_name']?.toString() ?? '';
    final name = [
      firstName,
      lastName,
    ].where((n) => n.isNotEmpty).join(' ').trim();
    final uhid = patient['uhid']?.toString() ?? 'N/A';
    final mobile = patient['mobile_number']?.toString() ?? '';

    final opdVisits =
        (patient['opd_visits'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final ipdAdmissions =
        (patient['ipd_admissions'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final opdCount = opdVisits.length;
    final ipdCount = ipdAdmissions.length;

    final lastOpdDate = _latestDate(opdVisits, 'visit_date');
    final lastIpdDate = _latestDate(ipdAdmissions, 'admission_date');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        title: Text(
          name.isEmpty ? 'Unknown' : name,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('UHID: $uhid'),
            if (mobile.isNotEmpty) Text('Mobile: $mobile'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _VisitCountBadge(
                  icon: Icons.event_available,
                  label: '$opdCount OPD',
                  color: const Color(0xFF1565C0),
                  detail: lastOpdDate == null ? null : 'Last: $lastOpdDate',
                ),
                _VisitCountBadge(
                  icon: Icons.local_hotel,
                  label: '$ipdCount IPD',
                  color: const Color(0xFF2E7D32),
                  detail: lastIpdDate == null ? null : 'Last: $lastIpdDate',
                ),
              ],
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/patients/${patient['id']}'),
      ),
    );
  }

  String? _latestDate(List<Map<String, dynamic>> rows, String column) {
    DateTime? latest;
    for (final row in rows) {
      final parsed = DateTime.tryParse(row[column]?.toString() ?? '');
      if (parsed == null) continue;
      if (latest == null || parsed.isAfter(latest)) latest = parsed;
    }
    if (latest == null) return null;
    final month = latest.month.toString().padLeft(2, '0');
    final day = latest.day.toString().padLeft(2, '0');
    return '$day-$month-${latest.year}';
  }
}

class _VisitCountBadge extends StatelessWidget {
  const _VisitCountBadge({
    required this.icon,
    required this.label,
    required this.color,
    this.detail,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 6),
            Text(
              detail!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CenteredHint extends StatelessWidget {
  const _CenteredHint({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
