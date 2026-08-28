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

  bool get isAdmin => this == UserRole.admin;
  bool get isDoctor => this == UserRole.doctor;
  bool get isNurse => this == UserRole.nurse;
  bool get isReceptionist => this == UserRole.receptionist;
}