import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../widgets/smart_navigation.dart';

/// Unified Billing Management screen (`/billing`).
///
/// Five tabs, one for every bill source tracked by the unified billing system:
/// * All     — every bill across all sources
/// * OPD     — OPD slip bills (raw `opd_registrations` + materialised rows)
/// * IPD     — bills generated at IPD discharge / billing
/// * Lab     — lab & diagnostics bills
/// * Manual  — manual bills created from the billing module
class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _sourceTypes = <String?>[null, 'opd', 'ipd', 'lab', 'manual'];

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

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Unified Billing'),
        actions: [
          AppRefreshButton(
            onRefresh: () {
              if (hospitalId != null && hospitalId.isNotEmpty) {
                for (final sourceType in _sourceTypes) {
                  ref.invalidate(
                    allBillsProvider(
                      BillingFilter(
                        hospitalId: hospitalId,
                        sourceType: sourceType,
                      ),
                    ),
                  );
                }
              }
              setState(() {});
            },
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
            Tab(text: 'Manual'),
          ],
        ),
      ),
      floatingActionButton: hospitalId == null || hospitalId.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.push('/billing/new'),
              icon: const Icon(Icons.add),
              label: const Text('New Manual Bill'),
            ),
      body: hospitalId == null
          ? const Center(
              child: Text('Hospital not assigned to this user.'),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                for (final sourceType in _sourceTypes)
                  _BillListTab(hospitalId: hospitalId, sourceType: sourceType),
              ],
            ),
    );
  }
}

/// One tab of the billing screen. Renders bills with client-side search.
class _BillListTab extends ConsumerStatefulWidget {
  const _BillListTab({required this.hospitalId, required this.sourceType});

  final String hospitalId;
  final String? sourceType;

  @override
  ConsumerState<_BillListTab> createState() => _BillListTabState();
}

class _BillListTabState extends ConsumerState<_BillListTab> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = BillingFilter(
      hospitalId: widget.hospitalId,
      sourceType: widget.sourceType,
    );
    final billsAsync = ref.watch(allBillsProvider(filter));

    return Column(
      children: [
        _buildSearchBar(context),
        Expanded(
          child: billsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Failed to load bills: $error'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => ref.invalidate(allBillsProvider(filter)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
            data: (bills) {
              final query = _searchQuery.trim().toLowerCase();
              final visible = query.isEmpty
                  ? bills
                  : bills
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

              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(allBillsProvider(filter));
                },
                child: visible.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(16),
                        children: const [
                          SizedBox(height: 80),
                          Icon(Icons.receipt_long_outlined,
                              size: 64, color: Colors.grey),
                          SizedBox(height: 12),
                          Center(child: Text('No bills found.')),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) =>
                            _BillCard(bill: visible[index]),
                      ),
              );
            },
          ),
        ),
      ],
    );
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

/// A single bill card: patient, UHID, bill number, date, source, amounts,
/// status and expandable transaction history (payment logs).
class _BillCard extends ConsumerWidget {
  const _BillCard({required this.bill});

  final Map<String, dynamic> bill;

  static final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final total = _toDouble(bill['total_amount']);
    final paid = _toDouble(bill['paid_amount']);
    final balance = _toDouble(bill['balance_amount']);
    final status = bill['payment_status']?.toString() ?? 'unpaid';
    final sourceType = bill['source_type']?.toString() ?? 'manual';
    final logs = ((bill['payment_logs'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final items = ((bill['billing_items'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final date = _parseDate(bill['bill_date']);

    return Card(
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/billing/edit/${bill['id']}'),
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
                          '${date?.toDisplayDate ?? 'N/A'}   •   '
                          '${items.length} item${items.length == 1 ? '' : 's'}',
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
              if (logs.isNotEmpty) ...[
                const SizedBox(height: 4),
                Theme(
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 4),
                    title: Text(
                      'Transaction History (${logs.length})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
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
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _inr(double value) => _currency.format(value);

  static double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String _formatDateTime(dynamic value) {
    final date = _parseDate(value);
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
