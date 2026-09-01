// ---------------------------------------------------------------------------
// Attendance summary models (HRMS module).
//
// These are pure domain objects produced by `AttendanceCalculator` — they
// never touch Supabase and never contain salary figures.
// ---------------------------------------------------------------------------

enum AttendanceStatus {
  present('present', 'Present'),
  halfDay('half_day', 'Half Day'),
  absent('absent', 'Absent');

  const AttendanceStatus(this.value, this.label);

  final String value;
  final String label;
}

/// One employee's calculated attendance for a single date.
class EmployeeDailyAttendance {
  const EmployeeDailyAttendance({
    required this.employeeId,
    required this.date,
    required this.status,
    this.firstPunchIn,
    this.lastPunchOut,
    this.workingMinutes = 0,
    this.isCurrentlyPunchedIn = false,
  });

  final String employeeId;

  /// The calendar date this summary belongs to.
  final DateTime date;

  final AttendanceStatus status;
  final DateTime? firstPunchIn;
  final DateTime? lastPunchOut;

  /// Completed IN -> OUT session minutes only. An open IN (missing final OUT)
  /// contributes 0 minutes and sets [isCurrentlyPunchedIn] instead.
  final int workingMinutes;

  /// True when the last valid punch of the day is an IN with no matching OUT —
  /// the employee is still on duty.
  final bool isCurrentlyPunchedIn;

  double get workingHours => workingMinutes / 60;
}

/// One employee's aggregated attendance for a whole month.
class EmployeeMonthlyAttendance {
  const EmployeeMonthlyAttendance({
    required this.employeeId,
    required this.year,
    required this.month,
    required this.eligibleDays,
    required this.presentDays,
    required this.halfDays,
    required this.absentDays,
    required this.attendanceUnits,
    required this.totalWorkingMinutes,
  });

  final String employeeId;
  final int year;

  /// 1 (January) .. 12 (December).
  final int month;

  /// Calendar days in [month] where the employee was eligible (joined, not yet
  /// relieved, active). Days before joining / after relieving are never
  /// counted as absent.
  final int eligibleDays;

  final int presentDays;
  final int halfDays;
  final int absentDays;

  /// Present = 1, Half Day = 0.5, Absent = 0.
  final double attendanceUnits;

  final int totalWorkingMinutes;

  double get totalWorkingHours => totalWorkingMinutes / 60;

  int get accountedDays => presentDays + halfDays + absentDays;
}
