import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase Auth session ke liye [LocalStorage] implementation jo
/// `flutter_secure_storage` use karta hai.
///
/// Default `SharedPreferencesLocalStorage` session (JWT) ko plain
/// SharedPreferences mein store karta hai — ye security requirement ke
/// khilaf hai. Is class ki madad se Supabase apna poora session JSON
/// (access token + refresh token) secure storage mein rakhta hai.
class SecureLocalStorage extends LocalStorage {
  SecureLocalStorage(
    this._storage, {
    this.persistSessionKey = supabasePersistSessionKey,
  });

  final FlutterSecureStorage _storage;
  final String persistSessionKey;

  @override
  Future<void> initialize() async {
    // Migration/cleanup: purana session agar SharedPreferences mein pada hai
    // to use delete kar do taaki JWT kabhi plain preferences mein na rahe.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(supabasePersistSessionKey);
    } catch (_) {
      // Best effort — secure storage is the source of truth ab.
    }
  }

  @override
  Future<bool> hasAccessToken() async {
    return _storage.containsKey(key: persistSessionKey);
  }

  @override
  Future<String?> accessToken() async {
    return _storage.read(key: persistSessionKey);
  }

  @override
  Future<void> removePersistedSession() async {
    await _storage.delete(key: persistSessionKey);
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    await _storage.write(key: persistSessionKey, value: persistSessionString);
  }
}
