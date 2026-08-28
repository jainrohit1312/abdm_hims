import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// Lab Revenue Dashboard — daily/monthly lab revenue, category-wise test
/// breakdown and pending vs completed order counts.
class LabRevenueDashboard extends ConsumerWidget {
  const LabRevenueDashboard({super.key});

  static const Map<String, String> _categoryLabels = {
    'pathology': 'Pathology',
    'radiology': 'Radiology',
    'cardiology': 'Cardiology',
    'other': 'Other',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Lab Revenue')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final statsAsync = ref.watch(diagnosticsRevenueStatsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Lab Revenue Dashboard')),
      body: statsAsync.when(
        data: (stats) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(diagnosticsRevenueStatsProvider(hospitalId));
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildRevenueCards(stats),
              const SizedBox(height: 16),
              _buildCategoryBreakdown(stats),
              const SizedBox(height: 16),
              _buildPendingVsCompleted(stats),
            ],
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to load revenue stats: $error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(
                  diagnosticsRevenueStatsProvider(hospitalId),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Daily + monthly revenue cards
  // ---------------------------------------------------------------------------
  Widget _buildRevenueCards(Map<String, dynamic> stats) {
    final daily = _toDouble(stats['daily_revenue']);
    final monthly = _toDouble(stats['monthly_revenue']);

    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Daily Lab Revenue',
            value: _formatCurrency(daily),
            icon: Icons.today_outlined,
            color: Colors.green,
            subLabel: 'Tests booked today',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'Monthly Lab Revenue',
            value: _formatCurrency(monthly),
            icon: Icons.calendar_month_outlined,
            color: Colors.indigo,
            subLabel: 'Current month collection',
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Category-wise breakdown
  // ---------------------------------------------------------------------------
  Widget _buildCategoryBreakdown(Map<String, dynamic> stats) {
    final breakdown = ((stats['category_breakdown'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    final amounts = <String, double>{};
    final counts = <String, int>{};
    var total = 0.0;

    for (final entry in breakdown) {
      final category = entry['category']?.toString() ?? 'other';
      final amount = _toDouble(entry['amount']);
      amounts[category] = amount;
      counts[category] = (entry['count'] as num?)?.toInt() ?? 0;
      total += amount;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tests Breakdown (Completed Orders)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            if (breakdown.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No completed tests yet.'),
              )
            else
              for (final category in _categoryLabels.keys) ...[
                _CategoryBar(
                  label: _categoryLabels[category] ?? category,
                  amount: amounts[category] ?? 0,
                  count: counts[category] ?? 0,
                  total: total,
                  color: _categoryColor(category),
                ),
                const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pending vs completed
  // ---------------------------------------------------------------------------
  Widget _buildPendingVsCompleted(Map<String, dynamic> stats) {
    final pending = (stats['pending_orders'] as num?)?.toInt() ?? 0;
    final completed = (stats['completed_orders'] as num?)?.toInt() ?? 0;

    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Pending Orders',
            value: '$pending',
            icon: Icons.pending_actions_outlined,
            color: Colors.orange,
            subLabel: 'Awaiting results',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'Completed Orders',
            value: '$completed',
            icon: Icons.check_circle_outline,
            color: Colors.green,
            subLabel: 'Results finalised',
          ),
        ),
      ],
    );
  }

  String _formatCurrency(double value) {
    final format = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    return format.format(value);
  }

  double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  Color _categoryColor(String category) {
    switch (category) {
      case 'pathology':
        return Colors.purple;
      case 'radiology':
        return Colors.blue;
      case 'cardiology':
        return Colors.red;
      default:
        return Colors.teal;
    }
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? subLabel;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.subLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            if (subLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                subLabel!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  final String label;
  final double amount;
  final int count;
  final double total;
  final Color color;

  const _CategoryBar({
    required this.label,
    required this.amount,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total <= 0 ? 0.0 : (amount / total).clamp(0.0, 1.0);
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              '${currency.format(amount)}  •  $count tests',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor: color.withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}
