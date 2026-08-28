import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import '../models/personalized_tag_models.dart';
import 'database_service.dart';

/// ---------------------------------------------------------------------------
/// Personalized User Tag System — data service.
///
/// Handles all Supabase access for the per-user tag collections:
/// * `user_tags`   — the user's personal tag master list (per field context)
/// * `entity_tags` — which tags are applied to which records
///
/// Everything is **user-scoped**: tags are stored per user (never shared
/// across users) and suggestions are ordered by the user's own usage
/// frequency, which gives the UI its "AI learns your preferences" feel.
/// ---------------------------------------------------------------------------
class PersonalizedTagService {
  PersonalizedTagService(this._client);

  final SupabaseClient _client;

  static const int maxNameLength = 120;
  static const int maxTagsPerEntity = 20;

  // ---------------------------------------------------------------------------
  // Tag collection (user_tags)
  // ---------------------------------------------------------------------------

  /// All tags in the user's personal collection for [fieldKey], ordered by
  /// usage frequency (most-used first), then most recently used.
  Future<List<PersonalizedTag>> getUserTags(
    String userId,
    String fieldKey,
  ) async {
    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.userTagsTable)
            .select()
            .eq('user_id', userId)
            .eq('field_key', fieldKey)
            .order('usage_count', ascending: false)
            .order('last_used_at', ascending: false)
            .order('name', ascending: true),
      );
      return response
          .map((row) => PersonalizedTag.fromJson(row))
          .toList();
    } catch (e) {
      AppLogger.e('Error fetching user tags for $fieldKey', e);
      return [];
    }
  }

  /// Auto-suggest list for the inline dropdown.
  ///
  /// Returns the user's history tags for [fieldKey] that contain [query]
  /// (case-insensitive), excluding [excludeNames], ordered by usage frequency.
  /// When [query] is empty the most-used tags are returned so the field can
  /// show "Based on your history..." even before the user types.
  Future<List<PersonalizedTag>> suggest(
    String userId,
    String fieldKey, {
    String query = '',
    List<String> excludeNames = const [],
  }) async {
    final tags = await getUserTags(userId, fieldKey);
    final normalizedQuery = query.trim().toLowerCase();
    final excluded = excludeNames.map((n) => n.trim().toLowerCase()).toSet();

    final matches = <PersonalizedTag>[];
    for (final tag in tags) {
      final name = tag.name.toLowerCase();
      if (excluded.contains(name)) continue;
      if (normalizedQuery.isNotEmpty && !name.contains(normalizedQuery)) {
        continue;
      }
      matches.add(tag);
    }
    return matches;
  }

  /// Ensures [name] exists in the user's personal collection for [fieldKey]
  /// and records one usage (usage_count + 1, last_used_at = now).
  ///
  /// Returns the existing (now bumped) or freshly created tag. New tags are
  /// added to the user's personal collection automatically — that is how the
  /// system "learns" new vocabulary.
  Future<PersonalizedTag> ensureTag(
    String userId,
    String fieldKey,
    String name,
  ) async {
    final normalized = normalizeTagName(name);
    if (normalized.isEmpty) {
      throw ArgumentError('Tag name cannot be empty');
    }

    final existing = await _findTagByName(userId, fieldKey, normalized);
    if (existing != null) {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.userTagsTable)
            .update({
              'usage_count': existing.usageCount + 1,
              'last_used_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', existing.id)
            .select()
            .single(),
      );
      return PersonalizedTag.fromJson(response);
    }

    try {
      final response = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.userTagsTable)
            .insert({
              'user_id': userId,
              'field_key': fieldKey,
              'name': normalized,
              'usage_count': 1,
              'last_used_at': DateTime.now().toUtc().toIso8601String(),
            })
            .select()
            .single(),
      );
      return PersonalizedTag.fromJson(response);
    } catch (e) {
      // A parallel insert may have won the race — resolve by name and bump it.
      AppLogger.w('Tag insert race for "$normalized", resolving existing: $e');
      final raced = await _findTagByName(userId, fieldKey, normalized);
      if (raced != null) {
        return ensureTag(userId, fieldKey, normalized);
      }
      rethrow;
    }
  }

  /// Deletes a tag from the user's collection. Linked entity rows cascade.
  Future<void> deleteTag(String tagId) async {
    await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.userTagsTable)
          .delete()
          .eq('id', tagId),
    );
  }

  // ---------------------------------------------------------------------------
  // Entity links (entity_tags)
  // ---------------------------------------------------------------------------

  /// Tags currently applied to one record, sorted by name.
  Future<List<PersonalizedTag>> getEntityTags(
    String userId,
    String entityType,
    String entityId,
  ) async {
    try {
      final links = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.entityTagsTable)
            .select('tag_id')
            .eq('user_id', userId)
            .eq('entity_type', entityType)
            .eq('entity_id', entityId),
      );

      final tagIds = <String>[
        for (final link in links)
          if (link['tag_id']?.toString().isNotEmpty == true)
            link['tag_id'].toString(),
      ];
      if (tagIds.isEmpty) return [];

      final tags = await DatabaseService.fetchWithRetry(
        () => _client
            .from(ApiConstants.userTagsTable)
            .select()
            .inFilter('id', tagIds)
            .order('name', ascending: true),
      );
      return tags.map((row) => PersonalizedTag.fromJson(row)).toList();
    } catch (e) {
      AppLogger.e('Error fetching entity tags', e);
      return [];
    }
  }

  /// Replaces the tag set of one record with [names].
  ///
  /// * Every name is first ensured in the user's personal collection and its
  ///   usage counter is bumped — so the suggestion order evolves with usage.
  /// * Removed tags stay in the user's collection (history is never lost),
  ///   only the link to this record is removed.
  Future<List<PersonalizedTag>> setEntityTags({
    required String userId,
    required String fieldKey,
    required String entityType,
    required String entityId,
    required List<String> names,
  }) async {
    final normalized = <String>[];
    for (final name in names) {
      final clean = normalizeTagName(name);
      if (clean.isEmpty || normalized.contains(clean)) continue;
      normalized.add(clean);
    }
    if (normalized.length > maxTagsPerEntity) {
      normalized.removeRange(maxTagsPerEntity, normalized.length);
    }

    // 1. Ensure every desired tag exists and record usage.
    final wantedTagIds = <String>[];
    for (final name in normalized) {
      final tag = await ensureTag(userId, fieldKey, name);
      wantedTagIds.add(tag.id);
    }

    // 2. Load current links for this record.
    final existing = await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.entityTagsTable)
          .select('id, tag_id')
          .eq('user_id', userId)
          .eq('entity_type', entityType)
          .eq('entity_id', entityId),
    );
    final existingTagIds = <String>{};
    for (final row in existing) {
      final tagId = row['tag_id']?.toString();
      if (tagId != null && tagId.isNotEmpty) existingTagIds.add(tagId);
    }

    // 3. Remove links that are no longer wanted.
    for (final row in existing) {
      final rowId = row['id']?.toString();
      final tagId = row['tag_id']?.toString();
      if (rowId == null || tagId == null) continue;
      if (!wantedTagIds.contains(tagId)) {
        await DatabaseService.fetchWithRetry(
          () => _client
              .from(ApiConstants.entityTagsTable)
              .delete()
              .eq('id', rowId),
        );
      }
    }

    // 4. Insert missing links.
    for (final tagId in wantedTagIds) {
      if (existingTagIds.contains(tagId)) continue;
      await DatabaseService.fetchWithRetry(
        () => _client.from(ApiConstants.entityTagsTable).insert({
          'tag_id': tagId,
          'user_id': userId,
          'entity_type': entityType,
          'entity_id': entityId,
        }),
      );
    }

    return getEntityTags(userId, entityType, entityId);
  }

  /// Removes all tags from one record (used when a record is deleted, when
  /// the owning form supports it).
  Future<void> clearEntityTags({
    required String userId,
    required String entityType,
    required String entityId,
  }) async {
    await DatabaseService.fetchWithRetry(
      () => _client
          .from(ApiConstants.entityTagsTable)
          .delete()
          .eq('user_id', userId)
          .eq('entity_type', entityType)
          .eq('entity_id', entityId),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Trims, collapses inner whitespace and caps the length of a tag name.
  static String normalizeTagName(String name) {
    var cleaned = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.length > maxNameLength) {
      cleaned = cleaned.substring(0, maxNameLength);
    }
    return cleaned.trim();
  }

  Future<PersonalizedTag?> _findTagByName(
    String userId,
    String fieldKey,
    String name,
  ) async {
    final tags = await getUserTags(userId, fieldKey);
    final target = name.toLowerCase();
    for (final tag in tags) {
      if (tag.name.toLowerCase() == target) return tag;
    }
    return null;
  }
}
