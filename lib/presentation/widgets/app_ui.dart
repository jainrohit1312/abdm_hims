import 'package:flutter/material.dart';

import 'smart_navigation.dart';

/// ---------------------------------------------------------------------------
/// Responsive breakpoints & helpers
/// ---------------------------------------------------------------------------
class AppBreakpoints {
  AppBreakpoints._();

  /// Phones / small browser windows.
  static const double compact = 600;

  /// Tablets / medium windows.
  static const double medium = 1024;

  /// Desktop windows.
  static const double expanded = 1280;
}

/// Standard vertical gaps used between form elements.
class AppGap {
  AppGap._();

  static const SizedBox xxs = SizedBox(height: 4);
  static const SizedBox xs = SizedBox(height: 8);
  static const SizedBox sm = SizedBox(height: 12);
  static const SizedBox md = SizedBox(height: 16);
  static const SizedBox lg = SizedBox(height: 24);
  static const SizedBox xl = SizedBox(height: 32);
}

extension AppResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;

  bool get isCompact => screenWidth < AppBreakpoints.compact;

  bool get isMedium =>
      screenWidth >= AppBreakpoints.compact && screenWidth < AppBreakpoints.medium;

  bool get isWide => screenWidth >= AppBreakpoints.medium;

  /// Standard horizontal page padding (smaller on phones).
  double get pageHorizontalPadding => isCompact ? 16 : 24;

  EdgeInsets get pagePadding =>
      EdgeInsets.fromLTRB(pageHorizontalPadding, 16, pageHorizontalPadding, 32);
}

/// ---------------------------------------------------------------------------
/// AppPage — consistent responsive scaffold for module screens.
///
/// Provides the SmartAppBar, a bottom safe-area, responsive horizontal padding
/// and a max content width so forms stay readable on desktop monitors.
/// ---------------------------------------------------------------------------
class AppPage extends StatelessWidget {
  const AppPage({
    required this.title,
    required this.children,
    super.key,
    this.actions,
    this.floatingActionButton,
    this.padding,
    this.maxWidth,
    this.scrollable = true,
    this.isRootPage,
    this.body,
  });

  final String title;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  /// Pre-built body. When provided, [children] is ignored.
  final Widget? body;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final double? maxWidth;
  final bool scrollable;
  final bool? isRootPage;

  @override
  Widget build(BuildContext context) {
    final effectivePadding = padding ?? context.pagePadding;

    final content = body ??
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );

    final padded = Padding(
      padding: effectivePadding,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth ?? _maxContentWidth(context),
          ),
          child: content,
        ),
      ),
    );

    return Scaffold(
      appBar: SmartAppBar(
        title: Text(title),
        actions: actions,
        isRootPage: isRootPage,
      ),
      floatingActionButton: floatingActionButton,
      body: SafeArea(
        top: false,
        child: scrollable ? SingleChildScrollView(child: padded) : padded,
      ),
    );
  }
}

double _maxContentWidth(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1400) return 1200;
  if (width >= 900) return 1040;
  return double.infinity;
}

/// ---------------------------------------------------------------------------
/// AppSectionCard — flat card with optional header row.
/// ---------------------------------------------------------------------------
class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    required this.child,
    super.key,
    this.title,
    this.subtitle,
    this.action,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.color,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = title != null || action != null;

    return Card(
      margin: margin,
      color: color,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasHeader) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (title != null)
                          Text(
                            title!,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(width: 8),
                    action!,
                  ],
                ],
              ),
              const SizedBox(height: 14),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// AppSectionHeader — "Section title + optional trailing action" outside a card.
/// ---------------------------------------------------------------------------
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: 8),
          action!,
        ],
      ],
    );
  }
}

/// ---------------------------------------------------------------------------
/// AppFieldRow — lays form fields side by side on wide screens and stacks them
/// on phones, which fixes the "two fields squeezed together" overflow.
/// ---------------------------------------------------------------------------
class AppFieldRow extends StatelessWidget {
  const AppFieldRow({
    required this.children,
    super.key,
    this.gap = 12,
  });

  /// Usually two widgets (each field already wrapped in `Expanded`-friendly
  /// containers). When more than two are provided they are distributed evenly.
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // On phones, stack fields vertically.
        if (constraints.maxWidth < AppBreakpoints.compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(height: gap),
                children[i],
              ],
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(child: children[i]),
            ],
          ],
        );
      },
    );
  }
}

/// ---------------------------------------------------------------------------
/// AppResponsiveGrid — grid that picks its column count from the available
/// width instead of a hard-coded `crossAxisCount` (fixes overflow on phones).
/// ---------------------------------------------------------------------------
class AppResponsiveGrid extends StatelessWidget {
  const AppResponsiveGrid({
    required this.itemCount,
    required this.itemBuilder,
    super.key,
    this.minItemWidth = 150,
    this.spacing = 12,
    this.childAspectRatio = 0.95,
    this.shrinkWrap = true,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double minItemWidth;
  final double spacing;
  final double childAspectRatio;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: minItemWidth,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }
}

/// ---------------------------------------------------------------------------
/// AppSubmitButton — full-width primary action with loading state.
/// ---------------------------------------------------------------------------
class AppSubmitButton extends StatelessWidget {
  const AppSubmitButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.loading = false,
    this.icon,
    this.variant = AppButtonVariant.filled,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final AppButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          )
        : icon == null
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 8),
                  Text(label),
                ],
              );

    return SizedBox(
      width: double.infinity,
      child: switch (variant) {
        AppButtonVariant.filled => FilledButton(
            onPressed: loading ? null : onPressed,
            child: child,
          ),
        AppButtonVariant.elevated => ElevatedButton(
            onPressed: loading ? null : onPressed,
            child: child,
          ),
        AppButtonVariant.outlined => OutlinedButton(
            onPressed: loading ? null : onPressed,
            child: child,
          ),
      },
    );
  }
}

enum AppButtonVariant { filled, elevated, outlined }

/// ---------------------------------------------------------------------------
/// AppInfoBanner — themed inline notice (info / success / warning / error).
/// Replaces hand-rolled `Container(color: Colors.orange[50], ...)` banners so
/// dark mode and spacing stay consistent.
/// ---------------------------------------------------------------------------
enum AppBannerTone { info, success, warning, error }

class AppInfoBanner extends StatelessWidget {
  const AppInfoBanner({
    required this.message,
    super.key,
    this.tone = AppBannerTone.info,
    this.icon,
    this.padding = const EdgeInsets.all(12),
  });

  final String message;
  final AppBannerTone tone;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (Color background, Color foreground, IconData defaultIcon) = switch (
        tone) {
      AppBannerTone.info => (
          scheme.primaryContainer.withValues(alpha: 0.45),
          scheme.onPrimaryContainer,
          Icons.info_outline,
        ),
      AppBannerTone.success => (
          const Color(0xFFE8F5E9),
          const Color(0xFF1B5E20),
          Icons.check_circle_outline,
        ),
      AppBannerTone.warning => (
          const Color(0xFFFFF4E5),
          const Color(0xFF8A5300),
          Icons.warning_amber_rounded,
        ),
      AppBannerTone.error => (
          scheme.errorContainer.withValues(alpha: 0.5),
          scheme.onErrorContainer,
          Icons.error_outline,
        ),
    };

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: foreground.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? defaultIcon, size: 20, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: foreground,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
