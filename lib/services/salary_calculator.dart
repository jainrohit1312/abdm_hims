import '../models/employee_attendance_summary.dart';
import '../models/employee_model.dart';
import '../models/employee_salary_summary.dart';

/// ---------------------------------------------------------------------------
/// SalaryCalculator — pure domain logic for salary computation.
///
/// Input:
///   * Employee
///   * EmployeeMonthlyAttendance (computed by AttendanceCalculator)
///   * selected month/year
///
/// Output:
///   * EmployeeSalarySummary
///
/// Formula (documented, v1 — no PF/ESI/TDS/payroll):
///   dailyRate  = monthlySalary / eligibleDaysInMonth
///   payable    = dailyRate x attendanceUnits
///   units      = Present(1) + HalfDay(0.5) + Absent(0)
///
/// `eligibleDaysInMonth` comes from the monthly attendance summary and already
/// respects joiningDate / relievingDate:
///   * joins 15 Sep  -> denominator = 16 (15..30 Sep); 1-14 are never absence
///   * relieves 20 Sep -> denominator = 20 (1..20 Sep); 21-30 are never absence
///
/// This class does NOT query Supabase, does not know widgets/routes, and does
/// not know how punches were captured (face kiosk or otherwise).
/// ---------------------------------------------------------------------------
class SalaryCalculator {
  const SalaryCalculator();

  EmployeeSalarySummary calculate({
    required Employee employee,
    required EmployeeMonthlyAttendance attendance,
    required int year,
    required int month,
  }) {
    final eligibleDays = attendance.eligibleDays;
    final dailyRate = eligibleDays > 0 ? employee.monthlySalary / eligibleDays : 0.0;
    final payable = dailyRate * attendance.attendanceUnits;

    return EmployeeSalarySummary(
      employeeId: employee.id,
      employeeName: employee.fullName,
      employeeCode: employee.employeeCode,
      year: year,
      month: month,
      monthlySalary: employee.monthlySalary,
      eligibleDays: eligibleDays,
      presentDays: attendance.presentDays,
      halfDays: attendance.halfDays,
      absentDays: attendance.absentDays,
      attendanceUnits: attendance.attendanceUnits,
      dailyRate: _round2(dailyRate),
      payableSalary: _round2(payable),
    );
  }

  /// Rounds to 2 decimal places so ₹ amounts stay clean for display.
  double _round2(double value) => (value * 100).roundToDouble() / 100;
}
