import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../core/utils/logger.dart';
import 'database_service.dart';
import 'local_db.dart';

/// Dashboard "Sync Status" indicator ke states.
///
/// * [idle]     — service start hua hai lekin abhi tak koi pass complete nahi.
/// * [syncing]  — ek sync pass abhi chal raha hai.
/// * [synced]   — saare local records Supabase tak upload ho chuke hain.
/// * [pending]  — kuch records abhi bhi local queue mein waiting hain.
/// * [offline]  — device ka network nahi hai; wapas online hote hi retry hoga.
enum SyncStatus { idle, syncing, synced, pending, offline }

/// Background Sync Service.
///
/// * Har [defaultInterval] (30 seconds) par [syncPendingData] chalta hai.
/// * [syncPendingData] actual Supabase insert / conflict logic
///   [DatabaseService.syncPendingData] ko delegate karta hai.
/// * Har successful sync ke baad [refreshPendingCount] local DB se pending
///   count dobara padhta hai — jab count 0 ho jata hai tab [isSynced] `true`
///   ho jata hai (Dashboard par "Synced" dikhta hai).
///
/// NOTE: `sync_service.dart` iske puraane naam ki compatibility ke liye
/// rakha gaya hai; naya code [BackgroundSyncService] use kare.
class BackgroundSyncService extends ChangeNotifier {
  BackgroundSyncService({required this.dbService, required this.localDb});

  /// Har kitne second mein sync attempt karna hai (spec: 30 seconds).
  static const Duration defaultInterval = Duration(seconds: 30);

  final DatabaseService dbService;
  final LocalDatabase localDb;

  Timer? _timer;
  bool _isSyncing = false;
  bool _disposed = false;
  bool _isOnline = true;
  int _pendingCount = 0;
  DateTime? _lastSyncedAt;
  String? _lastError;

  /// Shared connectivity probe — one `Connectivity()` instance reused for every
  /// 30-second tick instead of constructing a new plugin object per pass.
  final Connectivity _connectivity = Connectivity();

  /// Last values broadcast to listeners. The dashboard watches only
  /// [syncStatus] and [pendingCount], so a no-op pass (still synced, still 0
  /// pending) doesn't trigger any widget rebuilds.
  SyncStatus? _lastNotifiedStatus;
  int? _lastNotifiedPendingCount;

  /// Records currently waiting in the local database.
  int get pendingCount => _pendingCount;

  /// True while a sync pass is running.
  bool get isSyncing => _isSyncing;

  /// True jab saare local records Supabase tak sync ho chuke hain.
  bool get isSynced => !_isSyncing && _pendingCount == 0;

  /// True jab kuch records abhi bhi pending hain.
  bool get hasPending => _pendingCount > 0;

  /// Last successful sync ka timestamp (null = abhi tak koi sync nahi hua).
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// Last failed sync pass ka error message (null = koi error nahi).
  String? get lastError => _lastError;

  /// Current dashboard sync status.
  SyncStatus get syncStatus {
    if (_isSyncing) return SyncStatus.syncing;
    if (!_isOnline) return SyncStatus.offline;
    return _pendingCount == 0 ? SyncStatus.synced : SyncStatus.pending;
  }

  /// Starts the periodic sync timer. Safe to call multiple times — a second
  /// call is ignored while a timer is already active.
  void start({Duration interval = defaultInterval}) {
    if (_timer != null || _disposed) return;

    _timer = Timer.periodic(interval, (_) => syncPendingData());

    // Startup ke turant baad ek pass chala do taaki offline save kiye gaye
    // records ko full interval ka wait na karna pade.
    Future.delayed(const Duration(seconds: 3), () {
      if (!_disposed) syncPendingData();
    });
  }

  /// Stops the periodic timer (does not close the local database).
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
  ///
  /// Returns the number of records successfully uploaded in this pass.
  Future<int> syncPendingData() async {
    if (_isSyncing || _disposed) return 0;

    _isSyncing = true;
    _lastError = null;
    _notify();
    try {
      _isOnline = await _checkOnline();

      var synced = 0;
      if (_isOnline) {
        synced = await dbService.syncPendingData();
        if (synced > 0) {
          _lastSyncedAt = DateTime.now();
        }
      }

      await refreshPendingCount();
      return synced;
    } catch (e) {
      _lastError = e.toString();
      AppLogger.e('Background sync pass failed', e);
      return 0;
    } finally {
      _isSyncing = false;
      _notify();
    }
  }

  /// True jab usable network connection available ho.
  Future<bool> _checkOnline() async {
    try {
      final result = await _connectivity.checkConnectivity();
      return result != ConnectivityResult.none;
    } catch (_) {
      // Fail open — connectivity probe fail hone par sync block nahi hona
      // chahiye (actual Supabase call hi final decision lega).
      return true;
    }
  }

  /// Notifies listeners only when the dashboard-visible state (status or
  /// pending count) actually changed. Idle 30-second passes with nothing to
  /// sync therefore no longer rebuild the header/dashboard.
  void _notify() {
    if (_disposed) return;
    final status = syncStatus;
    final pending = _pendingCount;
    if (status == _lastNotifiedStatus && pending == _lastNotifiedPendingCount) {
      return;
    }
    _lastNotifiedStatus = status;
    _lastNotifiedPendingCount = pending;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
