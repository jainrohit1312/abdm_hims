import '../models/attendance_punch_model.dart';

/// ---------------------------------------------------------------------------
/// Focused persistence/query contract for raw attendance punch events.
///
/// Implementations must obey the same contract (LSP): the same inputs produce
/// the same shape of result, and failures surface as
/// [AttendanceRepositoryException].
///
/// The HIMS side only READS punches. The future Android kiosk writes rows into
/// Supabase directly — that contract lives in the migration, not here (ISP).
/// ---------------------------------------------------------------------------
abstract class AttendanceRepository {
  /// Punches for a single calendar date (local hospital date), sorted by
  /// `punched_at` ascending.
  Future<List<AttendancePunch>> getPunchesForDate({
    required String hospitalId,
    required DateTime date,
  });

  /// Punches in [from, to) — `to` is exclusive. Sorted by `punched_at`
  /// ascending. Used for monthly aggregation (one query, no N+1).
  Future<List<AttendancePunch>> getPunchesForRange({
    required String hospitalId,
    required DateTime from,
    required DateTime to,
  });
}

/// Base exception for attendance persistence failures.
class AttendanceRepositoryException implements Exception {
  const AttendanceRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}
