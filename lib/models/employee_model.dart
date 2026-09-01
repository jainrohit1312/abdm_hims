/// ---------------------------------------------------------------------------
/// Employee Master model (HRMS module).
///
/// A typed representation of one row in the `employees` table. Screens and
/// providers never pass raw `Map<String, dynamic>` around; only the Supabase
/// repository implementations map DB rows <-> this model.
///
/// NOTE: an employee is NOT a HIMS login user. `/users` continues to hold
/// login accounts; `employees` is the HRMS employee master.
/// ---------------------------------------------------------------------------
class Employee {
  const Employee({
    required this.id,
    required this.hospitalId,
    required this.employeeCode,
    required this.firstName,
    this.lastName,
    this.mobileNumber,
    this.departmentId,
    this.designation,
    this.monthlySalary = 0,
    this.joiningDate,
    this.relievingDate,
    this.isActive = true,
    this.faceReferenceId,
    this.faceEnrolled = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String hospitalId;
  final String employeeCode;
  final String firstName;
  final String? lastName;
  final String? mobileNumber;
  final String? departmentId;
  final String? designation;
  final double monthlySalary;
  final DateTime? joiningDate;
  final DateTime? relievingDate;
  final bool isActive;

  /// Backend metadata only. Face/biometric data is never exposed or edited in
  /// the HIMS UI — the future Android kiosk owns these fields.
  final String? faceReferenceId;
  final bool faceEnrolled;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get fullName => '$firstName ${lastName ?? ''}'.trim();

  /// True when the employee can be marked present/absent for [date].
  ///
  /// Eligibility rules (single source of truth for the attendance module):
  /// * employee must currently be active,
  /// * date must be >= joining date,
  /// * date must be <= relieving date when one exists.
  bool isEligibleOn(DateTime date) {
    if (!isActive) return false;
    final day = DateTime(date.year, date.month, date.day);

    final joining = joiningDate;
    if (joining != null) {
      final joiningDay = DateTime(joining.year, joining.month, joining.day);
      if (day.isBefore(joiningDay)) return false;
    }

    final relieving = relievingDate;
    if (relieving != null) {
      final relievingDay = DateTime(
        relieving.year,
        relieving.month,
        relieving.day,
      );
      if (day.isAfter(relievingDay)) return false;
    }

    return true;
  }

  factory Employee.fromJson(Map<String, dynamic> json) {
    return Employee(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      employeeCode: json['employee_code']?.toString() ?? '',
      firstName: json['first_name']?.toString() ?? '',
      lastName: json['last_name']?.toString(),
      mobileNumber: json['mobile_number']?.toString(),
      departmentId: json['department_id']?.toString(),
      designation: json['designation']?.toString(),
      monthlySalary: _toDouble(json['monthly_salary']),
      joiningDate: _toDate(json['joining_date']),
      relievingDate: _toDate(json['relieving_date']),
      isActive: json['is_active'] != false,
      faceReferenceId: json['face_reference_id']?.toString(),
      faceEnrolled: json['face_enrolled'] == true,
      createdAt: _toDate(json['created_at']),
      updatedAt: _toDate(json['updated_at']),
    );
  }

  /// Round-trip serialization (including the id) for caching/tests.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hospital_id': hospitalId,
      'employee_code': employeeCode,
      'first_name': firstName,
      'last_name': lastName,
      'mobile_number': mobileNumber,
      'department_id': departmentId,
      'designation': designation,
      'monthly_salary': monthlySalary,
      'joining_date': _dateOnly(joiningDate),
      'relieving_date': _dateOnly(relievingDate),
      'is_active': isActive,
      'face_reference_id': faceReferenceId,
      'face_enrolled': faceEnrolled,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  Employee copyWith({
    String? id,
    String? hospitalId,
    String? employeeCode,
    String? firstName,
    String? lastName,
    String? mobileNumber,
    String? departmentId,
    String? designation,
    double? monthlySalary,
    DateTime? joiningDate,
    DateTime? relievingDate,
    bool? isActive,
    String? faceReferenceId,
    bool? faceEnrolled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Employee(
      id: id ?? this.id,
      hospitalId: hospitalId ?? this.hospitalId,
      employeeCode: employeeCode ?? this.employeeCode,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      mobileNumber: mobileNumber ?? this.mobileNumber,
      departmentId: departmentId ?? this.departmentId,
      designation: designation ?? this.designation,
      monthlySalary: monthlySalary ?? this.monthlySalary,
      joiningDate: joiningDate ?? this.joiningDate,
      relievingDate: relievingDate ?? this.relievingDate,
      isActive: isActive ?? this.isActive,
      faceReferenceId: faceReferenceId ?? this.faceReferenceId,
      faceEnrolled: faceEnrolled ?? this.faceEnrolled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

double _toDouble(dynamic value) => (value as num?)?.toDouble() ?? 0;

DateTime? _toDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

String? _dateOnly(DateTime? value) {
  if (value == null) return null;
  final y = value.year.toString().padLeft(4, '0');
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
