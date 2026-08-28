import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Web implementation of runtime environment access.
///
/// Reads `window._env_.<key>`, which is written by `web/env.js`. On Vercel the
/// build script (`npm run vercel-build`) regenerates `web/env.js` from the
/// project environment variables; locally the committed empty template lets
/// the caller fall back to `--dart-define` values and dev constants.
String? readRuntimeEnv(String key) {
  try {
    final rawEnv = globalContext['_env_'];
    if (rawEnv == null || !rawEnv.isA<JSObject>()) return null;
    final env = rawEnv as JSObject;

    final rawValue = env[key];
    if (rawValue == null) return null;

    if (rawValue.isA<JSString>()) {
      return (rawValue as JSString).toDart;
    }
    return rawValue.toString();
  } catch (_) {
    // `window._env_` may be missing or malformed on local/dev builds; the
    // caller falls back to --dart-define values and local constants.
    return null;
  }
}
