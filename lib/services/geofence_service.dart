import 'dart:math';

/// ---------------------------------------------------------------------------
/// Pure geofence verification service.
///
/// Input:
///   * doctor latitude / longitude (the stored official clinic location)
///   * employee current latitude / longitude (captured at the visit punch)
///   * allowed radius in meters
///
/// Output: [GeoFenceResult] with the Haversine distance, the allowed radius
/// and whether the employee is inside the geofence.
///
/// This class has NO Supabase, NO Flutter UI and NO Android GPS dependency.
/// ---------------------------------------------------------------------------
class GeoFenceResult {
  const GeoFenceResult({
    required this.distanceMeters,
    required this.allowedRadiusMeters,
    required this.isInside,
  });

  final double distanceMeters;
  final double allowedRadiusMeters;
  final bool isInside;
}

class GeoFenceService {
  const GeoFenceService();

  /// Runs the geofence check. A distance exactly equal to the radius counts
  /// as inside (inclusive boundary).
  GeoFenceResult check({
    required double doctorLatitude,
    required double doctorLongitude,
    required double employeeLatitude,
    required double employeeLongitude,
    required double allowedRadiusMeters,
  }) {
    final distance = distanceInMeters(
      doctorLatitude,
      doctorLongitude,
      employeeLatitude,
      employeeLongitude,
    );
    return GeoFenceResult(
      distanceMeters: distance,
      allowedRadiusMeters: allowedRadiusMeters,
      isInside: distance <= allowedRadiusMeters,
    );
  }

  /// Haversine great-circle distance between two coordinates, in meters.
  double distanceInMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _radians(lat2 - lat1);
    final dLon = _radians(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_radians(lat1)) *
            cos(_radians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  double _radians(double degrees) => degrees * pi / 180.0;
}
