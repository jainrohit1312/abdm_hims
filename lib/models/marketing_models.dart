/// ---------------------------------------------------------------------------
/// PRO / Marketing module models.
///
/// Typed representations of the marketing domain. Only the Supabase
/// repository implementations map DB rows <-> these models; screens and
/// providers never pass raw `Map<String, dynamic>` around (where practical).
///
/// Domain note: `ReferralDoctor` is NOT a hospital doctor. It is a completely
/// separate domain stored in `referral_doctors` and never touches the
/// hospital `doctors` table.
/// ---------------------------------------------------------------------------
class MarketingArea {
  const MarketingArea({
    required this.id,
    required this.hospitalId,
    required this.name,
    this.code,
    this.description,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String hospitalId;
  final String name;
  final String? code;
  final String? description;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory MarketingArea.fromJson(Map<String, dynamic> json) {
    return MarketingArea(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      code: json['code']?.toString(),
      description: json['description']?.toString(),
      isActive: json['is_active'] != false,
      createdAt: _toDate(json['created_at']),
      updatedAt: _toDate(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hospital_id': hospitalId,
      'name': name,
      'code': code,
      'description': description,
      'is_active': isActive,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}

class ReferralDoctor {
  const ReferralDoctor({
    required this.id,
    required this.hospitalId,
    required this.name,
    this.clinicName,
    this.practitionerType = 'clinic',
    this.registrationNumber,
    this.mobileNumber,
    this.alternateMobile,
    this.areaId,
    this.areaName,
    this.village,
    this.address,
    this.city,
    this.pincode,
    this.latitude,
    this.longitude,
    this.geoRadiusMeters = 150,
    this.locationVerified = false,
    this.locationVerifiedAt,
    this.locationVerifiedBy,
    this.isActive = true,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String hospitalId;
  final String name;
  final String? clinicName;
  final String practitionerType;
  final String? registrationNumber;
  final String? mobileNumber;
  final String? alternateMobile;
  final String? areaId;

  /// Resolved by the repository from `marketing_areas.name` (embedded select).
  /// Kept on the model so the analytics service can name areas without an
  /// extra lookup.
  final String? areaName;

  final String? village;
  final String? address;
  final String? city;
  final String? pincode;
  final double? latitude;
  final double? longitude;
  final int geoRadiusMeters;
  final bool locationVerified;
  final DateTime? locationVerifiedAt;
  final String? locationVerifiedBy;
  final bool isActive;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasLocation => latitude != null && longitude != null;

  factory ReferralDoctor.fromJson(Map<String, dynamic> json) {
    return ReferralDoctor(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      clinicName: json['clinic_name']?.toString(),
      practitionerType: json['practitioner_type']?.toString() ?? 'clinic',
      registrationNumber: json['registration_number']?.toString(),
      mobileNumber: json['mobile_number']?.toString(),
      alternateMobile: json['alternate_mobile']?.toString(),
      areaId: json['area_id']?.toString(),
      areaName: _embeddedName(json['marketing_areas']),
      village: json['village']?.toString(),
      address: json['address']?.toString(),
      city: json['city']?.toString(),
      pincode: json['pincode']?.toString(),
      latitude: _toDoubleOrNull(json['latitude']),
      longitude: _toDoubleOrNull(json['longitude']),
      geoRadiusMeters: _toInt(json['geo_radius_meters']) ?? 150,
      locationVerified: json['location_verified'] == true,
      locationVerifiedAt: _toDate(json['location_verified_at']),
      locationVerifiedBy: json['location_verified_by']?.toString(),
      isActive: json['is_active'] != false,
      notes: json['notes']?.toString(),
      createdAt: _toDate(json['created_at']),
      updatedAt: _toDate(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hospital_id': hospitalId,
      'name': name,
      'clinic_name': clinicName,
      'practitioner_type': practitionerType,
      'registration_number': registrationNumber,
      'mobile_number': mobileNumber,
      'alternate_mobile': alternateMobile,
      'area_id': areaId,
      'village': village,
      'address': address,
      'city': city,
      'pincode': pincode,
      'latitude': latitude,
      'longitude': longitude,
      'geo_radius_meters': geoRadiusMeters,
      'location_verified': locationVerified,
      'location_verified_at': locationVerifiedAt?.toIso8601String(),
      'location_verified_by': locationVerifiedBy,
      'is_active': isActive,
      'notes': notes,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}

class MarketingVisit {
  const MarketingVisit({
    required this.id,
    required this.hospitalId,
    this.marketingEmployeeId,
    required this.referralDoctorId,
    this.areaId,
    required this.visitedAt,
    this.latitude,
    this.longitude,
    this.distanceFromDoctorMeters,
    this.geofenceRadiusMeters,
    this.geoVerified = false,
    this.visitSource = 'mobile_app',
    this.visitPurpose,
    this.visitNotes,
    this.nextFollowUpDate,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String hospitalId;
  final String? marketingEmployeeId;
  final String referralDoctorId;
  final String? areaId;
  final DateTime visitedAt;

  /// Employee location captured ONLY at the visit-punch moment. No continuous
  /// tracking is implemented anywhere in the module.
  final double? latitude;
  final double? longitude;

  final double? distanceFromDoctorMeters;
  final int? geofenceRadiusMeters;
  final bool geoVerified;
  final String visitSource;
  final String? visitPurpose;
  final String? visitNotes;
  final DateTime? nextFollowUpDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory MarketingVisit.fromJson(Map<String, dynamic> json) {
    return MarketingVisit(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      marketingEmployeeId: json['marketing_employee_id']?.toString(),
      referralDoctorId: json['referral_doctor_id']?.toString() ?? '',
      areaId: json['area_id']?.toString(),
      visitedAt: _toDate(json['visited_at']) ?? DateTime.now(),
      latitude: _toDoubleOrNull(json['latitude']),
      longitude: _toDoubleOrNull(json['longitude']),
      distanceFromDoctorMeters: _toDoubleOrNull(json['distance_from_doctor_meters']),
      geofenceRadiusMeters: _toInt(json['geofence_radius_meters']),
      geoVerified: json['geo_verified'] == true,
      visitSource: json['visit_source']?.toString() ?? 'mobile_app',
      visitPurpose: json['visit_purpose']?.toString(),
      visitNotes: json['visit_notes']?.toString(),
      nextFollowUpDate: _toDate(json['next_follow_up_date']),
      createdAt: _toDate(json['created_at']),
      updatedAt: _toDate(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hospital_id': hospitalId,
      'marketing_employee_id': marketingEmployeeId,
      'referral_doctor_id': referralDoctorId,
      'area_id': areaId,
      'visited_at': visitedAt.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'distance_from_doctor_meters': distanceFromDoctorMeters,
      'geofence_radius_meters': geofenceRadiusMeters,
      'geo_verified': geoVerified,
      'visit_source': visitSource,
      'visit_purpose': visitPurpose,
      'visit_notes': visitNotes,
      'next_follow_up_date': _dateOnly(nextFollowUpDate),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}

class PatientReferral {
  const PatientReferral({
    required this.id,
    required this.hospitalId,
    required this.patientId,
    this.patientUhid,
    this.patientName,
    required this.referralDoctorId,
    this.marketingEmployeeId,
    required this.referralDate,
    this.opdRegistrationId,
    this.ipdAdmissionId,
    this.source = 'admin_entry',
    this.notes,
    this.createdAt,
  });

  final String id;
  final String hospitalId;
  final String patientId;

  /// Resolved by the repository from `patients` (embedded select) so the
  /// referrals screen can show patient name + UHID without N+1 lookups.
  final String? patientUhid;
  final String? patientName;

  final String referralDoctorId;
  final String? marketingEmployeeId;
  final DateTime referralDate;
  final String? opdRegistrationId;
  final String? ipdAdmissionId;
  final String source;
  final String? notes;
  final DateTime? createdAt;

  factory PatientReferral.fromJson(Map<String, dynamic> json) {
    final patient = _embeddedMap(json['patients']);
    return PatientReferral(
      id: json['id']?.toString() ?? '',
      hospitalId: json['hospital_id']?.toString() ?? '',
      patientId: json['patient_id']?.toString() ?? '',
      patientUhid: patient?['uhid']?.toString(),
      patientName: _patientName(patient),
      referralDoctorId: json['referral_doctor_id']?.toString() ?? '',
      marketingEmployeeId: json['marketing_employee_id']?.toString(),
      referralDate: _toDate(json['referral_date']) ?? DateTime.now(),
      opdRegistrationId: json['opd_registration_id']?.toString(),
      ipdAdmissionId: json['ipd_admission_id']?.toString(),
      source: json['source']?.toString() ?? 'admin_entry',
      notes: json['notes']?.toString(),
      createdAt: _toDate(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hospital_id': hospitalId,
      'patient_id': patientId,
      'referral_doctor_id': referralDoctorId,
      'marketing_employee_id': marketingEmployeeId,
      'referral_date': _dateOnly(referralDate),
      'opd_registration_id': opdRegistrationId,
      'ipd_admission_id': ipdAdmissionId,
      'source': source,
      'notes': notes,
      'created_at': createdAt?.toIso8601String(),
    };
  }
}

// ---------------------------------------------------------------------------
// Analytics summary models (produced by MarketingAnalyticsService, pure)
// ---------------------------------------------------------------------------

class AreaActivitySummary {
  const AreaActivitySummary({
    required this.areaId,
    required this.areaName,
    required this.referralDoctorCount,
    required this.visitedToday,
    required this.visitedThisMonth,
    required this.referralsThisMonth,
  });

  final String areaId;
  final String areaName;
  final int referralDoctorCount;
  final int visitedToday;
  final int visitedThisMonth;
  final int referralsThisMonth;
}

class ReferralDoctorSummary {
  const ReferralDoctorSummary({
    required this.referralDoctorId,
    required this.referralDoctorName,
    this.clinicName,
    this.areaId,
    this.areaName,
    required this.totalVisits,
    this.lastVisit,
    required this.visitsThisMonth,
    required this.totalReferrals,
    required this.referralsThisMonth,
    required this.locationVerified,
  });

  final String referralDoctorId;
  final String referralDoctorName;
  final String? clinicName;
  final String? areaId;
  final String? areaName;
  final int totalVisits;
  final DateTime? lastVisit;
  final int visitsThisMonth;
  final int totalReferrals;
  final int referralsThisMonth;
  final bool locationVerified;
}

class MarketingDashboardSummary {
  const MarketingDashboardSummary({
    required this.todayVisits,
    required this.geoVerifiedVisitsToday,
    required this.referralDoctorsVisitedToday,
    required this.referralsToday,
    required this.referralsThisMonth,
    required this.areaActivity,
    required this.topReferralDoctorsThisMonth,
    required this.recentVisits,
  });

  final int todayVisits;
  final int geoVerifiedVisitsToday;
  final int referralDoctorsVisitedToday;
  final int referralsToday;
  final int referralsThisMonth;
  final List<AreaActivitySummary> areaActivity;
  final List<ReferralDoctorSummary> topReferralDoctorsThisMonth;
  final List<MarketingVisit> recentVisits;
}

/// Aggregated detail for the referral-doctor detail screen. Never loads an
/// entire lifetime of history rows — the provider passes a bounded window and
/// only lifetime *counts* are queried.
class ReferralDoctorDetail {
  const ReferralDoctorDetail({
    required this.doctor,
    required this.totalVisits,
    required this.visitsThisMonth,
    required this.patientsReferred,
    required this.patientsReferredThisMonth,
    this.lastVisit,
    this.recentVisits = const [],
    this.recentReferrals = const [],
  });

  final ReferralDoctor doctor;
  final int totalVisits;
  final int visitsThisMonth;
  final int patientsReferred;
  final int patientsReferredThisMonth;
  final DateTime? lastVisit;
  final List<MarketingVisit> recentVisits;
  final List<PatientReferral> recentReferrals;
}

// ---------------------------------------------------------------------------
// JSON helpers (shared by the models above)
// ---------------------------------------------------------------------------

String? _embeddedName(dynamic value) {
  if (value is Map) {
    return value['name']?.toString();
  }
  if (value is List && value.isNotEmpty && value.first is Map) {
    return (value.first as Map)['name']?.toString();
  }
  return null;
}

DateTime? _toDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

double? _toDoubleOrNull(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim());
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

String? _dateOnly(DateTime? value) {
  if (value == null) return null;
  final y = value.year.toString().padLeft(4, '0');
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

Map<String, dynamic>? _embeddedMap(dynamic value) {
  if (value is Map) return value.cast<String, dynamic>();
  if (value is List && value.isNotEmpty && value.first is Map) {
    return (value.first as Map).cast<String, dynamic>();
  }
  return null;
}

String? _patientName(Map<String, dynamic>? patient) {
  if (patient == null) return null;
  final first = patient['first_name']?.toString() ?? '';
  final last = patient['last_name']?.toString() ?? '';
  final name = '$first $last'.trim();
  return name.isEmpty ? null : name;
}
