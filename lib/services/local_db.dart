import 'local_db_web.dart' if (dart.library.io) 'local_db_io.dart' as platform;

/// Canonical table names shared between the local cache, the sync engine and
/// the Supabase schema.
class LocalTables {
  LocalTables._();

  static const String patients = 'patients';
  static const String opdRegistrations = 'opd_registrations';
  static const String ipdAdmissions = 'ipd_admissions';
  static const String billing = 'billing';

  /// Sync order matters: child tables reference parent rows by id, so parents
  /// must reach Supabase first.
  static const List<String> all = [
    patients,
    opdRegistrations,
    ipdAdmissions,
    billing,
  ];

  static bool contains(String table) => all.contains(table);
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
