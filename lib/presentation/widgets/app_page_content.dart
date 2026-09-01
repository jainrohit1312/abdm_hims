import 'package:flutter/material.dart';

import 'app_footer.dart';

/// Shared page-content helpers that append the global [AppFooter] as the
/// LAST ITEM of a screen's own scroll view.
///
/// These wrappers are used by screens whose body is already a scrollable
/// ([SingleChildScrollView] or [ListView]). The footer is appended inside the
/// same scroll flow, so it scrolls with the page content instead of being
/// pinned to the viewport bottom by the global shell.

/// Drop-in replacement for [SingleChildScrollView] that renders the global
/// footer below the page content inside the SAME scroll view.
///
/// The optional [padding] is applied to the page content only; the footer
/// stays full-width (same look as the previous shell-level footer).
class AppPageScrollView extends StatelessWidget {
  const AppPageScrollView({
    super.key,
    required this.child,
    this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (padding != null)
            Padding(padding: padding!, child: child)
          else
            child,
          const AppFooter(),
        ],
      ),
    );
  }
}

/// Drop-in replacement for `ListView(children: [...])` that renders the global
/// footer as the last list item inside the SAME scroll view.
///
/// The optional [padding] is applied to the page content only; the footer
/// stays full-width.
class AppPageListView extends StatelessWidget {
  const AppPageListView({
    super.key,
    required this.children,
    this.padding,
    this.physics,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: physics,
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: padding ?? EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
        const AppFooter(),
      ],
    );
  }
}
