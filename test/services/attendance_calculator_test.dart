import 'package:flutter_test/flutter_test.dart';

import 'package:abdm_hims/models/attendance_punch_model.dart';
import 'package:abdm_hims/models/employee_attendance_summary.dart';
import 'package:abdm_hims/models/employee_model.dart';
import 'package:abdm_hims/services/attendance_calculator.dart';

/// Pure unit tests for [AttendanceCalculator] — no Supabase, no widgets.
void main() {
  const calculator = AttendanceCalculator();

  AttendancePunch punch(
    String employeeId,
    int hour,
    int minute,
    AttendancePunchType type, {
    int day = 1,
    int month = 9,
    int year = 2026,
  }) {
    return AttendancePunch(
      id: 'p-$employeeId-$day-$hour-$minute',
      hospitalId: 'h1',
      employeeId: employeeId,
      punchedAt: DateTime(year, month, day, hour, minute),
      punchType: type,
      source: 'face_kiosk',
    );
  }

  Employee employee({
    String id = 'e1',
    DateTime? joiningDate,
    DateTime? relievingDate,
    bool isActive = true,
  }) {
    return Employee(
      id: id,
      hospitalId: 'h1',
      employeeCode: 'EMP-0001',
      firstName: 'Test',
      joiningDate: joiningDate,
      relievingDate: relievingDate,
      isActive: isActive,
      monthlySalary: 30000,
    );
  }

  group('daily attendance pairing', () {
    test('09:00 IN -> 18:00 OUT is Present with 9h', () {
      final date = DateTime(2026, 9, 1);
      final rows = calculator.dailyAttendanceForDate(
        date: date,
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 18, 0, AttendancePunchType.punchOut),
        ],
      );

      expect(rows, hasLength(1));
      expect(rows.single.status, AttendanceStatus.present);
      expect(rows.single.workingMinutes, 540); // 9h
      expect(rows.single.isCurrentlyPunchedIn, isFalse);
    });

    test('multiple sessions are summed, not last OUT - first IN', () {
      final date = DateTime(2026, 9, 1);
      final rows = calculator.dailyAttendanceForDate(
        date: date,
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 13, 0, AttendancePunchType.punchOut),
          punch('e1', 14, 0, AttendancePunchType.punchIn),
          punch('e1', 18, 0, AttendancePunchType.punchOut),
        ],
      );

      expect(rows.single.status, AttendanceStatus.present);
      expect(rows.single.workingMinutes, 480); // 4h + 4h = 8h
    });

    test('no punches means Absent (derived, no DB row needed)', () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: const [],
      );

      expect(rows.single.status, AttendanceStatus.absent);
      expect(rows.single.workingMinutes, 0);
    });

    test('working below 4h threshold is Half Day', () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 12, 30, AttendancePunchType.punchOut), // 3.5h
        ],
      );

      expect(rows.single.status, AttendanceStatus.halfDay);
      expect(rows.single.workingMinutes, 210);
    });

    test('exactly 4h is Present (threshold inclusive)', () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 13, 0, AttendancePunchType.punchOut),
        ],
      );

      expect(rows.single.status, AttendanceStatus.present);
      expect(rows.single.workingMinutes, 240);
    });

    test('missing final OUT: currently punched in, Present, 0 completed min',
        () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [punch('e1', 9, 0, AttendancePunchType.punchIn)],
      );

      expect(rows.single.status, AttendanceStatus.present);
      expect(rows.single.isCurrentlyPunchedIn, isTrue);
      expect(rows.single.workingMinutes, 0);
    });

    test('OUT without IN is ignored and day is Absent', () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [punch('e1', 18, 0, AttendancePunchType.punchOut)],
      );

      expect(rows.single.status, AttendanceStatus.absent);
    });

    test('two consecutive INs: second is ignored', () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 10, 0, AttendancePunchType.punchIn),
          punch('e1', 18, 0, AttendancePunchType.punchOut),
        ],
      );

      expect(rows.single.workingMinutes, 540);
      expect(rows.single.firstPunchIn, DateTime(2026, 9, 1, 9, 0));
    });

    test('two consecutive OUTs: second is ignored', () {
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 13, 0, AttendancePunchType.punchOut),
          punch('e1', 14, 0, AttendancePunchType.punchOut),
        ],
      );

      expect(rows.single.workingMinutes, 240);
    });

    test('half-day threshold is configurable', () {
      const custom = AttendanceCalculator(
        rules: AttendanceRules(halfDayThreshold: Duration(hours: 3)),
      );
      final rows = custom.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [employee()],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn),
          punch('e1', 12, 30, AttendancePunchType.punchOut), // 3.5h
        ],
      );

      expect(rows.single.status, AttendanceStatus.present);
    });
  });

  group('eligibility', () {
    test('joined mid-month: no absence before joining', () {
      final joined = employee(joiningDate: DateTime(2026, 9, 15));
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 14),
        employees: [joined],
        punches: const [],
      );

      expect(rows, isEmpty); // not eligible => not even shown as absent
    });

    test('relieved mid-month: no absence after relieving', () {
      final relieved = employee(relievingDate: DateTime(2026, 9, 20));
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 25),
        employees: [relieved],
        punches: const [],
      );

      expect(rows, isEmpty);
    });

    test('inactive employee is excluded', () {
      final inactive = employee(isActive: false);
      final rows = calculator.dailyAttendanceForDate(
        date: DateTime(2026, 9, 1),
        employees: [inactive],
        punches: const [],
      );

      expect(rows, isEmpty);
    });
  });

  group('monthly aggregation', () {
    test('joined mid-month: eligibleDays = 16 (15..30 Sep), no pre-join absence',
        () {
      final joined = employee(joiningDate: DateTime(2026, 9, 15));
      final monthly = calculator.monthlyAttendanceFor(
        year: 2026,
        month: 9,
        employees: [joined],
        punches: const [],
      );

      expect(monthly.single.eligibleDays, 16);
      expect(monthly.single.absentDays, 16);
      expect(monthly.single.presentDays, 0);
      expect(monthly.single.halfDays, 0);
      expect(monthly.single.attendanceUnits, 0);
    });

    test('relieved mid-month: eligibleDays = 20 (1..20 Sep)', () {
      final relieved = employee(
        joiningDate: DateTime(2026, 9, 1),
        relievingDate: DateTime(2026, 9, 20),
      );
      final monthly = calculator.monthlyAttendanceFor(
        year: 2026,
        month: 9,
        employees: [relieved],
        punches: const [],
      );

      expect(monthly.single.eligibleDays, 20);
      expect(monthly.single.absentDays, 20);
    });

    test('aggregates present / half / absent / units / hours correctly', () {
      final emp = employee();
      final punches = <AttendancePunch>[];

      // 25 full days: 09:00 - 18:00 (540m)
      for (var day = 1; day <= 25; day++) {
        punches
          ..add(punch('e1', 9, 0, AttendancePunchType.punchIn, day: day))
          ..add(punch('e1', 18, 0, AttendancePunchType.punchOut, day: day));
      }
      // 2 half days: 09:00 - 12:30 (210m)
      for (var day = 26; day <= 27; day++) {
        punches
          ..add(punch('e1', 9, 0, AttendancePunchType.punchIn, day: day))
          ..add(punch('e1', 12, 30, AttendancePunchType.punchOut, day: day));
      }
      // days 28, 29, 30 => absent (no rows)

      final monthly = calculator.monthlyAttendanceFor(
        year: 2026,
        month: 9,
        employees: [emp],
        punches: punches,
      );

      expect(monthly.single.eligibleDays, 30);
      expect(monthly.single.presentDays, 25);
      expect(monthly.single.halfDays, 2);
      expect(monthly.single.absentDays, 3);
      expect(monthly.single.attendanceUnits, 26.0);
      expect(monthly.single.totalWorkingMinutes, 25 * 540 + 2 * 210);
    });

    test('ignores punches outside the selected month', () {
      final emp = employee();
      final monthly = calculator.monthlyAttendanceFor(
        year: 2026,
        month: 9,
        employees: [emp],
        punches: [
          punch('e1', 9, 0, AttendancePunchType.punchIn,
              day: 31, month: 8),
          punch('e1', 18, 0, AttendancePunchType.punchOut,
              day: 31, month: 8),
        ],
      );

      expect(monthly.single.presentDays, 0);
      expect(monthly.single.absentDays, 30);
    });
  });
}
