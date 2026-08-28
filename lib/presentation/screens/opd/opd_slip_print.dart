import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// OPD payment slip PDF generator + printer.
///
/// Registration ke time payment collect hone ke baad is service se slip
/// generate/print ki jaati hai.
class OPDSlipPrintService {
  static Future<Uint8List> generateSlipPdf({
    required String hospitalName,
    required String hospitalAddress,
    required String patientName,
    required String uhid,
    required String doctorName,
    required String department,
    required double paymentAmount,
    required String paymentMode,
    required String paymentStatus,
    required DateTime date,
    required String slipNumber,
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
                    'OPD PAYMENT SLIP',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            pw.TableHelper.fromTextArray(
              headers: ['Particulars', 'Details'],
              data: [
                ['Slip No.', slipNumber],
                ['Date', date.toIso8601String().split('T')[0]],
                ['Patient Name', patientName],
                ['UHID', uhid],
                ['Department', department],
                ['Doctor', doctorName],
                ['Payment Amount', '₹ ${paymentAmount.toStringAsFixed(0)}'],
                ['Payment Mode', paymentMode],
                ['Payment Status', paymentStatus],
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

  /// Opens the platform print dialog with the generated OPD slip PDF.
  static Future<void> printSlip(Map<String, dynamic> data) async {
    final bytes = await generateSlipPdf(
      hospitalName: data['hospitalName']?.toString() ?? 'HIMS Hospital',
      hospitalAddress:
          data['hospitalAddress']?.toString() ??
          '123, Healthcare Avenue, New Delhi',
      patientName: data['patientName']?.toString() ?? 'Unknown',
      uhid: data['uhid']?.toString() ?? 'N/A',
      doctorName: data['doctorName']?.toString() ?? 'N/A',
      department: data['department']?.toString() ?? 'N/A',
      paymentAmount: _toDouble(data['paymentAmount']),
      paymentMode: data['paymentMode']?.toString() ?? 'Cash',
      paymentStatus: data['paymentStatus']?.toString() ?? 'paid',
      date: data['date'] ?? DateTime.now(),
      slipNumber:
          data['slipNumber']?.toString() ??
          'OPD-${DateTime.now().millisecondsSinceEpoch}',
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => bytes);
  }
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  return double.tryParse(value.toString()) ?? 0;
}

/// OPD Payment Slip preview + print screen.
///
/// `getOPDPaymentDetails` se payment data load karta hai, slip preview
/// dikhata hai aur Print button se PDF print karta hai.
class OPDSlipPrintScreen extends ConsumerWidget {
  final String opdRegistrationId;

  /// OPD registration screen se aata hai (doctors table ka naam). Stored
  /// `doctor_name` column bhi fallback ke roop mein use hota hai.
  final String? doctorName;

  const OPDSlipPrintScreen({
    super.key,
    required this.opdRegistrationId,
    this.doctorName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final detailsAsync = ref.watch(opdSlipDetailsProvider(opdRegistrationId));

    return Scaffold(
      appBar: SmartAppBar(title: const Text('OPD Payment Slip')),
      body: detailsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 12),
                Text('Failed to load slip: $error', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () =>
                      ref.invalidate(opdSlipDetailsProvider(opdRegistrationId)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        data: (details) {
          if (details == null) {
            return const Center(child: Text('OPD registration not found.'));
          }
          final payment =
              (details['payment'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          final hospital =
              (details['hospital'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          final doctor =
              (details['doctor'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          final department =
              (details['department'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          final patient =
              (payment['patients'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};

          final patientName =
              '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'
                  .trim();
          final id = opdRegistrationId;
          final slipNumber =
              'OPD-${(id.length >= 8 ? id.substring(0, 8) : id).toUpperCase()}';

          final slipData = <String, dynamic>{
            'hospitalName': hospital['name']?.toString() ?? 'HIMS Hospital',
            'hospitalAddress':
                hospital['address']?.toString() ??
                '123, Healthcare Avenue, New Delhi',
            'patientName': patientName.isEmpty ? 'Unknown Patient' : patientName,
            'uhid': patient['uhid']?.toString() ?? 'N/A',
            'doctorName': _effectiveDoctorName(
              doctor,
              payment['doctor_name']?.toString(),
            ),
            'department': department['name']?.toString() ?? 'N/A',
            'paymentAmount': _toDouble(payment['payment_amount']),
            'paymentMode': _paymentModeLabel(payment['payment_mode']),
            'paymentStatus': _paymentStatusLabel(payment['payment_status']),
            'date': DateTime.tryParse(
                  payment['visit_date']?.toString() ?? '',
                ) ??
                DateTime.now(),
            'slipNumber': slipNumber,
          };

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Column(
                            children: [
                              Text(
                                slipData['hospitalName'] as String,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                slipData['hospitalAddress'] as String,
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'OPD PAYMENT SLIP',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 24),
                        _infoRow(theme, 'Slip No.', slipData['slipNumber']),
                        _infoRow(
                          theme,
                          'Date',
                          (slipData['date'] as DateTime)
                              .toIso8601String()
                              .split('T')[0],
                        ),
                        _infoRow(theme, 'Patient Name', slipData['patientName']),
                        _infoRow(theme, 'UHID', slipData['uhid']),
                        _infoRow(theme, 'Department', slipData['department']),
                        _infoRow(theme, 'Doctor', slipData['doctorName']),
                        const Divider(height: 24),
                        _infoRow(
                          theme,
                          'Payment Amount',
                          '₹ ${_toDouble(payment['payment_amount']).toStringAsFixed(0)}',
                          valueColor: theme.colorScheme.primary,
                          bold: true,
                        ),
                        _infoRow(theme, 'Payment Mode', slipData['paymentMode']),
                        _infoRow(
                          theme,
                          'Payment Status',
                          slipData['paymentStatus'],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        await OPDSlipPrintService.printSlip(slipData);
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Print failed. Please try again.'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.print),
                    label: const Text('Print Slip'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _infoRow(
    ThemeData theme,
    String label,
    dynamic value, {
    Color? valueColor,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value?.toString() ?? 'N/A',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _effectiveDoctorName(
    Map<String, dynamic> doctor,
    String? storedName,
  ) {
    final fromRoute = doctorName?.trim();
    if (fromRoute != null && fromRoute.isNotEmpty) return fromRoute;
    final fromRow = storedName?.trim();
    if (fromRow != null && fromRow.isNotEmpty) return fromRow;
    return doctor['name']?.toString() ?? 'N/A';
  }

  String _paymentModeLabel(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'cash':
        return 'Cash';
      case 'card':
        return 'Card';
      case 'upi':
        return 'UPI';
      case 'insurance':
        return 'Insurance';
      default:
        return value?.toString() ?? 'N/A';
    }
  }

  String _paymentStatusLabel(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'paid':
        return 'Paid';
      case 'unpaid':
        return 'Unpaid';
      case 'partially_paid':
        return 'Partially Paid';
      default:
        return value?.toString() ?? 'N/A';
    }
  }
}
