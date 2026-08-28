import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_db.dart';

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

@DriftDatabase(
  tables: [
    PatientRecords,
    OpdRegistrationRecords,
    IpdAdmissionRecords,
    BillingRecords,
  ],
)
class LocalDriftDatabase extends _$LocalDriftDatabase {
  LocalDriftDatabase(super.e);

  @override
  int get schemaVersion => 1;
}

/// Native (Android / Windows / Linux / macOS / iOS) implementation backed by a
/// drift SQLite database stored in the app documents directory.
class DriftLocalDatabase implements LocalDatabase {
  LocalDriftDatabase? _db;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) return;
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
        await db.into(db.patientRecords).insertOnConflictUpdate(
          PatientRecordsCompanion.insert(
            offlineId: offlineId,
            payload: payload,
            updatedAt: ts,
            isSynced: Value(isSynced),
          ),
        );
      case LocalTables.opdRegistrations:
        await db.into(db.opdRegistrationRecords).insertOnConflictUpdate(
          OpdRegistrationRecordsCompanion.insert(
            offlineId: offlineId,
            payload: payload,
            updatedAt: ts,
            isSynced: Value(isSynced),
          ),
        );
      case LocalTables.ipdAdmissions:
        await db.into(db.ipdAdmissionRecords).insertOnConflictUpdate(
          IpdAdmissionRecordsCompanion.insert(
            offlineId: offlineId,
            payload: payload,
            updatedAt: ts,
            isSynced: Value(isSynced),
          ),
        );
      case LocalTables.billing:
        await db.into(db.billingRecords).insertOnConflictUpdate(
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
        await (db.update(db.patientRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .write(
          PatientRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      case LocalTables.opdRegistrations:
        await (db.update(db.opdRegistrationRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .write(
          OpdRegistrationRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      case LocalTables.ipdAdmissions:
        await (db.update(db.ipdAdmissionRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .write(
          IpdAdmissionRecordsCompanion(
            isSynced: const Value(true),
            updatedAt: Value(ts),
          ),
        );
      case LocalTables.billing:
        await (db.update(db.billingRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .write(
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
        await (db.delete(db.patientRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .go();
      case LocalTables.opdRegistrations:
        await (db.delete(db.opdRegistrationRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .go();
      case LocalTables.ipdAdmissions:
        await (db.delete(db.ipdAdmissionRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .go();
      case LocalTables.billing:
        await (db.delete(db.billingRecords)
              ..where((t) => t.offlineId.equals(offlineId)))
            .go();
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

    count += (await (db.select(db.patientRecords)
              ..where((t) => t.isSynced.equals(false)))
            .get())
        .length;
    count += (await (db.select(db.opdRegistrationRecords)
              ..where((t) => t.isSynced.equals(false)))
            .get())
        .length;
    count += (await (db.select(db.ipdAdmissionRecords)
              ..where((t) => t.isSynced.equals(false)))
            .get())
        .length;
    count += (await (db.select(db.billingRecords)
              ..where((t) => t.isSynced.equals(false)))
            .get())
        .length;

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

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _initialized = false;
  }
}
