import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/sync_engine.dart';

/// Live sync-health banner shown on the dashboard.
///
/// It watches [syncEngineStatusProvider], so every [SyncEngine] status change
/// (in-progress, verified pull, reconciliation failure, offline…) rebuilds the
/// banner immediately — no manual refresh of the widget required.
///
/// "Up to date" (green) is only shown when a pull verified cloud freshness AND
/// the full reconciliation completed; an offline device with zero pending
/// records stays red/neutral instead of claiming "all data is up to date".
class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

  static String _shortTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
