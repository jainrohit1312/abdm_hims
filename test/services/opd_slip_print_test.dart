import 'dart:convert';
import 'dart:typed_data';

import 'package:abdm_hims/core/utils/display_names.dart';
import 'package:abdm_hims/core/utils/pdf_font_helper.dart';
import 'package:abdm_hims/presentation/screens/opd/opd_slip_print.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await PDFFontHelper.loadFonts();
  });

  group('formatHospitalAddress', () {
    test('combines address, city, state and pincode in expected format', () {
      final address = formatHospitalAddress(
        address: 'Navada',
        city: 'Mathura',
        state: 'Uttar Pradesh',
        pincode: '281001',
      );

      expect(address, 'Navada, Mathura, Uttar Pradesh - 281001');
    });

    test('ignores null and empty components without printing null', () {
      expect(
        formatHospitalAddress(
          address: null,
          city: '',
          state: null,
          pincode: '',
        ),
        '',
      );
      expect(formatHospitalAddress(city: 'Mathura'), 'Mathura');
      expect(
        formatHospitalAddress(city: 'Mathura', pincode: '281001'),
        'Mathura - 281001',
      );
    });

    test('does not duplicate city/state already present in address', () {
      final address = formatHospitalAddress(
        address: 'Navada, Mathura',
        city: 'Mathura',
        state: 'Uttar Pradesh',
        pincode: '281001',
      );

      expect(address, 'Navada, Mathura, Uttar Pradesh - 281001');
      expect(address.indexOf('Mathura, Mathura'), -1);
    });

    test('shows pincode only when available', () {
      expect(
        formatHospitalAddress(
          address: 'Navada',
          city: 'Mathura',
          state: 'Uttar Pradesh',
        ),
        'Navada, Mathura, Uttar Pradesh',
      );
    });
  });

  group('resolveOpdSlipDoctorName / cleanDoctorName', () {
    test('uses the clean doctor row name and never prints a UUID', () {
      final name = resolveOpdSlipDoctorName({
        'name': 'Dr. Om Chaudhary',
      }, storedName: 'Dr. Om Chaudhary - 123e4567-e89b-12d3-a456-426614174000');

      expect(name, 'Dr. Om Chaudhary');
      expect(name.contains('123e4567'), isFalse);
      expect(name.contains('-'), isFalse);
    });

    test('cleans legacy stored doctor_name when no doctor row exists', () {
      final name = resolveOpdSlipDoctorName(
        const {},
        storedName: 'Dr. Om Chaudhary - 123e4567-e89b-12d3-a456-426614174000',
      );

      expect(name, 'Dr. Om Chaudhary');
      expect(name.contains('123e4567'), isFalse);
    });

    test('falls back to first_name/last_name from the users table shape', () {
      final name = resolveOpdSlipDoctorName({
        'first_name': 'Om',
        'last_name': 'Chaudhary',
      });

      expect(name, 'Om Chaudhary');
    });

    test('cleanDoctorName keeps the Dr. prefix', () {
      expect(
        cleanDoctorName(
          'Dr. Om Chaudhary - 123e4567-e89b-12d3-a456-426614174000',
        ),
        'Dr. Om Chaudhary',
      );
    });
  });

  group('PDFFontHelper rupee formatting and embedded font', () {
    test('formats amounts with Indian grouping and no space', () {
      expect(PDFFontHelper.formatIndianCurrency(300), '₹300');
      expect(PDFFontHelper.formatIndianCurrency(1000), '₹1,000');
      expect(PDFFontHelper.formatIndianCurrency(100000), '₹1,00,000');
      expect(
        PDFFontHelper.formatIndianCurrency(1234567.89, decimals: 2),
        '₹12,34,567.89',
      );
    });

    test('loads embedded NotoSans fonts that support the rupee glyph', () {
      expect(PDFFontHelper.hasEmbeddedFonts, isTrue);
      final style = PDFFontHelper.textStyle();
      expect(style.fontNormal, isNotNull);
      expect(style.fontBold, isNotNull);
    });
  });

  group('OPDSlipPrintService.buildBillingRows', () {
    test('hides discount row when discount is zero', () {
      final rows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 0,
        netPayable: 300,
        paidAmount: 300,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
      );

      expect(rows.any((row) => row.first == 'Discount'), isFalse);
      expect(
        rows.any((row) => row[0] == 'Net Payable' && row[1] == '₹300'),
        isTrue,
      );
    });

    test('shows discount row when discount is positive', () {
      final rows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 50,
        netPayable: 250,
        paidAmount: 250,
        balanceAmount: 0,
        paymentMode: 'UPI',
        paymentStatus: 'Paid',
      );

      expect(
        rows.any((row) => row[0] == 'Discount' && row[1] == '₹50'),
        isTrue,
      );
      expect(
        rows.any((row) => row[0] == 'Net Payable' && row[1] == '₹250'),
        isTrue,
      );
    });

    test('net payable remains accurate regardless of discount visibility', () {
      final zeroDiscountRows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 0,
        netPayable: 300,
        paidAmount: 300,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
      );
      final positiveDiscountRows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 50,
        netPayable: 250,
        paidAmount: 250,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
      );

      expect(
        zeroDiscountRows.any(
          (row) => row[0] == 'Net Payable' && row[1] == '₹300',
        ),
        isTrue,
      );
      expect(
        positiveDiscountRows.any(
          (row) => row[0] == 'Net Payable' && row[1] == '₹250',
        ),
        isTrue,
      );
    });
  });

  group('OPDSlipPrintService.generateSlipPdf page format', () {
    Future<Uint8List> generatePdf({
      double discountAmount = 0,
      String hospitalName = 'HIMS Hospital',
      String hospitalAddress = 'Navada, Mathura, Uttar Pradesh - 281001',
      String patientName = 'Rohit Kumar',
      String doctorName = 'Dr. Om Chaudhary',
      bool longTexts = false,
    }) {
      return OPDSlipPrintService.generateSlipPdf(
        hospitalName: longTexts
            ? 'Super Speciality Hospital And Research Centre With A Very Long Name That Keeps Going On'
            : hospitalName,
        hospitalAddress: longTexts
            ? 'This Is A Very Long Hospital Address That Continues Well Beyond A Single Line, Plot 12, Sector 62, Noida, Uttar Pradesh - 201309'
            : hospitalAddress,
        patientName: longTexts
            ? 'A Very Long Patient Name That Would Normally Overflow A Small Receipt Line'
            : patientName,
        uhid: 'UHID-0001',
        doctorName: longTexts
            ? 'Dr. Very Long Doctor Name That Keeps Continuing Without Stopping Soon'
            : doctorName,
        department: 'General Medicine',
        consultationFee: 300,
        discountAmount: discountAmount,
        netPayable: 300 - discountAmount,
        paidAmount: 300 - discountAmount,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
        date: DateTime(2026, 9, 10),
        slipNumber: 'OPD-ABC12345',
        tokenNumber: '42',
        isEmergency: false,
      );
    }

    List<List<double>> mediaBoxes(Uint8List bytes) {
      final text = latin1.decode(bytes);
      final pattern = RegExp(
        r'/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]',
      );
      return [
        for (final match in pattern.allMatches(text))
          [
            double.parse(match.group(1)!),
            double.parse(match.group(2)!),
            double.parse(match.group(3)!),
            double.parse(match.group(4)!),
          ],
      ];
    }

    int pageCount(Uint8List bytes) {
      final text = latin1.decode(bytes);
      return RegExp(r'/Type\s*/Page(?!s)').allMatches(text).length;
    }

    test('is exactly one page of 210 mm x 148 mm', () async {
      final bytes = await generatePdf();

      expect(pageCount(bytes), 1, reason: 'OPD slip must be a single page');
      final boxes = mediaBoxes(bytes);
      expect(boxes, hasLength(1));

      final box = boxes.first;
      final widthMm = (box[2] - box[0]) * 25.4 / 72;
      final heightMm = (box[3] - box[1]) * 25.4 / 72;
      expect(widthMm, closeTo(210, 0.1));
      expect(heightMm, closeTo(148, 0.1));
    });

    test('embeds the PDF-compatible rupee-capable font', () async {
      final bytes = await generatePdf();

      final text = latin1.decode(bytes);
      expect(text, contains('/FontFile2'));
    });

    test(
      'does not overflow with long hospital, patient and doctor names',
      () async {
        final bytes = await generatePdf(longTexts: true);

        expect(pageCount(bytes), 1);
        final box = mediaBoxes(bytes).first;
        final widthMm = (box[2] - box[0]) * 25.4 / 72;
        final heightMm = (box[3] - box[1]) * 25.4 / 72;
        expect(widthMm, closeTo(210, 0.1));
        expect(heightMm, closeTo(148, 0.1));
      },
    );
  });
}
