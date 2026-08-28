import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/utils/pdf_font_helper.dart';

/// Generates and prints the IPD Discharge Summary PDF.
///
/// This is a **clinical document** only. It contains the patient's medical
/// record for the admission: patient info, admission details, diagnosis,
/// treatment summary, discharge advice and the treating doctor. No billing or
/// financial data belongs in this document.
class DischargeSummaryService {
  static Future<Uint8List> generateIPDDischargeSummaryPdf({
    required String hospitalName,
    String? hospitalAddress,
    String? hospitalPhone,
    required String patientName,
    required String uhid,
    String? patientAge,
    String? patientGender,
    required String admissionDate,
    required String dischargeDate,
    required String dischargeType,
    required String diagnosis,
    required String treatmentSummary,
    required String dischargeAdvice,
    String? doctorName,
    String? ward,
    String? bedNumber,
    String? lengthOfStay,
  }) async {
    await PDFFontHelper.loadFonts();

    final pdf = pw.Document();

    final patientRows = <List<String>>[
      ['Patient Name', patientName],
      if (patientAge != null && patientAge.isNotEmpty) ['Age', patientAge],
      if (patientGender != null && patientGender.isNotEmpty)
        ['Gender', patientGender],
      ['UHID', uhid],
      ['Admission Date', admissionDate],
      ['Discharge Date', dischargeDate],
      ['Discharge Type', dischargeType],
      if (ward != null && ward.isNotEmpty) ['Ward', ward],
      if (bedNumber != null && bedNumber.isNotEmpty) ['Bed No.', bedNumber],
      if (lengthOfStay != null && lengthOfStay.isNotEmpty)
        ['Length of Stay', lengthOfStay],
      ['Consultant / Doctor', doctorName ?? 'N/A'],
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
                  bottom: pw.BorderSide(color: PdfColors.blue800, width: 1.5),
                ),
              ),
              child: pw.Column(
                children: [
                  PDFFontHelper.text(
                    hospitalName,
                    textAlign: pw.TextAlign.center,
                    fontSize: 20,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue900,
                  ),
                  if (hospitalAddress != null && hospitalAddress.isNotEmpty) ...[
                    pw.SizedBox(height: 2),
                    PDFFontHelper.text(
                      hospitalAddress,
                      textAlign: pw.TextAlign.center,
                      fontSize: 9,
                      color: PdfColors.grey700,
                    ),
                  ],
                  if (hospitalPhone != null && hospitalPhone.isNotEmpty) ...[
                    pw.SizedBox(height: 2),
                    PDFFontHelper.text(
                      'Phone: $hospitalPhone',
                      textAlign: pw.TextAlign.center,
                      fontSize: 9,
                      color: PdfColors.grey700,
                    ),
                  ],
                  pw.SizedBox(height: 8),
                  pw.Container(
                    width: double.infinity,
                    padding: const pw.EdgeInsets.symmetric(vertical: 5),
                    color: PdfColors.blue50,
                    child: PDFFontHelper.text(
                      'IPD DISCHARGE SUMMARY',
                      textAlign: pw.TextAlign.center,
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.blue800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 14),

            // ---------------------------------------------------------------
            // Patient & admission details
            // ---------------------------------------------------------------
            _sectionLabel('Patient & Admission Details'),
            pw.TableHelper.fromTextArray(
              headers: ['Particulars', 'Details'],
              data: patientRows,
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: PDFFontHelper.textStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blue700,
              ),
              cellStyle: PDFFontHelper.bodyStyle(fontSize: 10),
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
            // Clinical summary
            // ---------------------------------------------------------------
            _sectionLabel('Diagnosis'),
            _clinicalBox(diagnosis.isEmpty ? 'N/A' : diagnosis),
            pw.SizedBox(height: 10),
            _sectionLabel('Treatment Summary / Course in Hospital'),
            _clinicalBox(treatmentSummary.isEmpty ? 'N/A' : treatmentSummary),
            pw.SizedBox(height: 10),
            _sectionLabel('Discharge Advice & Follow-Up'),
            _clinicalBox(dischargeAdvice.isEmpty ? 'N/A' : dischargeAdvice),
            pw.SizedBox(height: 24),

            // ---------------------------------------------------------------
            // Signature block
            // ---------------------------------------------------------------
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    PDFFontHelper.text(
                      'Generated on: ${_now()}',
                      fontSize: 9,
                    ),
                    pw.SizedBox(height: 4),
                    PDFFontHelper.text(
                      'This is a computer-generated clinical document for '
                      'patient medical records.',
                      fontSize: 8,
                      color: PdfColors.grey600,
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    PDFFontHelper.text(
                      'Doctor\'s Signature',
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                    pw.SizedBox(height: 28),
                    PDFFontHelper.text(
                      doctorName ?? 'N/A',
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                    PDFFontHelper.text(
                      'Consultant In-Charge',
                      fontSize: 8,
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

  /// Opens the system print/share dialog with the generated PDF.
  static Future<void> printIPDDischargeSummary(
    Map<String, dynamic> data,
  ) async {
    final pdfBytes = await generateIPDDischargeSummaryPdf(
      hospitalName: data['hospitalName'] ?? 'HIMS Hospital',
      hospitalAddress: data['hospitalAddress'],
      hospitalPhone: data['hospitalPhone'],
      patientName: data['patientName'] ?? 'Unknown',
      uhid: data['uhid'] ?? 'N/A',
      patientAge: data['patientAge'],
      patientGender: data['patientGender'],
      admissionDate: data['admissionDate'] ?? '',
      dischargeDate: data['dischargeDate'] ?? '',
      dischargeType: data['dischargeType'] ?? 'Routine',
      diagnosis: data['diagnosis'] ?? '',
      treatmentSummary: data['treatmentSummary'] ?? '',
      dischargeAdvice: data['dischargeAdvice'] ?? '',
      doctorName: data['doctorName'],
      ward: data['ward'],
      bedNumber: data['bedNumber'],
      lengthOfStay: data['lengthOfStay'],
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdfBytes,
    );
  }

  static pw.Widget _sectionLabel(String title) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: PDFFontHelper.text(
        title,
        fontSize: 11,
        fontWeight: pw.FontWeight.bold,
      ),
    );
  }

  static pw.Widget _clinicalBox(String text) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
      ),
      child: PDFFontHelper.text(
        text,
        fontSize: 10,
        lineSpacing: 2,
      ),
    );
  }

  static String _now() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
  }
}
