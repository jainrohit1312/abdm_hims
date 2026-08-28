import 'package:flutter/foundation.dart' show kIsWeb;

import 'supabase_web_config_stub.dart'
    if (dart.library.js_interop) 'supabase_web_config_web.dart'
    as platform;

/// Web-aware runtime configuration for values that differ per environment
/// (Supabase, DeepSeek, ...).
///
/// Resolution order for every value:
///   1. Runtime `window._env_` (web builds only) — `web/env.js` is generated
///      by the Vercel build script in `package.json` from Vercel environment
///      variables (`process.env` on the build machine).
///   2. Compile-time `--dart-define` — the Vercel build script also passes
///      `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `DEEPSEEK_API_KEY` as
///      dart-defines, which `String.fromEnvironment` reads here.
///   3. Local-development fallbacks — keep the app runnable with a plain
///      `flutter run` when no environment configuration is present.
///
/// Non-web platforms skip step 1 via the [kIsWeb] guard (they have no
/// `window` object); they still honour dart-defines and the fallbacks.
class SupabaseWebConfig {
  SupabaseWebConfig._();

  // Compile-time defines. The Vercel build script passes these from
  // process.env; `String.fromEnvironment` returns '' when a define is absent.
  static const String _dartDefineSupabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
  );
  static const String _dartDefineSupabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );
  static const String _dartDefineDeepSeekApiKey = String.fromEnvironment(
    'DEEPSEEK_API_KEY',
  );

  // Local-development fallbacks. These keep `flutter run` working out of the
  // box and are only used when no env var / dart-define is configured.
  static const String _fallbackSupabaseUrl =
      'https://hzwnguirzdnvqjkxxilz.supabase.co';
  static const String _fallbackSupabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6d25ndWlyemRudnFqa3h4aWx6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYzODQ3NTMsImV4cCI6MjEwMTk2MDc1M30.rmBa3WnaXr9Gd3UT7nCmFaGULwZcHVLkkjx9qBNp84I';
  static const String _fallbackDeepSeekApiKey =
      'sk-0aa3fc4161c941acb7dc117a14eb077f';

  /// Supabase project URL.
  static String get supabaseUrl => _resolve(
        runtimeValue: _readRuntimeEnv('SUPABASE_URL'),
        dartDefine: _dartDefineSupabaseUrl,
        fallback: _fallbackSupabaseUrl,
      );

  /// Supabase anon (public) key.
  ///
  /// This key is designed to be shipped to browsers — row level security (RLS)
  /// keeps the data protected. Never put the `service_role` key here.
  static String get supabaseAnonKey => _resolve(
        runtimeValue: _readRuntimeEnv('SUPABASE_ANON_KEY'),
        dartDefine: _dartDefineSupabaseAnonKey,
        fallback: _fallbackSupabaseAnonKey,
      );

  /// DeepSeek API key used by the clinical counseling summarization flow.
  ///
  /// NOTE: client-side apps cannot keep this key secret. Prefer proxying the
  /// DeepSeek call through a Supabase Edge Function in production.
  static String get deepSeekApiKey => _resolve(
        runtimeValue: _readRuntimeEnv('DEEPSEEK_API_KEY'),
        dartDefine: _dartDefineDeepSeekApiKey,
        fallback: _fallbackDeepSeekApiKey,
      );

  /// Reads a value from `window._env_` at runtime (web builds only).
  ///
  /// Never throws — any JS-interop or missing-window issue resolves to `null`
  /// so the caller falls through to the next configuration source.
  static String? _readRuntimeEnv(String key) {
    if (!kIsWeb) return null;
    try {
      return platform.readRuntimeEnv(key);
    } catch (_) {
      return null;
    }
  }

  /// Returns the first non-empty configuration value, in priority order.
  static String _resolve({
    required String? runtimeValue,
    required String dartDefine,
    required String fallback,
  }) {
    final runtime = _clean(runtimeValue);
    if (runtime != null) return runtime;

    final define = _clean(dartDefine);
    if (define != null) return define;

    return fallback;
  }

  /// Normalizes a raw configuration value. Empty strings and placeholder
  /// values are treated as "not configured" so the next source is used.
  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('YOUR_') || trimmed.startsWith('your_')) return null;
    return trimmed;
  }
}
