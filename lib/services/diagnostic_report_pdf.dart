import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Generates and prints the final Diagnostic Report PDF.
///
/// The report shows patient/demographic info, a quantitative result table
/// (test, value, reference range, unit) and — for radiology/cardiology —
/// findings, impression, recommendations and the uploaded image.
class DiagnosticReportService {
  static Future<Uint8List> generateDiagnosticReportPdf({
    required String hospitalName,
    required String hospitalAddress,
    required String patientName,
    required String uhid,
    required String doctorName,
    required String orderDate,
    required String reportDate,
    required List<Map<String, dynamic>> results,
    required String technicianName,
  }) async {
    final pdf = pw.Document();

    // Pre-download any uploaded result images so the sync PDF builder can
    // embed them via MemoryImage.
    final imageBytes = <String, Uint8List?>{};
    for (final result in results) {
      final url = result['image_url']?.toString() ?? '';
      if (url.isNotEmpty && !imageBytes.containsKey(url)) {
        imageBytes[url] = await _downloadImage(url);
      }
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            // ------------------------------------------------------------
            // Hospital header
            // ------------------------------------------------------------
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        hospitalName,
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      if (hospitalAddress.trim().isNotEmpty)
                        pw.Text(
                          hospitalAddress,
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                    ],
                  ),
                ),
                pw.Text(
                  'DIAGNOSTIC REPORT',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.purple800,
                  ),
                ),
              ],
            ),
            pw.Divider(thickness: 1.5),
            pw.SizedBox(height: 12),

            // ------------------------------------------------------------
            // Patient + doctor info
            // ------------------------------------------------------------
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: _infoBlock('Patient', {
                    'Name': patientName,
                    'UHID': uhid,
                    'Order Date': orderDate,
                    'Report Date': reportDate,
                  }),
                ),
                pw.SizedBox(width: 24),
                pw.Expanded(
                  child: _infoBlock('Referred By', {
                    'Doctor': doctorName,
                    'Lab Technician': technicianName,
                  }),
                ),
              ],
            ),
            pw.SizedBox(height: 16),

            // ------------------------------------------------------------
            // Results table (quantitative part)
            // ------------------------------------------------------------
            pw.Text(
              'Results',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['#', 'Test', 'Result Value', 'Reference Range', 'Unit'],
              data: _buildTableRows(results),
              border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 9,
              ),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.purple800),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignment: pw.Alignment.topLeft,
              headerAlignment: pw.Alignment.centerLeft,
              columnWidths: const {
                0: pw.FixedColumnWidth(20),
                1: pw.FlexColumnWidth(3),
                2: pw.FlexColumnWidth(2),
                3: pw.FlexColumnWidth(2),
                4: pw.FlexColumnWidth(1.2),
              },
            ),
            pw.SizedBox(height: 16),

            // ------------------------------------------------------------
            // Radiology / cardiology descriptive blocks + images
            // ------------------------------------------------------------
            for (final result in results)
              if (_hasNarrative(result)) ...[
                _narrativeBlock(result, imageBytes),
                pw.SizedBox(height: 10),
              ],

            pw.SizedBox(height: 28),

            // ------------------------------------------------------------
            // Signature block
            // ------------------------------------------------------------
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    technicianName,
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  pw.SizedBox(height: 24),
                  pw.Text(
                    'Lab Technician Signature',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Text(
              'This is a computer generated report. Results should be '
              'correlated clinically.',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  /// Opens the platform print dialog with the generated report.
  static Future<void> printDiagnosticReport({
    required String hospitalName,
    required String hospitalAddress,
    required String patientName,
    required String uhid,
    required String doctorName,
    required String orderDate,
    required String reportDate,
    required List<Map<String, dynamic>> results,
    required String technicianName,
  }) async {
    final bytes = await generateDiagnosticReportPdf(
      hospitalName: hospitalName,
      hospitalAddress: hospitalAddress,
      patientName: patientName,
      uhid: uhid,
      doctorName: doctorName,
      orderDate: orderDate,
      reportDate: reportDate,
      results: results,
      technicianName: technicianName,
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => bytes);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static pw.Widget _infoBlock(String title, Map<String, String> values) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.purple900,
          ),
        ),
        pw.SizedBox(height: 4),
        for (final entry in values.entries)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 90,
                  child: pw.Text(
                    entry.key,
                    style: const pw.TextStyle(
                      fontSize: 10,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    entry.value,
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static List<List<String>> _buildTableRows(List<Map<String, dynamic>> results) {
    return [
      for (var i = 0; i < results.length; i++)
        [
          '${i + 1}',
          results[i]['test_name']?.toString() ?? '-',
          _valueOrDash(results[i]['result_value']),
          _valueOrDash(results[i]['reference_range']),
          _valueOrDash(results[i]['unit']),
        ],
    ];
  }

  static String _valueOrDash(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? '-' : text;
  }

  static bool _hasNarrative(Map<String, dynamic> result) {
    return _valueOrDash(result['findings']) != '-' ||
        _valueOrDash(result['impression']) != '-' ||
        _valueOrDash(result['recommendations']) != '-' ||
        _valueOrDash(result['image_url']) != '-';
  }

  /// Renders findings/impression/recommendations + uploaded image for a
  /// radiology / cardiology / other test.
  static pw.Widget _narrativeBlock(
    Map<String, dynamic> result,
    Map<String, Uint8List?> imageBytes,
  ) {
    final testName = result['test_name']?.toString() ?? 'Test';
    final findings = _valueOrDash(result['findings']);
    final impression = _valueOrDash(result['impression']);
    final recommendations = _valueOrDash(result['recommendations']);
    final imageUrl = _valueOrDash(result['image_url']);
    final imageData = imageUrl == '-' ? null : imageBytes[imageUrl];

    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            testName,
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          if (findings != '-') _labelValueRow('Findings', findings),
          if (impression != '-') _labelValueRow('Impression', impression),
          if (recommendations != '-')
            _labelValueRow('Recommendations', recommendations),
          if (imageUrl != '-') ...[
            pw.SizedBox(height: 6),
            pw.Text(
              'Image:',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Container(
              height: 160,
              alignment: pw.Alignment.centerLeft,
              child: imageData != null
                  ? pw.Image(
                      pw.MemoryImage(imageData),
                      fit: pw.BoxFit.contain,
                    )
                  : pw.Text(
                      'Image could not be loaded.',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  /// Downloads an uploaded image as bytes (best effort — failures leave a
  /// placeholder text in the report instead of breaking generation).
  static Future<Uint8List?> _downloadImage(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static pw.Widget _labelValueRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 100,
            child: pw.Text(
              label,
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(value, style: const pw.TextStyle(fontSize: 9)),
          ),
        ],
      ),
    );
  }
}
