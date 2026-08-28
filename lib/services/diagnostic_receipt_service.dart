import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

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
    final pdf = pw.Document();
    String currency(double v) => '₹ ${v.toStringAsFixed(2)}';

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Column(
                children: [
                  pw.Text(
                    hospitalName,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (hospitalAddress.trim().isNotEmpty)
                    pw.Text(
                      hospitalAddress,
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  pw.Divider(),
                  pw.Text(
                    'DIAGNOSTIC TEST RECEIPT',
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 12),
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
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 9,
              ),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
              cellStyle: const pw.TextStyle(fontSize: 9),
              columnWidths: const {
                0: pw.FixedColumnWidth(90),
                1: pw.FlexColumnWidth(1),
              },
            ),
            pw.SizedBox(height: 12),

            // Tests table
            pw.TableHelper.fromTextArray(
              headers: const ['#', 'Test', 'Amount'],
              data: [
                for (var i = 0; i < tests.length; i++)
                  [
                    '${i + 1}',
                    tests[i]['test_name']?.toString() ?? '-',
                    currency(
                      double.tryParse(tests[i]['price']?.toString() ?? '') ?? 0,
                    ),
                  ],
                ['', 'TOTAL', currency(totalAmount)],
                ['', 'PAID', currency(paidAmount)],
                ['', 'BALANCE', currency(balanceAmount)],
              ],
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 9,
              ),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
              cellStyle: const pw.TextStyle(fontSize: 9),
              columnWidths: const {
                0: pw.FixedColumnWidth(20),
                1: pw.FlexColumnWidth(3),
                2: pw.FixedColumnWidth(70),
              },
            ),
            pw.SizedBox(height: 24),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'Authorized Signature',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.SizedBox(height: 20),
                  pw.Text(
                    'Keep this receipt for test collection & reports.',
                    style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
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

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => bytes);
  }
}
