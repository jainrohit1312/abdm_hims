/// Unified prescription domain models.
///
/// Ek hi `prescriptions` row OPD aur IPD dono contexts ke liye kaam karti hai:
///   * OPD -> `history` + `investigations` + `medicines` + `advice` (full
///            clinical document)
///   * IPD -> sirf `medicines` (baaki sections dusre IPD modules handle
///            karte hain)
///
/// Sabhi models JSONB columns (`history`, `investigations`, `medicines`,
/// `advice`) ke saath direct map hote hain aur legacy columns
/// (`clinical_notes`, `prescription_items`) ka fallback bhi sambhalte hain.
library;

/// Visit context of a prescription row.
enum VisitType {
  opd('opd', 'OPD'),
  ipd('ipd', 'IPD');

  const VisitType(this.value, this.label);

  /// DB value (`opd` / `ipd`).
  final String value;

  /// Human-readable label.
  final String label;

  /// Parses a DB value. Unknown/missing values default to [VisitType.opd]
  /// taaki legacy rows bina visit_type ke bhi safe rahein.
  static VisitType fromDb(String? value) {
    if (value == 'ipd') return VisitType.ipd;
    return VisitType.opd;
  }

  bool get isIpd => this == VisitType.ipd;
  bool get isOpd => this == VisitType.opd;
}

/// One medicine line inside the `medicines` JSONB array.
class PrescriptionMedicine {
  final String medicineName;
  final String? genericName;
  final String? strength;
  final String dosage;
  final String frequency;
  final String duration;
  final String route;
  final String instructions;
  final List<String> customTimes;

  const PrescriptionMedicine({
    required this.medicineName,
    this.genericName,
    this.strength,
    this.dosage = '',
    this.frequency = '',
    this.duration = '',
    this.route = '',
    this.instructions = '',
    this.customTimes = const [],
  });

  factory PrescriptionMedicine.fromJson(Map<String, dynamic> json) {
    return PrescriptionMedicine(
      medicineName: json['medicine_name']?.toString() ?? '',
      genericName: _nullIfEmpty(json['generic_name']?.toString()),
      strength: _nullIfEmpty(json['strength']?.toString()),
      dosage: json['dosage']?.toString() ?? '',
      frequency: json['frequency']?.toString() ?? '',
      duration: json['duration']?.toString() ?? '',
      route: json['route']?.toString() ?? '',
      instructions: json['instructions']?.toString() ?? '',
      customTimes: (json['custom_times'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'medicine_name': medicineName,
        if (genericName != null) 'generic_name': genericName,
        if (strength != null) 'strength': strength,
        'dosage': dosage,
        'frequency': frequency,
        'duration': duration,
        'route': route,
        'instructions': instructions,
        'custom_times': customTimes,
      };

  /// Medicine ka display title — strength ke saath jab available ho.
  String get displayName => strength == null || strength!.isEmpty
      ? medicineName
      : '$medicineName ($strength)';
}

/// `history` JSONB — OPD only.
class PrescriptionHistory {
  final String chiefComplaints;
  final String historyPresentingIllness;
  final String pastHistory;
  final String personalHistory;
  final String familyHistory;
  final String allergies;
  final String examinationFindings;
  final String diagnosis;
  final Map<String, dynamic> vitals;

  const PrescriptionHistory({
    this.chiefComplaints = '',
    this.historyPresentingIllness = '',
    this.pastHistory = '',
    this.personalHistory = '',
    this.familyHistory = '',
    this.allergies = '',
    this.examinationFindings = '',
    this.diagnosis = '',
    this.vitals = const {},
  });

  factory PrescriptionHistory.fromJson(Map<String, dynamic> json) {
    return PrescriptionHistory(
      chiefComplaints: json['chief_complaints']?.toString() ?? '',
      historyPresentingIllness:
          json['history_presenting_illness']?.toString() ?? '',
      pastHistory: json['past_history']?.toString() ?? '',
      personalHistory: json['personal_history']?.toString() ?? '',
      familyHistory: json['family_history']?.toString() ?? '',
      allergies: json['allergies']?.toString() ?? '',
      examinationFindings: json['examination_findings']?.toString() ?? '',
      diagnosis: json['diagnosis']?.toString() ?? '',
      vitals: json['vitals'] is Map
          ? Map<String, dynamic>.from(json['vitals'] as Map)
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
        'chief_complaints': chiefComplaints,
        'history_presenting_illness': historyPresentingIllness,
        'past_history': pastHistory,
        'personal_history': personalHistory,
        'family_history': familyHistory,
        'allergies': allergies,
        'examination_findings': examinationFindings,
        'diagnosis': diagnosis,
        'vitals': vitals,
      };

  bool get isEmpty =>
      toJson().values.every((value) => value is String
          ? value.trim().isEmpty
          : (value is Map ? value.isEmpty : true));
}

/// `investigations` JSONB — OPD only.
class PrescriptionInvestigations {
  final List<String> labTests;
  final List<String> radiology;
  final List<String> otherInvestigations;

  const PrescriptionInvestigations({
    this.labTests = const [],
    this.radiology = const [],
    this.otherInvestigations = const [],
  });

  factory PrescriptionInvestigations.fromJson(Map<String, dynamic> json) {
    List<String> list(dynamic value) => (value is List)
        ? value.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : const [];

    return PrescriptionInvestigations(
      labTests: list(json['lab_tests']),
      radiology: list(json['radiology']),
      otherInvestigations: list(json['other_investigations']),
    );
  }

  Map<String, dynamic> toJson() => {
        'lab_tests': labTests,
        'radiology': radiology,
        'other_investigations': otherInvestigations,
      };

  bool get isEmpty =>
      labTests.isEmpty && radiology.isEmpty && otherInvestigations.isEmpty;
}

/// `advice` JSONB — OPD only.
class PrescriptionAdvice {
  final String followUpDate;
  final String dietaryAdvice;
  final String activityAdvice;
  final String otherAdvice;
  final String followUp;

  const PrescriptionAdvice({
    this.followUpDate = '',
    this.dietaryAdvice = '',
    this.activityAdvice = '',
    this.otherAdvice = '',
    this.followUp = '',
  });

  factory PrescriptionAdvice.fromJson(Map<String, dynamic> json) {
    return PrescriptionAdvice(
      followUpDate: json['follow_up_date']?.toString() ?? '',
      dietaryAdvice: json['dietary_advice']?.toString() ?? '',
      activityAdvice: json['activity_advice']?.toString() ?? '',
      otherAdvice: json['other_advice']?.toString() ?? '',
      followUp: json['follow_up']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'follow_up_date': followUpDate,
        'dietary_advice': dietaryAdvice,
        'activity_advice': activityAdvice,
        'other_advice': otherAdvice,
        'follow_up': followUp,
      };

  bool get isEmpty => toJson().values.every(
      (value) => value is String && value.trim().isEmpty);
}

/// Parsed view of one unified `prescriptions` row.
class UnifiedPrescription {
  final String id;
  final String? hospitalId;
  final String? patientId;
  final String? doctorId;
  final VisitType visitType;
  final String? opdRegistrationId;
  final String? ipdAdmissionId;
  final String prescriptionDate;
  final PrescriptionHistory history;
  final PrescriptionInvestigations investigations;
  final List<PrescriptionMedicine> medicines;
  final PrescriptionAdvice advice;
  final String status;

  const UnifiedPrescription({
    required this.id,
    this.hospitalId,
    this.patientId,
    this.doctorId,
    required this.visitType,
    this.opdRegistrationId,
    this.ipdAdmissionId,
    required this.prescriptionDate,
    this.history = const PrescriptionHistory(),
    this.investigations = const PrescriptionInvestigations(),
    this.medicines = const [],
    this.advice = const PrescriptionAdvice(),
    this.status = 'active',
  });

  /// Builds from a Supabase row. New JSONB columns ko pehle padhta hai aur
  /// legacy `clinical_notes` + `items`/`prescription_items` se fallback karta
  /// hai taaki purani prescriptions bhi sahi dikhein.
  factory UnifiedPrescription.fromRow(Map<String, dynamic> row) {
    final historyJson = _asMap(row['history']);
    final investigationsJson = _asMap(row['investigations']);
    final adviceJson = _asMap(row['advice']);

    // Naye medicines JSONB se, warna legacy inline `items` list se.
    final medicines = <PrescriptionMedicine>[];
    final rawMedicines = row['medicines'];
    if (rawMedicines is List && rawMedicines.isNotEmpty) {
      medicines.addAll(
        rawMedicines
            .whereType<Map>()
            .map((m) => PrescriptionMedicine.fromJson(
                Map<String, dynamic>.from(m))),
      );
    } else {
      final items = row['items'];
      if (items is List) {
        medicines.addAll(
          items
              .whereType<Map>()
              .map((m) => PrescriptionMedicine.fromJson(
                  Map<String, dynamic>.from(m))),
        );
      } else if (row['medicine_name']?.toString().isNotEmpty == true &&
          row['medicine_name']?.toString() != 'No medicines prescribed') {
        medicines.add(
          PrescriptionMedicine(
            medicineName: row['medicine_name'].toString(),
            dosage: row['dosage']?.toString() ?? '',
            frequency: row['frequency']?.toString() ?? '',
            duration: row['duration']?.toString() ?? '',
            route: row['route']?.toString() ?? '',
            instructions: row['instructions']?.toString() ?? '',
          ),
        );
      }
    }

    return UnifiedPrescription(
      id: row['id']?.toString() ?? '',
      hospitalId: row['hospital_id']?.toString(),
      patientId: row['patient_id']?.toString(),
      doctorId: row['doctor_id']?.toString(),
      visitType: VisitType.fromDb(row['visit_type']?.toString()),
      opdRegistrationId: row['opd_registration_id']?.toString(),
      ipdAdmissionId: row['ipd_admission_id']?.toString(),
      prescriptionDate: row['prescription_date']?.toString() ?? '',
      history: PrescriptionHistory.fromJson(historyJson),
      investigations: PrescriptionInvestigations.fromJson(investigationsJson),
      medicines: medicines,
      advice: PrescriptionAdvice.fromJson(adviceJson),
      status: row['status']?.toString() ?? 'active',
    );
  }

  /// Insert payload for `savePrescription` (unified columns + legacy sync).
  Map<String, dynamic> toInsertPayload() => {
        'visit_type': visitType.value,
        'history': history.toJson(),
        'investigations': investigations.toJson(),
        'medicines': medicines.map((m) => m.toJson()).toList(),
        'advice': advice.toJson(),
      };

  bool get isOpd => visitType.isOpd;
  bool get isIpd => visitType.isIpd;

  /// True jab OPD wale clinical sections mein koi data ho.
  bool get hasClinicalData => !history.isEmpty ||
      !investigations.isEmpty ||
      !advice.isEmpty;
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

String? _nullIfEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
