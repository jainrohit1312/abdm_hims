import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../models/marketing_models.dart';
import '../services/database_service.dart';
import 'patient_referral_repository.dart';

/// Supabase implementation of [PatientReferralRepository].
///
/// This is the ONLY class in the marketing module that knows the Supabase
/// patient-referral syntax. Every query is hospital scoped. The patient
/// master is never modified with a permanent referral-doctor field.
class SupabasePatientReferralRepository implements PatientReferralRepository {
  SupabasePatientReferralRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<PatientReferral>> getReferralsForRange({
    required String hospitalId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.patientReferralsTable)
          .select('*, patients(uhid, first_name, last_name)')
          .eq('hospital_id', hospitalId)
          .gte('referral_date', _dateOnly(from))
          .lt('referral_date', _dateOnly(to))
          .order('referral_date', ascending: false)
          .order('created_at', ascending: false),
    );
    return rows.map(PatientReferral.fromJson).toList();
  }

  @override
  Future<List<PatientReferral>> getReferralsForDoctorRange({
    required String hospitalId,
    required String doctorId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.patientReferralsTable)
          .select('*, patients(uhid, first_name, last_name)')
          .eq('hospital_id', hospitalId)
          .eq('referral_doctor_id', doctorId)
          .gte('referral_date', _dateOnly(from))
          .lt('referral_date', _dateOnly(to))
          .order('referral_date', ascending: false)
          .order('created_at', ascending: false),
    );
    return rows.map(PatientReferral.fromJson).toList();
  }

  @override
  Future<int> countReferralsForDoctor({
    required String hospitalId,
    required String doctorId,
  }) async {
    final response = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.patientReferralsTable)
          .select('id')
          .eq('hospital_id', hospitalId)
          .eq('referral_doctor_id', doctorId)
          .count(CountOption.exact),
    );
    return response.count;
  }

  @override
  Future<PatientReferral> createReferral({
    required String hospitalId,
    required PatientReferral referral,
  }) async {
    final row = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.patientReferralsTable)
          .insert(_referralPayload(referral, hospitalId: hospitalId)
            ..['created_at'] = DateTime.now().toUtc().toIso8601String())
          .select()
          .single(),
    );
    return PatientReferral.fromJson(row);
  }

  Map<String, dynamic> _referralPayload(
    PatientReferral referral, {
    required String hospitalId,
  }) {
    return {
      'hospital_id': hospitalId,
      'patient_id': referral.patientId,
      'referral_doctor_id': referral.referralDoctorId,
      'marketing_employee_id': referral.marketingEmployeeId,
      'referral_date': _dateOnly(referral.referralDate),
      'opd_registration_id': referral.opdRegistrationId,
      'ipd_admission_id': referral.ipdAdmissionId,
      'source': referral.source,
      'notes': referral.notes,
    };
  }

  String _dateOnly(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
