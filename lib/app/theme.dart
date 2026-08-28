import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central design system for HIMS.
///
/// Single source of truth for typography, form fields, buttons, cards and all
/// Material component styling. Screen-level code should consume this theme
/// instead of hard-coding sizes/colours so every device (Android phone,
/// mobile Chrome and desktop) gets a consistent, compact and readable UI.
class AppTheme {
  AppTheme._();

  // ---------------------------------------------------------------------
  // Brand palette
  // ---------------------------------------------------------------------
  /// Deep medical blue — reads as trustworthy and professional.
  static const Color primaryColor = Color(0xFF1565C0);

  /// Teal accent for success states and secondary actions.
  static const Color secondaryColor = Color(0xFF0D9488);

  static const Color errorColor = Color(0xFFD32F2F);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color successColor = Color(0xFF16A34A);
  static const Color infoColor = Color(0xFF0284C7);

  // ---------------------------------------------------------------------
  // Metrics
  // ---------------------------------------------------------------------
  /// Target single-line form field height (compact, finger friendly).
  static const double inputHeight = 48;

  /// Primary action button height.
  static const double buttonHeight = 48;

  /// Standard content padding for full-screen scroll views.
  static const EdgeInsets pagePadding = EdgeInsets.all(16);

  /// Maximum readable width for forms & content on large screens.
  static const double maxContentWidth = 960;

  /// Cards stay below this width and are centred on desktop.
  static const double maxCardWidth = 1120;

  static const double radiusSmall = 8;
  static const double radiusMedium = 12;
  static const double radiusLarge = 16;

  // ---------------------------------------------------------------------
  // Typography (scaled down from Material defaults for a dense, clean UI)
  // ---------------------------------------------------------------------
  static TextTheme _buildTextTheme(Brightness brightness) {
    final base = ThemeData(brightness: brightness).textTheme;
    final textTheme = GoogleFonts.interTextTheme(base);

    return textTheme
        .copyWith(
          displaySmall: textTheme.displaySmall?.copyWith(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
          headlineLarge: textTheme.headlineLarge?.copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
          headlineMedium: textTheme.headlineMedium?.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          headlineSmall: textTheme.headlineSmall?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          titleLarge: textTheme.titleLarge?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          titleMedium: textTheme.titleMedium?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
          titleSmall: textTheme.titleSmall?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
          bodyLarge: textTheme.bodyLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            height: 1.45,
          ),
          bodyMedium: textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.45,
          ),
          bodySmall: textTheme.bodySmall?.copyWith(
            fontSize: 12.5,
            fontWeight: FontWeight.w400,
            height: 1.4,
          ),
          labelLarge: textTheme.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          labelMedium: textTheme.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          labelSmall: textTheme.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        )
        .apply(fontFamily: GoogleFonts.inter().fontFamily);
  }

  // ---------------------------------------------------------------------
  // Input decoration — the main fix for "oversized text boxes".
  // 14px horizontal + 13px vertical padding with a 15px font keeps a
  // single-line field at ~48px tall while multi-line fields still grow.
  // ---------------------------------------------------------------------
  static InputDecorationTheme _buildInputDecoration(ColorScheme scheme) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusMedium),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 13,
      ),
      labelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant,
      ),
      hintStyle: TextStyle(
        fontSize: 14,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
      errorStyle: TextStyle(fontSize: 12, color: scheme.error, height: 1.2),
      helperStyle: TextStyle(
        fontSize: 12,
        color: scheme.onSurfaceVariant,
        height: 1.2,
      ),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
      floatingLabelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: scheme.primary,
      ),
      prefixIconConstraints: const BoxConstraints(
        minWidth: 44,
        minHeight: 44,
      ),
      suffixIconConstraints: const BoxConstraints(
        minWidth: 44,
        minHeight: 44,
      ),
      errorMaxLines: 2,
      helperMaxLines: 2,
      border: border,
      enabledBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
      disabledBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Themes
  // ---------------------------------------------------------------------
  static ThemeData get lightTheme => _buildTheme(Brightness.light);

  static ThemeData get darkTheme => _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      secondary: secondaryColor,
      error: errorColor,
      brightness: brightness,
    ).copyWith(
      // Soft app background so white/raised surfaces read as "cards".
      surface: isDark ? const Color(0xFF111827) : Colors.white,
      onSurface: isDark ? const Color(0xFFE5E7EB) : const Color(0xFF111827),
    );

    final scaffoldBackground = isDark
        ? const Color(0xFF0B1220)
        : const Color(0xFFF4F6FA);

    final textTheme = _buildTextTheme(brightness);

    final buttonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, buttonHeight)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      textStyle: WidgetStatePropertyAll(
        textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      elevation: const WidgetStatePropertyAll(0),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBackground,
      textTheme: textTheme,

      // ---------------------------------------------------------------
      // App bars
      // ---------------------------------------------------------------
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 56,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant, size: 22),
        actionsIconTheme: IconThemeData(
          color: colorScheme.onSurfaceVariant,
          size: 22,
        ),
      ),

      // ---------------------------------------------------------------
      // Cards — flat with a hairline border (modern, less bulky)
      // ---------------------------------------------------------------
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),

      // ---------------------------------------------------------------
      // Form fields
      // ---------------------------------------------------------------
      inputDecorationTheme: _buildInputDecoration(colorScheme),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.25),
        selectionHandleColor: colorScheme.primary,
      ),

      // ---------------------------------------------------------------
      // Buttons
      // ---------------------------------------------------------------
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: buttonStyle.merge(
          ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            disabledBackgroundColor: colorScheme.onSurface.withValues(alpha: 0.10),
            disabledForegroundColor: colorScheme.onSurface.withValues(alpha: 0.35),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: buttonStyle.merge(
          FilledButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: buttonStyle.merge(
          OutlinedButton.styleFrom(
            foregroundColor: colorScheme.primary,
            side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.7)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          visualDensity: VisualDensity.standard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),

      // ---------------------------------------------------------------
      // Menus, dialogs & sheets
      // ---------------------------------------------------------------
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge)),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLarge)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),

      // ---------------------------------------------------------------
      // Lists & navigation
      // ---------------------------------------------------------------
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        horizontalTitleGap: 12,
        minVerticalPadding: 8,
        iconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurface,
        titleTextStyle: textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurface,
        ),
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
      ),

      // ---------------------------------------------------------------
      // Chips & selection controls
      // ---------------------------------------------------------------
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        selectedColor: colorScheme.primaryContainer,
        labelStyle: textTheme.labelMedium?.copyWith(color: colorScheme.onSurface),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: colorScheme.onPrimaryContainer,
        ),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      checkboxTheme: CheckboxThemeData(
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: colorScheme.outline, width: 1.4),
      ),
      radioTheme: RadioThemeData(),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(colorScheme.onPrimary),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colorScheme.primary
              : colorScheme.outlineVariant,
        ),
      ),

      // ---------------------------------------------------------------
      // Dropdowns & pickers
      // ---------------------------------------------------------------
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: textTheme.bodyMedium,
        inputDecorationTheme: _buildInputDecoration(colorScheme),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colorScheme.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge)),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge)),
      ),

      // ---------------------------------------------------------------
      // Tabs
      // ---------------------------------------------------------------
      tabBarTheme: TabBarThemeData(
        labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        labelColor: colorScheme.primary,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: colorScheme.outlineVariant.withValues(alpha: 0.6),
      ),

      // ---------------------------------------------------------------
      // Tooltips
      // ---------------------------------------------------------------
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: textTheme.labelMedium?.copyWith(
          color: colorScheme.onInverseSurface,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
    );
  }
}
