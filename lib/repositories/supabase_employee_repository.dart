import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../models/employee_model.dart';
import '../services/database_service.dart';
import 'employee_repository.dart';

/// Supabase implementation of [EmployeeRepository].
///
/// This is the ONLY class in the HRMS module that knows the Supabase employee
/// syntax (table names, RPC names, row mapping) — business logic and UI depend
/// on the abstraction instead (DIP).
class SupabaseEmployeeRepository implements EmployeeRepository {
  SupabaseEmployeeRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Employee>> getEmployees({required String hospitalId}) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.employeesTable)
          .select()
          .eq('hospital_id', hospitalId)
          .order('employee_code', ascending: true),
    );
    return rows.map(Employee.fromJson).toList();
  }

  @override
  Future<Employee?> getEmployeeById({
    required String hospitalId,
    required String id,
  }) async {
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.employeesTable)
          .select()
          .eq('id', id)
          .eq('hospital_id', hospitalId)
          .maybeSingle(),
    );
    return row == null ? null : Employee.fromJson(row);
  }

  @override
  Future<Employee> createEmployee({
    required String hospitalId,
    required Employee employee,
  }) async {
    final employeeCode = await _nextEmployeeCode(hospitalId);
    final now = DateTime.now().toUtc().toIso8601String();

    final payload = _employeePayload(employee, hospitalId: hospitalId)
      ..['employee_code'] = employeeCode
      ..['created_at'] = now
      ..['updated_at'] = now;

    try {
      final row = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.employeesTable)
            .insert(payload)
            .select()
            .single(),
      );
      return Employee.fromJson(row);
    } on PostgrestException catch (e) {
      if (e.code == '23505') throw const EmployeeCodeConflictException();
      rethrow;
    }
  }

  @override
  Future<Employee> updateEmployee({
    required String hospitalId,
    required Employee employee,
  }) async {
    final payload = _employeePayload(employee, hospitalId: hospitalId)
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String();

    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.employeesTable)
          .update(payload)
          .eq('id', employee.id)
          .eq('hospital_id', hospitalId)
          .select()
          .single(),
    );
    return Employee.fromJson(row);
  }

  /// Calls the SECURITY DEFINER database function that atomically mints the
  /// next hospital-wise employee code (EMP-0001, EMP-0002, ...).
  Future<String> _nextEmployeeCode(String hospitalId) async {
    final value = await DatabaseService.fetchWithRetry(
      () => _client.rpc(
        'next_employee_code',
        params: {'p_hospital_id': hospitalId},
      ),
    );
    final code = value?.toString().trim() ?? '';
    if (code.isEmpty) {
      throw const EmployeeRepositoryException(
        'Could not generate an employee code. Please try again.',
      );
    }
    return code;
  }

  /// Builds the insert/update column map from a typed [Employee]. Never
  /// includes `id` / `employee_code` (code is immutable and generated).
  Map<String, dynamic> _employeePayload(
    Employee employee, {
    required String hospitalId,
  }) {
    return {
      'hospital_id': hospitalId,
      'first_name': employee.firstName,
      'last_name': employee.lastName,
      'mobile_number': employee.mobileNumber,
      'department_id': employee.departmentId,
      'designation': employee.designation,
      'monthly_salary': employee.monthlySalary,
      'joining_date': _dateOnly(employee.joiningDate),
      'relieving_date': _dateOnly(employee.relievingDate),
      'is_active': employee.isActive,
      // Backend metadata preserved on update; never edited by the HIMS UI.
      'face_reference_id': employee.faceReferenceId,
      'face_enrolled': employee.faceEnrolled,
    };
  }

  String? _dateOnly(DateTime? value) {
    if (value == null) return null;
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
