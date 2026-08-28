/// Non-web stub for runtime environment access.
///
/// Native platforms (Android, iOS, Windows, Linux, macOS) have no
/// `window._env_`; they rely on `--dart-define` values and the local
/// fallbacks in `SupabaseWebConfig`.
String? readRuntimeEnv(String key) => null;
