import 'package:flutter/material.dart';

/// Global authenticated-shell footer.
///
/// Branding ONLY. This widget deliberately contains no keyboard, scroll or
/// form logic — those concerns live in `keyboard_safe_content.dart` and in the
/// screens themselves.
///
/// It reuses the existing MediFlux lockup from `assets/branding/` (the same
/// asset the global header uses) and adds the Edwin Pharma subsidiary line in
/// plain text, so no new image assets are required.
class AppFooter extends StatelessWidget {
  const AppFooter({super.key});

  /// Shared MediFlux logo lockup (same asset as the header/drawer brand).
  static const String _logoAsset =
      'assets/branding/mediflux_header_logo_light.png';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final year = DateTime.now().year;
    final mediaSize = MediaQuery.sizeOf(context);
    final isCompact = mediaSize.width < 600;

    // Mobile-only scroll runway: pages need extra scrollable content below
    // their last TextField so the field (and any suggestion dropdown) can be
    // scrolled well above the on-screen keyboard. The reserve is intentionally
    // plain whitespace appended after the branding and only applies on phones;
    // tablet/desktop keep the compact footer.
    final mobileScrollReserve = isCompact
        ? (mediaSize.height * 0.30).clamp(220.0, 340.0).toDouble()
        : 0.0;

    return Material(
      color: colorScheme.surface,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 16 : 24,
          vertical: isCompact ? 12 : 14,
        ),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: isCompact
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildCompactLayout(colorScheme, textTheme, year),
                    SizedBox(height: mobileScrollReserve),
                  ],
                )
              : _buildWideLayout(colorScheme, textTheme, year),
        ),
      ),
    );
  }

  /// Mobile/compact: stacked, centred lockup so the footer stays subtle on
  /// small screens.
  Widget _buildCompactLayout(
    ColorScheme colorScheme,
    TextTheme textTheme,
    int year,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          _logoAsset,
          height: 22,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        const SizedBox(height: 6),
        Text(
          'MediFlux',
          style: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'A subsidiary of Edwin Pharma',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        Text(
          'Hospital Management & Digital Healthcare Platform',
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          '© $year Edwin Pharma',
          style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// Desktop/wide: compact horizontal lockup.
  Widget _buildWideLayout(
    ColorScheme colorScheme,
    TextTheme textTheme,
    int year,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          _logoAsset,
          height: 24,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 2,
            children: [
              Text(
                'MediFlux',
                style: textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              Text(
                '— A subsidiary of Edwin Pharma',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '· Hospital Management & Digital Healthcare Platform',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
              Text(
                '· © $year Edwin Pharma',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
