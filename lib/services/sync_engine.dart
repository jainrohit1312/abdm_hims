import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/utils/logger.dart';
import 'database_service.dart';
import 'local_db.dart';
import 'outbox.dart';

/// Coarse health of the sync engine, mapped to the dashboard indicator.
///
///   * [neutral]          — initial setup / baseline download incomplete.
///   * [downloading]      — baseline/bootstrap download in progress.
///   * [syncing]          — a sync pass is currently running.
///   * [upToDate]         — green: cloud freshness verified + nothing pending.
///   * [awaitingUpload]   — amber: records saved locally, awaiting upload.
///   * [offline]          — red: no network connection.
///   * [cloudUnreachable] — red: network up but Supabase unreachable.
///   * [syncFailed]       — red: a sync pass failed for another reason.
///   * [conflict]         — attention: one or more unresolved conflicts.
///   * [signInRequired]   — attention: reauthentication needed.
///   * [setupRequired]    — attention: server-side change-log migration absent.
enum SyncHealth {
  neutral,
  downloading,
  syncing,
  upToDate,
  awaitingUpload,
  offline,
  cloudUnreachable,
  syncFailed,
  conflict,
  signInRequired,
  setupRequired,
}

/// Snapshot of the sync engine's current state, used by the dashboard.
class SyncStatusInfo {
  const SyncStatusInfo({
    required this.health,
    this.lastSyncedAt,
    this.pendingUploadCount = 0,
    this.conflictCount = 0,
    this.failureReason,
    this.pullVerified = false,
    this.deviceId = '',
    this.lastReconciliationAt,
    this.reconciliationComplete = false,
  });

  final SyncHealth health;
  final DateTime? lastSyncedAt;
  final int pendingUploadCount;
  final int conflictCount;
  final String? failureReason;

  /// True only after a successful upload acknowledgement AND a successful
  /// incremental pull catch-up with no unresolved conflicts/errors. This is
  /// NOT a lossless guarantee — see [reconciliationComplete].
  final bool pullVerified;

  /// True after the last full dataset reconciliation completed. Reconciliation
  /// is the eventual-consistency guarantee that recovers any change the
  /// incremental cursor could miss (e.g. a very late-committing transaction).
  final bool reconciliationComplete;

  /// When the last reconciliation pass finished (null = never).
  final DateTime? lastReconciliationAt;

  final String deviceId;

  bool get isGreen => health == SyncHealth.upToDate;
  bool get isBlue =>
      health == SyncHealth.syncing || health == SyncHealth.downloading;
  bool get isAmber => health == SyncHealth.awaitingUpload;
  bool get isRed =>
      health == SyncHealth.offline ||
      health == SyncHealth.cloudUnreachable ||
      health == SyncHealth.syncFailed;
  bool get isAttention =>
      health == SyncHealth.conflict ||
      health == SyncHealth.signInRequired ||
      health == SyncHealth.setupRequired;
  bool get isNeutral => health == SyncHealth.neutral;

  @override
  String toString() =>
      'SyncStatusInfo($health, pending=$pendingUploadCount, '
      'conflicts=$conflictCount, pullVerified=$pullVerified, '
      'lastSyncedAt=$lastSyncedAt, failure=$failureReason)';
}

/// Single coordinated sync engine.
///
/// Replaces the previous two-service setup (`SyncService` + `BackgroundSyncService`)
/// with one timer and one queue. Screens no longer start their own timers, and
/// closing a screen never cancels a module's pending sync.
class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required this.dbService,
    required this.localDb,
    this.interval = const Duration(seconds: 30),
    this.reconcileInterval = const Duration(minutes: 10),
    this.batchSize = 50,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DatabaseService dbService;
  final LocalDatabase localDb;
  final Duration interval;
  final Duration reconcileInterval;
  final int batchSize;
  final DateTime Function() _now;

  Timer? _timer;
  Timer? _reconcileTimer;
  bool _disposed = false;
  bool _isSyncing = false;
  bool _isReconciling = false;

  SyncStatusInfo _status = const SyncStatusInfo(health: SyncHealth.neutral);

  SyncStatusInfo get status => _status;
  SyncHealth get health => _status.health;

  /// Starts the incremental sync timer and the separate reconciliation timer.
  /// Safe to call multiple times.
  void start() {
    if (_timer == null && !_disposed) {
      _timer = Timer.periodic(interval, (_) => syncNow());
      Future.delayed(const Duration(seconds: 3), () {
        if (!_disposed) syncNow();
      });
    }
    if (_reconcileTimer == null && !_disposed) {
      _reconcileTimer = Timer.periodic(
        reconcileInterval,
        (_) => reconcileNow(),
      );
      // First reconciliation shortly after startup (background, bounded).
      Future.delayed(const Duration(seconds: 5), () {
        if (!_disposed) reconcileNow();
      });
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
  }

  /// One bounded reconciliation pass (paginated full scan of the authorized
  /// OPD datasets, independent of the incremental cursor).
  Future<void> reconcileNow() async {
    if (_isReconciling || _disposed) return;
    _isReconciling = true;
    try {
      final complete = await dbService.reconcileAll();
      if (_disposed) return;
      _status = _status.copyWith(
        reconciliationComplete: complete,
        lastReconciliationAt: complete ? _now() : _status.lastReconciliationAt,
      );
      notifyListeners();
    } catch (e) {
      AppLogger.w('Reconciliation pass failed: $e');
    } finally {
      _isReconciling = false;
    }
  }

  Future<void> refreshStatus() async {
    if (_disposed) return;
    await _recomputeStatus();
  }

  /// One full sync pass: upload due outbox entries, then pull fresh data.
  /// Overlapping calls are ignored.
  Future<void> syncNow() async {
    if (_isSyncing || _disposed) return;

    _isSyncing = true;
    _setStatus(_status.copyWith(health: SyncHealth.syncing));
    try {
      final online = await dbService.probeSupabase();
      if (!online) {
        _setStatus(
          _status.copyWith(
            health: await dbService.hasNetwork()
                ? SyncHealth.cloudUnreachable
                : SyncHealth.offline,
          ),
        );
        return;
      }

      await _uploadDueOutbox();
      final pullOutcome = await _pullChangedData();

      if (_disposed) return;

      // Recompute pending/conflict counts for an honest status.
      final pending = await localDb.outboxPendingCount();
      final conflicts = await localDb.getConflicts();
      final now = _now();

      SyncHealth health;
      if (pullOutcome == PullOutcome.setupIncomplete) {
        // Server-side change-log migration absent: limited mode, not "current".
        health = SyncHealth.setupRequired;
      } else if (conflicts.isNotEmpty) {
        health = SyncHealth.conflict;
      } else if (pending > 0) {
        health = SyncHealth.awaitingUpload;
      } else if (pullOutcome == PullOutcome.complete &&
          _status.reconciliationComplete) {
        // Green only after incremental catch-up AND a completed full
        // reconciliation — never on incremental alone.
        health = SyncHealth.upToDate;
      } else if (pullOutcome == PullOutcome.complete) {
        health = SyncHealth.downloading;
      } else {
        health = SyncHealth.awaitingUpload;
      }

      final pullVerified =
          pullOutcome == PullOutcome.complete &&
          pending == 0 &&
          conflicts.isEmpty;

      _setStatus(
        _status.copyWith(
          health: health,
          lastSyncedAt: now,
          pendingUploadCount: pending,
          conflictCount: conflicts.length,
          pullVerified: pullVerified,
          deviceId: _status.deviceId,
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Sync pass failed', e, stack);
      _setStatus(
        _status.copyWith(
          health: SyncHealth.syncFailed,
          failureReason: e.toString(),
        ),
      );
    } finally {
      _isSyncing = false;
    }
  }

  /// Uploads every due outbox entry. One bad entry never blocks the queue.
  Future<int> _uploadDueOutbox() async {
    var acknowledged = 0;
    final due = await localDb.getDueOutbox(limit: batchSize);
    for (final entry in due) {
      if (_disposed) break;
      try {
        final result = await dbService.syncOutboxEntry(entry);
        switch (result) {
          case OutboxUploadResult.acknowledged:
          case OutboxUploadResult.alreadyCommitted:
            // The outbox acknowledgement and the covered local rows are marked
            // synced together, so a verified cloud commit never leaves the row
            // looking "pending" (which would block online-only workflows).
            await localDb.markOutboxSynced(
              entry.operationId,
              syncedRecords: dbService.acknowledgedLocalRecords(entry),
            );
            acknowledged++;
          case OutboxUploadResult.conflict:
            await localDb.markOutboxConflict(entry.operationId);
          case OutboxUploadResult.rejected:
            // Non-retryable: leave rejected so it is never retried blindly.
            await localDb.markOutboxRejected(
              entry.operationId,
              'Server rejected the operation',
            );
          case OutboxUploadResult.retryableFailure:
            await localDb.markOutboxFailed(
              entry.operationId,
              'Transient upload failure',
              _backoffRetryAt(entry.attemptCount),
            );
        }
      } catch (e) {
        // Independent-record isolation: record the failure and move on.
        await localDb.markOutboxFailed(
          entry.operationId,
          e.toString(),
          _backoffRetryAt(entry.attemptCount),
        );
      }
    }
    return acknowledged;
  }

  /// Pulls changed data from the server change-log via [DatabaseService.pullChanges].
  Future<PullOutcome> _pullChangedData() async {
    if (_disposed) return PullOutcome.failed;
    return dbService.pullChanges();
  }

  DateTime _backoffRetryAt(int attemptCount) {
    // Exponential backoff with full jitter, capped at ~5 minutes.
    final base = math.min(300, math.pow(2, attemptCount).toDouble()).toInt();
    final jitter = math.Random().nextInt(base + 1);
    return _now().add(Duration(seconds: base + jitter));
  }

  Future<void> _recomputeStatus() async {
    final pending = await localDb.outboxPendingCount();
    final conflicts = await localDb.getConflicts();
    _setStatus(
      _status.copyWith(
        pendingUploadCount: pending,
        conflictCount: conflicts.length,
      ),
    );
  }

  void _setStatus(SyncStatusInfo next) {
    if (_disposed) return;
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

extension on SyncStatusInfo {
  SyncStatusInfo copyWith({
    SyncHealth? health,
    DateTime? lastSyncedAt,
    int? pendingUploadCount,
    int? conflictCount,
    String? failureReason,
    bool? pullVerified,
    String? deviceId,
    DateTime? lastReconciliationAt,
    bool? reconciliationComplete,
  }) {
    return SyncStatusInfo(
      health: health ?? this.health,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      pendingUploadCount: pendingUploadCount ?? this.pendingUploadCount,
      conflictCount: conflictCount ?? this.conflictCount,
      failureReason: failureReason ?? this.failureReason,
      pullVerified: pullVerified ?? this.pullVerified,
      deviceId: deviceId ?? this.deviceId,
      lastReconciliationAt: lastReconciliationAt ?? this.lastReconciliationAt,
      reconciliationComplete:
          reconciliationComplete ?? this.reconciliationComplete,
    );
  }
}
