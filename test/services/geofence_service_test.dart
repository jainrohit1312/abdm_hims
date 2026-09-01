import 'package:flutter_test/flutter_test.dart';

import 'package:abdm_hims/services/geofence_service.dart';

/// Pure unit tests for [GeoFenceService] — no Supabase, no widgets.
void main() {
  const service = GeoFenceService();

  // Base coordinates: a clinic near Mathura / Vrindavan.
  const clinicLat = 27.4924;
  const clinicLng = 77.6737;

  group('GeoFenceService.check', () {
    test('employee inside radius is allowed', () {
      // ~50 m north of the clinic (1 degree latitude ≈ 111,320 m).
      final result = service.check(
        doctorLatitude: clinicLat,
        doctorLongitude: clinicLng,
        employeeLatitude: clinicLat + 50 / 111320,
        employeeLongitude: clinicLng,
        allowedRadiusMeters: 150,
      );

      expect(result.isInside, isTrue);
      expect(result.allowedRadiusMeters, 150);
      expect(result.distanceMeters, lessThan(60));
      expect(result.distanceMeters, greaterThan(40));
    });

    test('employee outside radius is rejected', () {
      // ~500 m north of the clinic.
      final result = service.check(
        doctorLatitude: clinicLat,
        doctorLongitude: clinicLng,
        employeeLatitude: clinicLat + 500 / 111320,
        employeeLongitude: clinicLng,
        allowedRadiusMeters: 150,
      );

      expect(result.isInside, isFalse);
      expect(result.distanceMeters, greaterThan(450));
      expect(result.distanceMeters, lessThan(550));
    });

    test('radius boundary: exactly at the radius is inside (inclusive)', () {
      final exactDistance = service.distanceInMeters(
        clinicLat,
        clinicLng,
        clinicLat + 150 / 111320,
        clinicLng,
      );

      final result = service.check(
        doctorLatitude: clinicLat,
        doctorLongitude: clinicLng,
        employeeLatitude: clinicLat + 150 / 111320,
        employeeLongitude: clinicLng,
        allowedRadiusMeters: exactDistance,
      );

      expect(result.isInside, isTrue);
      expect(result.distanceMeters, closeTo(exactDistance, 0.5));
    });

    test('radius boundary: one meter beyond the radius is outside', () {
      final exactDistance = service.distanceInMeters(
        clinicLat,
        clinicLng,
        clinicLat + 150 / 111320,
        clinicLng,
      );

      final result = service.check(
        doctorLatitude: clinicLat,
        doctorLongitude: clinicLng,
        employeeLatitude: clinicLat + 150 / 111320,
        employeeLongitude: clinicLng,
        allowedRadiusMeters: exactDistance - 1,
      );

      expect(result.isInside, isFalse);
    });
  });

  group('GeoFenceService.distanceInMeters', () {
    test('same point has zero distance', () {
      expect(
        service.distanceInMeters(clinicLat, clinicLng, clinicLat, clinicLng),
        0,
      );
    });

    test('distance is symmetric', () {
      final a = service.distanceInMeters(
        clinicLat,
        clinicLng,
        clinicLat + 0.001,
        clinicLng + 0.001,
      );
      final b = service.distanceInMeters(
        clinicLat + 0.001,
        clinicLng + 0.001,
        clinicLat,
        clinicLng,
      );
      expect(a, closeTo(b, 0.0001));
    });
  });
}
