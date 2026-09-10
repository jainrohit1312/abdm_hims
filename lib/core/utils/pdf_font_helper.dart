import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Centralised PDF font helper.
///
/// The default PDF fonts (Helvetica / Helvetica-Bold) are Type1 fonts that
/// cannot render Unicode glyphs like `₹`, `—`, `•`, `₂` or Hindi/Devanagari
/// text. This helper loads NotoSans TTF fonts from `assets/fonts/` and exposes
/// them through the standard [pw.Text] / [pw.TextStyle] API so every PDF
/// service in the app renders Unicode correctly.
///
/// Usage:
/// ```dart
/// await PDFFontHelper.loadFonts();
/// ...
/// PDFFontHelper.text('₹ 500', fontWeight: pw.FontWeight.bold);
/// ```
class PDFFontHelper {
  PDFFontHelper._();

  static pw.Font? _regularFont;
  static pw.Font? _boldFont;
  static bool _fontsLoaded = false;
  static bool _embeddedFontsLoaded = false;

  /// Loads the NotoSans fonts from the asset bundle.
  ///
  /// Safe to call multiple times — fonts are only loaded once. If loading
  /// fails for any reason (missing asset, malformed font, etc.) the helper
  /// falls back to the built-in Helvetica fonts so PDF generation never
  /// breaks.
  static Future<void> loadFonts() async {
    if (_fontsLoaded) return;
    try {
      final regularData = await rootBundle.load(
        'assets/fonts/NotoSans-Regular.ttf',
      );
      _regularFont = pw.Font.ttf(regularData);
      final boldData = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
      _boldFont = pw.Font.ttf(boldData);
      _fontsLoaded = true;
      _embeddedFontsLoaded = true;
    } catch (_) {
      _regularFont = pw.Font.helvetica();
      _boldFont = pw.Font.helveticaBold();
      _fontsLoaded = true;
      _embeddedFontsLoaded = false;
    }
  }

  /// True when the embedded NotoSans TTF assets were loaded successfully.
  ///
  /// Helvetica fallback does not contain the Indian rupee glyph, so callers
  /// that print `₹` amounts can assert/verify this flag before generating a
  /// PDF.
  static bool get hasEmbeddedFonts => _embeddedFontsLoaded;

  /// Regular NotoSans font (Helvetica fallback if fonts are not loaded yet
  /// or failed to load).
  static pw.Font get regularFont => _regularFont ?? pw.Font.helvetica();

  /// Bold NotoSans font (Helvetica-Bold fallback if fonts are not loaded yet
  /// or failed to load).
  static pw.Font get boldFont => _boldFont ?? pw.Font.helveticaBold();

  /// Base text style for PDF documents.
  ///
  /// [fontWeight] picks the correct NotoSans face automatically, so callers
  /// only need to pass the same style properties they used before.
  static pw.TextStyle textStyle({
    double fontSize = 10,
    pw.FontWeight fontWeight = pw.FontWeight.normal,
    PdfColor color = PdfColors.black,
    double? letterSpacing,
    double? lineSpacing,
    bool inherit = true,
  }) {
    return pw.TextStyle(
      inherit: inherit,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      lineSpacing: lineSpacing,
      fontNormal: regularFont,
      fontBold: boldFont,
      fontFallback: <pw.Font>[regularFont, boldFont],
    );
  }

  /// Style for section headings / titles.
  static pw.TextStyle headingStyle({
    double fontSize = 12,
    PdfColor color = PdfColors.black,
    double? letterSpacing,
    double? lineSpacing,
  }) {
    return textStyle(
      fontSize: fontSize,
      fontWeight: pw.FontWeight.bold,
      color: color,
      letterSpacing: letterSpacing,
      lineSpacing: lineSpacing,
    );
  }

  /// Style for regular body text.
  static pw.TextStyle bodyStyle({
    double fontSize = 10,
    PdfColor color = PdfColors.black,
    double? letterSpacing,
    double? lineSpacing,
  }) {
    return textStyle(
      fontSize: fontSize,
      color: color,
      letterSpacing: letterSpacing,
      lineSpacing: lineSpacing,
    );
  }

  /// Style used for `₹` currency amounts.
  static pw.TextStyle currencyStyle({
    double fontSize = 10,
    PdfColor color = PdfColors.black,
  }) {
    return textStyle(fontSize: fontSize, color: color);
  }

  /// Unicode-safe replacement for [pw.Text].
  static pw.Widget text(
    String text, {
    double fontSize = 10,
    pw.FontWeight fontWeight = pw.FontWeight.normal,
    PdfColor color = PdfColors.black,
    pw.TextAlign textAlign = pw.TextAlign.left,
    double? letterSpacing,
    double? lineSpacing,
    int? maxLines,
    pw.TextOverflow? overflow,
  }) {
    return pw.Text(
      text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: textStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
        lineSpacing: lineSpacing,
      ),
    );
  }

  /// Unicode-safe bold heading widget.
  static pw.Widget heading(
    String text, {
    double fontSize = 12,
    PdfColor color = PdfColors.black,
    pw.TextAlign textAlign = pw.TextAlign.left,
    double? letterSpacing,
    double? lineSpacing,
    int? maxLines,
    pw.TextOverflow? overflow,
  }) {
    return pw.Text(
      text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: headingStyle(
        fontSize: fontSize,
        color: color,
        letterSpacing: letterSpacing,
        lineSpacing: lineSpacing,
      ),
    );
  }

  /// Unicode-safe `₹` currency widget.
  static pw.Widget currency(
    String text, {
    double fontSize = 10,
    PdfColor color = PdfColors.black,
    pw.TextAlign textAlign = pw.TextAlign.left,
    int? maxLines,
    pw.TextOverflow? overflow,
  }) {
    return pw.Text(
      text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: currencyStyle(fontSize: fontSize, color: color),
    );
  }

  /// Formats a numeric amount as an Indian Rupee string, e.g. `₹ 500.00`.
  ///
  /// Useful for table cells where a widget cannot be used but the amount
  /// still needs to render with the NotoSans currency glyph.
  static String formatCurrency(num amount, {int decimals = 2}) {
    return '₹ ${amount.toStringAsFixed(decimals)}';
  }

  /// Formats a numeric amount with Indian digit grouping and no space after
  /// the rupee symbol: `₹300`, `₹1,000`, `₹1,05,000.50`.
  ///
  /// The embedded NotoSans font used by [textStyle] contains the `₹` glyph
  /// (U+20B9), so these strings render correctly wherever that style is
  /// applied to the amount text.
  static String formatIndianCurrency(num amount, {int decimals = 0}) {
    if (amount.isNaN || amount.isInfinite) {
      return '₹0${decimals > 0 ? '.${'0' * decimals}' : ''}';
    }
    final sign = amount < 0 ? '-' : '';
    final fixed = amount.abs().toStringAsFixed(decimals);
    final split = fixed.split('.');
    final intPart = split[0];

    var grouped = intPart;
    if (intPart.length > 3) {
      final last3 = intPart.substring(intPart.length - 3);
      final rest = intPart.substring(0, intPart.length - 3);
      final groups = <String>[];
      for (var i = rest.length; i > 0; i -= 2) {
        final start = (i - 2) < 0 ? 0 : (i - 2);
        groups.insert(0, rest.substring(start, i));
      }
      grouped = '${groups.join(',')},$last3';
    }

    final decimalPart = split.length > 1 ? '.${split[1]}' : '';
    return '$sign₹$grouped$decimalPart';
  }
}
