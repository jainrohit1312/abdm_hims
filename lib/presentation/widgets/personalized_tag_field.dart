import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../models/personalized_tag_models.dart';
import '../../services/personalized_tag_service.dart';

/// ---------------------------------------------------------------------------
/// PersonalizedTagField — the reusable "AI-personalized" tag input.
///
/// * Shows the note "✨ These tags are customized for you" under the label.
/// * Renders the selected tags as removable chips.
/// * Provides an inline type-ahead dropdown whose top section is
///   "Based on your history..." (the user's own tag collection ordered by
///   usage frequency) plus a "+ Create `<query>`" row for new tags.
///
/// Tags are stored **per user + per field context** (`fieldKey`). The widget
/// itself only manages the selected names; the owning form persists them via
/// [PersonalizedTagService.setEntityTags] once the record id is known.
///
/// Use a [GlobalKey] of type [PersonalizedTagFieldState] to read the current
/// selection from the form before saving:
///
/// ```dart
/// final _tagsKey = GlobalKey<PersonalizedTagFieldState>();
/// ...
/// PersonalizedTagField(
///   key: _tagsKey,
///   fieldKey: PersonalizedTagFields.patient,
///   entityType: PersonalizedTagEntityTypes.patient,
/// )
/// ...
/// _tagsKey.currentState?.selectedTags
/// ```
/// ---------------------------------------------------------------------------
class PersonalizedTagField extends ConsumerStatefulWidget {
  const PersonalizedTagField({
    super.key,
    required this.fieldKey,
    required this.entityType,
    this.entityId,
    this.label = 'Tags',
    this.hint = 'Search or type a new tag...',
    this.note = '✨ These tags are customized for you',
    this.enabled = true,
    this.maxTags = PersonalizedTagService.maxTagsPerEntity,
    this.onChanged,
  });

  /// Field context — separates per-user tag vocabularies. Use
  /// [PersonalizedTagFields] constants.
  final String fieldKey;

  /// Record kind the tags are attached to. Use
  /// [PersonalizedTagEntityTypes] constants.
  final String entityType;

  /// When editing an existing record, pass its id so the widget pre-loads the
  /// currently applied tags.
  final String? entityId;

  final String label;
  final String hint;
  final String note;
  final bool enabled;
  final int maxTags;

  /// Called with the current list of tag names whenever the selection changes.
  final ValueChanged<List<String>>? onChanged;

  @override
  ConsumerState<PersonalizedTagField> createState() =>
      PersonalizedTagFieldState();
}

/// Public state so forms can read the selected tag names before saving.
class PersonalizedTagFieldState extends ConsumerState<PersonalizedTagField> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final List<String> _selectedNames = [];

  OverlayEntry? _overlayEntry;
  double _fieldWidth = 0;
  bool _loadedExisting = false;

  /// Cached history tags for the current user + field context. Loaded during
  /// [build] (the only place `ref.watch` is valid) and reused by the overlay
  /// suggestion panel so the overlay itself never calls `ref.watch`.
  List<PersonalizedTag> _historyTags = const [];

  /// Current selection (normalized, de-duplicated). The owning form reads
  /// this before persisting the record.
  List<String> get selectedTags => List.unmodifiable(_selectedNames);

  /// Replaces the selection. Useful for forms that need to reset or set tags
  /// programmatically.
  void setSelectedTags(List<String> names) {
    _selectedNames
      ..clear()
      ..addAll(_normalizeList(names));
    _loadedExisting = true;
    _notifyChanged();
    if (mounted) setState(() {});
  }

  /// Removes all selected tags.
  void clear() {
    _selectedNames.clear();
    _notifyChanged();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _closeDropdown();
    _focusNode.removeListener(_handleFocusChange);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      _openDropdown();
    } else {
      // Let taps on dropdown items land before the overlay is removed.
      Future.microtask(_closeDropdown);
    }
  }

  void _notifyChanged() {
    widget.onChanged?.call(selectedTags);
  }

  // ---------------------------------------------------------------------------
  // Selection logic
  // ---------------------------------------------------------------------------

  bool _containsName(String name) {
    final target = PersonalizedTagService.normalizeTagName(name).toLowerCase();
    if (target.isEmpty) return false;
    return _selectedNames.any((n) => n.toLowerCase() == target);
  }

  void _addName(String name) {
    final clean = PersonalizedTagService.normalizeTagName(name);
    if (clean.isEmpty) return;
    if (_containsName(clean)) {
      _searchController.clear();
      _refreshDropdown();
      return;
    }
    if (_selectedNames.length >= widget.maxTags) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You can add up to ${widget.maxTags} tags.'),
        ),
      );
      return;
    }
    setState(() {
      _selectedNames.add(clean);
      _searchController.clear();
    });
    _notifyChanged();
    _refreshDropdown();
    _focusNode.requestFocus();
  }

  void _removeName(String name) {
    setState(() {
      _selectedNames.removeWhere((n) => n == name);
    });
    _notifyChanged();
    _closeDropdown();
  }

  List<String> _normalizeList(List<String> names) {
    final seen = <String>{};
    final result = <String>[];
    for (final name in names) {
      final clean = PersonalizedTagService.normalizeTagName(name);
      if (clean.isEmpty) continue;
      final key = clean.toLowerCase();
      if (seen.add(key)) result.add(clean);
      if (result.length >= widget.maxTags) break;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Dropdown overlay
  // ---------------------------------------------------------------------------

  void _openDropdown() {
    if (!widget.enabled) return;
    _closeDropdown();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) => _buildDropdownOverlay(context),
    );
    _overlayEntry = entry;
    overlay.insert(entry);
  }

  void _closeDropdown() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _refreshDropdown() {
    if (_focusNode.hasFocus) _openDropdown();
  }

  Widget _buildDropdownOverlay(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        // Transparent barrier: any tap outside the panel closes the dropdown.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeDropdown,
          ),
        ),
        Positioned(
          width: _fieldWidth > 0 ? _fieldWidth : double.infinity,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 8),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surface,
              child: _buildSuggestionPanel(theme),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestionPanel(ThemeData theme) {
    final suggestions = _computeSuggestions();
    final query = PersonalizedTagService.normalizeTagName(
      _searchController.text,
    );
    final exactMatch = suggestions.any(
      (t) => t.name.toLowerCase() == query.toLowerCase(),
    );
    final showCreateRow = query.isNotEmpty && !exactMatch;

    if (suggestions.isEmpty && !showCreateRow) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No matching tags yet. Type to create your first one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        shrinkWrap: true,
        children: [
          if (suggestions.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.history,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Based on your history...',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
            for (final tag in suggestions)
              _SuggestionTile(
                icon: Icons.sell_outlined,
                title: tag.name,
                subtitle: tag.usageLabel,
                onTap: () => _addName(tag.name),
              ),
          ],
          if (showCreateRow) ...[
            if (suggestions.isNotEmpty)
              const Divider(height: 8, indent: 14, endIndent: 14),
            _SuggestionTile(
              icon: Icons.add_circle_outline,
              title: query,
              subtitle: 'Create new tag',
              emphasize: true,
              onTap: () => _addName(query),
            ),
          ],
        ],
      ),
    );
  }

  List<PersonalizedTag> _computeSuggestions() {
    final query = PersonalizedTagService.normalizeTagName(
      _searchController.text,
    ).toLowerCase();

    final matches = <PersonalizedTag>[];
    for (final tag in _historyTags) {
      if (query.isNotEmpty && !tag.name.toLowerCase().contains(query)) {
        continue;
      }
      if (_containsName(tag.name)) continue;
      matches.add(tag);
    }
    if (matches.length > 6) return matches.sublist(0, 6);
    return matches;
  }

  // ---------------------------------------------------------------------------
  // Existing entity tags (edit mode)
  // ---------------------------------------------------------------------------

  void _syncExistingEntityTags(String? userId) {
    final entityId = widget.entityId;
    if (_loadedExisting || entityId == null || entityId.isEmpty) return;
    if (userId == null || userId.isEmpty) return;
    final params = EntityTagParams(
      userId: userId,
      entityType: widget.entityType,
      entityId: entityId,
    );
    final tags = ref.watch(entityTagsProvider(params)).valueOrNull;
    if (tags == null) return;
    _loadedExisting = true;
    _selectedNames
      ..clear()
      ..addAll(_normalizeList(tags.map((t) => t.name).toList()));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Load the user's personal tag history during build (the only place
    // `ref.watch` may be used) and cache it for the overlay panel.
    final userId = ref.watch(currentPublicUserIdProvider).valueOrNull;
    if (userId != null && userId.isNotEmpty) {
      _historyTags =
          ref
                  .watch(
                    userTagsProvider(
                      UserTagParams(
                        userId: userId,
                        fieldKey: widget.fieldKey,
                      ),
                    ),
                  )
                  .valueOrNull ??
          const [];
    } else {
      _historyTags = const [];
    }

    if (widget.entityId != null && widget.entityId!.isNotEmpty) {
      _syncExistingEntityTags(userId);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.note,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.primary,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 10),
        if (_selectedNames.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in _selectedNames)
                InputChip(
                  key: ValueKey('tag_$name'),
                  label: Text(name),
                  avatar: Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  onDeleted: widget.enabled ? () => _removeName(name) : null,
                  deleteIconColor: theme.colorScheme.onSurfaceVariant,
                  backgroundColor: theme.colorScheme.primaryContainer
                      .withValues(alpha: 0.45),
                  side: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        CompositedTransformTarget(
          link: _layerLink,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _fieldWidth = constraints.maxWidth;
              return TextField(
                controller: _searchController,
                focusNode: _focusNode,
                enabled: widget.enabled,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  prefixIcon: Icon(
                    Icons.sell_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                textInputAction: TextInputAction.done,
                onChanged: (_) => _refreshDropdown(),
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) _addName(value);
                },
                onTap: _openDropdown,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One tappable row inside the suggestion dropdown.
class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.emphasize = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = emphasize
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 20, color: color),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
          color: emphasize ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(color: color),
      ),
      onTap: onTap,
    );
  }
}
