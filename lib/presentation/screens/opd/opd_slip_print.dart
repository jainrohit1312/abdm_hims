import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../app/providers.dart';
import '../../../core/utils/display_names.dart';
import '../../../core/utils/pdf_font_helper.dart';
import '../../widgets/smart_navigation.dart';

/// A5 landscape / half-A4 page: 210 mm wide x 148 mm high.
///
/// A4 is 210 x 297 mm, so half of an A4 sheet turned sideways is exactly
/// 210 x 148 mm. The slip is generated on this exact page size so it prints
/// on a half-A4 sheet without an A4-sized page or a second blank page.
final PdfPageFormat opdSlipA5Landscape = PdfPageFormat(
  210 * PdfPageFormat.mm,
  148 * PdfPageFormat.mm,
);

const double _slipMarginMm = 6;

String _cleanAddressPart(dynamic value) {
  return (value ?? '').toString().trim();
}

/// Builds a printable hospital address from the individual hospital columns.
///
/// Expected output format:
/// `Navada, Mathura, Uttar Pradesh - 281001`
///
/// * Null/empty fields are ignored.
/// * Fields already present in a previous component are not repeated (this
///   avoids duplicate commas / duplicate words).
/// * The PIN code is appended with a ` - ` separator only when available.
String formatHospitalAddress({
  dynamic address,
  dynamic city,
  dynamic state,
  dynamic pincode,
}) {
  final parts = <String>[];

  void addPart(String part) {
    final normalized = part.trim();
    if (normalized.isEmpty) return;
    final alreadyPresent = parts.any(
      (existing) =>
          existing.toLowerCase() == normalized.toLowerCase() ||
          existing.toLowerCase().contains(normalized.toLowerCase()) ||
          normalized.toLowerCase().contains(existing.toLowerCase()),
    );
    if (!alreadyPresent) parts.add(normalized);
  }

  addPart(_cleanAddressPart(address));
  addPart(_cleanAddressPart(city));
  addPart(_cleanAddressPart(state));

  final location = parts.join(', ');
  final pin = _cleanAddressPart(pincode);
  if (pin.isNotEmpty) {
    return location.isEmpty ? pin : '$location - $pin';
  }
  return location;
}

/// Reads the hospital record and returns the complete printed address.
String hospitalAddressFromRecord(Map<String, dynamic>? hospital) {
  if (hospital == null) return '';
  return formatHospitalAddress(
    address: hospital['address'],
    city: hospital['city'],
    state: hospital['state'],
    pincode: hospital['pincode'],
  );
}

/// Reads phone/email from the hospital record for the contact line.
String hospitalContactFromRecord(Map<String, dynamic>? hospital) {
  if (hospital == null) return '';
  final phone = _cleanAddressPart(hospital['phone']);
  final email = _cleanAddressPart(hospital['email']);
  return [phone, email].where((part) => part.isNotEmpty).join('  •  ');
}

Map<String, dynamic>? _asStringMap(dynamic value) {
  if (value == null) return null;
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _doctorNameFromRow(Map<String, dynamic>? doctor) {
  if (doctor == null) return '';

  final direct = cleanDoctorName(doctor['name'] ?? doctor['doctor_name']);
  if (direct.isNotEmpty) return direct;

  final first = cleanDoctorName(doctor['first_name']);
  final last = cleanDoctorName(doctor['last_name']);
  final combined = '$first $last'.trim();
  return cleanDoctorName(combined);
}

/// Resolves the clean doctor name that is safe to print on the OPD slip.
///
/// Primary source is the doctor row fetched from the database (the `doctors`
/// table uses a dedicated `name` column; the `users` fallback uses
/// `first_name`/`last_name`). Route/stored `doctor_name` strings are only
/// used as a fallback and are defensively cleaned so legacy `name - id`
/// values never print an internal id.
String resolveOpdSlipDoctorName(
  Map<String, dynamic> doctor, {
  String? storedName,
  String? routeName,
}) {
  final fromRow = _doctorNameFromRow(doctor);
  if (fromRow.isNotEmpty) return fromRow;

  final fromRoute = cleanDoctorName(routeName);
  if (fromRoute.isNotEmpty) return fromRoute;

  final fromStored = cleanDoctorName(storedName);
  if (fromStored.isNotEmpty) return fromStored;

  return 'N/A';
}

/// OPD payment slip PDF generator + printer.
///
/// Registration ke time payment collect hone ke baad is service se slip
/// generate/print ki jaati hai.
class OPDSlipPrintService {
  /// Amount rows for the billing section of the printed slip.
  ///
  /// The discount row is only included when the discount is greater than
  /// zero. Amounts are formatted with the Indian rupee symbol and Indian
  /// digit grouping (`₹300`, `₹1,000`).
  static List<List<dynamic>> buildBillingRows({
    required double consultationFee,
    required double discountAmount,
    required double netPayable,
    required double paidAmount,
    required double balanceAmount,
    required String paymentMode,
    required String paymentStatus,
  }) {
    return [
      ['Consultation Fee', PDFFontHelper.formatIndianCurrency(consultationFee)],
      if (discountAmount > 0)
        ['Discount', PDFFontHelper.formatIndianCurrency(discountAmount)],
      ['Net Payable', PDFFontHelper.formatIndianCurrency(netPayable)],
      ['Paid Amount', PDFFontHelper.formatIndianCurrency(paidAmount)],
      if (balanceAmount > 0)
        ['Balance', PDFFontHelper.formatIndianCurrency(balanceAmount)],
      ['Payment Mode', paymentMode],
      ['Payment Status', paymentStatus],
    ];
  }

  static Future<Uint8List> generateSlipPdf({
    required String hospitalName,
    required String hospitalAddress,
    String hospitalContact = '',
    required String patientName,
    required String uhid,
    required String doctorName,
    required String department,
    required double consultationFee,
    required double discountAmount,
    required double netPayable,
    required double paidAmount,
    required double balanceAmount,
    required String paymentMode,
    required String paymentStatus,
    required DateTime date,
    required String slipNumber,
    String? tokenNumber,
    bool isEmergency = false,
  }) async {
    await PDFFontHelper.loadFonts();

    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: opdSlipA5Landscape,
        orientation: pw.PageOrientation.natural,
        margin: const pw.EdgeInsets.all(_slipMarginMm * PdfPageFormat.mm),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _buildHeader(hospitalName, hospitalAddress, hospitalContact),
              pw.SizedBox(height: 2.5 * PdfPageFormat.mm),
              _buildMetaRow(slipNumber, date, tokenNumber),
              pw.SizedBox(height: 2.5 * PdfPageFormat.mm),
              pw.Expanded(
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      flex: 3,
                      child: _buildSectionTable(
                        title: 'Patient Details',
                        labelWidth: 72,
                        rows: [
                          ['Patient Name', patientName],
                          ['UHID', uhid],
                          ['Department', department],
                          ['Doctor', doctorName],
                          [
                            'Consultation Type',
                            isEmergency
                                ? 'Emergency Consultation'
                                : 'OPD Consultation',
                          ],
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 3 * PdfPageFormat.mm),
                    pw.Expanded(
                      flex: 2,
                      child: _buildSectionTable(
                        title: 'Billing Details',
                        labelWidth: 66,
                        rightAlignValues: true,
                        rows: buildBillingRows(
                          consultationFee: consultationFee,
                          discountAmount: discountAmount,
                          netPayable: netPayable,
                          paidAmount: paidAmount,
                          balanceAmount: balanceAmount,
                          paymentMode: paymentMode,
                          paymentStatus: paymentStatus,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 2.5 * PdfPageFormat.mm),
              _buildFooter(),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  static pw.Widget _buildHeader(
    String hospitalName,
    String hospitalAddress,
    String hospitalContact,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        PDFFontHelper.text(
          hospitalName,
          fontSize: 19,
          fontWeight: pw.FontWeight.bold,
          textAlign: pw.TextAlign.center,
        ),
        if (hospitalAddress.isNotEmpty)
          PDFFontHelper.text(
            hospitalAddress,
            fontSize: 10.5,
            textAlign: pw.TextAlign.center,
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
          ),
        if (hospitalContact.isNotEmpty)
          PDFFontHelper.text(
            hospitalContact,
            fontSize: 9.5,
            textAlign: pw.TextAlign.center,
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
          ),
        pw.SizedBox(height: 1.5 * PdfPageFormat.mm),
        pw.Divider(thickness: 1),
        pw.SizedBox(height: 1.5 * PdfPageFormat.mm),
        PDFFontHelper.text(
          'OPD PAYMENT SLIP',
          fontSize: 14,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blue900,
          textAlign: pw.TextAlign.center,
        ),
      ],
    );
  }

  static pw.Widget _buildMetaRow(
    String slipNumber,
    DateTime date,
    String? tokenNumber,
  ) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _buildMetaCell('Slip No.', slipNumber),
        pw.SizedBox(width: 2 * PdfPageFormat.mm),
        _buildMetaCell('Date', date.toIso8601String().split('T')[0]),
        pw.SizedBox(width: 2 * PdfPageFormat.mm),
        _buildMetaCell('Token', tokenNumber ?? 'N/A'),
      ],
    );
  }

  static pw.Widget _buildMetaCell(String label, String value) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey500, width: 0.6),
          borderRadius: pw.BorderRadius.circular(2),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            PDFFontHelper.text(
              label,
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.grey600,
            ),
            PDFFontHelper.text(
              value,
              fontSize: 10.5,
              fontWeight: pw.FontWeight.bold,
              maxLines: 1,
              overflow: pw.TextOverflow.clip,
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _buildSectionTable({
    required String title,
    required List<List<dynamic>> rows,
    double labelWidth = 80,
    bool rightAlignValues = false,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        PDFFontHelper.text(
          title,
          fontSize: 11,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blue900,
        ),
        pw.SizedBox(height: 1.5 * PdfPageFormat.mm),
        pw.TableHelper.fromTextArray(
          headers: const ['Particulars', 'Details'],
          data: rows,
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
          headerStyle: PDFFontHelper.textStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
          cellStyle: PDFFontHelper.bodyStyle(fontSize: 10),
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 3,
          ),
          columnWidths: {
            0: pw.FixedColumnWidth(labelWidth),
            1: pw.FlexColumnWidth(1),
          },
          cellAlignments: rightAlignValues
              ? <int, pw.AlignmentGeometry>{1: pw.Alignment.centerRight}
              : null,
        ),
      ],
    );
  }

  static pw.Widget _buildFooter() {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        PDFFontHelper.text(
          'This is a computer-generated slip.',
          fontSize: 8,
          color: PdfColors.grey600,
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            PDFFontHelper.text('Authorized Signature', fontSize: 10),
            pw.SizedBox(height: 3 * PdfPageFormat.mm),
            pw.Container(width: 90, height: 0.6, color: PdfColors.grey500),
          ],
        ),
      ],
    );
  }

  /// Opens the platform print dialog with the generated OPD slip PDF.
  static Future<void> printSlip(Map<String, dynamic> data) async {
    final fallbackNet = _toDouble(data['paymentAmount']);
    final consultationFee = _toDouble(data['consultationFee'] ?? fallbackNet);
    final discountAmount = _toDouble(
      data['discount'] ?? (consultationFee - fallbackNet),
    );
    final netPayable = _toDouble(data['netPayable'] ?? fallbackNet);
    final paidAmount = _toDouble(data['paidAmount'] ?? fallbackNet);
    final balanceAmount = _toDouble(
      data['balanceAmount'] ?? (netPayable - paidAmount),
    );

    final hospital = _asStringMap(data['hospital']);
    final hospitalName = _cleanAddressPart(hospital?['name']);
    final hospitalAddress = hospitalAddressFromRecord(hospital);
    final hospitalContact = hospitalContactFromRecord(hospital);
    final fallbackAddress = _cleanAddressPart(data['hospitalAddress']);

    final bytes = await generateSlipPdf(
      hospitalName: hospitalName.isNotEmpty
          ? hospitalName
          : (_cleanAddressPart(data['hospitalName']).isNotEmpty
                ? _cleanAddressPart(data['hospitalName'])
                : 'N/A'),
      hospitalAddress: hospitalAddress.isNotEmpty
          ? hospitalAddress
          : (fallbackAddress.isNotEmpty ? fallbackAddress : 'N/A'),
      hospitalContact: hospitalContact,
      patientName: _cleanAddressPart(data['patientName']).isNotEmpty
          ? _cleanAddressPart(data['patientName'])
          : 'N/A',
      uhid: _cleanAddressPart(data['uhid']).isNotEmpty
          ? _cleanAddressPart(data['uhid'])
          : 'N/A',
      doctorName: resolveOpdSlipDoctorName(
        _asStringMap(data['doctor']) ?? const <String, dynamic>{},
        storedName: data['doctorName']?.toString(),
      ),
      department: _cleanAddressPart(data['department']).isNotEmpty
          ? _cleanAddressPart(data['department'])
          : 'N/A',
      consultationFee: consultationFee,
      discountAmount: discountAmount,
      netPayable: netPayable,
      paidAmount: paidAmount,
      balanceAmount: balanceAmount,
      paymentMode: _cleanAddressPart(data['paymentMode']).isNotEmpty
          ? _cleanAddressPart(data['paymentMode'])
          : 'N/A',
      paymentStatus: _cleanAddressPart(data['paymentStatus']).isNotEmpty
          ? _cleanAddressPart(data['paymentStatus'])
          : 'N/A',
      date: data['date'] is DateTime
          ? data['date'] as DateTime
          : DateTime.now(),
      slipNumber: _cleanAddressPart(data['slipNumber']).isNotEmpty
          ? _cleanAddressPart(data['slipNumber'])
          : 'OPD-${DateTime.now().millisecondsSinceEpoch}',
      tokenNumber: data['tokenNumber']?.toString(),
      isEmergency: data['isEmergency'] == true,
    );

    await Printing.layoutPdf(
      format: opdSlipA5Landscape,
      onLayout: (PdfPageFormat format) async => bytes,
    );
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
                Text(
                  'Failed to load slip: $error',
                  textAlign: TextAlign.center,
                ),
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

          final consultationFee = _toDouble(payment['consultation_fee']);
          final netPayable = _toDouble(payment['payment_amount']);
          final discountAmount = consultationFee - netPayable;
          final paidAmount = _toDouble(payment['paid_amount'] ?? netPayable);
          final balanceAmount = _toDouble(
            payment['balance_amount'] ?? (netPayable - paidAmount),
          );

          final slipData = <String, dynamic>{
            'hospital': hospital,
            'doctor': doctor,
            'hospitalName': hospital['name']?.toString() ?? 'N/A',
            'hospitalAddress': hospitalAddressFromRecord(hospital),
            'hospitalContact': hospitalContactFromRecord(hospital),
            'patientName': patientName.isEmpty
                ? 'Unknown Patient'
                : patientName,
            'uhid': patient['uhid']?.toString() ?? 'N/A',
            'doctorName': resolveOpdSlipDoctorName(
              doctor,
              storedName: payment['doctor_name']?.toString(),
              routeName: doctorName,
            ),
            'department': department['name']?.toString() ?? 'N/A',
            'consultationFee': consultationFee,
            'discount': discountAmount,
            'netPayable': netPayable,
            'paymentAmount': netPayable,
            'paidAmount': paidAmount,
            'balanceAmount': balanceAmount,
            'paymentMode': _paymentModeLabel(payment['payment_mode']),
            'paymentStatus': _paymentStatusLabel(payment['payment_status']),
            'date':
                DateTime.tryParse(payment['visit_date']?.toString() ?? '') ??
                DateTime.now(),
            'slipNumber': slipNumber,
            'tokenNumber': payment['token_number']?.toString(),
            'isEmergency': payment['is_emergency'] == true,
          };

          final hospitalAddress = slipData['hospitalAddress'] as String;
          final hospitalContact = slipData['hospitalContact'] as String;

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
                                textAlign: TextAlign.center,
                              ),
                              if (hospitalAddress.isNotEmpty)
                                Text(
                                  hospitalAddress,
                                  style: theme.textTheme.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                              if (hospitalContact.isNotEmpty)
                                Text(
                                  hospitalContact,
                                  style: theme.textTheme.bodySmall,
                                  textAlign: TextAlign.center,
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
                        _infoRow(
                          theme,
                          'Token',
                          slipData['tokenNumber']?.toString() ?? 'N/A',
                        ),
                        _infoRow(
                          theme,
                          'Patient Name',
                          slipData['patientName'],
                        ),
                        _infoRow(theme, 'UHID', slipData['uhid']),
                        _infoRow(theme, 'Department', slipData['department']),
                        _infoRow(theme, 'Doctor', slipData['doctorName']),
                        _infoRow(
                          theme,
                          'Consultation Type',
                          slipData['isEmergency'] == true
                              ? 'Emergency Consultation'
                              : 'OPD Consultation',
                        ),
                        const Divider(height: 24),
                        _infoRow(
                          theme,
                          'Consultation Fee',
                          PDFFontHelper.formatIndianCurrency(consultationFee),
                        ),
                        if (discountAmount > 0)
                          _infoRow(
                            theme,
                            'Discount',
                            PDFFontHelper.formatIndianCurrency(discountAmount),
                          ),
                        _infoRow(
                          theme,
                          'Net Payable',
                          PDFFontHelper.formatIndianCurrency(netPayable),
                          valueColor: theme.colorScheme.primary,
                          bold: true,
                        ),
                        _infoRow(
                          theme,
                          'Paid Amount',
                          PDFFontHelper.formatIndianCurrency(paidAmount),
                        ),
                        if (balanceAmount > 0)
                          _infoRow(
                            theme,
                            'Balance',
                            PDFFontHelper.formatIndianCurrency(balanceAmount),
                          ),
                        _infoRow(
                          theme,
                          'Payment Mode',
                          slipData['paymentMode'],
                        ),
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
