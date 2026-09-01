import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../models/attendance_punch_model.dart';
import '../services/database_service.dart';
import 'attendance_repository.dart';

/// Supabase implementation of [AttendanceRepository].
///
/// This is the ONLY class in the HRMS module that knows the Supabase punch
/// syntax. It enforces hospital filtering on every query and maps rows to
/// typed [AttendancePunch] objects.
class SupabaseAttendanceRepository implements AttendanceRepository {
  SupabaseAttendanceRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<AttendancePunch>> getPunchesForDate({
    required String hospitalId,
    required DateTime date,
  }) {
    final from = DateTime(date.year, date.month, date.day);
    final to = DateTime(date.year, date.month + 1, 1);
    return getPunchesForRange(hospitalId: hospitalId, from: from, to: to);
  }

  @override
  Future<List<AttendancePunch>> getPunchesForRange({
    required String hospitalId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.employeeAttendancePunchesTable)
          .select()
          .eq('hospital_id', hospitalId)
          .gte('punched_at', from.toUtc().toIso8601String())
          .lt('punched_at', to.toUtc().toIso8601String())
          .order('punched_at', ascending: true),
    );
    return rows.map(AttendancePunch.fromJson).toList();
  }
}
