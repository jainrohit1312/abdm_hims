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

  /// In-flight passes. A second caller awaits the running pass instead of
  /// starting a competing one, so a timer pass and a manual refresh can never
  /// upload the same outbox entries or reconcile the same dataset twice.
  Future<void>? _syncFuture;
  Future<void>? _reconcileFuture;
  Future<void>? _refreshFuture;

  /// Bumped by [reset] so a pass that was already running when the session
  /// changed can never publish stale status afterwards.
  int _epoch = 0;

  /// Outcome of the most recent change-log pull, used to recompute health after
  /// reconciliation without repeating the pull.
  PullOutcome? _lastPullOutcome;

  /// Whether the last sync pass reached the server AND completed without a
  /// fatal error. A manual refresh only reconciles/finalizes when this is true.
  bool _lastSyncReachedServer = false;

  /// Whether the most recent reconciliation attempt failed outright.
  bool _reconciliationFailed = false;

  SyncStatusInfo _status = const SyncStatusInfo(health: SyncHealth.neutral);

  SyncStatusInfo get status => _status;
  SyncHealth get health => _status.health;

  /// Starts the incremental sync timer and the separate reconciliation timer,
  /// then kicks off one coordinated initial pass immediately so the dashboard
  /// leaves "Not synced yet" without waiting for the first timer tick.
  /// Safe to call multiple times.
  void start() {
    if (_disposed) return;
    final wasStopped = _timer == null;
    _timer ??= Timer.periodic(interval, (_) => syncNow());
    _reconcileTimer ??= Timer.periodic(
      reconcileInterval,
      (_) => reconcileNow(),
    );
    if (wasStopped) unawaited(refreshNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
  }

  /// Stops the timers and returns the visible health to neutral.
  ///
  /// Called on logout and on hospital change so the dashboard never keeps a
  /// previous session's health. Any pass already running is invalidated (its
  /// epoch no longer matches) so it cannot publish status after the reset.
  void reset() {
    if (_disposed) return;
    _epoch++;
    stop();
    _syncFuture = null;
    _reconcileFuture = null;
    _refreshFuture = null;
    _lastPullOutcome = null;
    _lastSyncReachedServer = false;
    _reconciliationFailed = false;
    _setStatus(const SyncStatusInfo(health: SyncHealth.neutral));
  }

  /// One bounded reconciliation pass (paginated full scan of the authorized
  /// OPD datasets, independent of the incremental cursor). Overlapping calls
  /// share the single running pass.
  Future<void> reconcileNow() {
    if (_disposed) return Future<void>.value();
    final existing = _reconcileFuture;
    if (existing != null) return existing;
    final future = _performReconcile();
    _reconcileFuture = future;
    future.whenComplete(() {
      if (identical(_reconcileFuture, future)) _reconcileFuture = null;
    });
    return future;
  }

  Future<void> _performReconcile() async {
    final epoch = _epoch;
    try {
      final outcomes = await dbService.reconcileAllDetailed();
      if (!_isCurrent(epoch)) return;

      final complete = outcomes.values.every(
        (o) => o == ReconcileOutcome.complete,
      );
      final failed = outcomes.values.any((o) => o == ReconcileOutcome.failed);
      _reconciliationFailed = failed;

      if (failed) {
        // Never swallow a reconciliation failure: it must be visible.
        _setStatus(
          _status.copyWith(
            reconciliationComplete: complete,
            health: SyncHealth.syncFailed,
            failureReason: 'Reconciliation failed',
          ),
        );
        return;
      }

      _status = _status.copyWith(
        reconciliationComplete: complete,
        lastReconciliationAt: complete ? _now() : _status.lastReconciliationAt,
      );
      notifyListeners();
    } catch (e, stack) {
      AppLogger.e('Reconciliation pass failed', e, stack);
      if (!_isCurrent(epoch)) return;
      _reconciliationFailed = true;
      _setStatus(
        _status.copyWith(
          health: SyncHealth.syncFailed,
          failureReason: 'Reconciliation failed: $e',
        ),
      );
    }
  }

  Future<void> refreshStatus() async {
    if (_disposed) return;
    await _recomputeStatus();
  }

  /// One full sync pass: upload due outbox entries, then pull fresh data.
  /// Overlapping calls (timer + manual refresh) share the single running pass.
  Future<void> syncNow() {
    if (_disposed) return Future<void>.value();
    final existing = _syncFuture;
    if (existing != null) return existing;
    final future = _performSync();
    _syncFuture = future;
    future.whenComplete(() {
      if (identical(_syncFuture, future)) _syncFuture = null;
    });
    return future;
  }

  Future<void> _performSync() async {
    final epoch = _epoch;
    _lastSyncReachedServer = false;
    _setStatus(
      _status.copyWith(health: SyncHealth.syncing, failureReason: null),
    );
    try {
      final online = await dbService.probeSupabase();
      if (!_isCurrent(epoch)) return;
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

      _lastSyncReachedServer = true;
      await _uploadDueOutbox();
      if (!_isCurrent(epoch)) return;
      final pullOutcome = await _pullChangedData();
      if (!_isCurrent(epoch)) return;
      _lastPullOutcome = pullOutcome;

      await _finalizeHealth(pullOutcome);
    } catch (e, stack) {
      AppLogger.e('Sync pass failed', e, stack);
      if (!_isCurrent(epoch)) return;
      // A pass that threw must not let a manual refresh finalize a success.
      _lastSyncReachedServer = false;
      _setStatus(
        _status.copyWith(
          health: SyncHealth.syncFailed,
          failureReason: e.toString(),
        ),
      );
    }
  }

  /// One coordinated manual refresh — the single entry point the UI calls.
  ///
  /// Runs one deterministic sequence (never concurrent passes):
  ///   1. publish an in-progress status immediately;
  ///   2. connectivity probe + outbox upload + change-log pull (coalesces with
  ///      any scheduled pass, so no entry is uploaded twice);
  ///   3. complete the initial/pending full reconciliation when required;
  ///   4. recompute the final, honest health after reconciliation.
  ///
  /// Overlapping manual refreshes share one running pass.
  Future<void> refreshNow() {
    if (_disposed) return Future<void>.value();
    final existing = _refreshFuture;
    if (existing != null) return existing;
    final future = _performRefresh();
    _refreshFuture = future;
    future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    return future;
  }

  Future<void> _performRefresh() async {
    final epoch = _epoch;

    // 1. Immediate, honest in-progress feedback.
    _setStatus(
      _status.copyWith(health: SyncHealth.syncing, failureReason: null),
    );

    try {
      // 2. Probe + outbox upload + change-log pull.
      await syncNow();
      if (!_isCurrent(epoch)) return;

      // Offline / cloud unreachable / setup incomplete: the sync pass already
      // published the honest red/attention status. Never reconcile against a
      // server we could not reach, and never overwrite that status.
      if (!_lastSyncReachedServer) return;

      // 3. Initial (or still-pending) reconciliation is required before the
      //    dashboard may claim "up to date".
      if (!_status.reconciliationComplete) {
        await reconcileNow();
        if (!_isCurrent(epoch)) return;
      }

      // 4. Final health, computed after reconciliation.
      await _finalizeHealth(_lastPullOutcome ?? PullOutcome.failed);
    } catch (e, stack) {
      // refreshNow() must never reject: the UI awaits it, and a thrown error
      // would otherwise skip the caller's post-sync data refresh.
      AppLogger.e('Manual refresh failed', e, stack);
      if (!_isCurrent(epoch)) return;
      _setStatus(
        _status.copyWith(
          health: SyncHealth.syncFailed,
          failureReason: e.toString(),
        ),
      );
    }
  }

  /// Recomputes the honest sync health from the last pull outcome, the
  /// pending/conflict counts and the reconciliation state.
  Future<void> _finalizeHealth(PullOutcome pullOutcome) async {
    final epoch = _epoch;
    final pending = await localDb.outboxPendingCount();
    final conflicts = await localDb.getConflicts();
    if (!_isCurrent(epoch)) return;
    final now = _now();

    SyncHealth health;
    if (pullOutcome == PullOutcome.setupIncomplete) {
      // Server-side change-log migration absent: limited mode, not "current".
      health = SyncHealth.setupRequired;
    } else if (conflicts.isNotEmpty) {
      health = SyncHealth.conflict;
    } else if (pending > 0) {
      health = SyncHealth.awaitingUpload;
    } else if (_reconciliationFailed) {
      // A failed reconciliation keeps us honestly "not up to date".
      health = SyncHealth.syncFailed;
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
        failureReason: _reconciliationFailed
            ? (_status.failureReason ?? 'Reconciliation failed')
            : null,
      ),
    );
  }

  bool _isCurrent(int epoch) => !_disposed && epoch == _epoch;

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
  static const Object _unset = Object();

  SyncStatusInfo copyWith({
    SyncHealth? health,
    DateTime? lastSyncedAt,
    int? pendingUploadCount,
    int? conflictCount,
    Object? failureReason = _unset,
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
      failureReason: identical(failureReason, _unset)
          ? this.failureReason
          : failureReason as String?,
      pullVerified: pullVerified ?? this.pullVerified,
      deviceId: deviceId ?? this.deviceId,
      lastReconciliationAt: lastReconciliationAt ?? this.lastReconciliationAt,
      reconciliationComplete:
          reconciliationComplete ?? this.reconciliationComplete,
    );
  }
}
