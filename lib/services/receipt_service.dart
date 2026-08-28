import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class ReceiptService {
  static Future<Uint8List> generateOPDReceipt({
    required String hospitalName,
    required String hospitalAddress,
    required String patientName,
    required String uhid,
    required String doctorName,
    required String department,
    required double fee,
    required DateTime date,
    required String receiptNumber,
  }) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a5,
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Column(
                children: [
                  pw.Text(
                    hospitalName,
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    hospitalAddress,
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.Divider(),
                  pw.Text(
                    'OPD RECEIPT',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            // ✅ Using TableHelper.fromTextArray (non-deprecated)
            pw.TableHelper.fromTextArray(
              headers: ['Particulars', 'Details'],
              data: [
                ['Receipt No.', receiptNumber],
                ['Date', date.toIso8601String().split('T')[0]],
                ['Patient Name', patientName],
                ['UHID', uhid],
                ['Department', department],
                ['Doctor', doctorName],
                ['Consultation Fee', '₹ $fee'],
              ],
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 1),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blue700,
              ),
            ),
            pw.SizedBox(height: 30),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                'Authorized Signature',
                style: const pw.TextStyle(fontSize: 12),
              ),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static Future<void> printReceipt(Map<String, dynamic> data) async {
    final Uint8List pdfBytes = await generateOPDReceipt(
      hospitalName: data['hospitalName'] ?? 'MediFlow HIMS',
      hospitalAddress:
          data['hospitalAddress'] ?? '123, Healthcare Avenue, New Delhi',
      patientName: data['patientName'] ?? 'Unknown',
      uhid: data['uhid'] ?? 'N/A',
      doctorName: data['doctorName'] ?? 'N/A',
      department: data['department'] ?? 'N/A',
      fee: data['fee'] ?? 0,
      date: data['date'] ?? DateTime.now(),
      receiptNumber:
          data['receiptNumber'] ??
          'OPD-${DateTime.now().millisecondsSinceEpoch}',
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdfBytes,
    );
  }
}
