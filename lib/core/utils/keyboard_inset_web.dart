import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Web implementation of [KeyboardInset].
///
/// Android Chrome (and a few other mobile browsers) may open the keyboard
/// without giving Flutter a usable `viewInsets.bottom`. Instead of relying on
/// the engine, we read the browser geometry directly:
///
/// * `navigator.virtualKeyboard.boundingRect.height` — most reliable on Chrome
///   Android when `interactive-widget=overlays-content` is active.
/// * `window.innerHeight - visualViewport.height` — fallback for browsers that
///   keep the default `resizes-visual` behaviour (iOS Safari, older Chrome).
///
/// We also pin the viewport to `interactive-widget=overlays-content` so the
/// browser stops resizing the Flutter canvas when the keyboard appears. That
/// keeps the layout stable and lets THIS code add keyboard padding itself.
double _currentKeyboardInset = 0.0;
final List<void Function()> _listeners = <void Function()>[];
bool _configured = false;

double get currentKeyboardInset => _currentKeyboardInset;

void ensureConfigured() {
  if (_configured) return;
  _configured = true;
  _applyOverlaysContent();
  _currentKeyboardInset = _readKeyboardInset();
  _subscribe();
}

void addKeyboardInsetListener(void Function() listener) {
  if (!_listeners.contains(listener)) {
    _listeners.add(listener);
  }
}

void removeKeyboardInsetListener(void Function() listener) {
  _listeners.remove(listener);
}

JSObject get _window => globalContext;

/// Sets `interactive-widget=overlays-content` on Flutter's generated viewport
/// meta and enables `navigator.virtualKeyboard.overlaysContent`.
///
/// Flutter's engine replaces any hand-written viewport meta with its own during
/// startup, so this must run from Dart AFTER engine initialization (i.e. from
/// `main()`).
void _applyOverlaysContent() {
  try {
    final document = _window['document'] as JSObject?;
    final head = document?['head'] as JSObject?;
    if (head == null) return;

    final metas = head.callMethodVarArgs<JSObject>(
      'querySelectorAll'.toJS,
      <JSAny?>['meta[name="viewport"]'.toJS],
    );
    final length = (metas['length'] as JSNumber?)?.toDartInt ?? 0;
    for (var i = 0; i < length; i++) {
      final meta = metas.callMethod<JSObject>('item'.toJS, i.toJS);
      final content = (meta['content'] as JSString?)?.toDart ?? '';
      if (content.isNotEmpty && !content.contains('interactive-widget')) {
        meta['content'] = '$content, interactive-widget=overlays-content'.toJS;
      }
    }

    final navigator = _window['navigator'] as JSObject?;
    final virtualKeyboard = navigator?['virtualKeyboard'] as JSObject?;
    if (virtualKeyboard != null) {
      try {
        virtualKeyboard['overlaysContent'] = true.toJS;
      } catch (_) {
        // Property not writable on this browser; the meta tag above still
        // covers Chrome-based browsers.
      }
    }
  } catch (_) {
    // Keyboard handling must never break app startup.
  }
}

double _readKeyboardInset() {
  try {
    var inset = 0.0;

    // visualViewport fallback sirf mobile browsers par use karo — desktop par
    // page-zoom se false positive aa sakta hai.
    if (_isMobileBrowser) {
      final windowInnerHeight =
          (_window['innerHeight'] as JSNumber?)?.toDartDouble ?? 0.0;
      final visualViewport = _window['visualViewport'] as JSObject?;
      if (visualViewport != null) {
        final visualHeight =
            (visualViewport['height'] as JSNumber?)?.toDartDouble ??
            windowInnerHeight;
        inset = windowInnerHeight - visualHeight;
        if (inset < 0) inset = 0;
      }
    }

    final navigator = _window['navigator'] as JSObject?;
    final virtualKeyboard = navigator?['virtualKeyboard'] as JSObject?;
    final boundingRect = virtualKeyboard?['boundingRect'] as JSObject?;
    final keyboardHeight =
        (boundingRect?['height'] as JSNumber?)?.toDartDouble ?? 0.0;
    if (keyboardHeight > inset) inset = keyboardHeight;

    return inset;
  } catch (_) {
    return 0.0;
  }
}

bool get _isMobileBrowser {
  try {
    final navigator = _window['navigator'] as JSObject?;
    final userAgent = (navigator?['userAgent'] as JSString?)?.toDart ?? '';
    return userAgent.contains('Android') ||
        userAgent.contains('iPhone') ||
        userAgent.contains('iPad') ||
        userAgent.contains('iPod');
  } catch (_) {
    return false;
  }
}

void _subscribe() {
  void onKeyboardChanged(JSObject _) {
    final inset = _readKeyboardInset();
    if ((inset - _currentKeyboardInset).abs() < 0.5) return;
    _currentKeyboardInset = inset;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  try {
    final visualViewport = _window['visualViewport'] as JSObject?;
    visualViewport?.callMethodVarArgs<JSObject>(
      'addEventListener'.toJS,
      <JSAny?>['resize'.toJS, onKeyboardChanged.toJS],
    );
    visualViewport?.callMethodVarArgs<JSObject>(
      'addEventListener'.toJS,
      <JSAny?>['scroll'.toJS, onKeyboardChanged.toJS],
    );

    final navigator = _window['navigator'] as JSObject?;
    final virtualKeyboard = navigator?['virtualKeyboard'] as JSObject?;
    virtualKeyboard?.callMethodVarArgs<JSObject>(
      'addEventListener'.toJS,
      <JSAny?>['geometrychange'.toJS, onKeyboardChanged.toJS],
    );
  } catch (_) {
    // Listener setup is best-effort.
  }
}
