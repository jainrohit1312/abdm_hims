/// Native (non-web) implementation of [KeyboardInset].
///
/// Native platforms already report reliable `MediaQuery.viewInsets`, so this
/// stub contributes nothing.
double get currentKeyboardInset => 0.0;

void ensureConfigured() {}

void addKeyboardInsetListener(void Function() listener) {}

void removeKeyboardInsetListener(void Function() listener) {}
