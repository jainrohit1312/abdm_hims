import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:abdm_hims/core/utils/display_names.dart';
import 'package:abdm_hims/core/utils/pdf_font_helper.dart';
import 'package:abdm_hims/presentation/screens/opd/opd_slip_print.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

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

  group('normalizeTokenNumber', () {
    test('returns a valid queue number', () {
      expect(normalizeTokenNumber('42'), '42');
      expect(normalizeTokenNumber(42), '42');
      expect(normalizeTokenNumber(' 007 '), '007');
    });

    test('hides null, empty, placeholder and zero tokens', () {
      expect(normalizeTokenNumber(null), isNull);
      expect(normalizeTokenNumber(''), isNull);
      expect(normalizeTokenNumber('N/A'), isNull);
      expect(normalizeTokenNumber('NA'), isNull);
      expect(normalizeTokenNumber('na'), isNull);
      expect(normalizeTokenNumber('0'), isNull);
      expect(normalizeTokenNumber('00'), isNull);
      expect(normalizeTokenNumber('abc'), isNull);
      expect(normalizeTokenNumber('12A'), isNull);
    });
  });

  group('OPDSlipPrintService meta row', () {
    final date = DateTime(2026, 9, 10);

    test('Date is the rightmost header box when token is valid', () {
      final cells = OPDSlipPrintService.buildMetaCells(
        'OPD-ABC12345',
        date,
        '42',
      );

      expect(cells.map((c) => c.label).toList(), ['Slip No.', 'Token', 'Date']);
      expect(cells.last.label, 'Date');
      expect(cells.first.label, 'Slip No.');
      expect(cells[1].value, '42');
    });

    test('Token is completely hidden when unavailable', () {
      for (final token in <String?>[null, '', 'N/A', 'NA', '0', 'abc']) {
        final cells = OPDSlipPrintService.buildMetaCells(
          'OPD-ABC12345',
          date,
          token,
        );

        expect(
          cells.map((c) => c.label).toList(),
          ['Slip No.', 'Date'],
          reason: 'token="$token" must hide the Token box',
        );
        expect(cells.last.label, 'Date');
      }
    });

    test(
      'visible boxes are equal flex and Slip/Date expand when Token hidden',
      () {
        final withToken =
            OPDSlipPrintService.buildMetaRow('OPD-ABC12345', date, '42')
                as pw.Row;
        final tokenExpanded = withToken.children
            .whereType<pw.Expanded>()
            .toList();
        expect(tokenExpanded, hasLength(3));
        expect(tokenExpanded.map((e) => e.flex).toSet(), {1});

        final withoutToken =
            OPDSlipPrintService.buildMetaRow('OPD-ABC12345', date, null)
                as pw.Row;
        final noTokenExpanded = withoutToken.children
            .whereType<pw.Expanded>()
            .toList();
        expect(noTokenExpanded, hasLength(2));
        expect(noTokenExpanded.map((e) => e.flex).toSet(), {1});
      },
    );
  });

  group('OPDSlipPrintService sections layout', () {
    final billingRows = OPDSlipPrintService.buildBillingRows(
      consultationFee: 300,
      discountAmount: 50,
      paidAmount: 250,
      balanceAmount: 0,
      paymentMode: 'Cash',
      paymentStatus: 'Paid',
    );

    test('Patient Details and Billing Details are equally wide', () {
      final row =
          OPDSlipPrintService.buildSectionsRow(
                patientName: 'Rohit Kumar',
                uhid: 'UHID-0001',
                department: 'General Medicine',
                doctorName: 'Dr. Om Chaudhary',
                isEmergency: false,
                billingRows: billingRows,
              )
              as pw.Row;

      final sections = row.children.whereType<pw.Expanded>().toList();
      expect(sections, hasLength(2));
      expect(sections[0].flex, 1);
      expect(sections[1].flex, 1);

      final gap = row.children.whereType<pw.SizedBox>().single;
      expect(gap.width, 3 * PdfPageFormat.mm);
    });

    test(
      'Billing Details label column is wide enough for Consultation Fee',
      () {
        final table = OPDSlipPrintService.buildSectionTable(
          rows: billingRows,
          labelFlex: 48,
          detailsFlex: 52,
          rightAlignValues: true,
        );

        final widths = table.columnWidths;
        expect(widths, isNotNull);
        final label = widths![0]! as pw.FlexColumnWidth;
        final details = widths[1]! as pw.FlexColumnWidth;
        expect(label.flex, closeTo(48, 0.001));
        expect(details.flex, closeTo(52, 0.001));

        // 48% of the section width (97.5 mm) is ~46.8 mm / ~132 pt, which
        // comfortably keeps `Consultation Fee`, `Paid Amount`, `Payment Mode`
        // and `Payment Status` on a single line at 10 pt.
        final rowLabels = billingRows
            .map((row) => row.first.toString())
            .toList();
        for (final label in rowLabels) {
          expect(label.contains('\n'), isFalse);
        }
        expect(rowLabels, contains('Consultation Fee'));
        expect(rowLabels, contains('Paid Amount'));
        expect(rowLabels, contains('Payment Mode'));
        expect(rowLabels, contains('Payment Status'));
      },
    );
  });

  group('OPDSlipPrintService.buildBillingRows', () {
    test('zero discount hides the discount row', () {
      final rows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 0,
        paidAmount: 300,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
      );

      expect(rows.any((row) => row.first == 'Discount'), isFalse);
    });

    test('positive discount displays the discount row', () {
      final rows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 50,
        paidAmount: 250,
        balanceAmount: 0,
        paymentMode: 'UPI',
        paymentStatus: 'Paid',
      );

      expect(
        rows.any((row) => row[0] == 'Discount' && row[1] == '₹50'),
        isTrue,
      );
    });

    test('Net Payable is never printed', () {
      final rows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 50,
        paidAmount: 250,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
      );

      expect(rows.any((row) => row.first == 'Net Payable'), isFalse);
    });

    test('internal net-payable input does not alter printed billing rows', () {
      // The printed rows only expose Consultation Fee, optional Discount,
      // Paid Amount and payment metadata. Net payable remains an internal
      // value passed separately to generateSlipPdf.
      final rows = OPDSlipPrintService.buildBillingRows(
        consultationFee: 300,
        discountAmount: 50,
        paidAmount: 250,
        balanceAmount: 0,
        paymentMode: 'Cash',
        paymentStatus: 'Paid',
      );

      expect(rows, [
        ['Consultation Fee', '₹300'],
        ['Discount', '₹50'],
        ['Paid Amount', '₹250'],
        ['Payment Mode', 'Cash'],
        ['Payment Status', 'Paid'],
      ]);
    });
  });

  group('OPDSlipPrintService.generateSlipPdf page format', () {
    Future<Uint8List> generatePdf({
      double discountAmount = 0,
      String hospitalName = 'HIMS Hospital',
      String hospitalAddress = 'Navada, Mathura, Uttar Pradesh - 281001',
      String patientName = 'Rohit Kumar',
      String doctorName = 'Dr. Om Chaudhary',
      String? tokenNumber = '42',
      bool longTexts = false,
      bool compress = false,
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
        tokenNumber: tokenNumber,
        isEmergency: false,
        compress: compress,
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

    test(
      'renders both sample cases without Net Payable and with one page',
      () async {
        final noTokenNoDiscount = await generatePdf(
          tokenNumber: null,
          discountAmount: 0,
        );
        final tokenAndDiscount = await generatePdf(
          tokenNumber: '42',
          discountAmount: 50,
        );

        expect(pageCount(noTokenNoDiscount), 1);
        expect(pageCount(tokenAndDiscount), 1);

        // The billing row builder is the single source of truth for the
        // printed billing section, so Net Payable cannot appear in either PDF.
        expect(
          OPDSlipPrintService.buildBillingRows(
            consultationFee: 300,
            discountAmount: 0,
            paidAmount: 300,
            balanceAmount: 0,
            paymentMode: 'Cash',
            paymentStatus: 'Paid',
          ).any((row) => row.first == 'Net Payable'),
          isFalse,
        );
        expect(
          OPDSlipPrintService.buildBillingRows(
            consultationFee: 300,
            discountAmount: 50,
            paidAmount: 250,
            balanceAmount: 0,
            paymentMode: 'Cash',
            paymentStatus: 'Paid',
          ).any((row) => row.first == 'Net Payable'),
          isFalse,
        );
      },
    );

    test(
      'writes both sample PDFs to build/opd_slip_samples for inspection',
      () async {
        final noTokenNoDiscount = await generatePdf(
          tokenNumber: null,
          discountAmount: 0,
        );
        final tokenAndDiscount = await generatePdf(
          tokenNumber: '42',
          discountAmount: 50,
        );

        final dir = Directory('build/opd_slip_samples');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/opd_slip_no_token_no_discount.pdf',
        ).writeAsBytes(noTokenNoDiscount, flush: true);
        await File(
          '${dir.path}/opd_slip_token_discount.pdf',
        ).writeAsBytes(tokenAndDiscount, flush: true);

        expect(
          File('${dir.path}/opd_slip_no_token_no_discount.pdf').existsSync(),
          isTrue,
        );
        expect(
          File('${dir.path}/opd_slip_token_discount.pdf').existsSync(),
          isTrue,
        );
      },
    );
  });
}
