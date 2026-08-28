import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Global AppBar refresh button — har screen ke `AppBar` ke `actions` mein
/// lagao.
///
/// Tap karne par ye core data providers invalidate karta hai taaki screens
/// apna data dobara fetch karein:
/// * [patientListProvider]
/// * [opdQueueProvider]
/// * [hospitalBedsProvider] (beds)
/// * [voucherStatsProvider] (dashboard stats)
///
/// [onRefresh] ek screen-specific callback hai (jaise `setState` ya extra
/// provider invalidations) jo in core invalidations ke turant baad chalta hai.
class AppRefreshButton extends ConsumerWidget {
  const AppRefreshButton({super.key, this.onRefresh, this.iconSize = 28});

  /// Screen-specific re-load (e.g. `setState`, local list re-fetch).
  final VoidCallback? onRefresh;

  /// Button icon size — user ko clearly dikhne ke liye default 28 rakha hai.
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return IconButton(
      tooltip: 'Refresh',
      iconSize: iconSize,
      style: IconButton.styleFrom(
        backgroundColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.55,
        ),
        foregroundColor: theme.colorScheme.onPrimaryContainer,
        shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.35),
        elevation: 2,
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(10),
      ),
      onPressed: () => _handleRefresh(ref),
      icon: const Icon(Icons.refresh),
    );
  }

  void _handleRefresh(WidgetRef ref) {
    // Core data providers invalidate karo — inke watchers dobara fetch
    // karenge (StateNotifier providers recreate hokar pehla page load karte
    // hain, FutureProviders fresh data fetch karte hain).
    ref.invalidate(patientListProvider);
    ref.invalidate(opdQueueProvider);

    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId != null && hospitalId.isNotEmpty) {
      ref.invalidate(hospitalBedsProvider(hospitalId));
      ref.invalidate(voucherStatsProvider(hospitalId));
    }

    // Screen-specific refresh (e.g. `setState` ya extra invalidations).
    onRefresh?.call();
  }
}
