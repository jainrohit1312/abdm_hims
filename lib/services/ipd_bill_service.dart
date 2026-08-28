import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Generates and prints the IPD Final Bill PDF.
///
/// This is a **financial document** only. It contains the itemized charges,
/// total amount, amount paid, balance due and payment status for billing,
/// insurance and accounts. No clinical content belongs in this document.
class IPDBillService {
  static Future<Uint8List> generateBillPdf({
    required String hospitalName,
    String? hospitalAddress,
    String? hospitalPhone,
    required String patientName,
    required String uhid,
    required String admissionDate,
    required String billNumber,
    required String billDate,
    required List<Map<String, dynamic>> items,
    required double totalAmount,
    required double paidAmount,
    required double balanceAmount,
    required String paymentStatus,
  }) async {
    final pdf = pw.Document();

    final rows = <List<String>>[
      for (var i = 0; i < items.length; i++)
        [
          '${i + 1}',
          items[i]['item_name']?.toString() ?? 'Charge',
          '${items[i]['quantity'] ?? 1}',
          _inr(items[i]['unit_price'] ?? 0),
          _inr(items[i]['total_price'] ?? items[i]['unit_price'] ?? 0),
        ],
    ];

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (pw.Context context) {
          return [
            // ---------------------------------------------------------------
            // Hospital letterhead
            // ---------------------------------------------------------------
            pw.Container(
              padding: const pw.EdgeInsets.only(bottom: 8),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.green800, width: 1.5),
                ),
              ),
              child: pw.Column(
                children: [
                  pw.Text(
                    hospitalName,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.green900,
                    ),
                  ),
                  if (hospitalAddress != null && hospitalAddress.isNotEmpty) ...[
                    pw.SizedBox(height: 2),
                    pw.Text(
                      hospitalAddress,
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                  if (hospitalPhone != null && hospitalPhone.isNotEmpty) ...[
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Phone: $hospitalPhone',
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                  pw.SizedBox(height: 8),
                  pw.Container(
                    width: double.infinity,
                    padding: const pw.EdgeInsets.symmetric(vertical: 5),
                    color: PdfColors.green50,
                    child: pw.Text(
                      'IPD FINAL BILL',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.green800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 14),

            // ---------------------------------------------------------------
            // Bill & patient information
            // ---------------------------------------------------------------
            _sectionLabel('Bill & Patient Details'),
            pw.TableHelper.fromTextArray(
              headers: ['Particulars', 'Details'],
              data: [
                ['Bill No.', billNumber],
                ['Bill Date', billDate],
                ['Patient Name', patientName],
                ['UHID', uhid],
                ['Admission Date', admissionDate],
                ['Payment Status', _paymentStatusLabel(paymentStatus)],
              ],
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.green800,
              ),
              cellStyle: const pw.TextStyle(fontSize: 10),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 4,
              ),
              columnWidths: {
                0: const pw.FixedColumnWidth(130),
                1: const pw.FlexColumnWidth(),
              },
            ),
            pw.SizedBox(height: 14),

            // ---------------------------------------------------------------
            // Itemized charges
            // ---------------------------------------------------------------
            _sectionLabel('Charge Details'),
            pw.TableHelper.fromTextArray(
              headers: const ['#', 'Description', 'Qty', 'Rate', 'Amount'],
              data: rows,
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.green800,
              ),
              cellStyle: const pw.TextStyle(fontSize: 10),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 4,
              ),
              cellAlignments: const {
                0: pw.Alignment.center,
                2: pw.Alignment.center,
                3: pw.Alignment.centerRight,
                4: pw.Alignment.centerRight,
              },
              columnWidths: const {
                0: pw.FixedColumnWidth(26),
                1: pw.FlexColumnWidth(),
                2: pw.FixedColumnWidth(36),
                3: pw.FixedColumnWidth(80),
                4: pw.FixedColumnWidth(80),
              },
            ),
            pw.SizedBox(height: 10),

            // ---------------------------------------------------------------
            // Totals
            // ---------------------------------------------------------------
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.TableHelper.fromTextArray(
                headers: const ['Summary', 'Amount'],
                data: [
                  ['Total Amount', _inr(totalAmount)],
                  ['Paid Amount', _inr(paidAmount)],
                  ['Balance Due', _inr(balanceAmount)],
                ],
                border: pw.TableBorder.all(
                  color: PdfColors.grey400,
                  width: 0.5,
                ),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                ),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.green800,
                ),
                cellStyle: const pw.TextStyle(fontSize: 10),
                cellPadding: const pw.EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                cellAlignments: const {
                  0: pw.Alignment.centerLeft,
                  1: pw.Alignment.centerRight,
                },
                columnWidths: const {
                  0: pw.FixedColumnWidth(110),
                  1: pw.FixedColumnWidth(90),
                },
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                'Payment Status: ${_paymentStatusLabel(paymentStatus)}',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _paymentStatusColor(paymentStatus),
                ),
              ),
            ),
            pw.SizedBox(height: 24),

            // ---------------------------------------------------------------
            // Footer / signature
            // ---------------------------------------------------------------
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Generated on: ${_now()}',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'This is a computer-generated bill and is valid for '
                      'payment and insurance purposes.',
                      style: const pw.TextStyle(
                        fontSize: 8,
                        color: PdfColors.grey600,
                      ),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      'Authorized Signatory',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 28),
                    pw.Text(
                      'Accounts Department',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ],
                ),
              ],
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static Future<void> printBill(Map<String, dynamic> data) async {
    final bytes = await generateBillPdf(
      hospitalName: data['hospitalName'] ?? 'HIMS Hospital',
      hospitalAddress: data['hospitalAddress'],
      hospitalPhone: data['hospitalPhone'],
      patientName: data['patientName'] ?? 'Unknown',
      uhid: data['uhid'] ?? 'N/A',
      admissionDate: data['admissionDate'] ?? '',
      billNumber: data['billNumber'] ?? 'N/A',
      billDate: data['billDate'] ?? '',
      items: (data['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [],
      totalAmount: _toDouble(data['totalAmount']),
      paidAmount: _toDouble(data['paidAmount']),
      balanceAmount: _toDouble(data['balanceAmount']),
      paymentStatus: data['paymentStatus'] ?? 'unpaid',
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => bytes);
  }

  static pw.Widget _sectionLabel(String title) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Text(
        title,
        style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
      ),
    );
  }

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }

  static String _inr(dynamic value) {
    final amount = _toDouble(value);
    return '₹ ${amount.toStringAsFixed(2)}';
  }

  static String _paymentStatusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'paid':
        return 'PAID';
      case 'partially_paid':
      case 'partial':
        return 'PARTIALLY PAID';
      case 'unpaid':
        return 'UNPAID';
      case 'generated':
        return 'GENERATED';
      default:
        return status.toUpperCase();
    }
  }

  static PdfColor _paymentStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'paid':
        return PdfColors.green800;
      case 'partially_paid':
      case 'partial':
        return PdfColors.orange800;
      case 'unpaid':
        return PdfColors.red800;
      default:
        return PdfColors.grey700;
    }
  }

  static String _now() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
  }
}
