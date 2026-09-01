import 'package:flutter_test/flutter_test.dart';

import 'package:abdm_hims/models/marketing_models.dart';
import 'package:abdm_hims/services/marketing_analytics_service.dart';

/// Pure unit tests for [MarketingAnalyticsService] — no Supabase, no widgets.
void main() {
  const service = MarketingAnalyticsService();
  final now = DateTime(2026, 9, 15, 12, 0);

  MarketingArea area(String id, String name) =>
      MarketingArea(id: id, hospitalId: 'h1', name: name);

  ReferralDoctor doctor(
    String id,
    String name, {
    String? areaId,
    String? areaName,
  }) {
    return ReferralDoctor(
      id: id,
      hospitalId: 'h1',
      name: name,
      clinicName: 'Clinic $name',
      areaId: areaId,
      areaName: areaName,
      locationVerified: true,
    );
  }

  MarketingVisit visit(
    String id,
    String doctorId,
    DateTime visitedAt, {
    String? areaId,
    bool geoVerified = true,
  }) {
    return MarketingVisit(
      id: id,
      hospitalId: 'h1',
      referralDoctorId: doctorId,
      areaId: areaId,
      visitedAt: visitedAt,
      geoVerified: geoVerified,
    );
  }

  PatientReferral referral(
    String id,
    String doctorId,
    DateTime referralDate,
  ) {
    return PatientReferral(
      id: id,
      hospitalId: 'h1',
      patientId: 'p-$id',
      referralDoctorId: doctorId,
      referralDate: referralDate,
    );
  }

  group('referralDoctorSummaries', () {
    test('doctor-wise visit counts are aggregated correctly', () {
      final doctors = [
        doctor('d1', 'Doctor A', areaId: 'a1', areaName: 'Govardhan'),
        doctor('d2', 'Doctor B', areaId: 'a2', areaName: 'Vrindavan'),
      ];

      final visits = [
        visit('v1', 'd1', DateTime(2026, 9, 1)),
        visit('v2', 'd1', DateTime(2026, 9, 2)),
        visit('v3', 'd1', DateTime(2026, 8, 15)),
        visit('v4', 'd2', DateTime(2026, 9, 3)),
      ];

      final summaries = service.referralDoctorSummaries(
        doctors: doctors,
        visits: visits,
        referrals: const [],
        now: now,
      );

      final byId = {for (final s in summaries) s.referralDoctorId: s};
      expect(byId['d1']!.totalVisits, 3);
      expect(byId['d1']!.visitsThisMonth, 2);
      expect(byId['d2']!.totalVisits, 1);
      expect(byId['d2']!.visitsThisMonth, 1);
      expect(byId['d1']!.areaName, 'Govardhan');
    });

    test('last visit is the newest visit timestamp', () {
      final doctors = [doctor('d1', 'Doctor A', areaId: 'a1')];
      final visits = [
        visit('v1', 'd1', DateTime(2026, 9, 1, 10)),
        visit('v2', 'd1', DateTime(2026, 9, 12, 15)),
      ];

      final summary = service
          .referralDoctorSummaries(
            doctors: doctors,
            visits: visits,
            referrals: const [],
            now: now,
          )
          .single;

      expect(summary.lastVisit, DateTime(2026, 9, 12, 15));
    });

    test('referral counts are aggregated per doctor', () {
      final doctors = [
        doctor('d1', 'Doctor A', areaId: 'a1'),
        doctor('d2', 'Doctor B', areaId: 'a2'),
      ];

      final referrals = [
        referral('r1', 'd1', DateTime(2026, 9, 1)),
        referral('r2', 'd1', DateTime(2026, 9, 2)),
        referral('r3', 'd1', DateTime(2026, 8, 20)),
        referral('r4', 'd2', DateTime(2026, 9, 3)),
      ];

      final summaries = service.referralDoctorSummaries(
        doctors: doctors,
        visits: const [],
        referrals: referrals,
        now: now,
      );

      final byId = {for (final s in summaries) s.referralDoctorId: s};
      expect(byId['d1']!.totalReferrals, 3);
      expect(byId['d1']!.referralsThisMonth, 2);
      expect(byId['d2']!.totalReferrals, 1);
      expect(byId['d2']!.referralsThisMonth, 1);
    });
  });

  group('areaSummaries', () {
    test('area-wise visit counts include zero-activity areas', () {
      final areas = [
        area('a1', 'Govardhan'),
        area('a2', 'Vrindavan'),
        area('a3', 'Barsana'),
      ];
      final doctors = [
        doctor('d1', 'Doctor A', areaId: 'a1', areaName: 'Govardhan'),
        doctor('d2', 'Doctor B', areaId: 'a2', areaName: 'Vrindavan'),
      ];
      final visits = [
        visit('v1', 'd1', DateTime(2026, 9, 1), areaId: 'a1'),
        visit('v2', 'd1', DateTime(2026, 9, 15), areaId: 'a1'),
        visit('v3', 'd2', DateTime(2026, 9, 3), areaId: 'a2'),
      ];

      final summaries = service.areaSummaries(
        doctors: doctors,
        visits: visits,
        referrals: const [],
        areas: areas,
        now: now,
      );

      final byId = {for (final s in summaries) s.areaId: s};
      expect(byId['a1']!.visitedThisMonth, 2);
      expect(byId['a2']!.visitedThisMonth, 1);
      expect(byId['a3']!.visitedThisMonth, 0);
      expect(byId['a1']!.referralDoctorCount, 1);
      expect(byId['a3']!.referralDoctorCount, 0);
    });

    test('area referral counts come from the doctor of each referral', () {
      final areas = [area('a1', 'Govardhan')];
      final doctors = [
        doctor('d1', 'Doctor A', areaId: 'a1', areaName: 'Govardhan'),
      ];
      final referrals = [
        referral('r1', 'd1', DateTime(2026, 9, 1)),
        referral('r2', 'd1', DateTime(2026, 9, 2)),
        referral('r3', 'd1', DateTime(2026, 8, 25)),
      ];

      final summary = service
          .areaSummaries(
            doctors: doctors,
            visits: const [],
            referrals: referrals,
            areas: areas,
            now: now,
          )
          .single;

      expect(summary.referralsThisMonth, 2);
    });
  });

  group('buildDashboard', () {
    test('dashboard summary counts today and this-month totals', () {
      final doctors = [
        doctor('d1', 'Doctor A', areaId: 'a1', areaName: 'Govardhan'),
      ];
      final visits = [
        visit('v1', 'd1', DateTime(2026, 9, 15, 9), geoVerified: true),
        visit('v2', 'd1', DateTime(2026, 9, 15, 11), geoVerified: false),
        visit('v3', 'd1', DateTime(2026, 9, 10)),
        visit('v4', 'd1', DateTime(2026, 8, 20)),
      ];
      final referrals = [
        referral('r1', 'd1', DateTime(2026, 9, 15)),
        referral('r2', 'd1', DateTime(2026, 9, 1)),
        referral('r3', 'd1', DateTime(2026, 8, 1)),
      ];

      final summary = service.buildDashboard(
        doctors: doctors,
        visits: visits,
        referrals: referrals,
        now: now,
      );

      expect(summary.todayVisits, 2);
      expect(summary.geoVerifiedVisitsToday, 1);
      expect(summary.referralDoctorsVisitedToday, 1);
      expect(summary.referralsToday, 1);
      expect(summary.referralsThisMonth, 2);
      expect(summary.recentVisits.length, 2);
      expect(summary.topReferralDoctorsThisMonth.single.visitsThisMonth, 3);
    });
  });
}
