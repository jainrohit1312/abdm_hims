import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'local_db.dart';
import 'outbox.dart';

/// Factory used by the conditional import in `local_db.dart`.
LocalDatabase createPlatformDatabase() => HiveLocalDatabase();

/// Web implementation backed by Hive (IndexedDB in the browser).
///
/// Each business table gets its own Hive box; values are JSON strings so no
/// custom TypeAdapters are required.
class HiveLocalDatabase implements LocalDatabase {
  bool _initialized = false;
  final Map<String, Box<String>> _boxes = {};

  static const String _outboxBox = 'offline_sync_outbox';
  static const String _cursorBox = 'offline_sync_cursors';
  static const String _conflictBox = 'offline_sync_conflicts';
  static const String _metadataBox = 'offline_app_metadata';
  static const String _mirrorBox = 'offline_master_mirror';

  @override
  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    for (final table in LocalTables.all) {
      _boxes[table] = await Hive.openBox<String>('offline_$table');
    }
    _boxes[_outboxBox] = await Hive.openBox<String>(_outboxBox);
    _boxes[_cursorBox] = await Hive.openBox<String>(_cursorBox);
    _boxes[_conflictBox] = await Hive.openBox<String>(_conflictBox);
    _boxes[_metadataBox] = await Hive.openBox<String>(_metadataBox);
    _boxes[_mirrorBox] = await Hive.openBox<String>(_mirrorBox);
    _initialized = true;
  }

  Box<String> _box(String table) {
    final box = _boxes[table];
    if (box == null) {
      throw StateError(
        'Local database is not initialised or table "$table" is not a '
        'supported offline table.',
      );
    }
    return box;
  }

  Map<String, dynamic> _decode(String raw) =>
      jsonDecode(raw) as Map<String, dynamic>;

  @override
  Future<void> saveRecord({
    required String table,
    required String offlineId,
    required Map<String, dynamic> data,
    bool isSynced = false,
  }) async {
    await init();
    await _box(table).put(
      offlineId,
      jsonEncode({
        'offline_id': offlineId,
        'is_synced': isSynced,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      }),
    );
  }

  @override
  Future<void> markSynced({
    required String table,
    required String offlineId,
  }) async {
    final box = _box(table);
    final raw = box.get(offlineId);
    if (raw == null) return;
    final record = _decode(raw);
    record['is_synced'] = true;
    record['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await box.put(offlineId, jsonEncode(record));
  }

  @override
  Future<void> deleteRecord({
    required String table,
    required String offlineId,
  }) async {
    await _box(table).delete(offlineId);
  }

  List<Map<String, dynamic>> _decodeRows(
    String table, {
    bool pendingOnly = false,
  }) {
    final rows = <Map<String, dynamic>>[];
    // Hive iterates in insertion order, which is exactly the order returned
    // by the server after a cache refresh — no extra sorting required.
    for (final raw in _box(table).values) {
      final record = _decode(raw);
      final isSynced = record['is_synced'] == true;
      if (pendingOnly && isSynced) continue;

      final data = Map<String, dynamic>.from(
        (record['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
      data['offline_id'] ??= record['offline_id'];
      data['sync_status'] ??= isSynced ? 'synced' : 'pending';
      data['is_synced'] = isSynced;
      rows.add(data);
    }
    return rows;
  }

  @override
  Future<List<Map<String, dynamic>>> getRecords({
    required String table,
    bool pendingOnly = false,
  }) async {
    await init();
    return _decodeRows(table, pendingOnly: pendingOnly);
  }

  @override
  Future<void> replaceRecords({
    required String table,
    required List<Map<String, dynamic>> records,
  }) async {
    final box = _box(table);
    await box.clear();

    final base = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < records.length; i++) {
      final row = records[i];
      final offlineId = (row['offline_id'] ?? row['id'])?.toString();
      if (offlineId == null || offlineId.isEmpty) continue;

      final data = Map<String, dynamic>.from(row);
      data['offline_id'] ??= offlineId;
      data['sync_status'] ??= 'synced';
      data['is_synced'] = true;

      await box.put(
        offlineId,
        jsonEncode({
          'offline_id': offlineId,
          'is_synced': true,
          'updated_at': base - i,
          'data': data,
        }),
      );
    }
  }

  @override
  Future<List<PendingSyncRecord>> getPendingRecords() async {
    await init();
    final result = <PendingSyncRecord>[];
    for (final table in LocalTables.all) {
      for (final raw in _box(table).values) {
        final record = _decode(raw);
        if (record['is_synced'] != false) continue;

        final offlineId = record['offline_id']?.toString() ?? '';
        if (offlineId.isEmpty) continue;

        final data = Map<String, dynamic>.from(
          (record['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        data['offline_id'] ??= offlineId;
        data['sync_status'] ??= 'pending';
        data['is_synced'] = false;
        result.add(
          PendingSyncRecord(table: table, offlineId: offlineId, data: data),
        );
      }
    }
    return result;
  }

  @override
  Future<int> pendingCount() async {
    var count = 0;
    for (final table in LocalTables.all) {
      for (final raw in _box(table).values) {
        final record = _decode(raw);
        if (record['is_synced'] == false) count++;
      }
    }
    return count;
  }

  @override
  Future<void> clearTable(String table) => _box(table).clear();

  // ---------------------------------------------------------------------------
  // Transactional outbox (Hive has no cross-box transaction; we write the
  // business row first, then the outbox entry, and treat a failure between
  // them as recoverable because both are independently idempotent).
  // ---------------------------------------------------------------------------

  @override
  Future<void> saveRecordWithOutbox({
    required String table,
    required String offlineId,
    required Map<String, dynamic> data,
    required OutboxEntry outbox,
  }) async {
    await saveRecord(
      table: table,
      offlineId: offlineId,
      data: data,
      isSynced: false,
    );
    await enqueueOutbox(outbox);
  }

  @override
  Future<void> enqueueOutbox(OutboxEntry entry) async {
    await _box(_outboxBox).put(entry.operationId, jsonEncode(entry.toJson()));
  }

  @override
  Future<List<OutboxEntry>> getDueOutbox({int limit = 100}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = <OutboxEntry>[];
    for (final raw in _box(_outboxBox).values) {
      final entry = OutboxEntry.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (entry.status != SyncOperationStatus.pending &&
          entry.status != SyncOperationStatus.failed) {
        continue;
      }
      final retryAt = entry.nextRetryAt?.millisecondsSinceEpoch ?? 0;
      if (entry.status == SyncOperationStatus.failed && retryAt > now) {
        continue;
      }
      due.add(entry);
    }
    due.sort(
      (a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
    return due.take(limit).toList();
  }

  Future<void> _putOutbox(String operationId, OutboxEntry entry) =>
      _box(_outboxBox).put(operationId, jsonEncode(entry.toJson()));

  Future<void> _updateOutbox(
    String operationId,
    OutboxEntry Function(OutboxEntry) update,
  ) async {
    final raw = _box(_outboxBox).get(operationId);
    if (raw == null) return;
    final entry = OutboxEntry.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
    await _putOutbox(operationId, update(entry));
  }

  @override
  Future<void> markOutboxSynced(
    String operationId, {
    List<LocalRecordRef> syncedRecords = const [],
  }) async {
    // Hive has no cross-box transaction: the writes below are ordered and
    // individually idempotent (documented best-effort, not atomic).
    await _updateOutbox(
      operationId,
      (e) => e.copyWith(status: SyncOperationStatus.synced, lastError: null),
    );
    for (final ref in syncedRecords) {
      await markSynced(table: ref.table, offlineId: ref.offlineId);
    }
  }

  @override
  Future<void> markOutboxFailed(
    String operationId,
    String error,
    DateTime nextRetryAt,
  ) => _updateOutbox(
    operationId,
    (e) => e.copyWith(
      status: SyncOperationStatus.failed,
      lastError: error,
      nextRetryAt: nextRetryAt,
      attemptCount: e.attemptCount + 1,
    ),
  );

  @override
  Future<void> markOutboxRejected(String operationId, String error) =>
      _updateOutbox(
        operationId,
        (e) =>
            e.copyWith(status: SyncOperationStatus.rejected, lastError: error),
      );

  @override
  Future<void> markOutboxConflict(String operationId) => _updateOutbox(
    operationId,
    (e) => e.copyWith(status: SyncOperationStatus.conflict),
  );

  @override
  Future<int> outboxPendingCount() async {
    var count = 0;
    for (final raw in _box(_outboxBox).values) {
      final entry = OutboxEntry.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (entry.status == SyncOperationStatus.pending ||
          entry.status == SyncOperationStatus.failed ||
          entry.status == SyncOperationStatus.inFlight) {
        count++;
      }
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // Pull cursors
  // ---------------------------------------------------------------------------

  @override
  Future<SyncCursor?> getSyncCursor(String dataset) async {
    final raw = _box(_cursorBox).get(dataset);
    if (raw == null) return null;
    return SyncCursor.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
  }

  @override
  Future<void> setSyncCursor(SyncCursor cursor) async {
    await _box(_cursorBox).put(cursor.dataset, jsonEncode(cursor.toJson()));
  }

  // ---------------------------------------------------------------------------
  // Conflicts
  // ---------------------------------------------------------------------------

  String _conflictKey(String entity, String recordId) => '$entity::$recordId';

  @override
  Future<void> saveConflict(SyncConflict conflict) async {
    await _box(_conflictBox).put(
      _conflictKey(conflict.entity, conflict.recordId),
      jsonEncode(conflict.toJson()),
    );
  }

  @override
  Future<List<SyncConflict>> getConflicts({String? entity}) async {
    final result = <SyncConflict>[];
    for (final raw in _box(_conflictBox).values) {
      final conflict = SyncConflict.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (entity != null && entity.isNotEmpty && conflict.entity != entity) {
        continue;
      }
      result.add(conflict);
    }
    return result;
  }

  @override
  Future<void> deleteConflict(String entity, String recordId) async {
    await _box(_conflictBox).delete(_conflictKey(entity, recordId));
  }

  // ---------------------------------------------------------------------------
  // Atomic transaction (best-effort on web) + scoped metadata
  // ---------------------------------------------------------------------------

  @override
  Future<void> applyTransaction(LocalTransaction transaction) async {
    // Web/Hive has no cross-box transaction. We apply records first, then
    // outbox entries; each write is individually idempotent (keyed by
    // offline_id / operationId) so a crash between the two is recoverable.
    // This is documented as best-effort, NOT atomic, on web.
    for (final rec in transaction.records) {
      await saveRecord(
        table: rec.table,
        offlineId: rec.offlineId,
        data: rec.data,
        isSynced: rec.isSynced,
      );
    }
    for (final entry in transaction.outbox) {
      await enqueueOutbox(entry);
    }
  }

  @override
  Future<void> setMetadata(String key, String value) async {
    await _box(_metadataBox).put(key, value);
  }

  @override
  Future<String?> getMetadata(String key) async {
    return _box(_metadataBox).get(key);
  }

  @override
  Future<void> removeMetadata(String key) async {
    await _box(_metadataBox).delete(key);
  }

  // ---------------------------------------------------------------------------
  // Read-only master mirror
  // ---------------------------------------------------------------------------

  String _mirrorKey(String table, String id) => '$table::$id';

  @override
  Future<void> saveMirror(
    String table,
    List<Map<String, dynamic>> records,
  ) async {
    final box = _box(_mirrorBox);
    // Remove existing entries for this table.
    final stale = <String>[];
    for (final key in box.keys) {
      if (key.startsWith('$table::')) stale.add(key);
    }
    for (final key in stale) {
      await box.delete(key);
    }
    for (final row in records) {
      final id = (row['offline_id'] ?? row['id'])?.toString();
      if (id == null || id.isEmpty) continue;
      await box.put(_mirrorKey(table, id), jsonEncode(row));
    }
  }

  @override
  Future<void> upsertMirrorRow(
    String table,
    Map<String, dynamic> record,
  ) async {
    final id = (record['offline_id'] ?? record['id'])?.toString();
    if (id == null || id.isEmpty) return;
    await _box(_mirrorBox).put(_mirrorKey(table, id), jsonEncode(record));
  }

  @override
  Future<void> deleteMirrorRow(String table, String recordId) async {
    final box = _box(_mirrorBox);
    // Match both the business id and a stored offline id.
    final stale = <String>[];
    for (final key in box.keys) {
      if (!key.startsWith('$table::')) continue;
      final raw = box.get(key);
      if (raw == null) {
        stale.add(key);
        continue;
      }
      final row = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (key == _mirrorKey(table, recordId) ||
          row['id']?.toString() == recordId ||
          row['offline_id']?.toString() == recordId) {
        stale.add(key);
      }
    }
    for (final key in stale) {
      await box.delete(key);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getMirror(String table) async {
    final box = _box(_mirrorBox);
    final result = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      if (!key.startsWith('$table::')) continue;
      final raw = box.get(key);
      if (raw == null) continue;
      result.add((jsonDecode(raw) as Map).cast<String, dynamic>());
    }
    return result;
  }

  @override
  Future<void> close() async {
    for (final box in _boxes.values) {
      await box.close();
    }
    _boxes.clear();
    _initialized = false;
  }
}
