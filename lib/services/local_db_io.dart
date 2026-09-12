import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_db.dart';
import 'outbox.dart';

part 'local_db_io.g.dart';

/// Factory used by the conditional import in `local_db.dart`.
LocalDatabase createPlatformDatabase() => DriftLocalDatabase();

// ---------------------------------------------------------------------------
// Drift tables (SQLite on Android / Windows / Linux / macOS / iOS)
//
// Each of the four business tables is mirrored locally. The full row is stored
// as a JSON [payload] so the cache never has to know the exact column layout;
// [isSynced] + [offlineId] are first-class columns for fast pending queries.
// ---------------------------------------------------------------------------

@DataClassName('OfflinePatient')
class PatientRecords extends Table {
  TextColumn get offlineId => text().named('offline_id')();
  BoolColumn get isSynced =>
      boolean().named('is_synced').withDefault(const Constant(false))();
  TextColumn get payload => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {offlineId};
}

@DataClassName('OfflineOpdRegistration')
class OpdRegistrationRecords extends Table {
  TextColumn get offlineId => text().named('offline_id')();
  BoolColumn get isSynced =>
      boolean().named('is_synced').withDefault(const Constant(false))();
  TextColumn get payload => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {offlineId};
}

@DataClassName('OfflineIpdAdmission')
class IpdAdmissionRecords extends Table {
  TextColumn get offlineId => text().named('offline_id')();
  BoolColumn get isSynced =>
      boolean().named('is_synced').withDefault(const Constant(false))();
  TextColumn get payload => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {offlineId};
}

@DataClassName('OfflineBilling')
class BillingRecords extends Table {
  TextColumn get offlineId => text().named('offline_id')();
  BoolColumn get isSynced =>
      boolean().named('is_synced').withDefault(const Constant(false))();
  TextColumn get payload => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {offlineId};
}

// ---------------------------------------------------------------------------
// Transactional outbox + pull cursor + conflict storage.
// ---------------------------------------------------------------------------

@DataClassName('OutboxRow')
class SyncOutboxEntries extends Table {
  TextColumn get operationId => text().named('operation_id')();
  TextColumn get hospitalId => text().named('hospital_id')();
  TextColumn get deviceId => text().named('device_id')();
  TextColumn get entity => text()();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get operationType => text().named('operation_type')();
  TextColumn get payload => text()();
  IntColumn get baseVersion => integer().named('base_version').nullable()();
  TextColumn get dependencyGroup =>
      text().named('dependency_group').nullable()();
  IntColumn get attemptCount =>
      integer().named('attempt_count').withDefault(const Constant(0))();
  IntColumn get nextRetryAt => integer().named('next_retry_at').nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().named('last_error').nullable()();
  IntColumn get createdAt => integer().named('created_at')();

  @override
  Set<Column> get primaryKey => {operationId};
}

@DataClassName('SyncCursorRow')
class SyncCursorRecords extends Table {
  TextColumn get dataset => text()();
  TextColumn get value => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {dataset};
}

@DataClassName('SyncConflictRow')
class SyncConflictRecords extends Table {
  TextColumn get entity => text()();
  TextColumn get recordId => text().named('record_id')();
  TextColumn get localPayload => text().named('local_payload')();
  TextColumn get remotePayload => text().named('remote_payload')();
  IntColumn get baseVersion => integer().named('base_version')();
  IntColumn get detectedAt => integer().named('detected_at')();

  @override
  Set<Column> get primaryKey => {entity, recordId};
}

/// Small scoped key/value store for identity mapping and sync-setup flags.
@DataClassName('AppMetadataRow')
class AppMetadataRecords extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {key};
}

/// Generic JSON mirror for read-only master datasets (doctors, departments,
/// hospitals). Keyed by (table, offline_id); payload is the full row JSON.
@DataClassName('MirrorRow')
class MirrorRecords extends Table {
  TextColumn get table => text()();
  TextColumn get offlineId => text().named('offline_id')();
  TextColumn get payload => text()();
  IntColumn get updatedAt => integer().named('updated_at')();

  @override
  Set<Column> get primaryKey => {table, offlineId};
}

@DriftDatabase(
  tables: [
    PatientRecords,
    OpdRegistrationRecords,
    IpdAdmissionRecords,
    BillingRecords,
    SyncOutboxEntries,
    SyncCursorRecords,
    SyncConflictRecords,
    AppMetadataRecords,
    MirrorRecords,
  ],
)
class LocalDriftDatabase extends _$LocalDriftDatabase {
  LocalDriftDatabase(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 -> v2 adds the outbox, cursor and conflict tables. Existing
      // business rows (and their pending flags) are preserved.
      if (from < 2) {
        await m.createTable(syncOutboxEntries);
        await m.createTable(syncCursorRecords);
        await m.createTable(syncConflictRecords);
      }
      // v2 -> v3 adds the scoped metadata store.
      if (from < 3) {
        await m.createTable(appMetadataRecords);
      }
      // v3 -> v4 adds the read-only master mirror.
      if (from < 4) {
        await m.createTable(mirrorRecords);
      }
    },
  );
}

/// Native (Android / Windows / Linux / macOS / iOS) implementation backed by a
/// drift SQLite database stored in the app documents directory.
class DriftLocalDatabase implements LocalDatabase {
  DriftLocalDatabase({LocalDriftDatabase? database}) : _injectedDb = database;

  /// Test hook: when set, [init] uses this database instead of opening a file
  /// in the app documents directory (which needs a platform plugin).
  final LocalDriftDatabase? _injectedDb;

  LocalDriftDatabase? _db;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) return;
    final injected = _injectedDb;
    if (injected != null) {
      _db = injected;
      _initialized = true;
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'hims_offline.sqlite'));
    _db = LocalDriftDatabase(NativeDatabase.createInBackground(file));
    _initialized = true;
  }

  LocalDriftDatabase _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('Local database is not initialised. Call init() first.');
    }
    return db;
  }

  Map<String, dynamic> _rowToMap({
    required String offlineId,
    required bool isSynced,
    required String payload,
  }) {
    final data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
    data['offline_id'] ??= offlineId;
    data['sync_status'] ??= isSynced ? 'synced' : 'pending';
    data['is_synced'] = isSynced;
    return data;
  }

  // -- Save -----------------------------------------------------------------

  @override
  Future<void> saveRecord({
    required String table,
    required String offlineId,
    required Map<String, dynamic> data,
    bool isSynced = false,
  }) async {
    final db = _requireDb();
    final payload = jsonEncode(data);
    final ts = DateTime.now().millisecondsSinceEpoch;

    switch (table) {
      case LocalTables.patients:
        await db
            .into(db.patientRecords)
            .insertOnConflictUpdate(
              PatientRecordsCompanion.insert(
                offlineId: offlineId,
                payload: payload,
                updatedAt: ts,
                isSynced: Value(isSynced),
              ),
            );
      case LocalTables.opdRegistrations:
        await db
            .into(db.opdRegistrationRecords)
            .insertOnConflictUpdate(
              OpdRegistrationRecordsCompanion.insert(
                offlineId: offlineId,
                payload: payload,
                updatedAt: ts,
                isSynced: Value(isSynced),
              ),
            );
      case LocalTables.ipdAdmissions:
        await db
            .into(db.ipdAdmissionRecords)
            .insertOnConflictUpdate(
              IpdAdmissionRecordsCompanion.insert(
                offlineId: offlineId,
                payload: payload,
                updatedAt: ts,
                isSynced: Value(isSynced),
              ),
            );
      case LocalTables.billing:
        await db
            .into(db.billingRecords)
            .insertOnConflictUpdate(
              BillingRecordsCompanion.insert(
                offlineId: offlineId,
                payload: payload,
                updatedAt: ts,
                isSynced: Value(isSynced),
              ),
            );
      default:
        throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }
  }

  // -- Sync state -----------------------------------------------------------

  @override
  Future<void> markSynced({
    required String table,
    required String offlineId,
  }) async {
    final db = _requireDb();
    final ts = DateTime.now().millisecondsSinceEpoch;

    switch (table) {
      case LocalTables.patients:
        await (db.update(
          db.patientRecords,
        )..where((t) => t.offlineId.equals(offlineId))).write(
          PatientRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      case LocalTables.opdRegistrations:
        await (db.update(
          db.opdRegistrationRecords,
        )..where((t) => t.offlineId.equals(offlineId))).write(
          OpdRegistrationRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      case LocalTables.ipdAdmissions:
        await (db.update(
          db.ipdAdmissionRecords,
        )..where((t) => t.offlineId.equals(offlineId))).write(
          IpdAdmissionRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      case LocalTables.billing:
        await (db.update(
          db.billingRecords,
        )..where((t) => t.offlineId.equals(offlineId))).write(
          BillingRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      default:
        throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }
  }

  @override
  Future<void> deleteRecord({
    required String table,
    required String offlineId,
  }) async {
    final db = _requireDb();

    switch (table) {
      case LocalTables.patients:
        await (db.delete(
          db.patientRecords,
        )..where((t) => t.offlineId.equals(offlineId))).go();
      case LocalTables.opdRegistrations:
        await (db.delete(
          db.opdRegistrationRecords,
        )..where((t) => t.offlineId.equals(offlineId))).go();
      case LocalTables.ipdAdmissions:
        await (db.delete(
          db.ipdAdmissionRecords,
        )..where((t) => t.offlineId.equals(offlineId))).go();
      case LocalTables.billing:
        await (db.delete(
          db.billingRecords,
        )..where((t) => t.offlineId.equals(offlineId))).go();
      default:
        throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }
  }

  // -- Reads ----------------------------------------------------------------

  @override
  Future<List<Map<String, dynamic>>> getRecords({
    required String table,
    bool pendingOnly = false,
  }) async {
    final db = _requireDb();

    switch (table) {
      case LocalTables.patients:
        final query = db.select(db.patientRecords);
        if (pendingOnly) {
          query.where((t) => t.isSynced.equals(false));
          query.orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
        } else {
          query.orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
        }
        final rows = await query.get();
        return [
          for (final row in rows)
            _rowToMap(
              offlineId: row.offlineId,
              isSynced: row.isSynced,
              payload: row.payload,
            ),
        ];

      case LocalTables.opdRegistrations:
        final query = db.select(db.opdRegistrationRecords);
        if (pendingOnly) {
          query.where((t) => t.isSynced.equals(false));
          query.orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
        } else {
          query.orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
        }
        final rows = await query.get();
        return [
          for (final row in rows)
            _rowToMap(
              offlineId: row.offlineId,
              isSynced: row.isSynced,
              payload: row.payload,
            ),
        ];

      case LocalTables.ipdAdmissions:
        final query = db.select(db.ipdAdmissionRecords);
        if (pendingOnly) {
          query.where((t) => t.isSynced.equals(false));
          query.orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
        } else {
          query.orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
        }
        final rows = await query.get();
        return [
          for (final row in rows)
            _rowToMap(
              offlineId: row.offlineId,
              isSynced: row.isSynced,
              payload: row.payload,
            ),
        ];

      case LocalTables.billing:
        final query = db.select(db.billingRecords);
        if (pendingOnly) {
          query.where((t) => t.isSynced.equals(false));
          query.orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
        } else {
          query.orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
        }
        final rows = await query.get();
        return [
          for (final row in rows)
            _rowToMap(
              offlineId: row.offlineId,
              isSynced: row.isSynced,
              payload: row.payload,
            ),
        ];

      default:
        throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }
  }

  // -- Cache replacement ----------------------------------------------------

  @override
  Future<void> replaceRecords({
    required String table,
    required List<Map<String, dynamic>> records,
  }) async {
    final db = _requireDb();
    final base = DateTime.now().millisecondsSinceEpoch;

    List<Map<String, dynamic>> validRows() {
      final rows = <Map<String, dynamic>>[];
      for (final row in records) {
        final offlineId = (row['offline_id'] ?? row['id'])?.toString();
        if (offlineId == null || offlineId.isEmpty) continue;
        final data = Map<String, dynamic>.from(row);
        data['offline_id'] ??= offlineId;
        data['sync_status'] ??= 'synced';
        data['is_synced'] = true;
        rows.add(data);
      }
      return rows;
    }

    switch (table) {
      case LocalTables.patients:
        final rows = validRows();
        await db.delete(db.patientRecords).go();
        await db.batch((batch) {
          batch.insertAll(db.patientRecords, [
            for (var i = 0; i < rows.length; i++)
              PatientRecordsCompanion.insert(
                offlineId: rows[i]['offline_id'] as String,
                payload: jsonEncode(rows[i]),
                updatedAt: base - i,
                isSynced: const Value(true),
              ),
          ]);
        });

      case LocalTables.opdRegistrations:
        final rows = validRows();
        await db.delete(db.opdRegistrationRecords).go();
        await db.batch((batch) {
          batch.insertAll(db.opdRegistrationRecords, [
            for (var i = 0; i < rows.length; i++)
              OpdRegistrationRecordsCompanion.insert(
                offlineId: rows[i]['offline_id'] as String,
                payload: jsonEncode(rows[i]),
                updatedAt: base - i,
                isSynced: const Value(true),
              ),
          ]);
        });

      case LocalTables.ipdAdmissions:
        final rows = validRows();
        await db.delete(db.ipdAdmissionRecords).go();
        await db.batch((batch) {
          batch.insertAll(db.ipdAdmissionRecords, [
            for (var i = 0; i < rows.length; i++)
              IpdAdmissionRecordsCompanion.insert(
                offlineId: rows[i]['offline_id'] as String,
                payload: jsonEncode(rows[i]),
                updatedAt: base - i,
                isSynced: const Value(true),
              ),
          ]);
        });

      case LocalTables.billing:
        final rows = validRows();
        await db.delete(db.billingRecords).go();
        await db.batch((batch) {
          batch.insertAll(db.billingRecords, [
            for (var i = 0; i < rows.length; i++)
              BillingRecordsCompanion.insert(
                offlineId: rows[i]['offline_id'] as String,
                payload: jsonEncode(rows[i]),
                updatedAt: base - i,
                isSynced: const Value(true),
              ),
          ]);
        });

      default:
        throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }
  }

  // -- Pending --------------------------------------------------------------

  @override
  Future<List<PendingSyncRecord>> getPendingRecords() async {
    await init();
    final result = <PendingSyncRecord>[];
    for (final table in LocalTables.all) {
      final rows = await getRecords(table: table, pendingOnly: true);
      for (final row in rows) {
        final offlineId = (row['offline_id'] ?? '').toString();
        if (offlineId.isEmpty) continue;
        result.add(
          PendingSyncRecord(table: table, offlineId: offlineId, data: row),
        );
      }
    }
    return result;
  }

  @override
  Future<int> pendingCount() async {
    final db = _requireDb();
    var count = 0;

    count += (await (db.select(
      db.patientRecords,
    )..where((t) => t.isSynced.equals(false))).get()).length;
    count += (await (db.select(
      db.opdRegistrationRecords,
    )..where((t) => t.isSynced.equals(false))).get()).length;
    count += (await (db.select(
      db.ipdAdmissionRecords,
    )..where((t) => t.isSynced.equals(false))).get()).length;
    count += (await (db.select(
      db.billingRecords,
    )..where((t) => t.isSynced.equals(false))).get()).length;

    return count;
  }

  @override
  Future<void> clearTable(String table) async {
    final db = _requireDb();
    switch (table) {
      case LocalTables.patients:
        await db.delete(db.patientRecords).go();
      case LocalTables.opdRegistrations:
        await db.delete(db.opdRegistrationRecords).go();
      case LocalTables.ipdAdmissions:
        await db.delete(db.ipdAdmissionRecords).go();
      case LocalTables.billing:
        await db.delete(db.billingRecords).go();
      default:
        throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }
  }

  // ---------------------------------------------------------------------------
  // Transactional outbox
  // ---------------------------------------------------------------------------

  OutboxEntry _outboxFromRow(OutboxRow row) {
    return OutboxEntry(
      operationId: row.operationId,
      hospitalId: row.hospitalId,
      deviceId: row.deviceId,
      entity: row.entity,
      recordId: row.recordId,
      operationType: SyncOperationType.fromWire(row.operationType),
      payload: (jsonDecode(row.payload) as Map).cast<String, dynamic>(),
      baseVersion: row.baseVersion,
      dependencyGroup: row.dependencyGroup,
      attemptCount: row.attemptCount,
      nextRetryAt: row.nextRetryAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.nextRetryAt!),
      status: SyncOperationStatus.values.firstWhere(
        (s) => s.name == row.status,
        orElse: () => SyncOperationStatus.pending,
      ),
      lastError: row.lastError,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }

  SyncOutboxEntriesCompanion _outboxToCompanion(OutboxEntry e) {
    return SyncOutboxEntriesCompanion.insert(
      operationId: e.operationId,
      hospitalId: e.hospitalId,
      deviceId: e.deviceId,
      entity: e.entity,
      recordId: e.recordId,
      operationType: e.operationType.wire,
      payload: jsonEncode(e.payload),
      baseVersion: Value(e.baseVersion),
      dependencyGroup: Value(e.dependencyGroup),
      attemptCount: Value(e.attemptCount),
      nextRetryAt: Value(e.nextRetryAt?.millisecondsSinceEpoch),
      status: Value(e.status.name),
      lastError: Value(e.lastError),
      createdAt: (e.createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> saveRecordWithOutbox({
    required String table,
    required String offlineId,
    required Map<String, dynamic> data,
    required OutboxEntry outbox,
  }) async {
    final db = _requireDb();
    await db.transaction(() async {
      // Business row first (kept `is_synced = false` -> pending).
      await saveRecord(
        table: table,
        offlineId: offlineId,
        data: data,
        isSynced: false,
      );
      // Then the outbox entry, atomically in the same transaction.
      await db
          .into(db.syncOutboxEntries)
          .insertOnConflictUpdate(_outboxToCompanion(outbox));
    });
  }

  @override
  Future<void> enqueueOutbox(OutboxEntry entry) async {
    final db = _requireDb();
    await db
        .into(db.syncOutboxEntries)
        .insertOnConflictUpdate(_outboxToCompanion(entry));
  }

  @override
  Future<List<OutboxEntry>> getDueOutbox({int limit = 100}) async {
    final db = _requireDb();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Due = pending, or failed whose nextRetryAt has passed. The retry-time
    // filter is applied in Dart so we never depend on nullable SQL comparison
    // operators across drift versions.
    final rows =
        await (db.select(db.syncOutboxEntries)
              ..where(
                (t) =>
                    t.status.equals(SyncOperationStatus.pending.name) |
                    t.status.equals(SyncOperationStatus.failed.name),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    return rows
        .map(_outboxFromRow)
        .where(
          (e) =>
              e.nextRetryAt == null ||
              e.nextRetryAt!.millisecondsSinceEpoch <= now,
        )
        .take(limit)
        .toList();
  }

  Future<void> _updateOutboxStatus(
    String operationId, {
    required String status,
    String? error,
    int? attemptCount,
    int? nextRetryAt,
  }) async {
    final db = _requireDb();
    await (db.update(
      db.syncOutboxEntries,
    )..where((t) => t.operationId.equals(operationId))).write(
      SyncOutboxEntriesCompanion(
        status: Value(status),
        lastError: Value(error),
        attemptCount: attemptCount == null
            ? const Value.absent()
            : Value(attemptCount),
        nextRetryAt: nextRetryAt == null
            ? const Value.absent()
            : Value(nextRetryAt),
      ),
    );
  }

  @override
  Future<void> markOutboxSynced(
    String operationId, {
    List<LocalRecordRef> syncedRecords = const [],
  }) async {
    final db = _requireDb();
    // One transaction: the outbox acknowledgement and the local
    // `is_synced` flags can never disagree after a crash.
    await db.transaction(() async {
      await _updateOutboxStatus(
        operationId,
        status: SyncOperationStatus.synced.name,
      );
      for (final ref in syncedRecords) {
        await markSynced(table: ref.table, offlineId: ref.offlineId);
      }
    });
  }

  @override
  Future<void> markOutboxFailed(
    String operationId,
    String error,
    DateTime nextRetryAt,
  ) => _updateOutboxStatus(
    operationId,
    status: SyncOperationStatus.failed.name,
    error: error,
    nextRetryAt: nextRetryAt.millisecondsSinceEpoch,
  );

  @override
  Future<void> markOutboxRejected(String operationId, String error) =>
      _updateOutboxStatus(
        operationId,
        status: SyncOperationStatus.rejected.name,
        error: error,
      );

  @override
  Future<void> markOutboxConflict(String operationId) => _updateOutboxStatus(
    operationId,
    status: SyncOperationStatus.conflict.name,
  );

  @override
  Future<int> outboxPendingCount() async {
    final db = _requireDb();
    final rows =
        await (db.select(db.syncOutboxEntries)..where(
              (t) =>
                  t.status.equals(SyncOperationStatus.pending.name) |
                  t.status.equals(SyncOperationStatus.failed.name) |
                  t.status.equals(SyncOperationStatus.inFlight.name),
            ))
            .get();
    return rows.length;
  }

  // ---------------------------------------------------------------------------
  // Pull cursors
  // ---------------------------------------------------------------------------

  @override
  Future<SyncCursor?> getSyncCursor(String dataset) async {
    final db = _requireDb();
    final row = await (db.select(
      db.syncCursorRecords,
    )..where((t) => t.dataset.equals(dataset))).getSingleOrNull();
    if (row == null) return null;
    return SyncCursor(
      dataset: row.dataset,
      value: row.value,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }

  @override
  Future<void> setSyncCursor(SyncCursor cursor) async {
    final db = _requireDb();
    await db
        .into(db.syncCursorRecords)
        .insertOnConflictUpdate(
          SyncCursorRecordsCompanion.insert(
            dataset: cursor.dataset,
            value: cursor.value,
            updatedAt:
                (cursor.updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
          ),
        );
  }

  // ---------------------------------------------------------------------------
  // Conflicts
  // ---------------------------------------------------------------------------

  @override
  Future<void> saveConflict(SyncConflict conflict) async {
    final db = _requireDb();
    await db
        .into(db.syncConflictRecords)
        .insertOnConflictUpdate(
          SyncConflictRecordsCompanion.insert(
            entity: conflict.entity,
            recordId: conflict.recordId,
            localPayload: jsonEncode(conflict.localPayload),
            remotePayload: jsonEncode(conflict.remotePayload),
            baseVersion: conflict.baseVersion,
            detectedAt: conflict.detectedAt.millisecondsSinceEpoch,
          ),
        );
  }

  @override
  Future<List<SyncConflict>> getConflicts({String? entity}) async {
    final db = _requireDb();
    final query = db.select(db.syncConflictRecords);
    if (entity != null && entity.isNotEmpty) {
      query.where((t) => t.entity.equals(entity));
    }
    final rows = await query.get();
    return [
      for (final row in rows)
        SyncConflict(
          entity: row.entity,
          recordId: row.recordId,
          localPayload: (jsonDecode(row.localPayload) as Map)
              .cast<String, dynamic>(),
          remotePayload: (jsonDecode(row.remotePayload) as Map)
              .cast<String, dynamic>(),
          baseVersion: row.baseVersion,
          detectedAt: DateTime.fromMillisecondsSinceEpoch(row.detectedAt),
        ),
    ];
  }

  @override
  Future<void> deleteConflict(String entity, String recordId) async {
    final db = _requireDb();
    await (db.delete(db.syncConflictRecords)
          ..where((t) => t.entity.equals(entity) & t.recordId.equals(recordId)))
        .go();
  }

  // ---------------------------------------------------------------------------
  // Atomic transaction + scoped metadata
  // ---------------------------------------------------------------------------

  @override
  Future<void> applyTransaction(LocalTransaction transaction) async {
    final db = _requireDb();
    await db.transaction(() async {
      for (final rec in transaction.records) {
        await saveRecord(
          table: rec.table,
          offlineId: rec.offlineId,
          data: rec.data,
          isSynced: rec.isSynced,
        );
      }
      for (final entry in transaction.outbox) {
        await db
            .into(db.syncOutboxEntries)
            .insertOnConflictUpdate(_outboxToCompanion(entry));
      }
    });
  }

  @override
  Future<void> setMetadata(String key, String value) async {
    final db = _requireDb();
    await db
        .into(db.appMetadataRecords)
        .insertOnConflictUpdate(
          AppMetadataRecordsCompanion.insert(
            key: key,
            value: value,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  @override
  Future<String?> getMetadata(String key) async {
    final db = _requireDb();
    final row = await (db.select(
      db.appMetadataRecords,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  @override
  Future<void> removeMetadata(String key) async {
    final db = _requireDb();
    await (db.delete(
      db.appMetadataRecords,
    )..where((t) => t.key.equals(key))).go();
  }

  // ---------------------------------------------------------------------------
  // Read-only master mirror
  // ---------------------------------------------------------------------------

  @override
  Future<void> saveMirror(
    String table,
    List<Map<String, dynamic>> records,
  ) async {
    final db = _requireDb();
    await db.transaction(() async {
      await (db.delete(
        db.mirrorRecords,
      )..where((t) => t.table.equals(table))).go();
      var i = 0;
      final base = DateTime.now().millisecondsSinceEpoch;
      for (final row in records) {
        final id = (row['offline_id'] ?? row['id'])?.toString();
        if (id == null || id.isEmpty) continue;
        await db
            .into(db.mirrorRecords)
            .insert(
              MirrorRecordsCompanion.insert(
                table: table,
                offlineId: id,
                payload: jsonEncode(row),
                updatedAt: base - i,
              ),
            );
        i++;
      }
    });
  }

  @override
  Future<void> upsertMirrorRow(
    String table,
    Map<String, dynamic> record,
  ) async {
    final db = _requireDb();
    final id = (record['offline_id'] ?? record['id'])?.toString();
    if (id == null || id.isEmpty) return;
    await db
        .into(db.mirrorRecords)
        .insertOnConflictUpdate(
          MirrorRecordsCompanion.insert(
            table: table,
            offlineId: id,
            payload: jsonEncode(record),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  @override
  Future<void> deleteMirrorRow(String table, String recordId) async {
    final db = _requireDb();
    await (db.delete(
      db.mirrorRecords,
    )..where((t) => t.table.equals(table) & t.offlineId.equals(recordId))).go();
  }

  @override
  Future<List<Map<String, dynamic>>> getMirror(String table) async {
    final db = _requireDb();
    final rows =
        await (db.select(db.mirrorRecords)
              ..where((t) => t.table.equals(table))
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
            .get();
    return [
      for (final row in rows)
        (jsonDecode(row.payload) as Map).cast<String, dynamic>(),
    ];
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _initialized = false;
  }
}
