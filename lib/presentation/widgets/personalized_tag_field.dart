import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/utils/keyboard_inset.dart';
import '../../models/personalized_tag_models.dart';
import '../../services/personalized_tag_service.dart';
import 'keyboard_safe_content.dart';

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
    this.recordUsageOnAdd = false,
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

  /// When true, adding a tag immediately records it in the user's personal
  /// collection (`user_tags`) so suggestions learn right away — useful for
  /// fields that are not linked to a saved record id (e.g. prescription
  /// investigation fields). Defaults to false; forms that persist entity
  /// links on save get the usage bump from [PersonalizedTagService.setEntityTags].
  final bool recordUsageOnAdd;

  @override
  ConsumerState<PersonalizedTagField> createState() =>
      PersonalizedTagFieldState();
}

/// Public state so forms can read the selected tag names before saving.
class PersonalizedTagFieldState extends ConsumerState<PersonalizedTagField> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();
  final List<String> _selectedNames = [];

  OverlayEntry? _overlayEntry;
  double _fieldWidth = 0;
  bool _loadedExisting = false;

  /// Cached history tags for the current user + field context. Loaded during
  /// [build] (the only place `ref.watch` is valid) and reused by the overlay
  /// suggestion panel so the overlay itself never calls `ref.watch`.
  List<PersonalizedTag> _historyTags = const [];

  /// Which [UserTagParams] the cached [_historyTags] belongs to. Used so a
  /// stale cache is never shown when the widget is reused for a different
  /// user/field context, and so optimistic local updates never leak across
  /// fields.
  UserTagParams? _historyTagParams;

  /// Public `users.id` of the logged-in user, resolved during [build] and used
  /// by [recordUsageOnAdd] callbacks that fire outside the build phase.
  String? _currentUserId;

  /// True while a blur event is waiting to convert leftover typed text into a
  /// tag. Tapping a suggestion cancels it so the chosen tag wins over the raw
  /// query text.
  bool _pendingBlurConvert = false;

  /// Deferred blur handlers. The text field can lose focus on pointer-down
  /// (desktop/web) before a suggestion row's onTap fires on pointer-up. Both
  /// actions are therefore deferred a little so an explicit suggestion tap can
  /// cancel them; otherwise the overlay was removed before the tap landed.
  Timer? _blurConvertTimer;
  Timer? _blurCloseTimer;

  /// True while a pointer is pressed on a suggestion row. While active, the
  /// deferred blur-close and blur-convert timers must not fire.
  bool _suggestionPressActive = false;

  /// Maps selected tag name (lowercase) → `user_tags.id`. Used by the ✕ delete
  /// button for entity-linked fields (where removing the chip is allowed to
  /// delete the DB row). For `recordUsageOnAdd` fields the mapping is kept
  /// updated but ✕ only removes the chip from the current selection — it never
  /// deletes the learned history row.
  final Map<String, String> _selectedTagIds = <String, String>{};

  /// Current selection (normalized, de-duplicated). The owning form reads
  /// this before persisting the record.
  List<String> get selectedTags => List.unmodifiable(_selectedNames);

  /// Replaces the selection. Useful for forms that need to reset or set tags
  /// programmatically.
  void setSelectedTags(List<String> names) {
    _selectedTagIds.clear();
    _selectedNames
      ..clear()
      ..addAll(_normalizeList(names));
    _loadedExisting = true;
    _notifyChanged();
    if (mounted) setState(() {});
  }

  /// Removes all selected tags (UI only — database cleanup is done per-tag via
  /// the ✕ button so an accidental `clear()` doesn't wipe the user's history).
  void clear() {
    _selectedTagIds.clear();
    _selectedNames.clear();
    _notifyChanged();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    // Web/browser keyboard height (Android Chrome etc.) — reuse the shared
    // KeyboardInset infrastructure so the dropdown can reposition itself when
    // the keyboard opens/closes.
    KeyboardInset.addListener(_handleKeyboardInsetChanged);
  }

  @override
  void dispose() {
    KeyboardInset.removeListener(_handleKeyboardInsetChanged);
    _blurConvertTimer?.cancel();
    _blurCloseTimer?.cancel();
    _closeDropdown();
    _focusNode.removeListener(_handleFocusChange);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Browser-reported keyboard height changed (mobile web). Reposition the
  /// open dropdown so it never stays behind the keyboard and bring the focused
  /// field back into view when needed.
  void _handleKeyboardInsetChanged() {
    if (!mounted) return;
    _overlayEntry?.markNeedsBuild();
    if (_focusNode.hasFocus) {
      _ensureFieldVisibleIfNeeded();
    }
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      // A pending blur-conversion is no longer needed — the user is back.
      _pendingBlurConvert = false;
      _suggestionPressActive = false;
      _blurConvertTimer?.cancel();
      _blurCloseTimer?.cancel();
      _openDropdown();
      // Keyboard open hone ke baad field ko visible area mein le aao (native
      // Android par viewInsets change hota hai; web par KeyboardInset listener
      // bhi handle karta hai). Delay isliye taaki keyboard open/close animation
      // settle ho jaye aur ensureVisible final viewport par measure kare.
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted && _focusNode.hasFocus) _ensureFieldVisibleIfNeeded();
      });
    } else {
      // The text field can lose focus on pointer-down (desktop/web) before a
      // suggestion row's onTap fires on pointer-up. Defer both the raw-query
      // conversion and the overlay close so an explicit suggestion tap can
      // cancel them via _handleSuggestionTapDown/_commitName.
      _pendingBlurConvert = true;
      _blurConvertTimer?.cancel();
      _blurConvertTimer = Timer(const Duration(milliseconds: 120), () {
        if (!mounted || !_pendingBlurConvert || _suggestionPressActive) return;
        _pendingBlurConvert = false;
        _convertTypedTextToTag();
      });
      _blurCloseTimer?.cancel();
      _blurCloseTimer = Timer(const Duration(milliseconds: 180), () {
        if (!mounted || _suggestionPressActive) return;
        if (!_focusNode.hasFocus) _closeDropdown();
      });
    }
  }

  /// Scrolls the field back into the visible (non-keyboard) area only when it
  /// is actually clipped. Avoids forced jumps when the field is already fully
  /// visible — the shared goal of the keyboard-safe layout helpers.
  void _ensureFieldVisibleIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _targetKey.currentContext;
      if (targetContext == null) return;
      final renderBox = targetContext.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) return;

      final media = MediaQuery.of(context);
      final keyboardHeight = keyboardInsetOf(context);
      final visibleBottom = media.size.height - keyboardHeight;
      final top = renderBox.localToGlobal(Offset.zero).dy;
      final bottom = top + renderBox.size.height;

      final fullyVisible = top >= media.padding.top && bottom <= visibleBottom;
      if (fullyVisible) return;

      final scrollable = Scrollable.maybeOf(targetContext);
      if (scrollable == null) return;

      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );

      // Dropdown anchors are computed from the field position; re-run the
      // overlay builder once the scroll settles so above/below stays correct.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _overlayEntry?.markNeedsBuild();
      });
    });
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

  void _addName(String name) => _commitName(name);

  /// Adds a tag that already exists in the database (suggestion tap), so the
  /// widget remembers its id for the ✕ delete flow.
  void _addExistingTag(PersonalizedTag tag) {
    _commitName(tag.name, tagId: tag.id);
  }

  /// Pointer-down on a suggestion row. This runs before the text field's blur
  /// timers can fire (same pointer event), so it cancels the pending blur
  /// conversion and prevents the blur-close timer from removing the overlay
  /// before the row's onTap lands on pointer-up.
  void _handleSuggestionTapDown(TapDownDetails details) {
    _suggestionPressActive = true;
    _pendingBlurConvert = false;
    _blurConvertTimer?.cancel();
  }

  /// Pointer-up outside the row / gesture canceled — release the guard so the
  /// deferred blur handlers can behave normally again.
  void _handleSuggestionTapCancel() {
    _suggestionPressActive = false;
  }

  /// Selection wrapper for a history suggestion row.
  void _selectExistingTag(PersonalizedTag tag) {
    _addExistingTag(tag);
    _suggestionPressActive = false;
  }

  /// Converts whatever is still sitting in the search field into a tag when
  /// the field loses focus (so "type + move on" also creates a tag). Does not
  /// yank focus back.
  void _convertTypedTextToTag() {
    final text = _searchController.text;
    if (PersonalizedTagService.normalizeTagName(text).isEmpty) return;
    _commitName(text, refocus: false);
  }

  void _commitName(String name, {bool refocus = true, String? tagId}) {
    if (!mounted) return;
    // Any explicit selection wins over the pending blur-conversion.
    _pendingBlurConvert = false;
    _blurConvertTimer?.cancel();
    _suggestionPressActive = false;
    final clean = PersonalizedTagService.normalizeTagName(name);
    if (clean.isEmpty) return;
    if (_containsName(clean)) {
      if (tagId != null) {
        _selectedTagIds[clean.toLowerCase()] = tagId;
      }
      _searchController.clear();
      if (refocus) _refreshDropdown();
      return;
    }
    if (_selectedNames.length >= widget.maxTags) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You can add up to ${widget.maxTags} tags.')),
      );
      return;
    }
    setState(() {
      _selectedNames.add(clean);
      if (tagId != null) {
        _selectedTagIds[clean.toLowerCase()] = tagId;
      }
      _searchController.clear();
    });
    _notifyChanged();
    if (widget.recordUsageOnAdd) unawaited(_recordUsage(clean));
    if (refocus) {
      _refreshDropdown();
      _focusNode.requestFocus();
    }
  }

  /// Records a tag into the user's personal collection immediately so
  /// "Based on your history..." starts suggesting it on the next visit.
  ///
  /// The call is non-blocking for the typing UI, but inside it we await the
  /// public `users.id` if it hasn't resolved yet — a tag committed before
  /// [currentPublicUserIdProvider] finished loading is no longer lost.
  Future<void> _recordUsage(String name) async {
    if (!mounted) return;

    final container = ProviderScope.containerOf(context);
    final service = ref.read(personalizedTagServiceProvider);

    final userId = await _resolveUserId(container);
    if (userId == null || userId.isEmpty) {
      debugPrint(
        'PersonalizedTagField: skipping usage record for "$name" '
        '(${widget.fieldKey}) — public users.id is unavailable.',
      );
      return;
    }

    final params = UserTagParams(userId: userId, fieldKey: widget.fieldKey);
    _historyTagParams ??= params;

    try {
      final tag = await service.ensureTag(userId, widget.fieldKey, name);

      // Optimistic local update: the tag is available for future suggestions
      // instantly, even before the invalidated provider refetch completes.
      if (mounted && _historyTagParams == params) {
        _upsertHistoryTag(tag);
        if (_focusNode.hasFocus) _overlayEntry?.markNeedsBuild();
      }

      // Invalidate the exact user + fieldKey provider so every other open
      // field / future visit sees the created-or-bumped tag without needing a
      // logout, refresh or restart. Using the container (captured above) also
      // works if the widget was disposed while the write was in flight.
      container.invalidate(userTagsProvider(params));
    } catch (e) {
      debugPrint(
        'PersonalizedTagField: tag usage record failed for "$name" '
        '(userId: $userId, fieldKey: ${widget.fieldKey}): $e',
      );
    }
  }

  /// Resolves the current public `users.id`, awaiting the provider future when
  /// [_currentUserId] has not been populated yet.
  Future<String?> _resolveUserId(ProviderContainer container) async {
    final cached = _currentUserId;
    if (cached != null && cached.isNotEmpty) return cached;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final userId = await container.read(currentPublicUserIdProvider.future);
        if (userId != null && userId.isNotEmpty) {
          _currentUserId = userId;
          return userId;
        }
        return null;
      } catch (e) {
        if (attempt == 0) {
          container.invalidate(currentPublicUserIdProvider);
          await Future<void>.delayed(const Duration(milliseconds: 150));
        } else {
          debugPrint(
            'PersonalizedTagField: failed to resolve public users.id: $e',
          );
        }
      }
    }
    return null;
  }

  /// Merges [tag] into the cached [_historyTags] list, keeping the ordering
  /// contract: usage_count DESC, then last_used_at DESC, then name ASC.
  void _upsertHistoryTag(PersonalizedTag tag) {
    final target = tag.name.toLowerCase();
    final updated = <PersonalizedTag>[];
    var replaced = false;
    for (final existing in _historyTags) {
      if (existing.name.toLowerCase() == target) {
        updated.add(tag);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) updated.add(tag);
    updated.sort(_compareHistoryTags);
    _historyTags = updated;
  }

  int _compareHistoryTags(PersonalizedTag a, PersonalizedTag b) {
    final byUsage = b.usageCount.compareTo(a.usageCount);
    if (byUsage != 0) return byUsage;
    final aLast = a.lastUsedAt;
    final bLast = b.lastUsedAt;
    if (aLast != null && bLast != null) {
      final byLast = bLast.compareTo(aLast);
      if (byLast != 0) return byLast;
    } else if (aLast != null) {
      return -1;
    } else if (bLast != null) {
      return 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Removes a tag from the UI selection.
  ///
  /// For history-learning fields (`recordUsageOnAdd: true`, e.g. the OPD
  /// investigation fields) ✕ only removes the chip from the current
  /// prescription — the learned `user_tags` row is intentionally kept so the
  /// doctor's personal history survives. For entity-linked fields the existing
  /// behaviour is preserved: the tag row is deleted from the collection too.
  void _removeName(String name) {
    final key = name.toLowerCase();
    final tagId = _selectedTagIds.remove(key);
    setState(() {
      _selectedNames.removeWhere((n) => n.toLowerCase() == key);
    });
    _notifyChanged();
    _closeDropdown();

    if (!widget.recordUsageOnAdd && tagId != null) {
      unawaited(_deleteTagFromDatabase(tagId));
    }
  }

  Future<void> _deleteTagFromDatabase(String tagId) async {
    try {
      await ref.read(personalizedTagServiceProvider).deleteTag(tagId);
      if (!mounted) return;
      _invalidateTagProviders();
    } catch (e) {
      debugPrint('Tag delete failed (non-blocking): $e');
    }
  }

  /// Refreshes the user's history list (and the entity link list, if this
  /// field is bound to an existing record) after a DB change.
  void _invalidateTagProviders() {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;
    ref.invalidate(
      userTagsProvider(
        UserTagParams(userId: userId, fieldKey: widget.fieldKey),
      ),
    );
    final entityId = widget.entityId;
    if (entityId != null && entityId.isNotEmpty) {
      ref.invalidate(
        entityTagsProvider(
          EntityTagParams(
            userId: userId,
            entityType: widget.entityType,
            entityId: entityId,
          ),
        ),
      );
    }
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
    final media = MediaQuery.of(context);
    final keyboardHeight = keyboardInsetOf(context);

    // Measure the space actually available around the field AFTER the keyboard
    // has claimed its share of the screen. Prefer opening BELOW when there is
    // enough room; otherwise open ABOVE. The panel's maxHeight is clamped to
    // the chosen side so it never renders behind the keyboard.
    const gap = 8.0;
    const maxPanelHeight = 320.0;
    const minBelowSpace = 140.0;

    final targetBox =
        _targetKey.currentContext?.findRenderObject() as RenderBox?;
    double? belowSpace;
    double? aboveSpace;
    if (targetBox != null && targetBox.hasSize) {
      final top = targetBox.localToGlobal(Offset.zero).dy;
      final bottom = targetBox
          .localToGlobal(Offset(0, targetBox.size.height))
          .dy;
      belowSpace = media.size.height - keyboardHeight - bottom - gap;
      aboveSpace = top - media.padding.top - gap;
    }

    final bool openAbove;
    final double panelMaxHeight;
    if (belowSpace != null && aboveSpace != null) {
      if (belowSpace >= minBelowSpace) {
        // Enough room below — keep the current below-anchor behaviour.
        openAbove = false;
        panelMaxHeight = math.min(maxPanelHeight, belowSpace);
      } else if (aboveSpace > belowSpace) {
        // Below is too tight and above has more room — open above.
        openAbove = true;
        panelMaxHeight = math.min(maxPanelHeight, aboveSpace);
      } else {
        // Both sides are tight; pick the larger one and still clamp so the
        // panel stays inside the visible area.
        openAbove = aboveSpace > belowSpace;
        panelMaxHeight = math.max(
          48.0,
          math.min(maxPanelHeight, math.max(belowSpace, aboveSpace)),
        );
      }
    } else {
      // Fallback (e.g. field not laid out yet): below anchors, clamped to the
      // screen area above the keyboard so the panel cannot go behind it.
      openAbove = false;
      panelMaxHeight = math.min(
        maxPanelHeight,
        math.max(48.0, media.size.height - keyboardHeight - gap * 2),
      );
    }

    return Stack(
      children: [
        // Outside-dismiss barrier. It is BEHIND the suggestion panel, so it
        // can never intercept a suggestion tap; the panel (last child) is
        // hit-tested first. Opaque so taps outside the panel close the
        // dropdown without leaking to the page behind the overlay.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeDropdown,
          ),
        ),
        Positioned(
          width: _fieldWidth > 0 ? _fieldWidth : double.infinity,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: openAbove ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor: openAbove
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(0, openAbove ? -gap : gap),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surface,
              child: _buildSuggestionPanel(theme, maxHeight: panelMaxHeight),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestionPanel(ThemeData theme, {required double maxHeight}) {
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
      constraints: BoxConstraints(maxHeight: maxHeight),
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
                onTap: () => _selectExistingTag(tag),
                onTapDown: _handleSuggestionTapDown,
                onTapCancel: _handleSuggestionTapCancel,
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
              onTapDown: _handleSuggestionTapDown,
              onTapCancel: _handleSuggestionTapCancel,
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
    _selectedTagIds.clear();
    for (final tag in tags) {
      _selectedTagIds[tag.name.toLowerCase()] = tag.id;
    }
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
    _currentUserId = userId;
    if (userId != null && userId.isNotEmpty) {
      final params = UserTagParams(userId: userId, fieldKey: widget.fieldKey);
      final previous = _historyTags;
      if (_historyTagParams != params) {
        // Never reuse history cached for another user/field context.
        _historyTags = const [];
        _historyTagParams = params;
      }
      final tags = ref.watch(userTagsProvider(params)).valueOrNull;
      if (tags != null) {
        _historyTags = tags;
      }
      if (!identical(previous, _historyTags)) {
        // The provider delivered fresh data while the dropdown may already be
        // open (focus-first / loading-then-resolved case). Rebuild the overlay
        // so "Based on your history..." appears without typing a keystroke.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _focusNode.hasFocus) {
            _overlayEntry?.markNeedsBuild();
          }
        });
      }
    } else {
      _historyTags = const [];
      _historyTagParams = null;
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
          key: _targetKey,
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
///
/// Built on [InkWell] (not [ListTile]) so the whole row is reliably clickable
/// and so `onTapDown`/`onTapCancel` can be observed to cancel the text field's
/// blur-conversion/close race before `onTap` fires.
class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onTapDown,
    this.onTapCancel,
    this.emphasize = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapCancelCallback? onTapCancel;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = emphasize
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      onTapDown: onTapDown,
      onTapCancel: onTapCancel,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
                      color: emphasize ? theme.colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
