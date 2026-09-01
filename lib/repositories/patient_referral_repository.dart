import '../models/marketing_models.dart';

/// Focused persistence contract for patient referral history.
///
/// Referral attribution is EVENT / VISIT based. The patient master has no
/// permanent referral-doctor field; this table is the history.
///
/// ISP: patient-referral queries/creation only.
abstract class PatientReferralRepository {
  /// Referrals in `[from, to)` — `to` is exclusive. Newest first.
  Future<List<PatientReferral>> getReferralsForRange({
    required String hospitalId,
    required DateTime from,
    required DateTime to,
  });

  /// Referrals for one referral doctor in `[from, to)`, newest first.
  Future<List<PatientReferral>> getReferralsForDoctorRange({
    required String hospitalId,
    required String doctorId,
    required DateTime from,
    required DateTime to,
  });

  /// Lifetime referral count for one referral doctor (single count query).
  Future<int> countReferralsForDoctor({
    required String hospitalId,
    required String doctorId,
  });

  Future<PatientReferral> createReferral({
    required String hospitalId,
    required PatientReferral referral,
  });
}
