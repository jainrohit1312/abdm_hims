import '../models/attendance_punch_model.dart';
import '../models/employee_attendance_summary.dart';
import '../models/employee_model.dart';

/// ---------------------------------------------------------------------------
/// AttendanceRules — the configurable thresholds for the attendance domain.
///
/// Kept in ONE place (not scattered across widgets) so the half-day / full-day
/// policy can be tuned without touching UI code.
///
/// Current default policy:
///   * >= 8h completed work  -> full-day hours (documented reference)
///   * >= 4h completed work  -> Present (full unit)
///   * > 0h and < 4h         -> Half Day (0.5 unit)
///   * no valid punch        -> Absent
///   * open IN (still on duty, no OUT yet) -> Present, 0 completed minutes
/// ---------------------------------------------------------------------------
class AttendanceRules {
  static const Duration defaultHalfDayThreshold = Duration(hours: 4);
  static const Duration defaultFullDayThreshold = Duration(hours: 8);

  const AttendanceRules({
    this.halfDayThreshold = defaultHalfDayThreshold,
    this.fullDayThreshold = defaultFullDayThreshold,
  });

  final Duration halfDayThreshold;
  final Duration fullDayThreshold;

  int get halfDayThresholdMinutes => halfDayThreshold.inMinutes;
  int get fullDayThresholdMinutes => fullDayThreshold.inMinutes;
}

/// ---------------------------------------------------------------------------
/// AttendanceCalculator — pure domain logic for daily + monthly attendance.
///
/// Responsibilities:
///   * raw punch events + employee eligibility -> daily summaries
///   * daily summaries aggregated per month -> monthly summaries
///
/// It does NOT:
///   * query Supabase
///   * know about widgets, routes, or face recognition
///   * calculate salary
///
/// Open/Closed: adding a new punch source (biometric device, mobile app) does
/// not change this class — it only sees [AttendancePunch] values.
/// ---------------------------------------------------------------------------
class AttendanceCalculator {
  const AttendanceCalculator({this.rules = const AttendanceRules()});

  final AttendanceRules rules;

  /// Daily summaries for every employee eligible on [date].
  ///
  /// Employees who joined after [date], relieved before [date], or are
  /// inactive are excluded entirely (never marked absent before joining or
  /// after relieving). Employees who are eligible but have no punches are
  /// reported as [AttendanceStatus.absent] — no database absent rows needed.
  List<EmployeeDailyAttendance> dailyAttendanceForDate({
    required DateTime date,
    required List<Employee> employees,
    required List<AttendancePunch> punches,
  }) {
    final dayPunches = <String, List<AttendancePunch>>{};
    for (final punch in punches) {
      if (!_isSameDay(punch.punchedAt, date)) continue;
      dayPunches.putIfAbsent(punch.employeeId, () => []).add(punch);
    }

    final summaries = <EmployeeDailyAttendance>[];
    for (final employee in employees) {
      if (!employee.isEligibleOn(date)) continue;
      summaries.add(
        _summarizeDay(
          employee.id,
          date,
          dayPunches[employee.id] ?? const <AttendancePunch>[],
        ),
      );
    }
    return summaries;
  }

  /// Monthly aggregation for all employees, one entry per employee.
  ///
  /// `eligibleDays` respects joiningDate / relievingDate / isActive per day:
  /// joining mid-month starts the count on the joining day, and relieving
  /// mid-month stops it on the relieving day. Days outside that window are
  /// NOT counted as absent.
  List<EmployeeMonthlyAttendance> monthlyAttendanceFor({
    required int year,
    required int month,
    required List<Employee> employees,
    required List<AttendancePunch> punches,
  }) {
    // Group punches by employee, then by day-of-month — one pass over punches,
    // no N+1 queries and no per-employee punch scans.
    final punchesByEmployeeDay = <String, Map<int, List<AttendancePunch>>>{};
    for (final punch in punches) {
      final local = punch.punchedAt;
      if (local.year != year || local.month != month) continue;
      final dayMap = punchesByEmployeeDay.putIfAbsent(
        punch.employeeId,
        () => <int, List<AttendancePunch>>{},
      );
      dayMap.putIfAbsent(local.day, () => <AttendancePunch>[]).add(punch);
    }

    final daysInMonth = DateTime(year, month + 1, 0).day;
    final summaries = <EmployeeMonthlyAttendance>[];

    for (final employee in employees) {
      final dayMap =
          punchesByEmployeeDay[employee.id] ?? const <int, List<AttendancePunch>>{};

      var eligibleDays = 0;
      var presentDays = 0;
      var halfDays = 0;
      var absentDays = 0;
      var totalWorkingMinutes = 0;

      for (var day = 1; day <= daysInMonth; day++) {
        final date = DateTime(year, month, day);
        if (!employee.isEligibleOn(date)) continue;
        eligibleDays++;

        final summary = _summarizeDay(
          employee.id,
          date,
          dayMap[day] ?? const <AttendancePunch>[],
        );
        switch (summary.status) {
          case AttendanceStatus.present:
            presentDays++;
          case AttendanceStatus.halfDay:
            halfDays++;
          case AttendanceStatus.absent:
            absentDays++;
        }
        totalWorkingMinutes += summary.workingMinutes;
      }

      summaries.add(
        EmployeeMonthlyAttendance(
          employeeId: employee.id,
          year: year,
          month: month,
          eligibleDays: eligibleDays,
          presentDays: presentDays,
          halfDays: halfDays,
          absentDays: absentDays,
          attendanceUnits: presentDays + (halfDays * 0.5),
          totalWorkingMinutes: totalWorkingMinutes,
        ),
      );
    }

    return summaries;
  }

  // ---------------------------------------------------------------------------
  // Punch pairing (deterministic, graceful on malformed sequences)
  // ---------------------------------------------------------------------------
  //
  // Pairs punches as completed IN -> OUT sessions:
  //   09:00 IN, 13:00 OUT, 14:00 IN, 18:00 OUT => 4h + 4h = 8h
  //
  // Malformed sequences:
  //   * OUT without a preceding IN  -> ignored
  //   * two consecutive IN          -> second IN ignored (first stays open)
  //   * two consecutive OUT         -> second OUT ignored (no open session)
  //   * missing final OUT           -> open session; employee is "currently
  //                                    punched in"; only completed sessions
  //                                    contribute working minutes
  EmployeeDailyAttendance _summarizeDay(
    String employeeId,
    DateTime date,
    List<AttendancePunch> punches,
  ) {
    final sorted = [...punches]..sort((a, b) => a.punchedAt.compareTo(b.punchedAt));

    DateTime? firstPunchIn;
    DateTime? lastPunchOut;
    DateTime? openSessionStart;
    var completedMinutes = 0;
    var hasValidIn = false;

    for (final punch in sorted) {
      if (punch.isPunchIn) {
        hasValidIn = true;
        firstPunchIn ??= punch.punchedAt;
        // Ignore a redundant IN while a session is already open.
        openSessionStart ??= punch.punchedAt;
      } else {
        // OUT: only meaningful when a session is open.
        final sessionStart = openSessionStart;
        if (sessionStart == null) continue;
        lastPunchOut = punch.punchedAt;
        final minutes = punch.punchedAt.difference(sessionStart).inMinutes;
        if (minutes > 0) completedMinutes += minutes;
        openSessionStart = null;
      }
    }

    final isCurrentlyPunchedIn = openSessionStart != null;
    final status = _statusFor(
      hasValidIn: hasValidIn,
      completedMinutes: completedMinutes,
      isCurrentlyPunchedIn: isCurrentlyPunchedIn,
    );

    return EmployeeDailyAttendance(
      employeeId: employeeId,
      date: DateTime(date.year, date.month, date.day),
      status: status,
      firstPunchIn: firstPunchIn,
      lastPunchOut: lastPunchOut,
      workingMinutes: completedMinutes,
      isCurrentlyPunchedIn: isCurrentlyPunchedIn,
    );
  }

  AttendanceStatus _statusFor({
    required bool hasValidIn,
    required int completedMinutes,
    required bool isCurrentlyPunchedIn,
  }) {
    if (!hasValidIn) return AttendanceStatus.absent;
    if (completedMinutes >= rules.halfDayThresholdMinutes) {
      return AttendanceStatus.present;
    }
    if (completedMinutes > 0) return AttendanceStatus.halfDay;
    // Valid IN but no completed minutes: an open IN means the employee is on
    // duty right now; otherwise (degenerate zero-length sessions) treat as
    // half day so the row is never shown as absent when a punch exists.
    if (isCurrentlyPunchedIn) return AttendanceStatus.present;
    return AttendanceStatus.halfDay;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
