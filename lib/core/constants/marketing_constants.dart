/// Shared constants for the PRO / Marketing module.
///
/// Single source of truth for the default geofence radius so the value is
/// never hardcoded in multiple screens/services.
class MarketingConstants {
  MarketingConstants._();

  /// Default geofence radius applied to a referral doctor's clinic location.
  /// Used as the fallback when creating/editing referral doctors and as the
  /// radius shown before a location is first verified.
  static const int defaultGeofenceRadiusMeters = 150;

  /// Practitioner categorization only — NOT a legal eligibility list.
  static const List<String> practitionerTypes = [
    'registered_practitioner',
    'local_practitioner',
    'clinic',
    'other',
  ];

  static const String practitionerTypeRegistered = 'registered_practitioner';
  static const String practitionerTypeLocal = 'local_practitioner';
  static const String practitionerTypeClinic = 'clinic';
  static const String practitionerTypeOther = 'other';

  /// Visit sources (extensible — the DB has no CHECK constraint).
  static const String visitSourceMobileApp = 'mobile_app';
  static const String visitSourceAdminEntry = 'admin_entry';

  /// Referral sources (extensible).
  static const String referralSourceMobileApp = 'mobile_app';
  static const String referralSourceAdminEntry = 'admin_entry';
}
