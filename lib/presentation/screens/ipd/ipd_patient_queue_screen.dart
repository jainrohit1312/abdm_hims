import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';

/// ---------------------------------------------------------------------------
/// IPD Patient Queue Screen (Primary IPD view)
/// ---------------------------------------------------------------------------
/// Hospital-wide list of every IPD patient (admitted + waiting + discharged +
/// transferred), newest first — same list paradigm as the OPD queue. Each card
/// shows patient name, UHID, ward, bed, doctor, admission date and status.
///
/// Tapping a card opens the IPD Patient Dashboard. The trailing overflow menu
/// exposes quick actions: View Profile, Discharge (only for admitted/waiting
/// patients) and View Bill.
/// ---------------------------------------------------------------------------
class IPDPatientQueueScreen extends ConsumerStatefulWidget {
  const IPDPatientQueueScreen({super.key});

  @override
  ConsumerState<IPDPatientQueueScreen> createState() =>
      _IPDPatientQueueScreenState();
}

class _IPDPatientQueueScreenState extends ConsumerState<IPDPatientQueueScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _statusFilter = 'all';
  bool _hasSearchText = false;

  static const _statusOptions = [
    {'value': 'all', 'label': 'All'},
    {'value': 'admitted', 'label': 'Admitted'},
    {'value': 'waiting', 'label': 'Waiting'},
    {'value': 'discharged', 'label': 'Discharged'},
    {'value': 'transferred', 'label': 'Transferred'},
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchTextChanged);
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchTextChanged() {
    final hasText = _searchController.text.isNotEmpty;
    if (hasText != _hasSearchText) {
      setState(() => _hasSearchText = hasText);
    }
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.extentAfter < 200) {
      ref.read(ipdPatientListProvider.notifier).nextPage();
    }
  }

  Future<void> _retryLoad() async {
    try {
      await ref.read(authStateProvider.notifier).checkAuthStatus();
    } catch (_) {}
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId != null && hospitalId.isNotEmpty) {
      await ref.read(ipdPatientListProvider.notifier).refresh();
    }
  }

  String _normalizeStatus(dynamic status) {
    return (status?.toString() ?? '').trim().toLowerCase();
  }

  String _patientName(Map<String, dynamic> entry) {
    final patient = entry['patients'] as Map<String, dynamic>?;
    if (patient == null) return 'Unknown';
    final names = [
      patient['first_name'],
      patient['last_name'],
    ].where((n) => n != null && n.toString().isNotEmpty).join(' ');
    return names.isNotEmpty ? names : 'Unknown';
  }

  String _patientUhid(Map<String, dynamic> entry) {
    final patient = entry['patients'] as Map<String, dynamic>?;
    return patient?['uhid']?.toString() ?? 'N/A';
  }

  String _bedNumber(Map<String, dynamic> entry) {
    final beds = entry['beds'] as Map<String, dynamic>?;
    final bedNumber = beds?['bed_number']?.toString();
    if (bedNumber != null && bedNumber.isNotEmpty) return bedNumber;
    return '—';
  }

  String _formatWardType(dynamic wardType) {
    final text = wardType?.toString() ?? '';
    if (text.isEmpty) return '—';
    final words = text.split('_').where((w) => w.isNotEmpty).toList();
    final formatted = words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join('-');
    return formatted.isEmpty ? 'General' : formatted;
  }

  String _formatDate(dynamic value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return '—';
    final date = DateTime.tryParse(text);
    if (date == null) return text;
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$day-$month-${date.year}';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'admitted':
        return Colors.green;
      case 'waiting':
        return Colors.blue;
      case 'transferred':
        return Colors.orange;
      case 'discharged':
        return Colors.blueGrey;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'admitted':
        return 'Admitted';
      case 'waiting':
        return 'Waiting';
      case 'discharged':
        return 'Discharged';
      case 'transferred':
        return 'Transferred';
      default:
        return status.isEmpty
            ? 'Unknown'
            : status[0].toUpperCase() + status.substring(1);
    }
  }

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> entries) {
    var filtered = entries.where((entry) {
      if (_statusFilter != 'all' &&
          _normalizeStatus(entry['status']) != _statusFilter) {
        return false;
      }
      return true;
    }).toList();

    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      filtered = filtered.where((entry) {
        final patient = entry['patients'] as Map<String, dynamic>?;
        final name =
            '${patient?['first_name'] ?? ''} ${patient?['last_name'] ?? ''}'
                .trim()
                .toLowerCase();
        final uhid = (patient?['uhid'] ?? '').toString().toLowerCase();
        final doctorName = (entry['doctor_name'] ?? '')
            .toString()
            .toLowerCase();
        final ward = (entry['ward_type'] ?? '').toString().toLowerCase();
        return name.contains(query) ||
            uhid.contains(query) ||
            doctorName.contains(query) ||
            ward.contains(query);
      }).toList();
    }
    return filtered;
  }

  void _handleQuickAction(
    BuildContext context,
    Map<String, dynamic> entry,
    String action,
  ) {
    final admissionId = entry['id']?.toString() ?? '';
    if (admissionId.isEmpty) return;

    switch (action) {
      case 'profile':
        final patientId = entry['patient_id']?.toString() ?? '';
        if (patientId.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Patient profile not linked.')),
          );
          return;
        }
        context.push('/patients/$patientId');
        break;
      case 'discharge':
        context.push('/ipd/discharge/$admissionId');
        break;
      case 'bill':
        context.push('/ipd/billing?admissionId=$admissionId');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authState = ref.watch(authStateProvider);
    final hospitalId = authState.hospitalId;

    // Hospital assignment change hone par fresh data load karo.
    ref.listen(authStateProvider, (previous, next) {
      final previousId = previous?.hospitalId;
      final nextId = next.hospitalId;
      if (nextId != null && nextId.isNotEmpty && nextId != previousId) {
        Future.microtask(() {
          if (mounted) {
            ref.read(ipdPatientListProvider.notifier).refresh();
          }
        });
      }
    });

    final listState = (hospitalId == null || hospitalId.isEmpty)
        ? null
        : ref.watch(ipdPatientListProvider);

    final allEntries = listState?.items ?? const <Map<String, dynamic>>[];

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('IPD Patient Queue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bed_outlined),
            tooltip: 'Ward Management',
            onPressed: () => context.push('/ipd/wards'),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/ipd/admit'),
            tooltip: 'Admit Patient',
          ),
          AppRefreshButton(
            onRefresh: () {
              if (hospitalId == null || hospitalId.isEmpty) {
                _retryLoad();
              } else {
                ref.read(ipdPatientListProvider.notifier).refresh();
              }
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search by patient name or UHID...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _hasSearchText
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.3),
                                      ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _statusOptions.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final opt = _statusOptions[index];
                      final selected = _statusFilter == opt['value'];
                      final count = opt['value'] == 'all'
                          ? allEntries.length
                          : allEntries
                                .where(
                                  (e) =>
                                      _normalizeStatus(e['status']) ==
                                      opt['value'],
                                )
                                .length;
                      return FilterChip(
                        label: Text(
                          '${opt['label']} ($count)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        selected: selected,
                        onSelected: (_) => setState(() {
                          _statusFilter = opt['value'] as String;
                        }),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: _buildBody(theme, hospitalId, listState),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    String? hospitalId,
    PaginationState<Map<String, dynamic>>? listState,
  ) {
    if (hospitalId == null || hospitalId.isEmpty) {
      return _buildHospitalNotAssigned(theme);
    }

    if (listState == null || (listState.isLoading && listState.items.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    if (listState.error != null && listState.items.isEmpty) {
      return _buildError(theme, listState.error!);
    }

    if (listState.items.isEmpty) {
      return _buildNoAdmissions(theme);
    }

    final filtered = _applyFilters(listState.items);

    if (filtered.isEmpty) {
      return _buildNoMatch(theme);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadMore();
    });

    return RefreshIndicator(
      onRefresh: () => ref.read(ipdPatientListProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: filtered.length + 1,
        itemBuilder: (context, index) {
          if (index < filtered.length) {
            return _buildEntryCard(theme, filtered[index]);
          }
          return _buildFooter(context, theme, listState, filtered.length);
        },
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    ThemeData theme,
    PaginationState<Map<String, dynamic>> state,
    int itemCount,
  ) {
    if (state.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (state.error != null && state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: () =>
                ref.read(ipdPatientListProvider.notifier).nextPage(),
            icon: const Icon(Icons.refresh),
            label: const Text('Failed to load more — Retry'),
          ),
        ),
      );
    }

    if (!state.hasMore && itemCount > 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'No more patients',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return const SizedBox(height: 16);
  }

  Widget _buildHospitalNotAssigned(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _retryLoad,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.local_hospital,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Hospital not assigned',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your account is not linked to any hospital. Please contact the administrator.',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      onPressed: () => _retryLoad(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ThemeData theme, String error) {
    return RefreshIndicator(
      onRefresh: () => ref.read(ipdPatientListProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load data',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      error,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      onPressed: () => ref.invalidate(ipdPatientListProvider),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoAdmissions(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: () => ref.read(ipdPatientListProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.local_hotel_outlined,
                    size: 64,
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No IPD patients yet',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'New admissions will appear here',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => context.push('/ipd/admit'),
                    icon: const Icon(Icons.add),
                    label: const Text('Admit Patient'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoMatch(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: () => ref.read(ipdPatientListProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.search_off,
                    size: 48,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No matching patients',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Try a different search or filter',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(ThemeData theme, Map<String, dynamic> entry) {
    final status = _normalizeStatus(entry['status']);
    final admissionId = entry['id'] as String?;
    final statusColor = _statusColor(status);
    final canDischarge = status == 'admitted' || status == 'waiting';

    final admissionDate = _formatDate(entry['admission_date']);
    final dischargeDate = _formatDate(entry['discharge_date']);
    final dateText = dischargeDate == '—'
        ? 'Admitted: $admissionDate'
        : '$admissionDate → $dischargeDate';
    final ward = _formatWardType(entry['ward_type']);
    final bed = _bedNumber(entry);
    final doctor = entry['doctor_name']?.toString();
    final department = entry['department_name']?.toString();

    final subtitleParts = <String>[
      'Ward: $ward  •  Bed: $bed',
      if (doctor != null && doctor.isNotEmpty) 'Doctor: $doctor',
      if (department != null && department.isNotEmpty)
        'Department: $department',
    ];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.18),
          child: Icon(Icons.local_hotel, color: statusColor, size: 24),
        ),
        title: Text(_patientName(entry), style: theme.textTheme.titleSmall),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('UHID: ${_patientUhid(entry)}'),
            const SizedBox(height: 2),
            Text(dateText),
            const SizedBox(height: 4),
            Text(subtitleParts.join('\n')),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _statusLabel(status),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<String>(
              tooltip: 'Quick actions',
              icon: const Icon(Icons.more_vert),
              onSelected: (action) =>
                  _handleQuickAction(context, entry, action),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'profile',
                  child: Row(
                    children: [
                      Icon(Icons.person_outline),
                      SizedBox(width: 12),
                      Text('View Profile'),
                    ],
                  ),
                ),
                if (canDischarge)
                  const PopupMenuItem(
                    value: 'discharge',
                    child: Row(
                      children: [
                        Icon(Icons.logout, color: Colors.red),
                        SizedBox(width: 12),
                        Text('Discharge'),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'bill',
                  child: Row(
                    children: [
                      Icon(Icons.receipt_long_outlined),
                      SizedBox(width: 12),
                      Text('View Bill'),
                    ],
                  ),
                ),
              ],
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () {
          if (admissionId != null) {
            context.push('/ipd/patient/$admissionId');
          }
        },
      ),
    );
  }
}
