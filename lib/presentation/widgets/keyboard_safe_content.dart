import 'package:flutter/material.dart';

import '../../core/utils/keyboard_inset.dart';

/// Keyboard-safe layout helpers shared by the authenticated shell (and any
/// screen that needs the same behaviour).
///
/// The global shell applies these for every authenticated page, so individual
/// screens do NOT need to add their own keyboard padding — doing so would
/// double-pad. Screens with a custom overlay strategy (e.g. OPD Consultation,
/// which keeps `resizeToAvoidBottomInset: false`) keep their existing logic.
///
/// This file intentionally contains keyboard/layout helpers only. Branding
/// (AppFooter) and shell composition (AppNavigationShell) live elsewhere.

/// Bottom inset contributed by the on-screen keyboard for the current context.
///
/// * Native (Android/iOS/desktop): returns `MediaQuery.viewInsets.bottom`
///   (the engine-reported inset). The browser-reported [KeyboardInset] is
///   always `0` there.
/// * Web (Android Chrome + `interactive-widget=overlays-content`): the engine
///   often keeps `viewInsets.bottom` at `0` while the keyboard overlays the
///   canvas, so the browser-reported [KeyboardInset.current] value is used.
///
/// The shell uses this only to decide whether a keyboard is open (for example
/// to hide the branding footer while typing). The actual space reservation is
/// split per platform — see [engineReportsKeyboardInset].
double keyboardInsetOf(BuildContext context) {
  final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
  final webInset = KeyboardInset.current;
  return viewInsets > webInset ? viewInsets : webInset;
}

/// Whether the engine itself is reporting a keyboard inset for [context].
///
/// Used by the shell to decide whether the browser-reported web inset must be
/// reserved manually (`false`) or whether the child Scaffolds already consume
/// `viewInsets` themselves (`true`, native resize / custom overlay screens).
bool engineReportsKeyboardInset(BuildContext context) =>
    MediaQuery.viewInsetsOf(context).bottom > 0;

/// Scrolls the currently focused field into view after the keyboard
/// open/close animation has had a chance to settle.
///
/// Native `Scaffold` resizing already keeps the focused field visible, but on
/// mobile web the browser keyboard height is applied by the shell as extra
/// padding; without this call the focused field can end up just behind the
/// keyboard until the user scrolls manually.
void ensureFocusedFieldVisible({double alignment = 0.3}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Wait for the keyboard padding animation to settle so ensureVisible
    // measures the final viewport instead of a stale position.
    Future.delayed(const Duration(milliseconds: 220), () {
      final focusNode = FocusManager.instance.primaryFocus;
      final fieldContext = focusNode?.context;
      if (fieldContext == null || !fieldContext.mounted) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: alignment,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  });
}
