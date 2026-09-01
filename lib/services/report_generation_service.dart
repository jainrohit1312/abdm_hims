import 'package:intl/intl.dart';
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

  static final NumberFormat _inr = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );

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
      case 'ipd':
        return _buildIPDReport(hospitalId, from, to);
      case 'diagnostic':
        return _buildDiagnosticReport(hospitalId, from, to);
      case 'voucher':
        return _buildVoucherReport(hospitalId, from, to);
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
          'Payment Status': _paymentStatusLabel(row['payment_status']),
          'Amount': _money(_toDouble(row['consultation_fee'])),
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'GRAND TOTAL',
        labelColumn: 'Patient',
        totals: {'Amount': fee},
      ),
    );

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Patient report (no financial amount exists — do not invent one)
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
          'Amount': '—',
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // IPD report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildIPDReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getIPDReportRowsForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    var admitted = 0;
    var discharged = 0;
    var totalAmount = 0.0;
    var losSum = 0;
    var losCount = 0;
    final wardCount = <String, int>{};
    final departmentCount = <String, int>{};
    final doctorCount = <String, int>{};

    for (final row in rows) {
      final status = (row['status']?.toString() ?? '').toLowerCase().trim();
      if (status == 'admitted') {
        admitted++;
      } else if (status == 'discharged') {
        discharged++;
      }

      totalAmount += _toDouble(row['ipd_amount']);
      final los = _lengthOfStay(row);
      if (los != null) {
        losSum += los;
        losCount++;
      }
      _increment(wardCount, _wardName(row));
      _increment(departmentCount, _departmentName(row));
      _increment(doctorCount, _doctorName(row));
    }

    final summary = <String, dynamic>{
      'Total IPD Admissions': rows.length,
      'Currently Admitted': admitted,
      'Discharged': discharged,
      if (losCount > 0)
        'Average Length of Stay (days)': (losSum / losCount).round(),
      'Total IPD Amount': _money(totalAmount),
    };
    _addTopEntries(summary, wardCount, limit: 3);
    _addTopEntries(summary, departmentCount, limit: 3);
    _addTopEntries(summary, doctorCount, limit: 3);

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Admission Date': _dateCell(row['admission_date']),
          'UHID': _patientUhid(row),
          'Patient': _patientName(row),
          'Doctor': _doctorName(row),
          'Department': _departmentName(row),
          'Ward': _wardName(row),
          'Bed': _bedNumber(row),
          'Status': _ipdStatusLabel(row['status']),
          'Amount': _money(_toDouble(row['ipd_amount'])),
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'GRAND TOTAL',
        labelColumn: 'Patient',
        totals: {'Amount': totalAmount},
      ),
    );

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Diagnostic report — one row per diagnostic order
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildDiagnosticReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final orders = await _db.getDiagnosticOrdersForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    var completedOrders = 0;
    var pendingOrders = 0;
    var totalTests = 0;
    var totalAmount = 0.0;
    final testCount = <String, int>{};
    final doctorCount = <String, int>{};
    final doctorIds = <String>{};

    for (final order in orders) {
      final status = (order['status']?.toString() ?? '')
          .toLowerCase()
          .trim();
      if (status == 'completed') {
        completedOrders++;
      } else if (status == 'pending' || status == 'in_progress') {
        pendingOrders++;
      }

      final items = _orderItems(order);
      totalTests += items.length;
      totalAmount += _toDouble(order['total_amount']);
      for (final item in items) {
        _increment(testCount, item['test_name']?.toString() ?? 'Unknown Test');
      }

      final doctorId = order['doctor_id']?.toString();
      if (doctorId != null && doctorId.isNotEmpty) {
        doctorIds.add(doctorId);
      }
    }

    final usersById = await _db.getUsersByIds(doctorIds);
    for (final order in orders) {
      final doctorId = order['doctor_id']?.toString();
      final doctor = _userName(usersById[doctorId]);
      _increment(doctorCount, doctor.isEmpty ? doctorId ?? 'Unknown' : doctor);
    }

    // Lab/diagnostic bills are the only paid/outstanding source for
    // diagnostics. They are aggregated separately (not per order) because the
    // schema does not link a diagnostic billing row back to its order id.
    var totalPaid = 0.0;
    var totalOutstanding = 0.0;
    final bills = await _db.getBillingForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );
    for (final bill in bills) {
      if (_billingSourceType(bill) != 'lab') continue;
      totalPaid += _toDouble(bill['paid_amount']);
      totalOutstanding += _toDouble(bill['balance_amount']);
    }

    final summary = <String, dynamic>{
      'Total Orders': orders.length,
      'Total Tests': totalTests,
      'Completed Orders': completedOrders,
      'Pending Orders': pendingOrders,
      'Total Diagnostic Amount': _money(totalAmount),
      'Total Paid': _money(totalPaid),
      'Total Outstanding': _money(totalOutstanding),
    };
    _addTopEntries(summary, testCount, limit: 3);
    _addTopEntries(summary, doctorCount, limit: 3);

    final data = <Map<String, dynamic>>[
      for (final order in orders)
        {
          'Order Date': _dateCell(order['order_date']),
          'UHID': _patientUhid(order),
          'Patient': _patientName(order),
          'Doctor': _userName(usersById[order['doctor_id']?.toString()]),
          'Test / Order': _testSummary(order),
          'Status': _diagnosticStatusLabel(order['status']),
          'Amount': _money(_toDouble(order['total_amount'])),
          'Paid': '—',
          'Balance': '—',
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'TOTAL',
        labelColumn: 'Patient',
        totals: {
          'Amount': totalAmount,
          'Paid': totalPaid,
          'Balance': totalOutstanding,
        },
      ),
    );

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Voucher report
  // ---------------------------------------------------------------------------

  Future<GeneratedReportData> _buildVoucherReport(
    String hospitalId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = await _db.getVouchersForRange(
      hospitalId: hospitalId,
      from: from,
      to: to,
    );

    var totalAmount = 0.0;
    final typeCount = <String, int>{};
    final categoryAmount = <String, double>{};
    final modeAmount = <String, double>{};
    final createdByIds = <String>{};

    for (final row in rows) {
      final amount = _toDouble(row['amount']);
      totalAmount += amount;

      final type = row['voucher_type']?.toString() ?? 'Expense';
      _increment(typeCount, type);

      final category = row['expense_category']?.toString() ?? '';
      _addAmount(categoryAmount, category, amount);

      final mode = row['payment_mode']?.toString() ?? '';
      _addAmount(modeAmount, mode, amount);

      final createdBy = row['created_by']?.toString();
      if (createdBy != null && createdBy.isNotEmpty) {
        createdByIds.add(createdBy);
      }
    }

    final usersById = await _db.getUsersByIds(createdByIds);

    final summary = <String, dynamic>{
      'Total Vouchers': rows.length,
      'Total Voucher Amount': _money(totalAmount),
    };
    for (final type in ['Expense', 'Payment', 'Adjustment']) {
      if (typeCount[type] != null) {
        summary['$type Vouchers'] = typeCount[type]!;
      }
    }
    _addTopAmountEntries(summary, categoryAmount, limit: 3);
    _addTopAmountEntries(summary, modeAmount, limit: 3);

    final data = <Map<String, dynamic>>[
      for (final row in rows)
        {
          'Date': _dateCell(row['voucher_date']),
          'Voucher No': row['voucher_number']?.toString() ?? '',
          'Type': _voucherTypeLabel(row['voucher_type']),
          'Category': row['expense_category']?.toString() ?? '',
          'Payee': row['payee_name']?.toString() ?? '',
          'Description': row['description']?.toString() ?? '',
          'Payment Mode': row['payment_mode']?.toString() ?? '',
          'Amount': _money(_toDouble(row['amount'])),
          'Created By': _userName(usersById[row['created_by']?.toString()]),
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'GRAND TOTAL',
        labelColumn: 'Payee',
        totals: {'Amount': totalAmount},
      ),
    );

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
      'Total Consultation Amount': _money(totalFees),
    };

    final data = <Map<String, dynamic>>[
      for (final doctor in doctors)
        {
          'Doctor': doctor.name,
          'Consultations': doctor.consultations,
          'Completed': doctor.completed,
          'Pending': doctor.pending,
          'Amount': _money(doctor.fees),
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'GRAND TOTAL',
        labelColumn: 'Doctor',
        totals: {'Amount': totalFees},
      ),
    );

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
          'Type': _billingSourceLabel(_billingSourceType(row)),
          'Amount': _money(_toDouble(row['net_amount'])),
          'Paid': _money(_toDouble(row['paid_amount'])),
          'Outstanding': _money(_toDouble(row['balance_amount'])),
          'Status': _paymentStatusLabel(row['payment_status']),
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'GRAND TOTAL',
        labelColumn: 'Patient',
        totals: {
          'Amount': totalRevenue,
          'Paid': paid,
          'Outstanding': outstanding,
        },
      ),
    );

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Counseling report (no counseling fee column exists — do not invent one)
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
          'Amount': '—',
        },
    ];

    return GeneratedReportData(data: data, summary: summary);
  }

  // ---------------------------------------------------------------------------
  // Follow-up report (follow_up_date rows carry their OPD consultation fee)
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
    var totalAmount = 0.0;
    for (final row in rows) {
      final status = _normalizeStatus(row['status']);
      if (status == 'completed') {
        completed++;
      } else if (status != 'cancelled') {
        pending++;
      }
      totalAmount += _toDouble(row['consultation_fee']);
    }

    final summary = <String, dynamic>{
      'Total Follow-ups': rows.length,
      'Pending': pending,
      'Completed': completed,
      'Total Follow-up Amount': _money(totalAmount),
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
          'Amount': _money(_toDouble(row['consultation_fee'])),
        },
    ];
    data.add(
      _makeTotalRow(
        data,
        label: 'GRAND TOTAL',
        labelColumn: 'Patient',
        totals: {'Amount': totalAmount},
      ),
    );

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
      case 'ipd':
        return 'IPD Report';
      case 'diagnostic':
        return 'Diagnostics Report';
      case 'voucher':
        return 'Voucher Report';
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

  static String _money(double value) => _inr.format(value);

  static String _dateCell(dynamic value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return '';
    final date = DateTime.tryParse(text);
    if (date == null) return text;
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day/$month/${date.year}';
  }

  /// Builds a footer row marked with `__total_row__` so `_TableData.from`
  /// always renders it after the detail rows and styles it bold.
  static Map<String, dynamic> _makeTotalRow(
    List<Map<String, dynamic>> rows, {
    required String label,
    required Map<String, double> totals,
    String? labelColumn,
  }) {
    final row = <String, dynamic>{'__total_row__': true};
    if (rows.isEmpty) return row;

    final keys = rows.first.keys
        .where((key) => !key.startsWith('__'))
        .toList();
    for (final key in keys) {
      row[key] = '';
    }

    final target = labelColumn != null && keys.contains(labelColumn)
        ? labelColumn
        : (keys.isNotEmpty ? keys.first : null);
    if (target != null) row[target] = label;

    for (final entry in totals.entries) {
      if (row.containsKey(entry.key)) {
        row[entry.key] = _money(entry.value);
      }
    }
    return row;
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

  static String _wardName(Map<String, dynamic> row) {
    final direct = row['ward_type']?.toString();
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();

    final bed = row['beds'];
    if (bed is Map) {
      final bedWard = bed['ward_type']?.toString();
      if (bedWard != null && bedWard.trim().isNotEmpty) return bedWard.trim();
      final wardName = bed['ward_name']?.toString();
      if (wardName != null && wardName.trim().isNotEmpty) {
        return wardName.trim();
      }
    }
    return row['ward_name']?.toString() ?? '';
  }

  static String _bedNumber(Map<String, dynamic> row) {
    final bed = row['beds'];
    if (bed is Map) {
      final bedNumber = bed['bed_number']?.toString();
      if (bedNumber != null && bedNumber.trim().isNotEmpty) {
        return bedNumber.trim();
      }
    }
    return row['bed_id']?.toString() ?? '';
  }

  static int? _lengthOfStay(Map<String, dynamic> row) {
    final admissionDate = DateTime.tryParse(
      row['admission_date']?.toString() ?? '',
    );
    if (admissionDate == null) return null;
    final dischargeDate = DateTime.tryParse(
      row['discharge_date']?.toString() ?? '',
    );
    final end = dischargeDate ?? DateTime.now();
    final days = end.difference(admissionDate).inDays;
    return days < 0 ? null : days;
  }

  static List<Map<String, dynamic>> _orderItems(Map<String, dynamic> order) {
    final items = order['diagnostic_order_items'];
    if (items is List) {
      return items.whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }

  static String _testSummary(Map<String, dynamic> order) {
    final items = _orderItems(order);
    if (items.isEmpty) return '';
    final first = items.first['test_name']?.toString() ?? 'Test';
    if (items.length == 1) return first;
    return '$first +${items.length - 1}';
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

  static void _addAmount(Map<String, double> amounts, String key, double value) {
    final resolved = key.trim().isEmpty ? 'Unknown' : key;
    amounts[resolved] = (amounts[resolved] ?? 0) + value;
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

  static void _addTopAmountEntries(
    Map<String, dynamic> summary,
    Map<String, double> amounts, {
    required int limit,
  }) {
    final entries = amounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in entries.take(limit)) {
      final key = entry.key.isEmpty ? 'Unknown' : entry.key;
      if (summary.containsKey(key)) continue;
      summary[key] = _money(entry.value);
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

  static String _ipdStatusLabel(dynamic status) {
    switch ((status?.toString() ?? '').toLowerCase().trim()) {
      case 'admitted':
        return 'Admitted';
      case 'discharged':
        return 'Discharged';
      case 'transferred':
        return 'Transferred';
      default:
        return status?.toString() ?? '';
    }
  }

  static String _diagnosticStatusLabel(dynamic status) {
    switch ((status?.toString() ?? '').toLowerCase().trim()) {
      case 'pending':
        return 'Pending';
      case 'in_progress':
      case 'in-progress':
        return 'In Progress';
      case 'completed':
        return 'Completed';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status?.toString() ?? '';
    }
  }

  static String _voucherTypeLabel(dynamic type) {
    switch ((type?.toString() ?? '').toLowerCase().trim()) {
      case 'expense':
        return 'Expense';
      case 'payment':
        return 'Payment';
      case 'adjustment':
        return 'Adjustment';
      default:
        return type?.toString() ?? '';
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
    'ipd',
    'diagnostic',
    'voucher',
    'counseling',
    'doctor_performance',
    'revenue',
    'followup',
  ];
}
