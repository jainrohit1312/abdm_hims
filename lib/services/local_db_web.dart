import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'local_db.dart';

/// Factory used by the conditional import in `local_db.dart`.
LocalDatabase createPlatformDatabase() => HiveLocalDatabase();

/// Web implementation backed by Hive (IndexedDB in the browser).
///
/// Each business table gets its own Hive box; values are JSON strings so no
/// custom TypeAdapters are required.
class HiveLocalDatabase implements LocalDatabase {
  bool _initialized = false;
  final Map<String, Box<String>> _boxes = {};

  @override
  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    for (final table in LocalTables.all) {
      _boxes[table] = await Hive.openBox<String>('offline_$table');
    }
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

  @override
  Future<void> close() async {
    for (final box in _boxes.values) {
      await box.close();
    }
    _boxes.clear();
    _initialized = false;
  }
}
