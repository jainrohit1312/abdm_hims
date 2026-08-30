import 'keyboard_inset_stub.dart'
    if (dart.library.js_interop) 'keyboard_inset_web.dart' as impl;

/// Cross-platform keyboard inset helper.
///
/// Native (Android/iOS/Windows) par ye [0] return karta hai — wahan
/// `MediaQuery.viewInsets` already reliable hota hai. Web par ye browser ke
/// `visualViewport` + `VirtualKeyboard` API se virtual keyboard ki height
/// nikalta hai, kyunki Android Chrome mein Flutter engine kabhi-kabhi
/// `viewInsets.bottom` 0 rakh kar canvas ko hi shrink kar deta hai.
abstract final class KeyboardInset {
  /// Current keyboard height in logical pixels (0 = keyboard closed/unknown).
  static double get current => impl.currentKeyboardInset;

  /// Applies web keyboard configuration (viewport meta + VirtualKeyboard API).
  /// Safe to call multiple times; native platforms par no-op hai.
  static void ensureConfigured() => impl.ensureConfigured();

  /// Notifies listeners when the browser-reported keyboard inset changes.
  static void addListener(void Function() listener) =>
      impl.addKeyboardInsetListener(listener);

  static void removeListener(void Function() listener) =>
      impl.removeKeyboardInsetListener(listener);
}
