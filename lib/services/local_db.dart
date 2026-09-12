import 'local_db_web.dart' if (dart.library.io) 'local_db_io.dart' as platform;
import 'outbox.dart';

/// Canonical table names shared between the local cache, the sync engine and
/// the Supabase schema.
class LocalTables {
  LocalTables._();

  static const String patients = 'patients';
  static const String opdRegistrations = 'opd_registrations';
  static const String ipdAdmissions = 'ipd_admissions';
  static const String billing = 'billing';

  /// Read-only master datasets mirrored locally for offline reads. They are
  /// never uploaded through the outbox; they are only refreshed from the cloud.
  static const String doctors = 'doctors';
  static const String departments = 'departments';
  static const String hospitals = 'hospitals';

  /// Sync order matters: child tables reference parent rows by id, so parents
  /// must reach Supabase first.
  static const List<String> all = [
    patients,
    opdRegistrations,
    ipdAdmissions,
    billing,
  ];

  /// Read-only datasets mirrored for offline reads (no outbox writes).
  static const List<String> readOnly = [doctors, departments, hospitals];

  static bool contains(String table) => all.contains(table);

  static bool isReadOnly(String table) => readOnly.contains(table);

  /// True when [table] is available in the local database at all (either a
  /// syncable operational table or a read-only mirror).
  static bool isLocal(String table) => contains(table) || isReadOnly(table);
}

/// A single record that was saved offline and has not been synced yet.
class PendingSyncRecord {
  const PendingSyncRecord({
    required this.table,
    required this.offlineId,
    required this.data,
  });

  final String table;
  final String offlineId;
  final Map<String, dynamic> data;
}

/// One business-record write inside a [LocalTransaction].
class LocalRecordWrite {
  const LocalRecordWrite({
    required this.table,
    required this.offlineId,
    required this.data,
    this.isSynced = false,
  });

  final String table;
  final String offlineId;
  final Map<String, dynamic> data;
  final bool isSynced;
}

/// One local business row that a server-acknowledged outbox entry covers.
///
/// A single outbox entry can stand for more than one row (for example the
/// atomic OPD payment operation updates the visit and creates its bill), so
/// acknowledgement has to mark every covered row as synced.
class LocalRecordRef {
  const LocalRecordRef({required this.table, required this.offlineId});

  final String table;
  final String offlineId;
}

/// A group of business-record writes and outbox entries that must commit
/// together.
///
/// On Drift/SQLite this is applied inside a single SQLite transaction, so a
/// crash can never leave a paid OPD without its bill/payment records, nor a
/// record without its queued outbox entry. On Hive/Web there is no cross-box
/// transaction: writes are applied in order and are individually idempotent,
/// which is documented (not presented as atomic).
class LocalTransaction {
  const LocalTransaction({this.records = const [], this.outbox = const []});

  final List<LocalRecordWrite> records;
  final List<OutboxEntry> outbox;
}

/// Platform-agnostic local persistence API.
///
/// * Web builds resolve to [HiveLocalDatabase] (IndexedDB via Hive).
/// * Android / Windows (and all other `dart.library.io` targets) resolve to
///   [DriftLocalDatabase] (SQLite via drift).
abstract class LocalDatabase {
  /// Opens the underlying store. Safe to call multiple times.
  Future<void> init();

  /// Inserts or replaces one record keyed by [offlineId].
  Future<void> saveRecord({
    required String table,
    required String offlineId,
    required Map<String, dynamic> data,
    bool isSynced = false,
  });

  /// Marks one local record as synced.
  Future<void> markSynced({required String table, required String offlineId});

  /// Deletes one local record.
  Future<void> deleteRecord({required String table, required String offlineId});

  /// Returns cached records for [table].
  ///
  /// When [pendingOnly] is true only unsynced rows are returned.
  Future<List<Map<String, dynamic>>> getRecords({
    required String table,
    bool pendingOnly = false,
  });

  /// Replaces the entire local cache for [table] with [records]
  /// (used after a successful Supabase fetch).
  Future<void> replaceRecords({
    required String table,
    required List<Map<String, dynamic>> records,
  });

  /// Returns every unsynced record across all tables in sync priority order.
  Future<List<PendingSyncRecord>> getPendingRecords();

  /// Number of records still waiting to be synced.
  Future<int> pendingCount();

  /// Removes all cached rows for [table].
  Future<void> clearTable(String table);

  // ---------------------------------------------------------------------------
  // Transactional outbox (durable local-first writes)
  // ---------------------------------------------------------------------------

  /// Atomically saves a business record and its outbox entry in one local
  /// transaction, so a crash can never leave a record without a queued sync
  /// operation (or vice versa). The record is saved `is_synced = false`.
  Future<void> saveRecordWithOutbox({
    required String table,
    required String offlineId,
    required Map<String, dynamic> data,
    required OutboxEntry outbox,
  });

  /// Enqueues a standalone outbox entry (delete/tombstone operations have no
  /// business row to keep locally).
  Future<void> enqueueOutbox(OutboxEntry entry);

  /// Returns outbox entries that are due for processing, oldest-first.
  ///
  /// An entry is "due" when its status is [SyncOperationStatus.pending] or
  /// [SyncOperationStatus.failed] and its `nextRetryAt` (if any) has passed.
  Future<List<OutboxEntry>> getDueOutbox({int limit = 100});

  /// Marks an outbox entry as server-acknowledged (durable) and, in the same
  /// local transaction, marks the local business rows it covers as synced.
  ///
  /// Marking the covered rows matters: a row that stays `is_synced = false`
  /// after a verified server commit would look "pending" forever and would
  /// block online-only workflows (IPD admission) that require a
  /// cloud-confirmed patient.
  Future<void> markOutboxSynced(
    String operationId, {
    List<LocalRecordRef> syncedRecords = const [],
  });

  /// Marks an outbox entry as failed (retryable network error) with a
  /// backoff-computed [nextRetryAt].
  Future<void> markOutboxFailed(
    String operationId,
    String error,
    DateTime nextRetryAt,
  );

  /// Marks an outbox entry as rejected (non-retryable auth/validation error).
  Future<void> markOutboxRejected(String operationId, String error);

  /// Marks an outbox entry as a conflict (both sides preserved).
  Future<void> markOutboxConflict(String operationId);

  /// Number of outbox entries not yet acknowledged by the server.
  Future<int> outboxPendingCount();

  /// Applies a group of business-record writes and outbox entries atomically
  /// (single SQLite transaction on native; ordered idempotent writes on web).
  Future<void> applyTransaction(LocalTransaction transaction);

  // ---------------------------------------------------------------------------
  // Scoped app metadata (identity mapping, sync-setup flags, etc.)
  // ---------------------------------------------------------------------------

  /// Stores a small scoped value. Not cleared on logout, so pending operations
  /// keep their originating identity even after a session expires.
  Future<void> setMetadata(String key, String value);

  Future<String?> getMetadata(String key);

  Future<void> removeMetadata(String key);

  // ---------------------------------------------------------------------------
  // Read-only master mirror (doctors / departments / hospitals)
  // ---------------------------------------------------------------------------

  /// Replaces the entire local mirror for a read-only [table] with [records].
  Future<void> saveMirror(String table, List<Map<String, dynamic>> records);

  /// Inserts or replaces ONE row in the mirror for a read-only [table].
  ///
  /// Used by the incremental change-log pull to apply a single child row (for
  /// example a `billing_items` or `payment_logs` change) without clearing the
  /// rest of the dataset the way [saveMirror] does.
  Future<void> upsertMirrorRow(String table, Map<String, dynamic> record);

  /// Removes one row from the mirror for a read-only [table] (soft-delete).
  Future<void> deleteMirrorRow(String table, String recordId);

  /// Returns mirrored records for a read-only [table] (empty when not
  /// downloaded yet).
  Future<List<Map<String, dynamic>>> getMirror(String table);

  // ---------------------------------------------------------------------------
  // Pull cursors (durable per-hospital/per-dataset)
  // ---------------------------------------------------------------------------

  Future<SyncCursor?> getSyncCursor(String dataset);

  Future<void> setSyncCursor(SyncCursor cursor);

  // ---------------------------------------------------------------------------
  // Conflicts (preserve both sides until resolved)
  // ---------------------------------------------------------------------------

  Future<void> saveConflict(SyncConflict conflict);

  Future<List<SyncConflict>> getConflicts({String? entity});

  Future<void> deleteConflict(String entity, String recordId);

  /// Closes the underlying store.
  Future<void> close();
}

LocalDatabase? _sharedInstance;

/// Returns the process-wide local database instance.
///
/// The concrete implementation is selected at compile time through the
/// conditional import above — no `kIsWeb` checks are needed in calling code.
LocalDatabase getLocalDatabase() =>
    _sharedInstance ??= platform.createPlatformDatabase();

/// Initialises the local database once during app startup (see `main.dart`).
Future<void> initializeLocalDatabase() => getLocalDatabase().init();
