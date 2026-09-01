import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Root (top-level module) paths whose AppBar back-arrow slot is replaced by a
/// Home icon. These screens have no meaningful parent inside the app shell, so
/// the Home icon navigates to `/dashboard` instead of popping.
const Set<String> kRootModulePaths = {
  '/dashboard',
  '/patients',
  '/opd/queue',
  '/ipd/queue',
  '/ipd/wards',
  '/billing',
  '/vouchers',
  '/compliance',
  '/diagnostics',
  '/settings',
  '/users',
  '/employees',
  '/marketing',
  '/notifications',
  '/whatsapp',
  '/reports',
};

/// Whether [path] is a root (top-level module) path.
bool isRootModulePath(String path) => kRootModulePaths.contains(path);

/// Smart AppBar leading for module screens.
///
/// - Root pages (see [kRootModulePaths]) show `Icons.home` and navigate to
///   `/dashboard`.
/// - Child pages show a regular back button and call `context.pop()` (with a
///   safe fallback to `/dashboard` when there is nothing to pop, e.g. after a
///   deep link or `context.go` navigation).
/// - Routes pushed outside go_router (e.g. the full-screen QR scanner) fall
///   back to `Navigator.maybePop`.
class SmartBackButton extends StatelessWidget {
  const SmartBackButton({super.key, this.isRootPage});

  /// Optional override. When `null`, the current GoRouter path decides.
  final bool? isRootPage;

  bool _isGoRoute(BuildContext context) {
    try {
      GoRouterState.of(context);
      return true;
    } on GoError {
      return false;
    }
  }

  bool _isRoot(BuildContext context) {
    final override = isRootPage;
    if (override != null) return override;
    try {
      return isRootModulePath(GoRouterState.of(context).uri.path);
    } on GoError {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRoot(context)) {
      return IconButton(
        tooltip: 'Go to Dashboard',
        icon: const Icon(Icons.home),
        onPressed: () => context.go('/dashboard'),
      );
    }

    return BackButton(
      onPressed: () {
        if (!_isGoRoute(context)) {
          // Plain Navigator route (e.g. full-screen QR scanner) — pop it the
          // standard way.
          Navigator.maybePop(context);
          return;
        }
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/dashboard');
        }
      },
    );
  }
}

/// Home action button shown on the right side of every module AppBar.
///
/// Tapping it always navigates to `/dashboard`.
class SmartHomeAction extends StatelessWidget {
  const SmartHomeAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Go to Dashboard',
      icon: const Icon(Icons.home),
      onPressed: () => context.go('/dashboard'),
    );
  }
}

/// AppBar with Smart Back Navigation baked in.
///
/// Use it exactly like [AppBar]: it automatically adds the correct
/// [SmartBackButton] in the leading slot (Home icon on root pages, back arrow
/// on child pages) and appends a [SmartHomeAction] to the actions.
class SmartAppBar extends AppBar {
  SmartAppBar({
    super.key,
    Widget? leading,
    super.automaticallyImplyLeading,
    super.title,
    List<Widget>? actions,
    super.bottom,
    super.backgroundColor,
    super.centerTitle,
    super.elevation,
    super.scrolledUnderElevation,
    super.titleSpacing,
    super.toolbarHeight,
    super.leadingWidth,
    this.isRootPage,
  }) : super(
         leading: leading ?? SmartBackButton(isRootPage: isRootPage),
         actions: [...?actions, const SmartHomeAction()],
       );

  /// Optional override for root-page detection. When `null`, the current
  /// GoRouter path is used.
  final bool? isRootPage;
}
