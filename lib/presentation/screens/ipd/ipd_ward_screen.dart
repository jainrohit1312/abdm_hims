import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';

class IPDWardScreen extends ConsumerWidget {
  const IPDWardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Bootstrap se hospitalId hamesha available rahega
    final hospitalId = ref.read(authStateProvider).hospitalId!;

    final bedsAsync = ref.watch(hospitalBedsProvider(hospitalId));
    final wardsAsync = ref.watch(hospitalWardsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Ward Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.format_list_bulleted),
            tooltip: 'IPD Patient Queue',
            onPressed: () => context.push('/ipd/queue'),
          ),
          AppRefreshButton(
            onRefresh: () => ref.invalidate(hospitalWardsProvider(hospitalId)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/ipd/admit'),
        icon: const Icon(Icons.add),
        label: const Text('Admit Patient'),
      ),
      body: bedsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(
          message: 'Failed to load beds: $e',
          onRetry: () => ref.invalidate(hospitalBedsProvider(hospitalId)),
        ),
        data: (beds) {
          return wardsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorView(
              message: 'Failed to load wards: $e',
              onRetry: () => ref.invalidate(hospitalWardsProvider(hospitalId)),
            ),
            data: (wards) {
              final tabs = ['All', ...wards];
              return _WardTabView(beds: beds, tabs: tabs);
            },
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tabs, Search, aur Filter logic yahan handle hoga
class _WardTabView extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> beds;
  final List<String> tabs;

  const _WardTabView({required this.beds, required this.tabs});

  @override
  ConsumerState<_WardTabView> createState() => _WardTabViewState();
}

class _WardTabViewState extends ConsumerState<_WardTabView>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: widget.tabs.length, vsync: this);
  }

  @override
  void didUpdateWidget(_WardTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.tabs, widget.tabs)) {
      _tabController.dispose();
      _tabController = TabController(length: widget.tabs.length, vsync: this);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = widget.tabs;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search patients in ward...',
                    prefixIcon: const Icon(Icons.search),
                                      ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  icon: const Icon(Icons.filter_list),
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabController,
          labelColor: theme.colorScheme.primary,
          tabs: tabs.map((tab) => Tab(text: tab)).toList(),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: tabs
                .map((tab) => _buildWardList(theme, tab, widget.beds))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _statusCard(String label, String count, Color color) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(
                count,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  String _formatWardType(String wardType) {
    final words = wardType.split('_').where((w) => w.isNotEmpty).toList();
    final formatted = words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join('-');
    return formatted.isEmpty ? 'General' : formatted;
  }

  Widget _buildWardList(
    ThemeData theme,
    String wardType,
    List<Map<String, dynamic>> allBeds,
  ) {
    final beds = wardType == 'All'
        ? allBeds
        : allBeds.where((b) {
            final dbWardType = b['ward_type']?.toString() ?? 'General';
            return dbWardType.toLowerCase() == wardType.toLowerCase();
          }).toList();

    final occupiedCount = beds
        .where((b) => b['status'].toString().toLowerCase() == 'occupied')
        .length;
    final availableCount = beds
        .where((b) => b['status'].toString().toLowerCase() == 'available')
        .length;
    final reservedCount = beds
        .where((b) => b['status'].toString().toLowerCase() == 'reserved')
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              _statusCard('Occupied', occupiedCount.toString(), Colors.orange),
              _statusCard('Available', availableCount.toString(), Colors.green),
              _statusCard('Reserved', reservedCount.toString(), Colors.blue),
            ],
          ),
        ),
        Expanded(
          child: beds.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.bed, size: 48, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text(
                        'No beds in this ward',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: beds.length,
                  itemBuilder: (context, index) {
                    final bed = beds[index];
                    final bedId = bed['id']?.toString() ?? '';
                    final bedNumber =
                        bed['bed_number']?.toString() ?? 'Bed ${index + 1}';
                    final status = bed['status']?.toString() ?? 'Available';
                    final patientName = bed['patient_name']?.toString();
                    final isOccupied = status.toLowerCase() == 'occupied';
                    final dbWardType = _formatWardType(
                      bed['ward_type']?.toString() ?? 'general',
                    );

                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: const Icon(Icons.bed),
                        ),
                        title: Text(bedNumber),
                        subtitle: Text(
                          isOccupied &&
                                  patientName != null &&
                                  patientName.isNotEmpty
                              ? '$patientName - $dbWardType Ward'
                              : '$dbWardType Ward',
                        ),
                        trailing: Chip(
                          label: Text(status),
                          backgroundColor: isOccupied
                              ? Colors.orange.withValues(alpha: 0.2)
                              : Colors.green.withValues(alpha: 0.2),
                        ),
                        onTap: () async {
                          if (!isOccupied) return;
                          final db = ref.read(databaseServiceProvider);
                          final admissionId = await db
                              .getActiveAdmissionIdForBed(bedId);
                          if (!context.mounted) return;
                          if (admissionId == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'No active admission found for this bed.',
                                ),
                              ),
                            );
                            return;
                          }
                          context.push('/ipd/patient/$admissionId');
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
