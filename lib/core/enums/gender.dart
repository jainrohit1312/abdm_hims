import 'package:flutter/material.dart';

enum Gender {
  male('M', 'Male'),
  female('F', 'Female'),
  other('O', 'Other'),
  declineToState('D', 'Decline to State');

  const Gender(this.value, this.label);
  final String value;
  final String label;

  static Gender fromValue(String value) {
    return Gender.values.firstWhere(
      (g) => g.value == value,
      orElse: () => Gender.declineToState,
    );
  }
}

enum BloodGroup {
  aPositive('A+'),
  aNegative('A-'),
  bPositive('B+'),
  bNegative('B-'),
  abPositive('AB+'),
  abNegative('AB-'),
  oPositive('O+'),
  oNegative('O-');

  const BloodGroup(this.value);
  final String value;

  static BloodGroup fromValue(String value) {
    return BloodGroup.values.firstWhere(
      (bg) => bg.value == value,
      orElse: () => BloodGroup.oPositive,
    );
  }
}

enum InsuranceType {
  pmjay('PMJAY', 'PM-JAY'),
  cghs('CGHS', 'CGHS'),
  echs('ECHS', 'ECHS'),
  stateScheme('STATE_SCHEME', 'State Scheme'),
  private('PRIVATE', 'Private Insurance'),
  cash('CASH', 'Cash'),
  other('OTHER', 'Other');

  const InsuranceType(this.value, this.label);
  final String value;
  final String label;

  bool get isAbhaRequired {
    switch (this) {
      case InsuranceType.pmjay:
      case InsuranceType.cghs:
      case InsuranceType.echs:
      case InsuranceType.stateScheme:
        return true;
      default:
        return false;
    }
  }
}

enum MaritalStatus {
  single('Single'),
  married('Married'),
  divorced('Divorced'),
  widowed('Widowed');

  const MaritalStatus(this.label);
  final String label;
}

enum AdmissionType {
  emergency('Emergency'),
  planned('Planned'),
  opdConverted('OPD Converted');

  const AdmissionType(this.label);
  final String label;
}

enum DischargeType {
  routine('Routine'),
  lama('LAMA'),
  dor('DOR'),
  death('Death');

  const DischargeType(this.label);
  final String label;
}

enum TriageLevel {
  emergency('Emergency', Colors.red),
  urgent('Urgent', Colors.orange),
  nonUrgent('Non-Urgent', Colors.green);

  const TriageLevel(this.label, this.color);
  final String label;
  final Color color;
}

enum ConsultationStatus {
  waiting('Waiting'),
  inConsultation('In Consultation'),
  done('Done'),
  cancelled('Cancelled');

  const ConsultationStatus(this.label);
  final String label;
}

enum InvestigationPriority {
  routine('Routine'),
  urgent('Urgent'),
  stat('STAT');

  const InvestigationPriority(this.label);
  final String label;
}

enum PaymentStatus {
  paid('Paid'),
  pending('Pending'),
  insurance('Insurance'),
  partial('Partial');

  const PaymentStatus(this.label);
  final String label;
}

enum BedStatus {
  available('Available'),
  occupied('Occupied'),
  reserved('Reserved'),
  maintenance('Maintenance');

  const BedStatus(this.label);
  final String label;
}

enum WardType {
  general('General'),
  semiPrivate('Semi-Private'),
  private('Private'),
  icu('ICU'),
  hdu('HDU');

  const WardType(this.label);
  final String label;
}

enum MedicationStatus {
  pending('Pending'),
  given('Given'),
  notGiven('Not Given'),
  refused('Refused');

  const MedicationStatus(this.label);
  final String label;
}

enum SampleStatus {
  collected('Collected'),
  received('Received'),
  processing('Processing'),
  reportReady('Report Ready');

  const SampleStatus(this.label);
  final String label;
}