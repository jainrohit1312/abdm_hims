import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/app_page_content.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/smart_navigation.dart';
import '../../../services/dashboard_metrics_service.dart';
import '../../../services/sync_engine.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final voucherStatsAsync = hospitalId == null
        ? null
        : ref.watch(voucherStatsProvider(hospitalId));
    final metricsAsync = hospitalId == null || hospitalId.isEmpty
        ? null
        : ref.watch(dashboardMetricsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('MediFlux Dashboard'),
        actions: [
          const AppRefreshButton(),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => context.push('/notifications'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: AppPageScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSyncStatusCard(context, ref),
            const SizedBox(height: 16),
            _buildQuickActions(context),
            const SizedBox(height: 24),
            _buildStatisticsCards(context, metricsAsync),
            const SizedBox(height: 24),
            _buildExpenseCards(context, voucherStatsAsync),
            const SizedBox(height: 24),
            _buildModuleGrid(context),
          ],
        ),
      ),
    );
  }

  /// Sync Status indicator — single coordinator ka live, honest status.
  ///
  /// "Up to date" (green) is only shown when a pull verified cloud freshness;
  /// an offline device with zero pending records stays red/neutral instead of
  /// claiming "all data is up to date".
  Widget _buildSyncStatusCard(BuildContext context, WidgetRef ref) {
    final info = ref.watch(syncEngineStatusProvider);
    final theme = Theme.of(context);

    final (
      IconData icon,
      Color color,
      String label,
      String subtitle,
    ) = switch (info.health) {
      SyncHealth.upToDate => (
        Icons.cloud_done_outlined,
        Colors.green,
        'Up to date',
        info.lastReconciliationAt == null
            ? 'Incremental sync caught up'
            : 'Reconciled ${_shortTime(info.lastReconciliationAt!)}',
      ),
      SyncHealth.syncing => (
        Icons.sync,
        Colors.blue,
        'Syncing',
        info.pendingUploadCount > 0
            ? '${info.pendingUploadCount} pending'
            : 'Contacting server',
      ),
      SyncHealth.downloading => (
        Icons.cloud_download_outlined,
        Colors.blue,
        'Downloading',
        info.reconciliationComplete
            ? 'Fetching baseline data'
            : 'Reconciling full dataset',
      ),
      SyncHealth.awaitingUpload => (
        Icons.cloud_upload_outlined,
        Colors.orange,
        'Saved locally',
        '${info.pendingUploadCount} record(s) awaiting upload',
      ),
      SyncHealth.offline => (
        Icons.cloud_off_outlined,
        Colors.red,
        'Offline',
        'No network — changes saved locally',
      ),
      SyncHealth.cloudUnreachable => (
        Icons.cloud_off_outlined,
        Colors.red,
        'Cloud unreachable',
        'Network up, but server not responding',
      ),
      SyncHealth.syncFailed => (
        Icons.error_outline,
        Colors.red,
        'Sync failed',
        info.failureReason ?? 'Retry to continue',
      ),
      SyncHealth.conflict => (
        Icons.warning_amber_outlined,
        Colors.orange,
        'Needs attention',
        '${info.conflictCount} conflict(s) to resolve',
      ),
      SyncHealth.signInRequired => (
        Icons.lock_outline,
        Colors.orange,
        'Sign-in required',
        'Reauthenticate to resume sync',
      ),
      SyncHealth.setupRequired => (
        Icons.settings_suggest_outlined,
        Colors.orange,
        'Sync setup incomplete',
        'Server change-log migration not installed',
      ),
      SyncHealth.neutral => (
        Icons.cloud_queue_outlined,
        Colors.blueGrey,
        'Not synced yet',
        'Initial download incomplete',
      ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Sync Status: ',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (info.health == SyncHealth.syncing ||
                info.health == SyncHealth.downloading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }

  String _shortTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildQuickActions(BuildContext context) {
    final actions = [
      (
        Icons.person_add,
        'New Patient',
        () => context.push('/patients/register'),
      ),
      (Icons.people, 'Patients', () => context.push('/patients')),
      (Icons.science, 'Diagnostics', () => context.push('/diagnostics')),
      (
        Icons.account_balance_wallet,
        'Vouchers',
        () => context.push('/vouchers'),
      ),
      (Icons.verified_user, 'Compliance', () => context.push('/compliance')),
      (Icons.fingerprint, 'ABDM', () => context.push('/abha')),
      (Icons.analytics, 'Reports', () => context.push('/reports')),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick Actions',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            AppResponsiveGrid(
              itemCount: actions.length,
              minItemWidth: 96,
              childAspectRatio: 1.05,
              itemBuilder: (context, index) {
                final action = actions[index];
                return _quickActionButton(
                  context,
                  action.$1,
                  action.$2,
                  action.$3,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickActionButton(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: colorScheme.primary, size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// "Today's Overview" cards — backed by [dashboardMetricsProvider].
  ///
  /// Each card carries its own state: a spinner while loading, the real value
  /// when available, and an explicit "Unavailable" (never a fabricated zero)
  /// when the metric could not be produced. A stale value is shown with the
  /// time it was observed.
  Widget _buildStatisticsCards(
    BuildContext context,
    AsyncValue<DashboardMetrics>? metricsAsync,
  ) {
    final theme = Theme.of(context);
    final metrics = metricsAsync?.valueOrNull;
    // Spinner only on the FIRST load; a background refresh keeps the previous
    // values visible instead of flashing empty.
    final isLoading =
        metricsAsync != null && metricsAsync.isLoading && !metricsAsync.hasValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Today\'s Overview',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                theme,
                Icons.people,
                'OPD Today',
                Colors.blue,
                isLoading: isLoading,
                metric: metrics?.opdToday,
                format: _formatCount,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _metricCard(
                theme,
                Icons.local_hotel,
                'IPD Today',
                Colors.green,
                isLoading: isLoading,
                metric: metrics?.ipdToday,
                format: _formatCount,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                theme,
                Icons.bed,
                'Beds Available',
                Colors.orange,
                isLoading: isLoading,
                metric: metrics?.bedsAvailable,
                format: _formatCount,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _metricCard(
                theme,
                Icons.currency_rupee,
                // "Collections" (money actually received today from the
                // unified payment ledger), not billed charges — so the label
                // never implies total billed revenue.
                'Collections Today',
                Colors.purple,
                isLoading: isLoading,
                metric: metrics?.collectionsToday,
                format: (value) => _formatCurrency(value.toDouble()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatCount(num value) => value.round().toString();

  /// One overview card whose value area reflects the metric's real state.
  Widget _metricCard(
    ThemeData theme,
    IconData icon,
    String label,
    Color color, {
    required bool isLoading,
    required MetricValue? metric,
    required String Function(num value) format,
  }) {
    final Widget valueChild;
    if (isLoading) {
      valueChild = const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (metric == null || !metric.isAvailable) {
      valueChild = Text(
        'Unavailable',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.error,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      valueChild = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            format(metric.value!),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (metric.isStale && metric.asOf != null)
            Text(
              'as of ${_shortTime(metric.asOf!)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            valueChild,
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildExpenseCards(
    BuildContext context,
    AsyncValue<Map<String, dynamic>>? statsAsync,
  ) {
    final theme = Theme.of(context);

    String valueOrPlaceholder(String key, String fallback) {
      if (statsAsync == null) return fallback;
      return statsAsync.maybeWhen(
        data: (stats) => _formatCurrency(_toDouble(stats[key])),
        orElse: () => '—',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Expenses',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _statCard(
                theme,
                Icons.money_off,
                "Today's Expenses",
                valueOrPlaceholder('today_total', '₹0'),
                Colors.deepOrange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statCard(
                theme,
                Icons.account_balance_wallet,
                'This Month Expenses',
                valueOrPlaceholder('month_total', '₹0'),
                Colors.brown,
              ),
            ),
          ],
        ),
      ],
    );
  }

  double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  String _formatCurrency(double value) =>
      NumberFormat.currency(locale: 'en_IN', symbol: '₹').format(value);

  Widget _statCard(
    ThemeData theme,
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleGrid(BuildContext context) {
    // Main dashboard module cards in the required display order.
    // These are display labels only; each card keeps its existing route.
    final modules = [
      {
        'icon': Icons.dashboard_outlined,
        'label': 'Dashboard',
        'route': '/dashboard',
        'color': Colors.blueGrey,
      },
      {
        'icon': Icons.medical_services,
        'label': 'OPD',
        'route': '/opd',
        'color': Colors.green,
      },
      {
        'icon': Icons.local_hotel,
        'label': 'IPD',
        'route': '/ipd/queue',
        'color': Colors.orange,
      },
      {
        'icon': Icons.biotech,
        'label': 'ABHA',
        'route': '/abha',
        'color': Colors.teal,
      },
      {
        'icon': Icons.local_hotel_outlined,
        'label': 'Ward',
        'route': '/ipd/wards',
        'color': Colors.cyan,
      },
      {
        'icon': Icons.people,
        'label': 'Patients',
        'route': '/patients',
        'color': Colors.blue,
      },
      {
        'icon': Icons.science,
        'label': 'Diagnostics',
        'route': '/diagnostics',
        'color': Colors.purple,
      },
      {
        'icon': Icons.local_pharmacy,
        'label': 'Pharmacy',
        'route': '/pharmacy',
        'color': Colors.red,
      },
      {
        'icon': Icons.receipt,
        'label': 'Billing',
        'route': '/billing',
        'color': Colors.indigo,
      },
      {
        'icon': Icons.account_balance_wallet,
        'label': 'Voucher/Expense',
        'route': '/vouchers',
        'color': Colors.deepOrange,
      },
      {
        'icon': Icons.badge_outlined,
        'label': 'Employees',
        'route': '/employees',
        'color': Colors.indigo,
      },
      {
        'icon': Icons.campaign,
        'label': 'PRO/Referrals',
        'route': '/marketing',
        'color': Colors.pink,
      },
      {
        'icon': Icons.verified_user,
        'label': 'Compliance',
        'route': '/compliance',
        'color': Colors.teal,
      },
      {
        'icon': Icons.chat,
        'label': 'WhatsApp',
        'route': '/whatsapp',
        'color': Colors.green,
      },
      {
        'icon': Icons.analytics,
        'label': 'Reports',
        'route': '/reports',
        'color': Colors.brown,
      },
      {
        'icon': Icons.settings_outlined,
        'label': 'Settings',
        'route': '/settings',
        'color': Colors.blueGrey,
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Modules',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = _moduleColumnCount(constraints.maxWidth);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.92,
              ),
              itemCount: modules.length,
              itemBuilder: (context, index) {
                final module = modules[index];
                return _moduleCard(
                  context,
                  module['icon'] as IconData,
                  module['label'] as String,
                  module['color'] as Color,
                  () => context.push(module['route'] as String),
                );
              },
            );
          },
        ),
      ],
    );
  }

  /// Picks the module grid column count from the available width so the
  /// 16 cards wrap into balanced rows without horizontal scrolling:
  /// 8-8, 6-6-4, 4-4-4-4 or 2 columns on phones.
  int _moduleColumnCount(double availableWidth) {
    const spacing = 12.0;
    const minCardWidth = 150.0;
    for (final count in const [8, 6, 4, 2]) {
      final needed = count * minCardWidth + (count - 1) * spacing;
      if (availableWidth >= needed) return count;
    }
    return 2;
  }

  Widget _moduleCard(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
