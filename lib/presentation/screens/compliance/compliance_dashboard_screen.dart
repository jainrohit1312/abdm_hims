import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../models/compliance_models.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/compliance_common.dart';

/// Compliance & Renewal Reminder dashboard (`/compliance`).
///
/// Shows the hospital's licences / NOCs / AMCs / CMCs / insurance / contracts
/// with live expiry status, search + filters, quick-access rows for favorites
/// and recently added items, and runs the automated 30/7/expired reminder
/// engine on load.
class ComplianceDashboardScreen extends ConsumerStatefulWidget {
  const ComplianceDashboardScreen({super.key});

  @override
  ConsumerState<ComplianceDashboardScreen> createState() =>
      _ComplianceDashboardScreenState();
}

class _ComplianceDashboardScreenState
    extends ConsumerState<ComplianceDashboardScreen> {
  final TextEditingController _searchController = TextEditingController();

  ComplianceCategory? _categoryFilter;
  ComplianceStatus? _statusFilter;
  bool _favoriteOnly = false;
  String _sortBy = 'expiry';
  bool _sortAscending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runReminderEngine());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _runReminderEngine() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) return;
    try {
      final counts = await ref
          .read(complianceServiceProvider)
          .processDueReminders(hospitalId);
      final total = counts.values.fold<int>(0, (sum, c) => sum + c);
      if (total > 0 && mounted) {
        ref.invalidate(complianceRefreshProvider);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '⏰ $total compliance reminder(s) generated '
                '(30-day: ${counts['30_day']}, 7-day: ${counts['7_day']}, '
                'expired: ${counts['expired']})',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } catch (_) {
      // Reminder engine is best-effort; the dashboard still renders.
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(complianceRefreshProvider);
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Compliance')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final recordsAsync = ref.watch(complianceRecordsProvider(hospitalId));
    final statsAsync = ref.watch(complianceStatsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Compliance & Renewals'),
        actions: [
          IconButton(
            tooltip: 'Reminder History',
            icon: const Icon(Icons.notifications_active_outlined),
            onPressed: () => context.push('/compliance/reminders'),
          ),
          IconButton(
            tooltip: 'Audit Logs',
            icon: const Icon(Icons.history_outlined),
            onPressed: () => context.push('/compliance/audit-logs'),
          ),
          AppRefreshButton(onRefresh: _refresh),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/compliance/new'),
        icon: const Icon(Icons.add),
        label: const Text('New Document'),
      ),
      body: Column(
        children: [
          _buildStatsBar(statsAsync),
          _buildSearchAndFilters(),
          Expanded(
            child: recordsAsync.when(
              data: (records) => _buildList(records),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ComplianceEmptyState(
                icon: Icons.error_outline,
                message: 'Failed to load compliance records.\n$error',
                actionLabel: 'Retry',
                onAction: _refresh,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _buildStatsBar(AsyncValue<Map<String, dynamic>> statsAsync) {
    return statsAsync.maybeWhen(
      data: (stats) {
        final total = stats['total_records'] ?? 0;
        final documents = stats['total_documents'] ?? 0;
        final expiring = stats['expiring'] ?? 0;
        final expired = stats['expired'] ?? 0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _statTile(Icons.folder_outlined, '$total', 'Records', Colors.blue),
              const SizedBox(width: 8),
              _statTile(Icons.description_outlined, '$documents', 'Files', Colors.indigo),
              const SizedBox(width: 8),
              _statTile(Icons.timer_outlined, '$expiring', 'Expiring', Colors.orange),
              const SizedBox(width: 8),
              _statTile(Icons.error_outline, '$expired', 'Expired', Colors.red),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  Widget _statTile(IconData icon, String value, String label, Color color) {
    return Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        color: color.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: color,
                ),
              ),
              Text(label, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
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
              hintText: 'Search name, type, authority, number, date...',
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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip(
                  label: 'All',
                  selected: _categoryFilter == null && _statusFilter == null,
                  onSelected: () => setState(() {
                    _categoryFilter = null;
                    _statusFilter = null;
                  }),
                ),
                for (final category in ComplianceCategory.values)
                  _filterChip(
                    label: category.label,
                    selected: _categoryFilter == category,
                    onSelected: () => setState(() {
                      _categoryFilter = _categoryFilter == category
                          ? null
                          : category;
                      _statusFilter = null;
                    }),
                  ),
                const SizedBox(width: 8),
                _filterChip(
                  label: '★ Favorites',
                  selected: _favoriteOnly,
                  onSelected: () =>
                      setState(() => _favoriteOnly = !_favoriteOnly),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final status in ComplianceStatus.values)
                  _filterChip(
                    label: status.label,
                    selected: _statusFilter == status,
                    color: complianceStatusColor(status),
                    onSelected: () => setState(() {
                      _statusFilter = _statusFilter == status ? null : status;
                    }),
                  ),
                const SizedBox(width: 12),
                PopupMenuButton<String>(
                  tooltip: 'Sort',
                  onSelected: (value) => setState(() {
                    if (_sortBy == value) {
                      _sortAscending = !_sortAscending;
                    } else {
                      _sortBy = value;
                      _sortAscending = false;
                    }
                  }),
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'expiry', child: Text('Sort: Expiry date')),
                    const PopupMenuItem(value: 'name', child: Text('Sort: Name')),
                    const PopupMenuItem(value: 'created', child: Text('Sort: Date uploaded')),
                  ],
                  child: Chip(
                    avatar: Icon(
                      _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                    ),
                    label: Text(
                      'Sort: ${_sortBy == 'name' ? 'Name' : _sortBy == 'created' ? 'Uploaded' : 'Expiry'}',
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

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    Color? color,
  }) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        selectedColor: effectiveColor.withValues(alpha: 0.18),
        checkmarkColor: effectiveColor,
        onSelected: (_) => onSelected(),
      ),
    );
  }

  Widget _buildList(List<ComplianceRecord> records) {
    final filtered = _applyFilters(records);

    if (records.isEmpty) {
      return const ComplianceEmptyState(
        icon: Icons.folder_off_outlined,
        message: 'No compliance documents yet.\n'
            'Add your first license, NOC or contract to start tracking renewals.',
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_favoriteOnly == false &&
              _categoryFilter == null &&
              _statusFilter == null &&
              _searchController.text.trim().isEmpty) ...[
            _buildQuickAccess(records),
            const SizedBox(height: 12),
          ],
          Text(
            '${filtered.length} record${filtered.length == 1 ? '' : 's'}',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (filtered.isEmpty)
            const ComplianceEmptyState(
              icon: Icons.search_off,
              message: 'No records match the current filters.',
            )
          else
            ...filtered.map((record) => _buildRecordCard(record)),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  List<ComplianceRecord> _applyFilters(List<ComplianceRecord> records) {
    var list = List<ComplianceRecord>.from(records);
    if (_favoriteOnly) {
      list = list.where((r) => r.isFavorite).toList();
    }
    if (_categoryFilter != null) {
      list = list.where((r) => r.category == _categoryFilter).toList();
    }
    if (_statusFilter != null) {
      list = list.where((r) => r.derivedStatus == _statusFilter).toList();
    }
    final search = _searchController.text.trim().toLowerCase();
    if (search.isNotEmpty) {
      list = list.where((r) {
        return r.documentName.toLowerCase().contains(search) ||
            r.documentType.toLowerCase().contains(search) ||
            (r.authorityName ?? '').toLowerCase().contains(search) ||
            (r.documentNumber ?? '').toLowerCase().contains(search) ||
            r.displayExpiry.toLowerCase().contains(search);
      }).toList();
    }
    list.sort((a, b) {
      int result;
      switch (_sortBy) {
        case 'name':
          result = a.documentName
              .toLowerCase()
              .compareTo(b.documentName.toLowerCase());
          break;
        case 'created':
          result = (b.createdAt ?? DateTime(2000)).compareTo(
            a.createdAt ?? DateTime(2000),
          );
          break;
        case 'expiry':
        default:
          result = (a.expiryDate ?? DateTime(9999)).compareTo(
            b.expiryDate ?? DateTime(9999),
          );
          break;
      }
      return _sortAscending ? result : -result;
    });
    return list;
  }

  Widget _buildQuickAccess(List<ComplianceRecord> records) {
    final favorites = records.where((r) => r.isFavorite).toList();
    final recent = List<ComplianceRecord>.from(records)
      ..sort(
        (a, b) => (b.createdAt ?? DateTime(2000)).compareTo(
          a.createdAt ?? DateTime(2000),
        ),
      );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (favorites.isNotEmpty) ...[
          _sectionTitle('★ Favorites'),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: favorites.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => _miniCard(favorites[index]),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (recent.isNotEmpty) ...[
          _sectionTitle('Recently Added'),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: recent.take(10).length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => _miniCard(recent[index]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _miniCard(ComplianceRecord record) {
    final status = record.derivedStatus;
    final color = complianceStatusColor(status);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/compliance/record/${record.id}'),
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(complianceCategoryIcon(record.category), size: 16, color: color),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    record.documentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              daysLeftLabel(record.daysToExpiry),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordCard(ComplianceRecord record) {
    final status = record.derivedStatus;
    final color = complianceStatusColor(status);
    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/compliance/record/${record.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: complianceCategoryColor(
                        record.category,
                      ).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      complianceCategoryIcon(record.category),
                      color: complianceCategoryColor(record.category),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                record.documentName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (record.isFavorite)
                              const Icon(Icons.star, size: 16, color: Colors.amber),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          record.documentType,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ComplianceStatusBadge(status: status),
                  ComplianceCategoryChip(category: record.category),
                  if (record.authorityName != null &&
                      record.authorityName!.isNotEmpty)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: Text(
                        record.authorityName!,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.event_outlined, size: 14, color: color),
                  const SizedBox(width: 4),
                  Text(
                    record.displayExpiry,
                    style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
                  ),
                  if (record.daysToExpiry != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '• ${daysLeftLabel(record.daysToExpiry)}',
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                  ],
                  const Spacer(),
                  if ((record.documentCount ?? 0) > 0)
                    Row(
                      children: [
                        const Icon(Icons.attach_file, size: 14),
                        const SizedBox(width: 2),
                        Text(
                          '${record.documentCount} file${record.documentCount == 1 ? '' : 's'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
