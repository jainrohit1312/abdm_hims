import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../widgets/smart_navigation.dart';

/// Unified Billing History screen (`/billing`).
///
/// Read-only, chronological payment/billing history across OPD, IPD and
/// Lab-Diagnostics (plus any legacy manual billing rows, which still appear
/// under "All"). Tapping a tile opens the ORIGINAL source workflow — this
/// screen never creates or edits bills itself.
///
/// Performance:
/// * Only the active tab fetches on open; other tabs load on demand and stay
///   cached once visited.
/// * Server-side pagination — 30 lightweight rows per page.
/// * No bulk `billing_items` / `payment_logs` payloads; transaction history
///   is lazy-loaded per bill when the tile is expanded.
class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// Tabs shown to the user. `null` = All. The legacy Manual tab is removed;
  /// historical manual rows still appear in All.
  static const _sourceTypes = <String?>[null, 'opd', 'ipd', 'lab'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _sourceTypes.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String? get _activeSourceType {
    final index = _tabController.index;
    if (index < 0 || index >= _sourceTypes.length) return _sourceTypes.first;
    return _sourceTypes[index];
  }

  void _refreshActiveTab(WidgetRef ref) {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) return;
    ref.invalidate(
      allBillsProvider(
        BillingFilter(hospitalId: hospitalId, sourceType: _activeSourceType),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Unified Billing'),
        actions: [
          IconButton(
            tooltip: 'Refresh active tab',
            onPressed: () => _refreshActiveTab(ref),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'OPD'),
            Tab(text: 'IPD'),
            Tab(text: 'Lab-Diagnostics'),
          ],
        ),
      ),
      body: hospitalId == null || hospitalId.isEmpty
          ? const Center(
              child: Text('Hospital not assigned to this user.'),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                for (final sourceType in _sourceTypes)
                  _BillListTab(
                    key: PageStorageKey('billing_tab_${sourceType ?? 'all'}'),
                    hospitalId: hospitalId,
                    sourceType: sourceType,
                  ),
              ],
            ),
    );
  }
}

/// One tab of the billing history screen. Only the active tab is mounted by
/// the `TabBarView`, so only the active source type is fetched. Once a tab has
/// been visited it is kept alive and its provider stays cached.
class _BillListTab extends ConsumerStatefulWidget {
  const _BillListTab({
    super.key,
    required this.hospitalId,
    required this.sourceType,
  });

  final String hospitalId;
  final String? sourceType;

  @override
  ConsumerState<_BillListTab> createState() => _BillListTabState();
}

class _BillListTabState extends ConsumerState<_BillListTab>
    with AutomaticKeepAliveClientMixin {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _searchQuery = '';

  @override
  bool get wantKeepAlive => true;

  BillingFilter get _filter => BillingFilter(
        hospitalId: widget.hospitalId,
        sourceType: widget.sourceType,
      );

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() => _searchQuery = _searchController.text);
  }

  /// Scroll-end detection: load the next page when the list end is near.
  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.extentAfter < 300) {
      ref.read(allBillsProvider(_filter).notifier).nextPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(allBillsProvider(_filter));

    final query = _searchQuery.trim().toLowerCase();
    final visible = query.isEmpty
        ? state.items
        : state.items
              .where(
                (bill) =>
                    (bill['patient_name']?.toString() ?? '')
                        .toLowerCase()
                        .contains(query) ||
                    (bill['uhid']?.toString() ?? '')
                        .toLowerCase()
                        .contains(query) ||
                    (bill['bill_number']?.toString() ?? '')
                        .toLowerCase()
                        .contains(query),
              )
              .toList();

    return Column(
      children: [
        _buildSearchBar(context),
        Expanded(child: _buildBody(context, state, visible)),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    PaginationState<Map<String, dynamic>> state,
    List<Map<String, dynamic>> visible,
  ) {
    // First page / refresh loading state. The second clause covers the brief
    // window before the provider's scheduled first-page fetch starts.
    if ((state.isLoading && state.items.isEmpty) ||
        (state.items.isEmpty &&
            state.hasMore &&
            state.error == null &&
            !state.isLoading)) {
      return const Center(child: CircularProgressIndicator());
    }

    // Initial load error state.
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Failed to load bills: ${state.error}'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  ref.read(allBillsProvider(_filter).notifier).refresh(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // No bills in this source at all.
    if (state.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => ref.read(allBillsProvider(_filter).notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: const [
            SizedBox(height: 80),
            Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 12),
            Center(child: Text('No bills found.')),
          ],
        ),
      );
    }

    // Client-side search over the loaded pages didn't match anything.
    if (visible.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: const [
          SizedBox(height: 80),
          Icon(Icons.search_off, size: 64, color: Colors.grey),
          SizedBox(height: 12),
          Center(child: Text('No bills match this search.')),
        ],
      );
    }

    // If the first page doesn't fill the viewport, load the next page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadMore();
    });

    return RefreshIndicator(
      onRefresh: () => ref.read(allBillsProvider(_filter).notifier).refresh(),
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: visible.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index < visible.length) {
            return _BillCard(bill: visible[index]);
          }
          return _buildFooter(context, state, visible.length);
        },
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
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
                ref.read(allBillsProvider(_filter).notifier).nextPage(),
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
            'No more bills',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    return const SizedBox(height: 16);
  }

  Widget _buildSearchBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: TextField(
          controller: _searchController,
          onChanged: (value) => setState(() => _searchQuery = value),
          decoration: InputDecoration(
            hintText: 'Search patient name, UHID or bill number…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
            isDense: true,
            filled: true,
          ),
        ),
      ),
    );
  }
}

/// A single bill history card: patient, UHID, bill number, date, source,
/// amounts, status and lazy-loaded transaction history.
class _BillCard extends ConsumerWidget {
  const _BillCard({required this.bill});

  final Map<String, dynamic> bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final total = _toDouble(bill['total_amount']);
    final paid = _toDouble(bill['paid_amount']);
    final balance = _toDouble(bill['balance_amount']);
    final status = bill['payment_status']?.toString() ?? 'unpaid';
    final sourceType = bill['source_type']?.toString() ?? 'manual';
    final date = _parseDate(bill['bill_date']);

    return Card(
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSource(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bill['patient_name']?.toString() ?? 'Unknown Patient',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'UHID: ${bill['uhid']?.toString() ?? 'N/A'}   •   '
                          '${bill['bill_number']?.toString() ?? 'N/A'}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          date?.toDisplayDate ?? 'N/A',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        _SourceChip(sourceType: sourceType),
                      ],
                    ),
                  ),
                  _StatusChip(status: status),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _AmountColumn(label: 'Total', value: total),
                  const SizedBox(width: 12),
                  _AmountColumn(label: 'Paid', value: paid, color: Colors.green),
                  const SizedBox(width: 12),
                  _AmountColumn(
                    label: 'Balance',
                    value: balance,
                    color: balance > 0 ? Colors.red : Colors.green,
                  ),
                ],
              ),
              if ((bill['id']?.toString() ?? '').isNotEmpty)
                _TransactionHistorySection(billId: bill['id'].toString()),
            ],
          ),
        ),
      ),
    );
  }

  void _openSource(BuildContext context) {
    final sourceType = bill['source_type']?.toString() ?? 'manual';
    final opdId = bill['opd_registration_id']?.toString();
    final ipdId = bill['ipd_admission_id']?.toString();
    final diagnosticOrderId = bill['diagnostic_order_id']?.toString();
    final billId = bill['id']?.toString() ?? '';

    switch (sourceType) {
      case 'opd':
        if (opdId != null && opdId.isNotEmpty) {
          context.push('/opd/consultation/$opdId');
        } else {
          _openReadOnlyBill(context, billId);
        }
      case 'ipd':
        if (ipdId != null && ipdId.isNotEmpty) {
          context.push('/ipd/patient/$ipdId');
        } else {
          _openReadOnlyBill(context, billId);
        }
      case 'lab':
      case 'diagnostics':
        if (diagnosticOrderId != null && diagnosticOrderId.isNotEmpty) {
          context.push('/diagnostics/results?orderId=$diagnosticOrderId');
        } else {
          context.push('/diagnostics/results');
        }
      default:
        _openReadOnlyBill(context, billId);
    }
  }

  void _openReadOnlyBill(BuildContext context, String billId) {
    if (billId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Source record not available.')),
      );
      return;
    }
    context.push('/billing/view/$billId');
  }

  static double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}

/// Lazily loads the payment logs of one bill only when the user expands the
/// "Transaction History" tile. The provider result stays cached by Riverpod
/// for subsequent expansions of the same bill.
class _TransactionHistorySection extends ConsumerStatefulWidget {
  const _TransactionHistorySection({required this.billId});

  final String billId;

  @override
  ConsumerState<_TransactionHistorySection> createState() =>
      _TransactionHistorySectionState();
}

class _TransactionHistorySectionState
    extends ConsumerState<_TransactionHistorySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: Text(
          'Transaction History',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
        children: _expanded ? [_buildLogs(theme)] : const [],
      ),
    );
  }

  Widget _buildLogs(ThemeData theme) {
    final logsAsync = ref.watch(billPaymentLogsProvider(widget.billId));

    return logsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Failed to load transaction history: $error',
          style: theme.textTheme.bodySmall,
        ),
      ),
      data: (logs) {
        if (logs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'No payments recorded yet.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        return Column(
          children: [
            for (final log in logs.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.payments_outlined,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${_formatDateTime(log['payment_date'])}   •   '
                        '${(log['payment_mode']?.toString() ?? 'cash').toUpperCase()}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      _inr(
                        _toDouble(
                          log['amount_paid'] ?? log['payment_amount'],
                        ),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  static String _inr(double value) => _currency.format(value);

  static double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  static String _formatDateTime(dynamic value) {
    final date = value == null ? null : DateTime.tryParse(value.toString());
    if (date == null) return 'N/A';
    return DateFormat('dd/MM/yyyy hh:mm a').format(date);
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.sourceType});

  final String sourceType;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (sourceType) {
      'opd' => ('OPD Slip', Icons.receipt_outlined, Colors.blue),
      'ipd' => ('IPD Discharge', Icons.local_hospital_outlined, Colors.teal),
      'lab' => ('Lab-Diagnostics', Icons.biotech_outlined, Colors.deepPurple),
      'pharmacy' => ('Pharmacy', Icons.medication_outlined, Colors.orange),
      _ => ('Manual', Icons.edit_note_outlined, Colors.brown),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountColumn extends StatelessWidget {
  const _AmountColumn({required this.label, required this.value, this.color});

  final String label;
  final double value;
  final Color? color;

  static final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            _currency.format(value),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: color ?? Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'paid' => ('Paid', Colors.green),
      'partially_paid' => ('Partial', Colors.orange),
      'refunded' => ('Refunded', Colors.purple),
      'waived' => ('Waived', Colors.blueGrey),
      _ => ('Unpaid', Colors.red),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
