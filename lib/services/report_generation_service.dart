import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import 'database_service.dart';

/// Raised when a report could not be generated. The message is user-facing.
class ReportGenerationException implements Exception {
  const ReportGenerationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The deterministic output of a report generation run.
class GeneratedReportData {
  const GeneratedReportData({required this.data, required this.summary});

  /// Detailed rows stored in `reports.data` (a list of maps — exactly the
  /// structure `_TableData.from` and `ReportVisuals.summaryEntries` expect).
  final List<Map<String, dynamic>> data;

  /// Flat key/value summary stored in `reports.summary`.
  final Map<String, dynamic> summary;
}

/// Generates analytics reports from real, tenant-scoped database records.
///
/// The workflow mirrors the `reports` table contract used by the existing
/// Reports UI:
///   1. insert a row with `status = generating`
///   2. calculate deterministic report data (all totals computed in code)
///   3. update the row to `status = ready` (or `status = failed` on error)
///
/// No fake/demo data is ever produced and every query is scoped by the
/// hospital id supplied by the caller.
class ReportGenerationService {
  ReportGenerationService(this._db);

  final DatabaseService _db;

  static const String followUpUnavailableMessage =
      'Follow-up reporting is not available because no follow-up data source '
      'is configured.';

  Future<Map<String, dynamic>> generateReport({
    required String hospitalId,
    required String reportType,
    required DateTime from,
    required DateTime to,
  }) async {
    final type = reportType.trim().toLowerCase();
    if (!ReportTypeKeys.all.contains(type)) {
      throw ReportGenerationException('Unsupported report type: $reportType');
    }
    if (from.isAfter(to)) {
      throw ReportGenerationException('From date must be before To date.');
    }

    String? generatedBy;
    try {
      // `generated_by` references public.users(id), so use the public record
      // id rather than the Supabase auth UUID.
      final userRecord = await _db.getCurrentUserRecord();
      generatedBy = userRecord?['id']?.toString();
    } catch (e) {
      AppLogger.w('Could not resolve generated_by user: $e');
    }

    final created = await _db.create(
      ApiConstants.reportsTable,
      {
        'report_type': type,
        'title': titleForType(type),
        'date_from': _dateOnly(from),
        'date_to': _dateOnly(to),
        'filters': {'from': _dateOnly(from), 'to': _dateOnly(to)},
        'generated_by': generatedBy,
        'data': const <Map<String, dynamic>>[],
        'summary': const <String, dynamic>{},
        'file_format': 'pdf',
        'status': 'generating',
      },
      hospitalId: hospitalId,
    );

    final reportId = created['id']?.toString();
    if (reportId == null || reportId.isEmpty) {
      throw ReportGenerationException('Report record could not be created.');
    }

    try {
      final result = await _buildReport(type, hospitalId, from, to);
      return await _db.update(
        ApiConstants.reportsTable,
        reportId,
        {
          'status': 'ready',
          'data': result.data,
          'summary': result.summary,
        },
        hospitalId: hospitalId,
      );
    } catch (e) {
      AppLogger.e('Report generation failed for $type', e);
      final message = _failureMessage(type, e);
      try {
        await _db.update(
          ApiConstants.reportsTable,
          reportId,
          {
            'status': 'failed',
            'data': const <Map<String, dynamic>>[],
            'summary': {'Error': message},
          },
          hospitalId: hospitalId,
        );
      } catch (updateError) {
        AppLogger.e('Could not mark failed report', updateError);
      }
      throw ReportGenerationException(message);
    }
  }

  Future<GeneratedReportData> _buildReport(
    String type,
    String hospitalId,
    DateTime from,
    DateTime to,
  ) {
    switch (type) {
      case 'consultation':
        return _buildConsultationReport(hospitalId, from, to);
      case 'patient':
        return _buildPatientReport(hospitalId, from, to);
      case 'counseling':
        return _buildCounselingReport(hospitalId, from, to);
      case 'doctor_performance':
        return _buildDoctorPerformanceReport(hospitalId, from, to);
      case 'revenue':
        return _buildRevenueReport(hospitalId, from, to);
      case 'followup':
        return _buildFollowUpReport(hospitalId, from, to);
      default:
        throw ReportGenerationException('Unsupported report type: $type');
    }
  }

  // ---------------------------------------------------------------------------
  // Consultation report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildConsultationReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getOPDRegistrationsForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    var completed = 0;
    var pending = 0;
    var fee = 0.0;
    final departmentCount = <String, int>{};
    final doctorCount = <String, int>{};

    for (final row in rows) {
      final status = _normalizeStatus(row['status']);
      if (status == 'completed') {
        completed++;
      } else if (status == 'cancelled') {
        // Cancelled visits are counted in the total but not as pending work.
      } else {
        pending++;
      }

      fee += _toDouble(row['consultation_fee']);
      _increment(departmentCount, _departmentName(row));
      _increment(doctorCount, _doctorName(row));
    }

    final summary = <String, dynamic>{
      'Total Consultations': rows.length,
      'Completed': completed,
      'Pending': pending,
      'Total Consultation Fee': _money(fee),
    };
    _addTopEntries(summary, departmentCount, limit: 3);
    _addTopEntries(summary, doctorCount, limit: 3);

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Date': _dateCell(row['visit_date']),
          'UHID': _patientUhid(row),
          'Patient': _patientName(row),
          'Doctor': _doctorName(row),
          'Department': _departmentName(row),
          'Type': _consultationTypeLabel(row['consultation_type']),
          'Status': _statusLabel(row['status']),
          'Fee': _money(_toDouble(row['consultation_fee'])),
          'Payment': _paymentStatusLabel(row['payment_status']),
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Patient report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildPatientReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getPatientsForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    var male = 0;
    var female = 0;
    var other = 0;
    var child = 0; // 0-18
    var young = 0; // 19-35
    var middle = 0; // 36-60
    var senior = 0; // 60+

    for (final row in rows) {
      final gender = (row['gender']?.toString() ?? '').toLowerCase().trim();
      switch (gender) {
        case 'male':
          male++;
          break;
        case 'female':
          female++;
          break;
        default:
          other++;
          break;
      }

      final age = _toInt(row['age']);
      if (age > 0 && age <= 18) {
        child++;
      } else if (age > 18 && age <= 35) {
        young++;
      } else if (age > 35 && age <= 60) {
        middle++;
      } else if (age > 60) {
        senior++;
      }
    }

    // When age is unavailable, keep the age buckets out of the summary so
    // the numbers are never misleading.
    final summary = <String, dynamic>{
      'Total Patients': rows.length,
      'Male': male,
      'Female': female,
      'Other': other,
    };
    final hasAnyAge = rows.any((row) => _toInt(row['age']) > 0);
    if (hasAnyAge) {
      summary.addAll({
        'Age 0-18': child,
        'Age 19-35': young,
        'Age 36-60': middle,
        'Age 60+': senior,
      });
    }

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Registration Date': _dateCell(
            row['registration_date'] ?? row['created_at'],
          ),
          'UHID': row['uhid']?.toString() ?? '',
          'Patient': _patientNameFromFields(row),
          'Age': row['age']?.toString() ?? '',
          'Gender': row['gender']?.toString() ?? '',
          'Mobile': row['mobile_number']?.toString() ?? '',
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Doctor performance report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildDoctorPerformanceReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getOPDRegistrationsForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    final doctorAgg = <String, _DoctorAggregate>{};
    for (final row in rows) {
      final rawDoctor = _doctorName(row);
      final doctor = rawDoctor.trim().isEmpty ? 'Unknown' : rawDoctor;
      final agg = doctorAgg.putIfAbsent(doctor, () => _DoctorAggregate(doctor));
      agg.consultations++;
      final status = _normalizeStatus(row['status']);
      if (status == 'completed') {
        agg.completed++;
      } else if (status != 'cancelled') {
        agg.pending++;
      }
      agg.fees += _toDouble(row['consultation_fee']);
    }

    final doctors = doctorAgg.values.toList()
      ..sort((a, b) => b.consultations.compareTo(a.consultations));

    var completed = 0;
    var pending = 0;
    var totalFees = 0.0;
    for (final doctor in doctors) {
      completed += doctor.completed;
      pending += doctor.pending;
      totalFees += doctor.fees;
    }

    final summary = <String, dynamic>{
      'Doctors': doctors.length,
      'Total Consultations': rows.length,
      'Completed': completed,
      'Pending': pending,
      'Total Consultation Fees': _money(totalFees),
    };

    final data = <Map<String, dynamic>>[
      for (final doctor in doctors)
        {
          'Doctor': doctor.name,
          'Consultations': doctor.consultations,
          'Completed': doctor.completed,
          'Pending': doctor.pending,
          'Fees': _money(doctor.fees),
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Revenue report (billing table only — no double counting)
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildRevenueReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getBillingForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    var totalRevenue = 0.0;
    var opdRevenue = 0.0;
    var ipdRevenue = 0.0;
    var diagnosticRevenue = 0.0;
    var paid = 0.0;
    var outstanding = 0.0;

    for (final row in rows) {
      final net = _toDouble(row['net_amount']);
      final source = _billingSourceType(row);
      totalRevenue += net;
      switch (source) {
        case 'opd':
          opdRevenue += net;
          break;
        case 'ipd':
          ipdRevenue += net;
          break;
        case 'lab':
          diagnosticRevenue += net;
          break;
      }
      paid += _toDouble(row['paid_amount']);
      outstanding += _toDouble(row['balance_amount']);
    }

    final summary = <String, dynamic>{
      'Total Revenue': _money(totalRevenue),
      'OPD Revenue': _money(opdRevenue),
      'IPD Revenue': _money(ipdRevenue),
      'Diagnostic Revenue': _money(diagnosticRevenue),
      'Paid': _money(paid),
      'Outstanding': _money(outstanding),
    };

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Date': _dateCell(row['bill_date']),
          'Bill No': row['bill_number']?.toString() ?? '',
          'Patient': _patientName(row),
          'Source': _billingSourceLabel(_billingSourceType(row)),
          'Total': _money(_toDouble(row['total_amount'])),
          'Net': _money(_toDouble(row['net_amount'])),
          'Paid': _money(_toDouble(row['paid_amount'])),
          'Balance': _money(_toDouble(row['balance_amount'])),
          'Status': _paymentStatusLabel(row['payment_status']),
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Counseling report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildCounselingReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getCounselingRecordsForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    // counseling_records has no status column — a saved record is a completed
    // (documented) session. `completed` is therefore the same as the total;
    // it is kept as an explicit metric because the Reports UI displays it.
    final patientIds = <String>{};
    var opdSessions = 0;
    var ipdSessions = 0;
    var totalDurationSeconds = 0;
    final doctorIds = <String>{};

    for (final row in rows) {
      final patientId = row['patient_id']?.toString();
      if (patientId != null && patientId.isNotEmpty) patientIds.add(patientId);

      final visitType = (row['visit_type']?.toString() ?? 'opd').toLowerCase();
      if (visitType == 'ipd') {
        ipdSessions++;
      } else {
        opdSessions++;
      }

      totalDurationSeconds += _toInt(row['duration_seconds']);
      final doctorId = row['doctor_id']?.toString();
      if (doctorId != null && doctorId.isNotEmpty) doctorIds.add(doctorId);
    }

    final usersById = await _db.getUsersByIds(doctorIds);

    final summary = <String, dynamic>{
      'Total Sessions': rows.length,
      'Completed Sessions': rows.length,
      'Patients': patientIds.length,
      'OPD Sessions': opdSessions,
      'IPD Sessions': ipdSessions,
      'Total Duration (min)': (totalDurationSeconds / 60).round(),
    };

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Session Date': _dateCell(row['counseling_date']),
          'UHID': _patientUhid(row),
          'Patient': _patientName(row),
          'Visit Type': (row['visit_type']?.toString() ?? 'opd').toUpperCase(),
          'Counselor': _userName(usersById[row['doctor_id']?.toString()]),
          'Duration (min)': ((_toInt(row['duration_seconds'])) / 60)
              .round()
              .toString(),
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Follow-up report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildFollowUpReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await _db.getFollowUpRowsForRange(
        hospitalId: hospitalId,
        from: from,
        to: to,
      );
    } on PostgrestException catch (e) {
      final message = e.message.toLowerCase();
      if (message.contains('column') || message.contains('does not exist')) {
        throw const ReportGenerationException(followUpUnavailableMessage);
      }
      rethrow;
    }

    var pending = 0;
    var completed = 0;
    for (final row in rows) {
      final status = _normalizeStatus(row['status']);
      if (status == 'completed') {
        completed++;
      } else if (status != 'cancelled') {
        pending++;
      }
    }

    final summary = <String, dynamic>{
      'Total Follow-ups': rows.length,
      'Pending': pending,
      'Completed': completed,
    };

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Follow-up Date': _dateCell(row['follow_up_date']),
          'UHID': _patientUhid(row),
          'Patient': _patientName(row),
          'Doctor': _doctorName(row),
          'Department': _departmentName(row),
          'Status': _statusLabel(row['status']),
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String titleForType(String type) {
    switch (type) {
      case 'consultation':
        return 'Consultation Report';
      case 'patient':
        return 'Patient Report';
      case 'counseling':
        return 'Counseling Report';
      case 'doctor_performance':
        return 'Doctor Performance Report';
      case 'revenue':
        return 'Revenue Report';
      case 'followup':
        return 'Follow-up Report';
      default:
        return 'Report';
    }
  }

  String _failureMessage(String type, Object error) {
    if (error is ReportGenerationException) return error.message;
    final raw = error.toString().toLowerCase();
    if (raw.contains('column') || raw.contains('does not exist')) {
      return 'This report type could not be generated because a required '
          'database field is not available.';
    }
    return 'Report generation failed. Please try again.';
  }

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static double _toDouble(dynamic value) =>
      value == null ? 0 : double.tryParse(value.toString()) ?? 0;

  static int _toInt(dynamic value) {
    if (value == null) return 0;
    return int.tryParse(value.toString()) ?? 0;
  }

  static String _money(double value) => value.toStringAsFixed(2);

  static String _dateCell(dynamic value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return '';
    final date = DateTime.tryParse(text);
    if (date == null) return text;
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day/$month/${date.year}';
  }

  static String _patientName(Map<String, dynamic> row) {
    final patient = row['patients'];
    if (patient is Map) {
      final first = patient['first_name']?.toString() ?? '';
      final last = patient['last_name']?.toString() ?? '';
      final name = '$first $last'.trim();
      if (name.isNotEmpty) return name;
    }
    return _patientNameFromFields(row);
  }

  static String _patientNameFromFields(Map<String, dynamic> row) {
    final first = row['first_name']?.toString() ?? '';
    final last = row['last_name']?.toString() ?? '';
    final name = '$first $last'.trim();
    if (name.isNotEmpty) return name;
    return row['patient_name']?.toString() ?? '';
  }

  static String _patientUhid(Map<String, dynamic> row) {
    final patient = row['patients'];
    if (patient is Map) {
      final uhid = patient['uhid']?.toString();
      if (uhid != null && uhid.isNotEmpty) return uhid;
    }
    return row['uhid']?.toString() ?? '';
  }

  static String _doctorName(Map<String, dynamic> row) {
    final name = row['doctor_name']?.toString();
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return row['doctor_id']?.toString() ?? '';
  }

  static String _departmentName(Map<String, dynamic> row) {
    final name = row['department_name']?.toString();
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return row['department_id']?.toString() ?? '';
  }

  static String _userName(Map<String, dynamic>? user) {
    if (user == null) return '';
    final first = user['first_name']?.toString() ?? '';
    final last = user['last_name']?.toString() ?? '';
    final name = '$first $last'.trim();
    if (name.isNotEmpty) return name;
    return user['designation']?.toString() ?? '';
  }

  static void _increment(Map<String, int> counts, String key) {
    final resolved = key.trim().isEmpty ? 'Unknown' : key;
    counts[resolved] = (counts[resolved] ?? 0) + 1;
  }

  static void _addTopEntries(
    Map<String, dynamic> summary,
    Map<String, int> counts, {
    required int limit,
  }) {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in entries.take(limit)) {
      final key = entry.key.isEmpty ? 'Unknown' : entry.key;
      if (summary.containsKey(key)) continue;
      summary[key] = entry.value;
    }
  }

  static String _normalizeStatus(dynamic status) {
    switch ((status?.toString() ?? '').toLowerCase().trim()) {
      case 'completed':
        return 'completed';
      case 'waiting':
      case 'in_consultation':
      case 'in-progress':
      case 'pending':
        return 'pending';
      case 'cancelled':
        return 'cancelled';
      case 'no_show':
      case 'no-show':
        return 'no_show';
      default:
        return 'unknown';
    }
  }

  static String _statusLabel(dynamic status) {
    switch (_normalizeStatus(status)) {
      case 'completed':
        return 'Completed';
      case 'pending':
        return 'Pending';
      case 'cancelled':
        return 'Cancelled';
      case 'no_show':
        return 'No Show';
      default:
        return 'Unknown';
    }
  }

  static String _consultationTypeLabel(dynamic type) {
    switch ((type?.toString() ?? '').toLowerCase().trim()) {
      case 'emergency':
        return 'Emergency';
      case 'follow_up':
      case 'followup':
        return 'Follow-up';
      case 'referral':
        return 'Referral';
      case 'general':
        return 'General';
      default:
        return type?.toString() ?? '';
    }
  }

  static String _paymentStatusLabel(dynamic status) {
    switch ((status?.toString() ?? '').toLowerCase().trim()) {
      case 'paid':
        return 'Paid';
      case 'partially_paid':
      case 'partial':
        return 'Partially Paid';
      case 'unpaid':
        return 'Unpaid';
      case 'refunded':
        return 'Refunded';
      case 'waived':
        return 'Waived';
      default:
        return status?.toString() ?? '';
    }
  }

  static String _billingSourceType(Map<String, dynamic> row) {
    final source = (row['source_type']?.toString() ?? '').toLowerCase().trim();
    if (source == 'opd' || source == 'ipd' || source == 'lab') return source;

    // Fallbacks for rows created before source_type was backfilled.
    if (row['opd_registration_id'] != null) return 'opd';
    if (row['ipd_admission_id'] != null) return 'ipd';
    final visitType = (row['visit_type']?.toString() ?? '')
        .toLowerCase()
        .trim();
    if (visitType == 'lab') return 'lab';
    return source.isEmpty ? 'manual' : source;
  }

  static String _billingSourceLabel(String source) {
    switch (source) {
      case 'opd':
        return 'OPD';
      case 'ipd':
        return 'IPD';
      case 'lab':
        return 'Diagnostic';
      case 'pharmacy':
        return 'Pharmacy';
      case 'manual':
        return 'Manual';
      default:
        return source.isEmpty ? 'Other' : source;
    }
  }
}

class _DoctorAggregate {
  _DoctorAggregate(this.name);

  final String name;
  int consultations = 0;
  int completed = 0;
  int pending = 0;
  double fees = 0;
}

/// Keeps the report type list local to this service without importing UI
/// widgets. The values are the exact `report_type` keys used by the existing
/// reports table constraint, `ReportFilterBar` and `ReportVisuals`.
class ReportTypeKeys {
  ReportTypeKeys._();

  static const List<String> all = [
    'consultation',
    'patient',
    'counseling',
    'doctor_performance',
    'revenue',
    'followup',
  ];
}
