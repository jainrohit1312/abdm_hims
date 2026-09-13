import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/utils/logger.dart';

/// Global AppBar refresh button — har screen ke `AppBar` ke `actions` mein
/// lagao.
///
/// Tap karne par:
/// 1. Visible data **turant** refresh hota hai (metric cards, lists, beds,
///    voucher stats) taaki tap ka response immediate ho — poora sync isko
///    block nahi karta.
/// 2. Ek coordinated sync pass chalta hai ([SyncEngine.refreshNow]):
///    connectivity probe, outbox upload, change-log pull aur (zaroori ho to)
///    full reconciliation.
/// 3. Sync attempt ke baad data **dobara** refresh hota hai taaki values me
///    pulled changes shaamil ho jaayein.
///
/// [onRefresh] ek screen-specific callback hai (jaise `setState` ya extra
/// provider invalidations) jo sync ke baad chalta hai.
///
/// Manual refresh ke dauraan button disabled rehta hai aur ek spinner dikhata
/// hai — repeated taps ek se zyada sync start nahi karte, aur metric cards ke
/// apne loading indicators waise hi chalte rehte hain.
class AppRefreshButton extends ConsumerStatefulWidget {
  const AppRefreshButton({super.key, this.onRefresh, this.iconSize = 28});

  /// Screen-specific re-load (e.g. `setState`, local list re-fetch).
  final VoidCallback? onRefresh;

  /// Button icon size — user ko clearly dikhne ke liye default 28 rakha hai.
  final double iconSize;

  @override
  ConsumerState<AppRefreshButton> createState() => _AppRefreshButtonState();
}

class _AppRefreshButtonState extends ConsumerState<AppRefreshButton> {
  bool _isRefreshing = false;

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);

    // 1. Refresh the visible data immediately so the metric cards respond to
    //    the tap right away. The full sync — including a potentially long
    //    reconciliation — must never gate this.
    _refreshLocalData();

    try {
      // 2. One coordinated sync pass: probe + upload + pull + reconciliation.
      await ref.read(syncEngineProvider).refreshNow();
    } catch (e, stack) {
      // The engine already publishes an honest failure status; never let a
      // sync error skip the post-sync data refresh below.
      AppLogger.e('Manual refresh failed', e, stack);
    } finally {
      if (mounted) {
        // 3. Refresh again so values include anything the sync just pulled.
        _refreshLocalData();
        widget.onRefresh?.call();
        setState(() => _isRefreshing = false);
      }
    }
  }

  void _refreshLocalData() {
    ref.invalidate(patientListProvider);
    ref.invalidate(opdQueueProvider);

    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId != null && hospitalId.isNotEmpty) {
      ref.invalidate(hospitalBedsProvider(hospitalId));
      ref.invalidate(voucherStatsProvider(hospitalId));
    }

    // Dashboard "Today's Overview" cards (single shared refresh tick).
    refreshDashboardMetrics(ref);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IconButton(
      tooltip: _isRefreshing ? 'Syncing…' : 'Refresh',
      iconSize: widget.iconSize,
      onPressed: _isRefreshing ? null : _handleRefresh,
      style: IconButton.styleFrom(
        backgroundColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.55,
        ),
        foregroundColor: theme.colorScheme.onPrimaryContainer,
        shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.35),
        elevation: 2,
        disabledBackgroundColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.35,
        ),
        disabledForegroundColor: theme.colorScheme.onPrimaryContainer
            .withValues(alpha: 0.6),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.all(10),
      ),
      icon: _isRefreshing
          ? SizedBox(
              width: widget.iconSize * 0.72,
              height: widget.iconSize * 0.72,
              child: const CircularProgressIndicator(strokeWidth: 2.5),
            )
          : const Icon(Icons.refresh),
    );
  }
}
