import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/utils/logger.dart';
import 'database_service.dart';
import 'local_db.dart';

/// Result of a single [SyncService.syncPendingData] pass.
class SyncResult {
  const SyncResult({required this.synced, this.remaining = 0, this.skipped = false});

  final int synced;
  final int remaining;
  final bool skipped;

  static const SyncResult skippedResult = SyncResult(
    synced: 0,
    skipped: true,
  );
}

/// Background sync engine.
///
/// * Starts a periodic timer (default: every 30 seconds).
/// * Each tick runs [syncPendingData] which delegates the actual Supabase
///   insert / conflict logic to [DatabaseService.syncPendingData].
/// * Exposes [pendingCount] so the UI can show how many records are still
///   waiting to reach the server.
class SyncService extends ChangeNotifier {
  SyncService({required this.dbService, required this.localDb});

  final DatabaseService dbService;
  final LocalDatabase localDb;

  Timer? _timer;
  bool _isSyncing = false;
  bool _disposed = false;
  int _pendingCount = 0;

  /// Records currently waiting in the local database.
  int get pendingCount => _pendingCount;

  /// True while a sync pass is running.
  bool get isSyncing => _isSyncing;

  /// Starts the periodic sync timer. Safe to call multiple times — a second
  /// call is ignored while a timer is already active.
  void start({Duration interval = const Duration(seconds: 30)}) {
    if (_timer != null || _disposed) return;

    _timer = Timer.periodic(interval, (_) => syncPendingData());

    // Kick off one pass shortly after startup so records saved while offline
    // don't have to wait a full interval.
    Future.delayed(const Duration(seconds: 3), () {
      if (!_disposed) syncPendingData();
    });
  }

  /// Stops the periodic timer (does not close the database).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-reads [pendingCount] from the local database and notifies listeners.
  Future<void> refreshPendingCount() async {
    if (_disposed) return;
    try {
      _pendingCount = await localDb.pendingCount();
      _notify();
    } catch (e) {
      AppLogger.e('Could not read pending sync count', e);
    }
  }

  /// One sync pass. Overlapping calls are ignored.
  Future<SyncResult> syncPendingData() async {
    if (_isSyncing || _disposed) return SyncResult.skippedResult;

    _isSyncing = true;
    _notify();
    try {
      final synced = await dbService.syncPendingData();
      await refreshPendingCount();
      return SyncResult(synced: synced, remaining: _pendingCount);
    } catch (e) {
      AppLogger.e('Sync pass failed', e);
      return const SyncResult(synced: 0, skipped: true);
    } finally {
      _isSyncing = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
