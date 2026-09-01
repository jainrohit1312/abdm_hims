/// ---------------------------------------------------------------------------
/// Employee salary summary (HRMS module).
///
/// Pure output of `SalaryCalculator`. The calculator receives an Employee and
/// a monthly attendance summary and returns this object — it never queries
/// Supabase, never touches widgets/routes and never knows about face
/// recognition.
/// ---------------------------------------------------------------------------
class EmployeeSalarySummary {
  const EmployeeSalarySummary({
    required this.employeeId,
    required this.employeeName,
    required this.employeeCode,
    required this.year,
    required this.month,
    required this.monthlySalary,
    required this.eligibleDays,
    required this.presentDays,
    required this.halfDays,
    required this.absentDays,
    required this.attendanceUnits,
    required this.dailyRate,
    required this.payableSalary,
  });

  final String employeeId;
  final String employeeName;
  final String employeeCode;
  final int year;

  /// 1 (January) .. 12 (December).
  final int month;

  final double monthlySalary;

  /// Days from joining (or month start) to relieving (or month end) — the
  /// salary denominator. Days before joining / after relieving are excluded.
  final int eligibleDays;

  final int presentDays;
  final int halfDays;
  final int absentDays;
  final double attendanceUnits;

  /// monthlySalary / eligibleDays (0 when there are no eligible days).
  final double dailyRate;

  /// dailyRate x attendanceUnits, rounded to 2 decimals.
  final double payableSalary;
}
