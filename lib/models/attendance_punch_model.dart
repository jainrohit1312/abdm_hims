// ---------------------------------------------------------------------------
// Raw attendance punch event (HRMS module).
//
// One row of `employee_attendance_punches`. Punches are the source of truth
// for attendance; business rules never depend on how a punch was created
// (face kiosk, manual admin, biometric device, mobile app, ...).
// ---------------------------------------------------------------------------

enum AttendancePunchType {
  punchIn('in', 'Punch In'),
  punchOut('out', 'Punch Out');

  const AttendancePunchType(this.value, this.label);

  final String value;
  final String label;

  static AttendancePunchType fromValue(String? value) {
    if (value == 'out') return AttendancePunchType.punchOut;
    return AttendancePunchType.punchIn;
  }
}

class AttendancePunch {
  const AttendancePunch({
    required this.id,
    required this.hospitalId,
    required this.employeeId,
    required this.punchedAt,
    required this.punchType,
    required this.source,
    this.deviceId,
    this.createdAt,
  });

  final String id;
  final String hospitalId;
  final String employeeId;

  /// Local date-time of the punch. The Supabase implementation converts the
  /// stored TIMESTAMPTZ to local time so day-grouping works in the hospital's
  /// own timezone.
  final DateTime punchedAt;

  final AttendancePunchType punchType;

  /// `face_kiosk`, `manual_admin`, `biometric_device`, `mobile_app`, ...
  /// Intentionally a free string (no CHECK constraint) so new sources can be
  /// added without a migration or calculator changes.
  final String source;

  final String? deviceId;
  final DateTime? createdAt;

  bool get isPunchIn => punchType == AttendancePunchType.punchIn;
  bool get isPunchOut => punchType == AttendancePunchType.punchOut;

  factory AttendancePunch.fromJson(Map<String, dynamic> json) {
    return AttendancePunch(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      employeeId: json['employee_id']?.toString() ?? '',
      punchedAt: _toLocalDateTime(json['punched_at']) ?? DateTime.now(),
      punchType: AttendancePunchType.fromValue(
        json['punch_type']?.toString(),
      ),
      source: json['source']?.toString() ?? 'face_kiosk',
      deviceId: json['device_id']?.toString(),
      createdAt: _toLocalDateTime(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hospital_id': hospitalId,
      'employee_id': employeeId,
      'punched_at': punchedAt.toIso8601String(),
      'punch_type': punchType.value,
      'source': source,
      'device_id': deviceId,
      'created_at': createdAt?.toIso8601String(),
    };
  }
}

DateTime? _toLocalDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toLocal();
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  return parsed?.toLocal();
}
