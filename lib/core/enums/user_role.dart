enum UserRole {
  admin('Admin', 'ADMIN'),
  doctor('Doctor', 'DOCTOR'),
  nurse('Nurse', 'NURSE'),
  receptionist('Receptionist', 'RECEPTIONIST'),
  pharmacist('Pharmacist', 'PHARMACIST'),
  labTechnician('Lab Technician', 'LAB_TECHNICIAN'),
  accountant('Accountant', 'ACCOUNTANT');

  const UserRole(this.label, this.value);
  final String label;
  final String value;

  static UserRole fromValue(String value) {
    return UserRole.values.firstWhere(
      (role) => role.value == value,
      orElse: () => UserRole.receptionist,
    );
  }

  /// Canonical owner/super-admin check for raw `users.role` values.
  ///
  /// Keep in sync with the existing authorization helpers:
  /// * SQL: `public.is_current_user_hospital_admin()` in migration
  ///   `20260825000006_hospital_onboarding_user_management.sql`
  ///   (`lower(role) IN ('super_admin', 'admin')`).
  /// * Edge: `isAdminRole()` in `supabase/functions/abdm-gateway/core.ts`.
  ///
  /// The project has no `owner` role value — `admin` and `super_admin` are
  /// the only owner-level roles. "Owner" is only a display label.
  static bool isOwnerOrSuperAdmin(String? role) {
    final normalized = (role ?? '').toLowerCase();
    return normalized == 'admin' || normalized == 'super_admin';
  }

  bool get isAdmin => this == UserRole.admin;
  bool get isDoctor => this == UserRole.doctor;
  bool get isNurse => this == UserRole.nurse;
  bool get isReceptionist => this == UserRole.receptionist;
}
