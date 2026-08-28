import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp API Key Cipher
/// ---------------------------------------------------------------------------
/// Meta WhatsApp access tokens are stored **encrypted** in Supabase. Because
/// the project has no dedicated AES package, this helper implements a keyed
/// stream cipher on top of `crypto`'s HMAC-SHA256:
///
///   secret   = 32 random bytes persisted in FlutterSecureStorage
///   iv       = 16 random bytes, unique per encryption
///   keystream = HMAC-SHA256(secret, iv) (repeated as needed)
///   cipher    = plaintext XOR keystream
///
/// The stored value is `v1.<base64url(iv || cipher)>`. Decryption needs the
/// same device secret, so the encrypted key can only be read on a device that
/// has already stored the secret. For cross-device key rotation / strongest
/// guarantees, a production deployment should move encryption to a Supabase
/// Edge Function (pgsodium) — the app-side contract stays the same.
/// ---------------------------------------------------------------------------
class WhatsappKeyCipher {
  static const String _secretStorageKey = 'whatsapp_api_key_secret_v1';
  static const int _ivLength = 16;

  final FlutterSecureStorage _storage;

  WhatsappKeyCipher(this._storage);

  /// Encrypts [plainText]. Returns an empty string when the input is empty.
  Future<String> encrypt(String plainText) async {
    if (plainText.isEmpty) return '';
    final secret = await _getOrCreateSecret();
    final iv = _randomBytes(_ivLength);
    final keystream = _keystream(secret, iv);
    final plain = utf8.encode(plainText);

    final cipher = List<int>.generate(
      plain.length,
      (i) => plain[i] ^ keystream[i % keystream.length],
    );

    return 'v1.${base64Url.encode([...iv, ...cipher])}';
  }

  /// Decrypts a value produced by [encrypt]. Values that were stored before
  /// encryption was introduced (plaintext, or non `v1.` prefixed) are returned
  /// unchanged for backwards compatibility.
  Future<String> decrypt(String stored) async {
    if (stored.isEmpty || !stored.startsWith('v1.')) return stored;
    final secret = await _getOrCreateSecret();

    try {
      final bytes = base64Url.decode(stored.substring(3));
      if (bytes.length <= _ivLength) return '';
      final iv = bytes.sublist(0, _ivLength);
      final cipher = bytes.sublist(_ivLength);
      final keystream = _keystream(secret, iv);

      final plain = List<int>.generate(
        cipher.length,
        (i) => cipher[i] ^ keystream[i % keystream.length],
      );
      return utf8.decode(plain);
    } catch (_) {
      // Corrupt / tampered payload — fail closed with an empty value so the
      // caller re-prompts for credentials instead of using garbage.
      return '';
    }
  }

  Future<List<int>> _getOrCreateSecret() async {
    var secret = await _storage.read(key: _secretStorageKey);
    if (secret != null && secret.isNotEmpty) {
      return utf8.encode(secret);
    }
    final raw = _randomBytes(32);
    final encoded = base64Url.encode(raw);
    await _storage.write(key: _secretStorageKey, value: encoded);
    return utf8.encode(encoded);
  }

  List<int> _keystream(List<int> secret, List<int> iv) {
    return Hmac(sha256, secret).convert(iv).bytes;
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
