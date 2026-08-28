import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import 'database_service.dart';

/// Generates and prints a doctor e-prescription PDF.
///
/// Prescription ab poori clinical document hai. Sirf wahi heads print hote
/// hain jinke paas data hai — empty sections apne aap skip ho jaate hain.
class PrescriptionPrintService {
  /// Builds the prescription PDF and returns its bytes.
  static Future<Uint8List> generatePrescriptionPdf({
    required String hospitalName,
    required String hospitalAddress,
    required String patientName,
    required String uhid,
    String? patientAge,
    String? patientSex,
    required String doctorName,
    required String prescriptionDate,
    required String prescriptionId,
    required List<Map<String, dynamic>> medicines,
    Map<String, dynamic>? clinicalNotes,
    Map<String, dynamic>? history,
    Map<String, dynamic>? investigations,
    Map<String, dynamic>? advice,
  }) async {
    final notes = _normalizeNotes(
      clinicalNotes: clinicalNotes,
      history: history,
      investigations: investigations,
      advice: advice,
    );
    final pdf = pw.Document();

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
                  'PRESCRIPTION',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue800,
                  ),
                ),
              ],
            ),
            pw.Divider(thickness: 1.5),
            pw.SizedBox(height: 12),

            // ------------------------------------------------------------
            // Patient + doctor info
            // ------------------------------------------------------------
            _patientDoctorRow(
              patientName: patientName,
              uhid: uhid,
              age: patientAge,
              sex: patientSex,
              date: prescriptionDate,
              doctorName: doctorName,
              prescriptionId: prescriptionId,
            ),

            // ------------------------------------------------------------
            // Clinical heads — sirf bhare hue sections print hote hain
            // ------------------------------------------------------------
            ..._section('Chief Complaints', notes['chief_complaints']),
            ..._section('History of Present Illness', notes['hopi']),
            ..._section('Past History', notes['past_history']),
            ..._section(
              'Personal / Family History',
              notes['personal_family_history'],
            ),
            ..._section('Drug / Allergy History', notes['drug_allergy']),
            ..._section('Vitals', _vitalsLine(notes['vitals'])),
            ..._section('Examination', notes['examination']),
            ..._section('Provisional Diagnosis', notes['diagnosis']),
            ..._section(
              'Investigations Advised',
              _investigationsLine(notes['investigations']),
            ),

            // Medicines table (Rx)
            ..._medicinesSection(medicines),

            ..._section('Advice', notes['advice']),
            ..._section('Follow-up', notes['follow_up']),

            pw.SizedBox(height: 36),

            // ------------------------------------------------------------
            // Signature block
            // ------------------------------------------------------------
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    doctorName,
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  pw.SizedBox(height: 24),
                  pw.Text(
                    'Doctor Signature',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Text(
              'This is a computer generated e-prescription.',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  /// Opens the platform print dialog with the generated prescription PDF.
  static Future<void> printPrescription({
    required String hospitalName,
    required String hospitalAddress,
    required String patientName,
    required String uhid,
    String? patientAge,
    String? patientSex,
    required String doctorName,
    required String prescriptionDate,
    required String prescriptionId,
    required List<Map<String, dynamic>> medicines,
    Map<String, dynamic>? clinicalNotes,
    Map<String, dynamic>? history,
    Map<String, dynamic>? investigations,
    Map<String, dynamic>? advice,
  }) async {
    final bytes = await generatePrescriptionPdf(
      hospitalName: hospitalName,
      hospitalAddress: hospitalAddress,
      patientName: patientName,
      uhid: uhid,
      patientAge: patientAge,
      patientSex: patientSex,
      doctorName: doctorName,
      prescriptionDate: prescriptionDate,
      prescriptionId: prescriptionId,
      medicines: medicines,
      clinicalNotes: clinicalNotes,
      history: history,
      investigations: investigations,
      advice: advice,
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => bytes);
  }

  /// OPD registration ki latest saved prescription fetch karke print karta
  /// hai (OPD queue / consultation saved list se use hota hai).
  ///
  /// Returns `null` on success, otherwise a user-facing error message.
  static Future<String?> printForOPD({
    required DatabaseService db,
    required String opdRegistrationId,
    String? hospitalId,
    String? prescriptionId,
    String fallbackPatientName = 'Patient',
    String fallbackUhid = 'N/A',
  }) async {
    try {
      final prescriptions = await db.getOPDPrescriptions(opdRegistrationId);
      if (prescriptions.isEmpty) {
        return 'No prescription saved for this visit yet.';
      }

      final prescription = (prescriptionId == null || prescriptionId.isEmpty)
          ? prescriptions.first
          : prescriptions.firstWhere(
              (p) => p['id']?.toString() == prescriptionId,
              orElse: () => prescriptions.first,
            );
      return _printPrescriptionRow(
        db: db,
        prescription: prescription,
        hospitalId: hospitalId,
        fallbackPatientName: fallbackPatientName,
        fallbackUhid: fallbackUhid,
      );
    } catch (e) {
      AppLogger.e('Prescription print failed', e);
      return 'Prescription print failed: $e';
    }
  }

  /// IPD admission ki saved (medicines-only) prescription print karta hai.
  static Future<String?> printForIPD({
    required DatabaseService db,
    required String ipdAdmissionId,
    String? hospitalId,
    String? prescriptionId,
    String fallbackPatientName = 'Patient',
    String fallbackUhid = 'N/A',
  }) async {
    try {
      final prescriptions = await db.getIPDPrescriptions(ipdAdmissionId);
      if (prescriptions.isEmpty) {
        return 'No IPD prescription saved for this admission yet.';
      }

      final prescription = (prescriptionId == null || prescriptionId.isEmpty)
          ? prescriptions.first
          : prescriptions.firstWhere(
              (p) => p['id']?.toString() == prescriptionId,
              orElse: () => prescriptions.first,
            );
      return _printPrescriptionRow(
        db: db,
        prescription: prescription,
        hospitalId: hospitalId,
        fallbackPatientName: fallbackPatientName,
        fallbackUhid: fallbackUhid,
      );
    } catch (e) {
      AppLogger.e('IPD prescription print failed', e);
      return 'Prescription print failed: $e';
    }
  }

  /// Shared print path for one unified prescription row (OPD or IPD).
  static Future<String?> _printPrescriptionRow({
    required DatabaseService db,
    required Map<String, dynamic> prescription,
    String? hospitalId,
    String fallbackPatientName = 'Patient',
    String fallbackUhid = 'N/A',
  }) async {
    // Medicines: naya `medicines` JSONB pehle, legacy `items` fallback.
    final rawMedicines = prescription['medicines'];
    final items = rawMedicines is List
        ? rawMedicines.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : ((prescription['items'] as List?)?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[]);
    final medicines = <Map<String, dynamic>>[
      for (final item in items)
        {
          'medicine_name': item['medicine_name']?.toString() ?? '',
          'dosage': item['dosage']?.toString() ?? '',
          'frequency': item['frequency']?.toString() ?? '',
          'duration': item['duration']?.toString() ?? '',
          'route': item['route']?.toString() ?? '',
          'instructions': item['instructions']?.toString() ?? '',
          'custom_times': item['custom_times'] ?? const <String>[],
        },
    ];

    // Patient details (prescription ke patient_id se resolve karo).
    var patientName = fallbackPatientName;
    var uhid = fallbackUhid;
    String? age;
    String? sex;
    final patientId = prescription['patient_id']?.toString();
    if (patientId != null && patientId.isNotEmpty) {
      final patient = await db.getById(ApiConstants.patientsTable, patientId);
      if (patient != null) {
        final first = patient['first_name']?.toString() ?? '';
        final last = patient['last_name']?.toString() ?? '';
        final name = '$first $last'.trim();
        if (name.isNotEmpty) patientName = name;
        uhid = patient['uhid']?.toString() ?? uhid;
        age = patient['age']?.toString();
        sex = patient['gender']?.toString();
      }
    }

    // Hospital header.
    var hospitalName = 'HIMS Hospital';
    var hospitalAddress = '123, Healthcare Avenue, New Delhi';
    final resolvedHospitalId =
        (hospitalId != null && hospitalId.isNotEmpty)
        ? hospitalId
        : prescription['hospital_id']?.toString();
    if (resolvedHospitalId != null && resolvedHospitalId.isNotEmpty) {
      final hospital = await db.getById(
        ApiConstants.hospitalsTable,
        resolvedHospitalId,
      );
      if (hospital != null) {
        hospitalName = hospital['name']?.toString() ?? hospitalName;
        hospitalAddress =
            hospital['address']?.toString() ?? hospitalAddress;
      }
    }

    final doctorName = await _resolveDoctorName(
      db,
      prescription['doctor_id']?.toString(),
    );

    final history = _asMap(prescription['history']);
    final investigations = _asMap(prescription['investigations']);
    final advice = _asMap(prescription['advice']);
    final clinicalNotes = _asMap(prescription['clinical_notes']);

    await printPrescription(
      hospitalName: hospitalName,
      hospitalAddress: hospitalAddress,
      patientName: patientName,
      uhid: uhid,
      patientAge: age,
      patientSex: sex,
      doctorName: doctorName,
      prescriptionDate:
          prescription['prescription_date']?.toString() ??
          DateTime.now().toIso8601String().split('T')[0],
      prescriptionId: prescription['id']?.toString() ?? 'N/A',
      medicines: medicines,
      clinicalNotes: clinicalNotes,
      history: history,
      investigations: investigations,
      advice: advice,
    );
    return null;
  }

  // ---------------------------------------------------------------------------
  // PDF section builders
  // ---------------------------------------------------------------------------

  static pw.Widget _patientDoctorRow({
    required String patientName,
    required String uhid,
    String? age,
    String? sex,
    required String date,
    required String doctorName,
    required String prescriptionId,
  }) {
    final ageSex = [
      if (age != null && age.isNotEmpty) age,
      if (sex != null && sex.isNotEmpty) sex,
    ].join(' / ');

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: _infoBlock('Patient', {
            'Name': patientName,
            if (ageSex.isNotEmpty) 'Age/Sex': ageSex,
            'UHID': uhid,
            'Date': date,
          }),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: _infoBlock('Doctor', {
            'Name': doctorName,
            'Rx ID': prescriptionId,
          }),
        ),
      ],
    );
  }

  static pw.Widget _infoBlock(String title, Map<String, String> values) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.blue900,
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

  /// Returns the section widgets when [content] is non-empty, otherwise an
  /// empty list — isi wajah se empty heads print nahi hote.
  static List<pw.Widget> _section(String title, dynamic content) {
    final text = _asText(content);
    if (text.isEmpty) return const <pw.Widget>[];
    return <pw.Widget>[
      pw.SizedBox(height: 12),
      pw.Text(
        title,
        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 4),
      pw.Text(text, style: const pw.TextStyle(fontSize: 10)),
    ];
  }

  static List<pw.Widget> _medicinesSection(
    List<Map<String, dynamic>> medicines,
  ) {
    if (medicines.isEmpty) return const <pw.Widget>[];
    return <pw.Widget>[
      pw.SizedBox(height: 12),
      pw.Text(
        'Treatment (Rx)',
        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: [
          '#',
          'Medicine',
          'Dosage',
          'Frequency',
          'Route',
          'Timing',
          'Duration',
          'Instructions',
        ],
        data: _buildTableRows(medicines),
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        headerStyle: pw.TextStyle(
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
          fontSize: 9,
        ),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blue800),
        cellStyle: const pw.TextStyle(fontSize: 9),
        cellAlignment: pw.Alignment.topLeft,
        headerAlignment: pw.Alignment.centerLeft,
        columnWidths: {
          0: const pw.FixedColumnWidth(20),
          1: const pw.FlexColumnWidth(3),
          2: const pw.FlexColumnWidth(1.5),
          3: const pw.FlexColumnWidth(1.5),
          4: const pw.FlexColumnWidth(1.5),
          5: const pw.FlexColumnWidth(2.5),
          6: const pw.FlexColumnWidth(1.5),
          7: const pw.FlexColumnWidth(2.5),
        },
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Clinical notes helpers
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

  /// Unified columns (`history`, `investigations`, `advice`) ko legacy
  /// `clinical_notes` keys mein normalize karta hai taaki baaki PDF section
  /// builders bina kisi change ke dono formats print kar saken.
  static Map<String, dynamic> _normalizeNotes({
    Map<String, dynamic>? clinicalNotes,
    Map<String, dynamic>? history,
    Map<String, dynamic>? investigations,
    Map<String, dynamic>? advice,
  }) {
    final notes = Map<String, dynamic>.from(_asMap(clinicalNotes));
    final h = _asMap(history);
    final inv = _asMap(investigations);
    final adv = _asMap(advice);

    void putNew(String key, String? value) {
      final existing = _asText(notes[key]);
      final incoming = (value ?? '').trim();
      if (existing.isEmpty && incoming.isNotEmpty) {
        notes[key] = incoming;
      }
    }

    putNew('chief_complaints', h['chief_complaints']?.toString());
    putNew('hopi', h['history_presenting_illness']?.toString());
    putNew('past_history', h['past_history']?.toString());
    putNew(
      'personal_family_history',
      _joinNonEmpty([
        h['personal_history']?.toString(),
        h['family_history']?.toString(),
      ], ' • '),
    );
    putNew('drug_allergy', h['allergies']?.toString());
    putNew('examination', h['examination_findings']?.toString());
    putNew('diagnosis', h['diagnosis']?.toString());

    final rawVitals = h['vitals'];
    if (rawVitals is Map &&
        (notes['vitals'] == null || (notes['vitals'] as Map).isEmpty)) {
      notes['vitals'] = rawVitals;
    }

    // Investigations: naye section maps se legacy structure banao.
    final legacyInvestigations = _asMap(notes['investigations']);
    final labTests = _asList(inv['lab_tests']);
    if (labTests.isNotEmpty && _asList(legacyInvestigations['blood']).isEmpty) {
      legacyInvestigations['blood'] = labTests;
    }
    final radiology = _asList(inv['radiology']);
    if (radiology.isNotEmpty &&
        _asList(legacyInvestigations['radiology']).isEmpty) {
      legacyInvestigations['radiology'] = radiology;
    }
    final otherInvestigations = _asList(inv['other_investigations']);
    if (otherInvestigations.isNotEmpty &&
        _asText(legacyInvestigations['previous_findings']).isEmpty) {
      legacyInvestigations['previous_findings'] = otherInvestigations.join(', ');
    }
    if (legacyInvestigations.isNotEmpty) {
      notes['investigations'] = legacyInvestigations;
    }

    // Advice: naye keys se legacy advice/follow_up banao.
    putNew('follow_up', adv['follow_up_date']?.toString());
    putNew(
      'advice',
      _joinNonEmpty([
        adv['dietary_advice']?.toString(),
        adv['activity_advice']?.toString(),
        adv['other_advice']?.toString(),
      ], ' • '),
    );

    return notes;
  }

  static String _joinNonEmpty(List<String?> values, String separator) {
    return values
        .map((e) => (e ?? '').trim())
        .where((e) => e.isNotEmpty)
        .join(separator);
  }

  static String _asText(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static List<String> _asList(dynamic value) {
    if (value is List) {
      return value.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }
    final text = _asText(value);
    if (text.isEmpty) return const <String>[];
    return [text];
  }

  static String _vitalsLine(dynamic rawVitals) {
    if (rawVitals is! Map) return '';
    final vitals = Map<String, dynamic>.from(rawVitals);
    final parts = <String>[
      if (_asText(vitals['bp']).isNotEmpty) 'BP: ${vitals['bp']}',
      if (_asText(vitals['pulse']).isNotEmpty) 'Pulse: ${vitals['pulse']} /min',
      if (_asText(vitals['temp']).isNotEmpty) 'Temp: ${vitals['temp']}°F',
      if (_asText(vitals['spo2']).isNotEmpty) 'SpO₂: ${vitals['spo2']}%',
      if (_asText(vitals['weight']).isNotEmpty) 'Weight: ${vitals['weight']} kg',
    ];
    return parts.join('   •   ');
  }

  static String _investigationsLine(dynamic rawInvestigations) {
    if (rawInvestigations is! Map) return '';
    final investigations = Map<String, dynamic>.from(rawInvestigations);

    final lines = <String>[
      if (_asText(investigations['previous_findings']).isNotEmpty)
        'Already done / Main findings: '
            '${investigations['previous_findings']}',
      if (_asList(investigations['blood']).isNotEmpty)
        'Blood / Lab: ${_asList(investigations['blood']).join(', ')}',
      if (_asList(investigations['radiology']).isNotEmpty)
        'Radiology / Imaging: '
            '${_asList(investigations['radiology']).join(', ')}',
    ];
    return lines.join('\n');
  }

  static Future<String> _resolveDoctorName(
    DatabaseService db,
    String? doctorId,
  ) async {
    if (doctorId == null || doctorId.isEmpty) return 'Doctor';
    try {
      final doctor = await db.getById(ApiConstants.doctorsTable, doctorId);
      final doctorName = doctor?['name']?.toString();
      if (doctorName != null && doctorName.isNotEmpty) return doctorName;

      final user = await db.getById(ApiConstants.usersTable, doctorId);
      if (user != null) {
        final name = [
          user['first_name'],
          user['last_name'],
        ].where((n) => n != null && n.toString().isNotEmpty).join(' ').trim();
        if (name.isNotEmpty) return 'Dr. $name';
      }
    } catch (_) {
      // Doctor name optional hai; prescription baaki data ke saath print hogi.
    }
    return 'Doctor';
  }

  // ---------------------------------------------------------------------------
  // Medicine table rows
  // ---------------------------------------------------------------------------

  static List<List<String>> _buildTableRows(
    List<Map<String, dynamic>> medicines,
  ) {
    return [
      for (var i = 0; i < medicines.length; i++)
        _buildTableRow(i + 1, medicines[i]),
    ];
  }

  static List<String> _buildTableRow(int index, Map<String, dynamic> med) {
    final customTimes = ((med['custom_times'] as List?) ?? const [])
        .cast<String>();
    final frequency = med['frequency']?.toString() ?? '-';
    final timing = customTimes.isNotEmpty
        ? customTimes.join(', ')
        : _standardTiming(frequency);

    return [
      '$index',
      med['medicine_name']?.toString() ?? '-',
      med['dosage']?.toString() ?? '-',
      frequency,
      med['route']?.toString().trim().isNotEmpty == true
          ? med['route'].toString()
          : '-',
      timing,
      med['duration']?.toString() ?? '-',
      med['instructions']?.toString() ?? '-',
    ];
  }

  static String _standardTiming(String frequency) {
    switch (frequency.toLowerCase()) {
      case 'od':
        return 'Once a day';
      case 'bd':
        return 'Twice a day';
      case 'tds':
        return 'Three times a day';
      case 'qid':
        return 'Four times a day';
      case 'hs':
        return 'At bedtime';
      case 'bbf':
        return 'Before breakfast';
      case 'ac':
        return 'Before meals';
      case 'pc':
        return 'After meals';
      case 'sos':
        return 'As needed';
      case 'stat':
        return 'Immediately';
      case 'custom':
        return 'As advised';
      default:
        return '-';
    }
  }
}
