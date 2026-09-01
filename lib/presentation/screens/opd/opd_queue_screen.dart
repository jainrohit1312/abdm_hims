import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../../services/print_prescription.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';
import 'opd_slip_print.dart';

class OPDQueueScreen extends ConsumerStatefulWidget {
  const OPDQueueScreen({super.key});

  @override
  ConsumerState<OPDQueueScreen> createState() => _OPDQueueScreenState();
}

class _OPDQueueScreenState extends ConsumerState<OPDQueueScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _statusFilter = 'all';
  bool _hasSearchText = false;
  String? _printingOpdId;
  String? _printingPrescriptionOpdId;

  static const _statusOptions = [
    {'value': 'all', 'label': 'All'},
    {'value': 'pending', 'label': 'Pending'},
    {'value': 'completed', 'label': 'Completed'},
    {'value': 'cancelled', 'label': 'Cancelled'},
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

  Future<void> _retryLoad() async {
    try {
      await ref.read(authStateProvider.notifier).checkAuthStatus();
    } catch (_) {}
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId != null && hospitalId.isNotEmpty) {
      await ref.read(opdQueueProvider.notifier).refresh();
    }
  }

  /// Scroll-end detection: jab list ke end ke paas pahunch jayein toh
  /// next page fetch karo.
  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.extentAfter < 200) {
      ref.read(opdQueueProvider.notifier).nextPage();
    }
  }

  void _onSearchTextChanged() {
    final hasText = _searchController.text.isNotEmpty;
    if (hasText != _hasSearchText) {
      setState(() => _hasSearchText = hasText);
    }
  }

  List<Map<String, dynamic>> _applyFilters(
    List<Map<String, dynamic>> entries,
  ) {
    var filtered = entries.where((entry) {
      if (_statusFilter != 'all' && entry['status'] != _statusFilter) {
        return false;
      }
      return true;
    }).toList();

    final query = _searchController.text;
    if (query.isNotEmpty) {
      final lower = query.toLowerCase();
      filtered = filtered.where((entry) {
        final patient = entry['patients'] as Map<String, dynamic>?;
        final name =
            '${patient?['first_name'] ?? ''} ${patient?['last_name'] ?? ''}'
                .trim()
                .toLowerCase();
        final uhid = (patient?['uhid'] ?? '').toString().toLowerCase();
        return name.contains(lower) || uhid.contains(lower);
      }).toList();
    }
    return filtered;
  }

  void _onSearchChanged(String query) {
    if (!mounted) return;
    setState(() {});
  }

  void _onStatusFilterChanged(String? value) {
    if (value == null) return;
    setState(() {
      _statusFilter = value;
    });
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

  Color _statusColor(String? status) {
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'pending':
        return Colors.orange;
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String? status) {
    switch (status) {
      case 'completed':
        return 'Completed';
      case 'pending':
        return 'Pending';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status ?? 'Unknown';
    }
  }

  String _paymentStatusLabel(dynamic status) {
    switch (status?.toString().toLowerCase()) {
      case 'paid':
        return 'Paid';
      case 'partially_paid':
        return 'Partially Paid';
      case 'unpaid':
        return 'Unpaid';
      default:
        return status?.toString() ?? 'Unpaid';
    }
  }

  String _paymentAmountText(Map<String, dynamic> entry) {
    final amount = entry['payment_amount'] ?? entry['paid_amount'] ?? 0;
    return amount.toString();
  }

  String _slipPaymentModeLabel(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'cash':
        return 'Cash';
      case 'card':
        return 'Card';
      case 'upi':
        return 'UPI';
      case 'insurance':
        return 'Insurance';
      default:
        return value?.toString() ?? 'N/A';
    }
  }

  /// Queue entry se seedha A5 payment slip ka print dialog kholta hai
  /// (registration ke baad wale flow jaisa).
  Future<void> _printSlip(Map<String, dynamic> entry) async {
    final opdId = entry['id']?.toString();
    if (opdId == null || opdId.isEmpty) return;
    if (_printingOpdId != null) return;

    setState(() => _printingOpdId = opdId);

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);
      final hospitalId = authState.hospitalId;

      final patients =
          (entry['patients'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final patientName = [
        patients['first_name'],
        patients['last_name'],
      ].where((n) => n != null && n.toString().isNotEmpty).join(' ').trim();

      Map<String, dynamic>? hospital;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        hospital = await dbService.getById(
          ApiConstants.hospitalsTable,
          hospitalId,
        );
      }

      final doctorId = entry['doctor_id']?.toString();
      final departmentId = entry['department_id']?.toString();
      final storedDoctorName = entry['doctor_name']?.toString();
      final doctorName = (storedDoctorName != null && storedDoctorName.isNotEmpty)
          ? storedDoctorName
          : await _resolveDoctorName(doctorId);
      var departmentName = 'N/A';
      if (departmentId != null && departmentId.isNotEmpty) {
        final dept = await dbService.getById(
          ApiConstants.departmentsTable,
          departmentId,
        );
        departmentName = dept?['name']?.toString() ?? 'N/A';
      }

      final slipNumber =
          'OPD-${(opdId.length >= 8 ? opdId.substring(0, 8) : opdId).toUpperCase()}';

      final netPayable = double.tryParse(
            (entry['payment_amount'] ?? entry['paid_amount'] ?? 0).toString(),
          ) ??
          0;
      final consultationFee = double.tryParse(
            entry['consultation_fee']?.toString() ?? '',
          ) ??
          netPayable;
      final paidAmount = double.tryParse(
            (entry['paid_amount'] ?? netPayable).toString(),
          ) ??
          netPayable;
      final balanceAmount = double.tryParse(
            (entry['balance_amount'] ?? (netPayable - paidAmount)).toString(),
          ) ??
          (netPayable - paidAmount);

      final slipData = <String, dynamic>{
        'hospitalName': hospital?['name']?.toString() ?? 'HIMS Hospital',
        'hospitalAddress':
            hospital?['address']?.toString() ??
            '123, Healthcare Avenue, New Delhi',
        'patientName': patientName.isEmpty ? 'Unknown Patient' : patientName,
        'uhid': patients['uhid']?.toString() ?? 'N/A',
        'doctorName': doctorName,
        'department': departmentName,
        'consultationFee': consultationFee,
        'discount': consultationFee - netPayable,
        'netPayable': netPayable,
        'paymentAmount': netPayable,
        'paidAmount': paidAmount,
        'balanceAmount': balanceAmount,
        'paymentMode': _slipPaymentModeLabel(entry['payment_mode']),
        'paymentStatus': _paymentStatusLabel(entry['payment_status']),
        'date':
            DateTime.tryParse(entry['visit_date']?.toString() ?? '') ??
            DateTime.now(),
        'slipNumber': slipNumber,
      };

      await OPDSlipPrintService.printSlip(slipData);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Slip print failed. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _printingOpdId = null);
    }
  }

  /// Queue entry ki saved prescription print karta hai (Save & Complete ke
  /// baad yahin se print hoti hai — OPD Slip ki tarah).
  Future<void> _printPrescription(Map<String, dynamic> entry) async {
    final opdId = entry['id']?.toString();
    if (opdId == null || opdId.isEmpty) return;
    if (_printingPrescriptionOpdId != null) return;

    setState(() => _printingPrescriptionOpdId = opdId);

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final patients =
          (entry['patients'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final patientName = [
        patients['first_name'],
        patients['last_name'],
      ].where((n) => n != null && n.toString().isNotEmpty).join(' ').trim();

      final error = await PrescriptionPrintService.printForOPD(
        db: dbService,
        opdRegistrationId: opdId,
        hospitalId: authState.hospitalId,
        fallbackPatientName: patientName.isEmpty ? 'Patient' : patientName,
        fallbackUhid: patients['uhid']?.toString() ?? 'N/A',
      );

      if (mounted && error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Prescription print failed. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _printingPrescriptionOpdId = null);
    }
  }

  Future<String> _resolveDoctorName(String? doctorId) async {
    if (doctorId == null || doctorId.isEmpty) return 'N/A';
    try {
      final dbService = ref.read(databaseServiceProvider);

      // doctor_id column har deployment mein exist nahi karta; agar kisi row
      // mein ho to doctors aur users dono tables try karo, warna N/A.
      final doctor = await dbService.getById(ApiConstants.doctorsTable, doctorId);
      final doctorName = doctor?['name']?.toString();
      if (doctorName != null && doctorName.isNotEmpty) return doctorName;

      final user = await dbService.getById(ApiConstants.usersTable, doctorId);
      if (user != null) {
        final name = [
          user['first_name'],
          user['last_name'],
        ].where((n) => n != null && n.toString().isNotEmpty).join(' ').trim();
        if (name.isNotEmpty) return name;
      }
    } catch (_) {
      // Doctor name optional hai; slip baaki data ke saath print ho jayegi.
    }
    return 'N/A';
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
      if (nextId != null &&
          nextId.isNotEmpty &&
          nextId != previousId) {
        Future.microtask(() {
          if (mounted) {
            ref.read(opdQueueProvider.notifier).refresh();
          }
        });
      }
    });

    // Hospital assigned hone par hi pagination provider watch karo.
    final queueState = (hospitalId == null || hospitalId.isEmpty)
        ? null
        : ref.watch(opdQueueProvider);

    final allEntries =
        queueState?.items ?? const <Map<String, dynamic>>[];

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('OPD Queue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/opd/register'),
            tooltip: 'New OPD Visit',
          ),
          AppRefreshButton(
            onRefresh: () {
              if (hospitalId == null || hospitalId.isEmpty) {
                _retryLoad();
              } else {
                setState(() {});
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
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.3),
                                      ),
                  onChanged: _onSearchChanged,
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
                      return FilterChip(
                        label: Text(
                          '${opt['label']} (${opt['value'] == 'all' ? allEntries.length : allEntries.where((e) => e['status'] == opt['value']).length})',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        selected: selected,
                        onSelected: (_) =>
                            _onStatusFilterChanged(opt['value'] as String),
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
      body: _buildBody(theme, hospitalId, queueState),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    String? hospitalId,
    PaginationState<Map<String, dynamic>>? queueState,
  ) {
    // Hospital assign nahi hua hai.
    if (hospitalId == null || hospitalId.isEmpty) {
      return _buildHospitalNotAssigned(theme);
    }

    // First-page / refresh loading state.
    if (queueState == null ||
        (queueState.isLoading && queueState.items.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    // Initial load error state.
    if (queueState.error != null && queueState.items.isEmpty) {
      return _buildError(theme, queueState.error!);
    }

    // Data loaded successfully but queue is empty.
    if (queueState.items.isEmpty) {
      return _buildNoRegistrations(theme);
    }

    final filtered = _applyFilters(queueState.items);

    if (filtered.isEmpty) {
      return _buildNoMatch(theme);
    }

    // Agar pehla page screen se chhota hai toh automatically next page load
    // karne ka mauka do (jab tak hasMore true hai).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadMore();
    });

    return RefreshIndicator(
      onRefresh: () => ref.read(opdQueueProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: filtered.length + 1,
        itemBuilder: (context, index) {
          if (index < filtered.length) {
            return _buildEntryCard(theme, filtered[index]);
          }
          return _buildFooter(context, theme, queueState, filtered.length);
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
    // Next page load ho raha hai.
    if (state.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    // Next page load fail hua — retry option.
    if (state.error != null && state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: () => ref.read(opdQueueProvider.notifier).nextPage(),
            icon: const Icon(Icons.refresh),
            label: const Text('Failed to load more — Retry'),
          ),
        ),
      );
    }

    // Saara data load ho chuka hai.
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
      onRefresh: () => ref.read(opdQueueProvider.notifier).refresh(),
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
                      onPressed: () => ref.invalidate(opdQueueProvider),
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

  Widget _buildNoRegistrations(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: () => ref.read(opdQueueProvider.notifier).refresh(),
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
                    Icons.queue,
                    size: 64,
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No OPD registrations yet',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'New visits will appear here',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => context.push('/opd/register'),
                    icon: const Icon(Icons.add),
                    label: const Text('New OPD Visit'),
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
      onRefresh: () => ref.read(opdQueueProvider.notifier).refresh(),
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
                    'No matching entries',
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
    final status = entry['status'] as String?;
    final opdId = entry['id'] as String?;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _statusColor(status).withValues(alpha: 0.2),
          child: Icon(
            Icons.person,
            color: _statusColor(status),
            size: 24,
          ),
        ),
        title: Text(
          _patientName(entry),
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('UHID: ${_patientUhid(entry)}'),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _statusLabel(status),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _statusColor(status),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (entry['visit_date'] != null)
                  Text(
                    entry['visit_date'].toString(),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            if (status == 'cancelled') ...[
              const SizedBox(height: 4),
              Text(
                'Reason: ${entry['cancellation_reason'] ?? 'No reason provided'}',
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Payment: ${_paymentStatusLabel(entry['payment_status'])} • '
              '₹ ${_paymentAmountText(entry)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_printingPrescriptionOpdId == opdId)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                icon: const Icon(
                  Icons.medication_outlined,
                  color: Colors.teal,
                ),
                tooltip: 'Print Prescription',
                onPressed: () {
                  if (opdId != null) {
                    _printPrescription(entry);
                  }
                },
              ),
            if (_printingOpdId == opdId)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.print, color: Colors.blue),
                tooltip: 'Print OPD Slip',
                onPressed: () {
                  if (opdId != null) {
                    _printSlip(entry);
                  }
                },
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () {
          if (opdId != null) {
            context.push('/opd/consultation/$opdId');
          }
        },
      ),
    );
  }
}
