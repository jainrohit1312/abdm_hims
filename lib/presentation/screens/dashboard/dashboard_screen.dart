import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';
import '../../../services/background_sync.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final voucherStatsAsync = hospitalId == null
        ? null
        : ref.watch(voucherStatsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('HIMS Dashboard'),
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSyncStatusCard(context, ref),
            const SizedBox(height: 16),
            _buildQuickActions(context),
            const SizedBox(height: 24),
            _buildStatisticsCards(context),
            const SizedBox(height: 24),
            _buildExpenseCards(context, voucherStatsAsync),
            const SizedBox(height: 24),
            _buildModuleGrid(context),
          ],
        ),
      ),
    );
  }

  /// Sync Status indicator — Background Sync Service ka live status dikhata
  /// hai (Synced / Pending / Syncing / Offline).
  Widget _buildSyncStatusCard(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final pendingCount = ref.watch(pendingSyncCountProvider);
    final theme = Theme.of(context);

    final (
      IconData icon,
      Color color,
      String label,
      String subtitle,
    ) = switch (status) {
      SyncStatus.synced => (
        Icons.cloud_done_outlined,
        Colors.green,
        'Synced',
        'All data is up to date',
      ),
      SyncStatus.pending => (
        Icons.cloud_upload_outlined,
        Colors.orange,
        'Pending',
        '$pendingCount record(s) waiting to sync',
      ),
      SyncStatus.syncing => (
        Icons.sync,
        Colors.blue,
        'Syncing...',
        'Uploading local data to server',
      ),
      SyncStatus.offline => (
        Icons.cloud_off_outlined,
        Colors.grey,
        'Offline',
        'Sync will resume when online',
      ),
      SyncStatus.idle => (
        Icons.cloud_queue_outlined,
        Colors.blueGrey,
        'Ready',
        'Background sync starting...',
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
            if (status == SyncStatus.syncing)
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

  Widget _buildQuickActions(BuildContext context) {
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _quickActionButton(
                  context,
                  Icons.person_add,
                  'New Patient',
                  () => context.push('/patients/register'),
                ),
                _quickActionButton(
                  context,
                  Icons.calendar_today,
                  'OPD Visit',
                  () => context.push('/opd/register'),
                ),
                _quickActionButton(
                  context,
                  Icons.local_hotel,
                  'Admit IPD',
                  () => context.push('/ipd/admit'),
                ),
                _quickActionButton(
                  context,
                  Icons.receipt_long,
                  'Billing',
                  () => context.push('/billing'),
                ),
              ],
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatisticsCards(BuildContext context) {
    final theme = Theme.of(context);
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
              child: _statCard(
                theme,
                Icons.people,
                'OPD Today',
                '0',
                Colors.blue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statCard(
                theme,
                Icons.local_hotel,
                'IPD Today',
                '0',
                Colors.green,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _statCard(
                theme,
                Icons.bed,
                'Beds Available',
                '0',
                Colors.orange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statCard(
                theme,
                Icons.currency_rupee,
                'Revenue Today',
                '₹0',
                Colors.purple,
              ),
            ),
          ],
        ),
      ],
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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleGrid(BuildContext context) {
    final modules = [
      {
        'icon': Icons.people,
        'label': 'Patients',
        'route': '/patients',
        'color': Colors.blue,
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
        'icon': Icons.chat,
        'label': 'WhatsApp',
        'route': '/whatsapp',
        'color': Colors.green,
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
        'label': 'Vouchers',
        'route': '/vouchers',
        'color': Colors.deepOrange,
      },
      {
        'icon': Icons.verified_user,
        'label': 'Compliance',
        'route': '/compliance',
        'color': Colors.teal,
      },
      {
        'icon': Icons.analytics,
        'label': 'Reports',
        'route': '/reports',
        'color': Colors.brown,
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
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            childAspectRatio: 0.85,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
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
        ),
      ],
    );
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
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
