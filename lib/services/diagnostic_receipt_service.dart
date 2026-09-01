import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/utils/pdf_font_helper.dart';

/// Half-A4 portrait page: A4 width (210 mm) x half A4 height (148.5 mm).
///
/// The generated PDF page itself is this custom size. It is not a full A4
/// page and it is not an A5 page in any orientation.
final PdfPageFormat halfA4Portrait = PdfPageFormat(
  210 * PdfPageFormat.mm,
  148.5 * PdfPageFormat.mm,
);

/// Generates and prints the diagnostic test receipt.
///
/// This is the cash receipt handed to the patient when a test order is cut
/// and payment is collected.
class DiagnosticReceiptService {
  static Future<Uint8List> generateDiagnosticReceipt({
    required String hospitalName,
    required String hospitalAddress,
    required String receiptNumber,
    required DateTime date,
    required String patientName,
    required String uhid,
    required String mobileNumber,
    required String doctorName,
    required String urgency,
    required List<Map<String, dynamic>> tests,
    required double totalAmount,
    required double paidAmount,
    required double balanceAmount,
    required String paymentMode,
  }) async {
    await PDFFontHelper.loadFonts();

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: halfA4Portrait,
        orientation: pw.PageOrientation.natural,
        margin: const pw.EdgeInsets.all(18),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              margin: const pw.EdgeInsets.only(bottom: 2 * PdfPageFormat.mm),
              child: pw.Column(
                children: [
                  PDFFontHelper.text(
                    hospitalName,
                    textAlign: pw.TextAlign.center,
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  if (hospitalAddress.trim().isNotEmpty)
                    PDFFontHelper.text(
                      hospitalAddress,
                      textAlign: pw.TextAlign.center,
                      fontSize: 9,
                    ),
                  pw.Divider(),
                  PDFFontHelper.text(
                    'DIAGNOSTIC TEST RECEIPT',
                    textAlign: pw.TextAlign.center,
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['Particulars', 'Details'],
              data: [
                ['Receipt No.', receiptNumber],
                ['Date', date.toIso8601String().split('T')[0]],
                ['Patient Name', patientName],
                ['UHID', uhid],
                ['Mobile', mobileNumber],
                ['Doctor', doctorName],
                ['Order Type', urgency.toUpperCase()],
                ['Payment Mode', paymentMode.toUpperCase()],
              ],
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: PDFFontHelper.textStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 9,
              ),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
              cellStyle: PDFFontHelper.bodyStyle(fontSize: 9),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 2,
              ),
              columnWidths: const {
                0: pw.FixedColumnWidth(90),
                1: pw.FlexColumnWidth(1),
              },
            ),
            pw.SizedBox(height: 6),

            // Tests table
            pw.TableHelper.fromTextArray(
              headers: const ['#', 'Test', 'Amount'],
              data: [
                for (var i = 0; i < tests.length; i++)
                  [
                    '${i + 1}',
                    tests[i]['test_name']?.toString() ?? '-',
                    PDFFontHelper.formatCurrency(
                      double.tryParse(tests[i]['price']?.toString() ?? '') ?? 0,
                    ),
                  ],
                ['', 'TOTAL', PDFFontHelper.formatCurrency(totalAmount)],
                ['', 'PAID', PDFFontHelper.formatCurrency(paidAmount)],
                ['', 'BALANCE', PDFFontHelper.formatCurrency(balanceAmount)],
              ],
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: PDFFontHelper.textStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 9,
              ),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
              cellStyle: PDFFontHelper.bodyStyle(fontSize: 9),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 2,
              ),
              columnWidths: const {
                0: pw.FixedColumnWidth(20),
                1: pw.FlexColumnWidth(3),
                2: pw.FixedColumnWidth(70),
              },
            ),
            pw.SizedBox(height: 10),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  PDFFontHelper.text(
                    'Authorized Signature',
                    fontSize: 10,
                  ),
                  pw.SizedBox(height: 8),
                  PDFFontHelper.text(
                    'Keep this receipt for test collection & reports.',
                    fontSize: 8,
                    color: PdfColors.grey600,
                  ),
                ],
              ),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static Future<void> printDiagnosticReceipt({
    required String hospitalName,
    required String hospitalAddress,
    required String receiptNumber,
    required DateTime date,
    required String patientName,
    required String uhid,
    required String mobileNumber,
    required String doctorName,
    required String urgency,
    required List<Map<String, dynamic>> tests,
    required double totalAmount,
    required double paidAmount,
    required double balanceAmount,
    required String paymentMode,
  }) async {
    final bytes = await generateDiagnosticReceipt(
      hospitalName: hospitalName,
      hospitalAddress: hospitalAddress,
      receiptNumber: receiptNumber,
      date: date,
      patientName: patientName,
      uhid: uhid,
      mobileNumber: mobileNumber,
      doctorName: doctorName,
      urgency: urgency,
      tests: tests,
      totalAmount: totalAmount,
      paidAmount: paidAmount,
      balanceAmount: balanceAmount,
      paymentMode: paymentMode,
    );

    await Printing.layoutPdf(
      format: halfA4Portrait,
      onLayout: (PdfPageFormat format) async => bytes,
    );
  }
}
