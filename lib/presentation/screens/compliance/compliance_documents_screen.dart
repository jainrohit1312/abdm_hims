import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/providers.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/share_utils.dart';
import '../../../models/compliance_models.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/compliance_common.dart';

/// "All Documents" screen (`/compliance/documents`).
///
/// Searchable, filterable, sortable flat list of every compliance document
/// file in the hospital — across all records. Supports starring (favorites),
/// multi-select ZIP export and per-document QR codes.
class ComplianceDocumentsScreen extends ConsumerStatefulWidget {
  const ComplianceDocumentsScreen({super.key});

  @override
  ConsumerState<ComplianceDocumentsScreen> createState() =>
      _ComplianceDocumentsScreenState();
}

class _ComplianceDocumentsScreenState
    extends ConsumerState<ComplianceDocumentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = {};
  bool _selectionMode = false;
  bool _exporting = false;

  ComplianceCategory? _categoryFilter;
  ComplianceStatus? _statusFilter;
  bool _favoriteOnly = false;
  String _sortBy = 'uploaded';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('All Documents')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final documentsAsync = ref.watch(allComplianceDocumentsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: Text(_selectionMode
            ? '${_selected.length} selected'
            : 'All Documents'),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              tooltip: 'Export selected as ZIP',
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.archive_outlined),
              onPressed: _exporting || _selected.isEmpty
                  ? null
                  : () => _exportSelectedZip(documentsAsync.valueOrNull ?? const []),
            ),
            IconButton(
              tooltip: 'Exit selection',
              icon: const Icon(Icons.close),
              onPressed: _toggleSelectionMode,
            ),
          ] else ...[
            IconButton(
              tooltip: 'Select multiple & export ZIP',
              icon: const Icon(Icons.checklist_outlined),
              onPressed: _toggleSelectionMode,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          _buildSearchAndFilters(),
          Expanded(
            child: documentsAsync.when(
              data: (documents) => _buildList(documents),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ComplianceEmptyState(
                icon: Icons.error_outline,
                message: 'Failed to load documents: $error',
                actionLabel: 'Retry',
                onAction: () =>
                    ref.invalidate(allComplianceDocumentsProvider(hospitalId)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search file name, record, type, authority, date...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                    ),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip('All', _categoryFilter == null && _statusFilter == null, () {
                  setState(() {
                    _categoryFilter = null;
                    _statusFilter = null;
                  });
                }),
                for (final category in ComplianceCategory.values)
                  _chip(category.label, _categoryFilter == category, () {
                    setState(() {
                      _categoryFilter =
                          _categoryFilter == category ? null : category;
                      _statusFilter = null;
                    });
                  }),
                const SizedBox(width: 8),
                _chip('★ Favorites', _favoriteOnly, () {
                  setState(() => _favoriteOnly = !_favoriteOnly);
                }),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final status in ComplianceStatus.values)
                  _chip(
                    status.label,
                    _statusFilter == status,
                    () => setState(() {
                      _statusFilter = _statusFilter == status ? null : status;
                    }),
                    color: complianceStatusColor(status),
                  ),
                const SizedBox(width: 12),
                PopupMenuButton<String>(
                  tooltip: 'Sort',
                  onSelected: (value) => setState(() => _sortBy = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'uploaded', child: Text('Sort: Date uploaded')),
                    PopupMenuItem(value: 'name', child: Text('Sort: File name')),
                    PopupMenuItem(value: 'expiry', child: Text('Sort: Expiry date')),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.sort, size: 16),
                    label: Text(
                      'Sort: ${_sortBy == 'name' ? 'File name' : _sortBy == 'expiry' ? 'Expiry' : 'Uploaded'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, {Color? color}) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        selectedColor: effectiveColor.withValues(alpha: 0.18),
        checkmarkColor: effectiveColor,
        onSelected: (_) => onTap(),
      ),
    );
  }

  List<Map<String, dynamic>> _applyFilters(
    List<Map<String, dynamic>> documents,
  ) {
    var list = List<Map<String, dynamic>>.from(documents);
    if (_favoriteOnly) {
      list = list.where((d) => d['record_is_favorite'] == true).toList();
    }
    if (_categoryFilter != null) {
      list = list
          .where(
            (d) =>
                d['record_category']?.toString() == _categoryFilter!.value,
          )
          .toList();
    }
    if (_statusFilter != null) {
      list = list.where((d) {
        final expiry = DateTime.tryParse(d['record_expiry']?.toString() ?? '');
        return ComplianceStatus.fromExpiry(expiry) == _statusFilter;
      }).toList();
    }
    final search = _searchController.text.trim().toLowerCase();
    if (search.isNotEmpty) {
      list = list.where((d) {
        return (d['file_name']?.toString() ?? '').toLowerCase().contains(search) ||
            (d['record_name']?.toString() ?? '').toLowerCase().contains(search) ||
            (d['record_type']?.toString() ?? '').toLowerCase().contains(search);
      }).toList();
    }
    list.sort((a, b) {
      int result;
      switch (_sortBy) {
        case 'name':
          result = (a['file_name']?.toString() ?? '')
              .toLowerCase()
              .compareTo((b['file_name']?.toString() ?? '').toLowerCase());
          break;
        case 'expiry':
          final aExpiry =
              DateTime.tryParse(a['record_expiry']?.toString() ?? '') ??
              DateTime(9999);
          final bExpiry =
              DateTime.tryParse(b['record_expiry']?.toString() ?? '') ??
              DateTime(9999);
          result = aExpiry.compareTo(bExpiry);
          break;
        case 'uploaded':
        default:
          final aCreated =
              DateTime.tryParse(a['created_at']?.toString() ?? '') ??
              DateTime(2000);
          final bCreated =
              DateTime.tryParse(b['created_at']?.toString() ?? '') ??
              DateTime(2000);
          result = bCreated.compareTo(aCreated);
          break;
      }
      return result;
    });
    return list;
  }

  Widget _buildList(List<Map<String, dynamic>> documents) {
    final filtered = _applyFilters(documents);
    if (documents.isEmpty) {
      return const ComplianceEmptyState(
        icon: Icons.description_outlined,
        message: 'No document files uploaded yet.',
      );
    }
    if (filtered.isEmpty) {
      return const ComplianceEmptyState(
        icon: Icons.search_off,
        message: 'No documents match the current filters.',
      );
    }
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(complianceRefreshProvider),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final doc = filtered[index];
          return _buildDocumentTile(doc);
        },
      ),
    );
  }

  Widget _buildDocumentTile(Map<String, dynamic> doc) {
    final id = doc['id']?.toString() ?? '';
    final fileName = doc['file_name']?.toString() ?? 'document';
    final file = ComplianceDocumentFile.fromJson(doc);
    final recordId = doc['record_id']?.toString() ?? '';
    final recordName = doc['record_name']?.toString() ?? 'Record';
    final recordType = doc['record_type']?.toString() ?? '';
    final isFavorite = doc['record_is_favorite'] == true;
    final selected = _selected.contains(id);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        selected: selected,
        selectedTileColor: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.3),
        leading: _selectionMode
            ? Icon(
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: selected ? Theme.of(context).colorScheme.primary : null,
              )
            : Icon(documentTypeIcon(fileName), size: 30),
        title: Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          '$recordName • $recordType\n${file.versionLabel} • ${file.displaySize} • '
          '${file.createdAt == null ? '' : DateFormat('dd MMM yyyy').format(file.createdAt!.toLocal())}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        isThreeLine: true,
        trailing: _selectionMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: isFavorite ? 'Unstar record' : 'Star record',
                    icon: Icon(
                      isFavorite ? Icons.star : Icons.star_border,
                      color: isFavorite ? Colors.amber : null,
                      size: 20,
                    ),
                    onPressed: () => _toggleFavorite(recordId, isFavorite),
                  ),
                  IconButton(
                    tooltip: 'QR code',
                    icon: const Icon(Icons.qr_code, size: 20),
                    onPressed: () => _showQr(doc),
                  ),
                ],
              ),
        onTap: () {
          if (_selectionMode) {
            setState(() {
              if (selected) {
                _selected.remove(id);
              } else {
                _selected.add(id);
              }
            });
          } else {
            context.push(
              '/compliance/document/$id/view?recordId=$recordId',
            );
          }
        },
        onLongPress: () {
          if (!_selectionMode) {
            _toggleSelectionMode();
            setState(() => _selected.add(id));
          }
        },
      ),
    );
  }

  Future<void> _toggleFavorite(String recordId, bool current) async {
    await ref.read(complianceServiceProvider).setFavorite(recordId, !current);
    ref.invalidate(complianceRefreshProvider);
  }

  Future<void> _exportSelectedZip(List<Map<String, dynamic>> documents) async {
    setState(() => _exporting = true);
    try {
      final selectedDocs = documents
          .where((d) => _selected.contains(d['id']?.toString()))
          .toList();
      if (selectedDocs.isEmpty) return;

      final archive = Archive();
      var count = 0;
      for (final doc in selectedDocs) {
        final filePath = doc['file_path']?.toString() ?? '';
        if (filePath.isEmpty) continue;
        final bytes = await ref
            .read(storageServiceProvider)
            .downloadBytes(filePath);
        final fileName = doc['file_name']?.toString() ?? 'document_$count';
        // Avoid duplicate names inside the ZIP.
        archive.addFile(
          ArchiveFile(
            count == 0 ? fileName : '${count}_$fileName',
            bytes.length,
            bytes,
          ),
        );
        count++;
      }

      final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final dir = await getTemporaryDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final zipFile = File(
        '${dir.path}${Platform.pathSeparator}compliance_documents_$stamp.zip',
      );
      await zipFile.writeAsBytes(zipBytes, flush: true);

      if (!mounted) return;
      await ShareUtils.shareFile(
        filePath: zipFile.path,
        fileName: 'compliance_documents_$stamp.zip',
        mimeType: 'application/zip',
        text: 'Exported $count compliance document(s) from HIMS',
      );
      setState(() => _selectionMode = false);
      _selected.clear();
    } catch (e) {
      AppLogger.e('ZIP export failed', e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showQr(Map<String, dynamic> doc) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Document QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: doc['file_url']?.toString() ?? '/compliance',
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 8),
            Text(
              doc['file_name']?.toString() ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
