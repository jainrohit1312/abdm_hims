import '../models/employee_model.dart';

/// ---------------------------------------------------------------------------
/// Focused persistence contract for the employee master (HRMS module).
///
/// Implementations must obey the same contract (LSP): the same inputs always
/// produce the same shape of result, and failures surface as
/// [EmployeeRepositoryException] (never as raw Supabase/PostgREST errors).
///
/// Salary and attendance logic do NOT belong here — this interface is
/// employee persistence only (ISP).
/// ---------------------------------------------------------------------------
abstract class EmployeeRepository {
  /// All employees of [hospitalId], ordered by employee code.
  Future<List<Employee>> getEmployees({required String hospitalId});

  /// One employee by id. Returns null when not found (or not in the hospital).
  Future<Employee?> getEmployeeById({
    required String hospitalId,
    required String id,
  });

  /// Creates a new employee. The employee code is generated hospital-wise by
  /// the implementation (see migration: `next_employee_code`).
  ///
  /// [employee.id] is ignored; [employee.employeeCode] is ignored and replaced
  /// with the generated code. Throws [EmployeeCodeConflictException] if the
  /// generated code can no longer be inserted.
  Future<Employee> createEmployee({
    required String hospitalId,
    required Employee employee,
  });

  /// Updates the editable master fields of an existing employee. The employee
  /// code is immutable once created.
  Future<Employee> updateEmployee({
    required String hospitalId,
    required Employee employee,
  });
}

/// Base exception for employee persistence failures. UI layers catch this and
/// show a friendly message instead of a raw PostgREST stack trace.
class EmployeeRepositoryException implements Exception {
  const EmployeeRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when the generated employee code violates the per-hospital unique
/// constraint (should be extremely rare with the database sequence).
class EmployeeCodeConflictException extends EmployeeRepositoryException {
  const EmployeeCodeConflictException()
      : super(
          'Could not allocate a unique employee code. Please try again.',
        );
}
