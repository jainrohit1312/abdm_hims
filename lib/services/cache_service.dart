import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../core/utils/logger.dart';

/// Cache keys for the frequently used data (see [CacheService]).
class CacheKeys {
  CacheKeys._();

  static const String doctors = 'doctors_cache';
  static const String departments = 'departments_cache';
  static const String medicines = 'medicines_cache';
  static const String patients = 'patients_cache';

  static const List<String> all = [doctors, departments, medicines, patients];
}

/// Hive-backed TTL cache for frequently used data.
///
/// Each key stores a JSON envelope:
/// ```json
/// {
///   "cached_at": 1756123456789,
///   "hospital_id": "abc-123",
///   "data": [ { ... }, ... ]
/// }
/// ```
///
/// * Data older than [ttl] (5 minutes) is treated as a cache miss and deleted.
/// * The optional `hospital_id` guard ensures a cache written for one tenant is
///   never served to a different tenant.
class CacheService {
  CacheService._();

  /// Process-wide singleton. ProviderScope keeps a reference to the same
  /// instance so every screen shares one Hive box handle.
  static final CacheService instance = CacheService._();

  static const String _boxName = 'hims_frequent_cache';

  /// Time-to-live for cached entries.
  static const Duration ttl = Duration(minutes: 5);

  Box<String>? _box;
  bool _initialized = false;

  /// Opens the Hive box. Safe to call multiple times and safe to call lazily —
  /// the first read/write from any screen will initialise Hive automatically.
  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    _box = await Hive.openBox<String>(_boxName);
    _initialized = true;
  }

  Box<String> get _requireBox {
    final box = _box;
    if (box == null) {
      throw StateError('CacheService.init() must be called before using the cache.');
    }
    return box;
  }

  /// Returns the cached list for [key], or null when:
  /// * there is no entry,
  /// * the entry is older than [ttl],
  /// * the entry was written for a different [hospitalId],
  /// * the stored data is malformed.
  Future<List<Map<String, dynamic>>?> get(
    String key, {
    String? hospitalId,
  }) async {
    await init();
    final raw = _requireBox.get(key);
    if (raw == null || raw.isEmpty) return null;

    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = envelope['cached_at'] as int? ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
      if (age > ttl.inMilliseconds) {
        await _requireBox.delete(key);
        return null;
      }

      // Tenant guard: don't serve hospital A's cache to hospital B.
      final cachedHospitalId = envelope['hospital_id'] as String?;
      if (hospitalId != null &&
          hospitalId.isNotEmpty &&
          cachedHospitalId != null &&
          cachedHospitalId.isNotEmpty &&
          cachedHospitalId != hospitalId) {
        return null;
      }

      final data = envelope['data'];
      if (data is! List) return null;

      return List<Map<String, dynamic>>.from(
        data.map((row) => Map<String, dynamic>.from(row as Map)),
      );
    } catch (e) {
      AppLogger.e('Failed to read Hive cache key "$key"', e);
      await _requireBox.delete(key);
      return null;
    }
  }

  /// Stores [data] under [key] with the current timestamp.
  Future<void> put(
    String key,
    List<Map<String, dynamic>> data, {
    String? hospitalId,
  }) async {
    await init();
    final envelope = jsonEncode({
      'cached_at': DateTime.now().millisecondsSinceEpoch,
      'hospital_id': hospitalId,
      'data': data,
    });
    await _requireBox.put(key, envelope);
  }

  /// True when [key] holds a valid (not expired, tenant-matching) entry.
  Future<bool> isValid(String key, {String? hospitalId}) async {
    return (await get(key, hospitalId: hospitalId)) != null;
  }

  /// Deletes a single cache entry.
  Future<void> invalidate(String key) async {
    await init();
    await _requireBox.delete(key);
  }

  /// Deletes every frequently-used cache entry.
  Future<void> invalidateAll() async {
    await init();
    for (final key in CacheKeys.all) {
      await _requireBox.delete(key);
    }
  }

  /// Timestamp of the last successful write for [key] (null when missing).
  Future<DateTime?> lastUpdated(String key) async {
    await init();
    final raw = _requireBox.get(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = envelope['cached_at'] as int?;
      if (cachedAt == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(cachedAt);
    } catch (_) {
      return null;
    }
  }
}
