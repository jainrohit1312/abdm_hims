import 'package:flutter_test/flutter_test.dart';

import 'package:abdm_hims/models/employee_attendance_summary.dart';
import 'package:abdm_hims/models/employee_model.dart';
import 'package:abdm_hims/models/employee_salary_summary.dart';
import 'package:abdm_hims/services/salary_calculator.dart';

/// Pure unit tests for [SalaryCalculator] — no Supabase, no widgets.
void main() {
  const calculator = SalaryCalculator();

  Employee employee({double monthlySalary = 30000, String name = 'Ravi'}) {
    return Employee(
      id: 'e1',
      hospitalId: 'h1',
      employeeCode: 'EMP-0001',
      firstName: name,
      monthlySalary: monthlySalary,
      joiningDate: DateTime(2026, 9, 1),
      isActive: true,
    );
  }

  EmployeeMonthlyAttendance monthly({
    int eligibleDays = 30,
    int presentDays = 0,
    int halfDays = 0,
    int absentDays = 30,
  }) {
    return EmployeeMonthlyAttendance(
      employeeId: 'e1',
      year: 2026,
      month: 9,
      eligibleDays: eligibleDays,
      presentDays: presentDays,
      halfDays: halfDays,
      absentDays: absentDays,
      attendanceUnits: presentDays + halfDays * 0.5,
      totalWorkingMinutes: 0,
    );
  }

  test('monthly salary matches attendance units (25P + 2H => 26 units)',
      () {
    final summary = calculator.calculate(
      employee: employee(monthlySalary: 30000),
      attendance: monthly(
        presentDays: 25,
        halfDays: 2,
        absentDays: 3,
      ),
      year: 2026,
      month: 9,
    );

    expect(summary.eligibleDays, 30);
    expect(summary.attendanceUnits, 26.0);
    expect(summary.dailyRate, 1000.0);
    expect(summary.payableSalary, 26000.0);
  });

  test('half day counts 0.5 unit', () {
    final summary = calculator.calculate(
      employee: employee(monthlySalary: 30000),
      attendance: monthly(presentDays: 0, halfDays: 1, absentDays: 29),
      year: 2026,
      month: 9,
    );

    expect(summary.attendanceUnits, 0.5);
    expect(summary.payableSalary, 500.0);
  });

  test('no attendance => no payable units and zero payable salary', () {
    final summary = calculator.calculate(
      employee: employee(),
      attendance: monthly(),
      year: 2026,
      month: 9,
    );

    expect(summary.attendanceUnits, 0);
    expect(summary.payableSalary, 0);
  });

  test('joining mid-month: denominator uses eligible days only', () {
    final summary = calculator.calculate(
      employee: employee(monthlySalary: 30000),
      attendance: monthly(eligibleDays: 16, presentDays: 16, absentDays: 0),
      year: 2026,
      month: 9,
    );

    // 30000 / 16 eligible days = 1875.0; all present => full monthly salary.
    expect(summary.eligibleDays, 16);
    expect(summary.dailyRate, 1875.0);
    expect(summary.payableSalary, 30000.0);
  });

  test('relieving mid-month: days after relieving never reduce salary', () {
    final summary = calculator.calculate(
      employee: employee(),
      attendance: monthly(eligibleDays: 20, presentDays: 20, absentDays: 0),
      year: 2026,
      month: 9,
    );

    expect(summary.eligibleDays, 20);
    expect(summary.dailyRate, 1500.0);
    expect(summary.payableSalary, 30000.0);
  });

  test('calculator works with zero eligible days without crashing', () {
    final summary = calculator.calculate(
      employee: employee(),
      attendance: monthly(eligibleDays: 0, presentDays: 0, absentDays: 0),
      year: 2026,
      month: 9,
    );

    expect(summary.dailyRate, 0);
    expect(summary.payableSalary, 0);
  });

  test('output is a typed EmployeeSalarySummary (no raw maps)', () {
    final summary = calculator.calculate(
      employee: employee(monthlySalary: 30000),
      attendance: monthly(presentDays: 30, absentDays: 0),
      year: 2026,
      month: 9,
    );

    expect(summary, isA<EmployeeSalarySummary>());
    expect(summary.employeeName, 'Ravi');
    expect(summary.payableSalary, 30000.0);
  });
}
