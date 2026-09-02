/// Presentation-level display-name helpers.
///
/// These functions only clean strings for the UI. They never persist values,
/// never hit the network/database and never change backend data — the stored
/// values stay exactly as they were written.
library;

final RegExp _leadingDoctorPrefix = RegExp(
  r'^(?:Dr\b\.?\s*)+',
  caseSensitive: false,
);

/// Full UUID (8-4-4-4-12 hex). Internal record ids must never be shown inside
/// patient context cards.
final RegExp _uuidToken = RegExp(
  r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
);

/// Longer hex run (covers truncated ids / id fragments such as `94ea14b8…`).
final RegExp _longHexToken = RegExp(r'\b[0-9a-fA-F]{8,}\b');

final RegExp _edgeSeparators = RegExp(r'^[\s\-–—|/\\,.;:]+|[\s\-–—|/\\,.;:]+$');

/// Cleans a doctor name for display in patient context cards.
///
/// Rules:
/// * Strips any leading `Dr.`/`Dr` repetitions so the caller can add exactly
///   one prefix without ever producing `Dr. Dr. …`.
/// * Removes raw UUID / long hex tokens (internal ids).
/// * If [department] is supplied and appears as a trailing token, removes it —
///   the department is shown on its own line on context cards.
/// * Collapses whitespace and trims stray separators left behind.
///
/// Returns `''` when nothing displayable remains; the caller decides the final
/// fallback (e.g. `N/A`) and whether to add the `Dr.` prefix.
String cleanDoctorDisplayName(String? raw, {String? department}) {
  var name = (raw ?? '').trim();
  if (name.isEmpty) return '';

  name = name.replaceFirst(_leadingDoctorPrefix, '').trim();
  name = name.replaceAll(_uuidToken, ' ');
  name = name.replaceAll(_longHexToken, ' ');
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

  final dept = (department ?? '').trim();
  if (dept.isNotEmpty) {
    // Drop a trailing department token ("Amit Sharma Cardiology" →
    // "Amit Sharma") so the card doesn't repeat it on the department line.
    final trailingDept = RegExp(
      '${RegExp.escape(dept)}\\s*\$',
      caseSensitive: false,
    );
    name = name.replaceFirst(trailingDept, ' ').trim();
    // If the "name" was really only the department, nothing remains.
    if (name.toLowerCase() == dept.toLowerCase()) name = '';
  }

  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  name = name.replaceAll(_edgeSeparators, '').trim();
  return name;
}
