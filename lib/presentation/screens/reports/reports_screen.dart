import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../widgets/app_footer.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/report_card.dart';
import 'widgets/report_filter.dart';

/// `/reports` — generated reports ki list.
///
/// Search, report-type filter chips, status filter chips, pull-to-refresh aur
/// [AppRefreshButton] ke saath. Tap karne par detail screen khulti hai.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedType;
  String? _selectedStatus;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _filteredReports(
    List<Map<String, dynamic>> reports,
  ) {
    final query = _query.trim().toLowerCase();
    return reports.where((report) {
      final title = report['title']?.toString().toLowerCase() ?? '';
      final type = report['report_type']?.toString().toLowerCase() ?? '';
      final matchesQuery =
          query.isEmpty || title.contains(query) || type.contains(query);
      final matchesType =
          _selectedType == null ||
          report['report_type']?.toString() == _selectedType;
      final matchesStatus =
          _selectedStatus == null ||
          report['status']?.toString() == _selectedStatus;
      return matchesQuery && matchesType && matchesStatus;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Reports')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final reportsAsync = ref.watch(reportsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            tooltip: 'Generate Report',
            icon: const Icon(Icons.add_chart),
            onPressed: () => context.push('/reports/generate'),
          ),
          AppRefreshButton(
            onRefresh: () => ref.invalidate(reportsProvider(hospitalId)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => context.push('/reports/generate'),
                icon: const Icon(Icons.add_chart),
                label: const Text('Generate New Report'),
              ),
            ),
          ),
          ReportFilterBar(
            searchController: _searchController,
            selectedType: _selectedType,
            selectedStatus: _selectedStatus,
            onSearchChanged: (value) => setState(() => _query = value),
            onTypeChanged: (value) => setState(() => _selectedType = value),
            onStatusChanged: (value) => setState(() => _selectedStatus = value),
          ),
          const Divider(height: 1),
          Expanded(
            child: reportsAsync.when(
              skipLoadingOnReload: true,
              data: (reports) {
                final visible = _filteredReports(reports);
                final hasFilters =
                    _query.isNotEmpty ||
                    _selectedType != null ||
                    _selectedStatus != null;
                return RefreshIndicator(
                  onRefresh: () => _refresh(hospitalId),
                  child: visible.isEmpty
                      ? _EmptyState(
                          hasFilters: hasFilters,
                          hasAnyReports: reports.isNotEmpty,
                          onGenerate: () => context.push('/reports/generate'),
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                          itemCount: visible.length + 1,
                          itemBuilder: (context, index) {
                            if (index == visible.length) {
                              return const AppFooter();
                            }
                            final report = visible[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: ReportCard(
                                report: report,
                                onTap: () {
                                  final id = report['id']?.toString();
                                  if (id != null && id.isNotEmpty) {
                                    context.push('/reports/$id');
                                  }
                                },
                              ),
                            );
                          },
                        ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ErrorState(
                error: error,
                onRetry: () => ref.invalidate(reportsProvider(hospitalId)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refresh(String hospitalId) async {
    // Existing pattern: invalidate karo aur thoda wait karo taaki RefreshIndicator
    // ka spinner provider ke naye state ke aane tak dikhta rahe.
    ref.invalidate(reportsProvider(hospitalId));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.hasFilters,
    required this.hasAnyReports,
    required this.onGenerate,
  });

  final bool hasFilters;
  final bool hasAnyReports;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final message = hasFilters
        ? (hasAnyReports
              ? 'No reports match your filters.'
              : 'No reports generated yet.')
        : 'No reports generated yet.\nReports will appear here once generated.';

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 140),
        Icon(
          hasFilters ? Icons.filter_alt_off_outlined : Icons.analytics_outlined,
          size: 64,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (!hasFilters) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: onGenerate,
              icon: const Icon(Icons.add_chart),
              label: const Text('Generate First Report'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 140),
        Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
        const SizedBox(height: 12),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Failed to load reports\n$error',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ),
      ],
    );
  }
}
