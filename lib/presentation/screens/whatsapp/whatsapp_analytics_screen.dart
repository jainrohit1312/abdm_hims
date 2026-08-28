import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/whatsapp_providers.dart';
import '../../../models/whatsapp_models.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp Analytics Screen (`/whatsapp`)
/// ---------------------------------------------------------------------------
/// Module dashboard: message funnel (sent → delivered → read), delivery/read
/// rates, opt-in/opt-out counts and quick links into the other WhatsApp
/// screens.
/// ---------------------------------------------------------------------------
class WhatsappAnalyticsScreen extends ConsumerWidget {
  const WhatsappAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('WhatsApp Marketing'),
        actions: [
          AppRefreshButton(
            onRefresh: () {
              if (hospitalId != null && hospitalId.isNotEmpty) {
                invalidateWhatsappProviders(ref, hospitalId: hospitalId);
              }
            },
          ),
        ],
      ),
      body: hospitalId == null
          ? const Center(child: Text('Hospital not assigned to this user.'))
          : ref
                .watch(whatsappAnalyticsProvider(hospitalId))
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to load analytics: $error'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => ref.invalidate(
                            whatsappAnalyticsProvider(hospitalId),
                          ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (stats) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildQuickLinks(context),
                      const SizedBox(height: 16),
                      _buildFunnel(context, stats),
                      const SizedBox(height: 16),
                      _buildRateCards(context, stats),
                      const SizedBox(height: 16),
                      _buildAudienceCards(context, stats),
                      const SizedBox(height: 16),
                      _buildRecentCampaigns(context, ref, hospitalId),
                    ],
                  ),
                ),
    );
  }

  Widget _buildQuickLinks(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _linkCard(
            context,
            Icons.campaign_outlined,
            'Campaigns',
            '/whatsapp/campaigns',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _linkCard(
            context,
            Icons.message_outlined,
            'Templates',
            '/whatsapp/templates',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _linkCard(
            context,
            Icons.settings_outlined,
            'Settings',
            '/whatsapp/settings',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _linkCard(
            context,
            Icons.block_outlined,
            'Opt-outs',
            '/whatsapp/opt-outs',
          ),
        ),
      ],
    );
  }

  Widget _linkCard(
    BuildContext context,
    IconData icon,
    String label,
    String route,
  ) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => context.push(route),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFunnel(BuildContext context, WhatsappAnalytics stats) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Message Funnel',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _funnelStat(
                  context,
                  'Sent',
                  stats.sent,
                  theme.colorScheme.primary,
                ),
                _funnelArrow(context),
                _funnelStat(context, 'Delivered', stats.delivered, Colors.teal),
                _funnelArrow(context),
                _funnelStat(context, 'Read', stats.read, Colors.green),
                _funnelArrow(context),
                _funnelStat(
                  context,
                  'Failed',
                  stats.failed,
                  theme.colorScheme.error,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _funnelStat(
    BuildContext context,
    String label,
    int value,
    Color color,
  ) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _funnelArrow(BuildContext context) {
    return Icon(
      Icons.arrow_forward,
      size: 16,
      color: Theme.of(context).colorScheme.outline,
    );
  }

  Widget _buildRateCards(BuildContext context, WhatsappAnalytics stats) {
    return Row(
      children: [
        Expanded(
          child: _rateCard(
            context,
            'Delivery Rate',
            stats.deliveryRate,
            Icons.check_circle_outline,
            Colors.teal,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _rateCard(
            context,
            'Read Rate',
            stats.readRate,
            Icons.remove_red_eye_outlined,
            Colors.green,
          ),
        ),
      ],
    );
  }

  Widget _rateCard(
    BuildContext context,
    String label,
    double rate,
    IconData icon,
    Color color,
  ) {
    final theme = Theme.of(context);
    final percent = (rate * 100).toStringAsFixed(0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '$percent%',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: rate,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudienceCards(BuildContext context, WhatsappAnalytics stats) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.people_outline, color: theme.colorScheme.primary),
                  const SizedBox(height: 8),
                  Text(
                    '${stats.optInPatients}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'Opted-in Patients',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.block, color: theme.colorScheme.error),
                  const SizedBox(height: 8),
                  Text(
                    '${stats.optOuts}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const Text('Opt-outs', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.campaign, color: Colors.indigo),
                  const SizedBox(height: 8),
                  Text(
                    '${stats.totalCampaigns}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text('Campaigns', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentCampaigns(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
  ) {
    final theme = Theme.of(context);
    final campaignsAsync = ref.watch(whatsappCampaignsProvider(hospitalId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent Campaigns',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        campaignsAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('Could not load campaigns: $e'),
          data: (campaigns) {
            if (campaigns.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No campaigns created yet.'),
                ),
              );
            }
            return Column(
              children: campaigns
                  .take(5)
                  .map(
                    (c) => Card(
                      child: ListTile(
                        leading: Icon(
                          Icons.campaign_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(c.name),
                        subtitle: Text(
                          '${c.recipients.length} recipients • '
                          '${c.sentCount} sent • ${c.failedCount} failed',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _statusChip(c.status),
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _statusChip(String status) {
    final color = switch (status.toLowerCase()) {
      'sent' => Colors.green,
      'sending' => Colors.blue,
      'scheduled' => Colors.orange,
      'failed' => Colors.red,
      'cancelled' => Colors.grey,
      _ => Colors.blueGrey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
