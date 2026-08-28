/// ---------------------------------------------------------------------------
/// Personalized User Tag System — typed models.
///
/// The Supabase rows are plain JSON maps; these classes add type-safety for
/// the UI layer. Every model keeps `fromJson`/`toJson` so it can round-trip
/// through Supabase.
/// ---------------------------------------------------------------------------
library;

/// Canonical field contexts used by the personalized tag system.
///
/// Each context has its own per-user tag collection, so a user can maintain
/// different tag vocabularies for patients, OPD visits, IPD admissions, etc.
class PersonalizedTagFields {
  PersonalizedTagFields._();

  static const String patient = 'patient';
  static const String opd = 'opd';
  static const String ipd = 'ipd';
  static const String compliance = 'compliance';

  // OPD Consultation → Investigations tab "other" fields.
  static const String opdLab = 'opd_lab';
  static const String opdRadiology = 'opd_radiology';
  static const String opdOtherInvestigations = 'opd_other_investigations';

  /// All known field contexts. Add new contexts here as more forms adopt tags.
  static const List<String> all = [
    patient,
    opd,
    ipd,
    compliance,
    opdLab,
    opdRadiology,
    opdOtherInvestigations,
  ];

  /// Validates a context value coming from a form so an unknown string never
  /// reaches the database.
  static bool isValid(String? value) =>
      value != null && value.isNotEmpty && all.contains(value);
}

/// Entity types the tags can be attached to. These mirror the Supabase table
/// names (or logical record kinds) and are stored in `entity_tags.entity_type`.
class PersonalizedTagEntityTypes {
  PersonalizedTagEntityTypes._();

  static const String patient = 'patient';
  static const String opdRegistration = 'opd_registration';
  static const String ipdAdmission = 'ipd_admission';

  /// Generic kind used by prescription/consultation fields where tags are part
  /// of the payload rather than linked to one record id.
  static const String prescription = 'prescription';
}

/// One tag in a user's personal collection (`user_tags` row).
class PersonalizedTag {
  const PersonalizedTag({
    required this.id,
    required this.userId,
    required this.fieldKey,
    required this.name,
    this.usageCount = 0,
    this.lastUsedAt,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String fieldKey;
  final String name;
  final int usageCount;
  final DateTime? lastUsedAt;
  final DateTime? createdAt;

  factory PersonalizedTag.fromJson(Map<String, dynamic> json) {
    return PersonalizedTag(
      id: json['id']?.toString() ?? '',
      userId: json['user_id']?.toString() ?? '',
      fieldKey: json['field_key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      usageCount: int.tryParse(json['usage_count']?.toString() ?? '') ?? 0,
      lastUsedAt: DateTime.tryParse(json['last_used_at']?.toString() ?? ''),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'user_id': userId,
    'field_key': fieldKey,
    'name': name,
    'usage_count': usageCount,
    'last_used_at': lastUsedAt?.toIso8601String(),
    'created_at': createdAt?.toIso8601String(),
  };

  /// Frequency label shown next to history suggestions ("used 12 times").
  String get usageLabel => usageCount <= 0
      ? 'new'
      : usageCount == 1
      ? 'used once'
      : 'used $usageCount times';

  @override
  String toString() => 'PersonalizedTag($fieldKey: $name, used $usageCount)';
}
