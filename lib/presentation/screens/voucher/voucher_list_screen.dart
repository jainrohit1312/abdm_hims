import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// Voucher List screen (`/vouchers`).
///
/// Shows all vouchers for the hospital with a date-range filter and the total
/// expense for the selected range.
class VoucherListScreen extends ConsumerStatefulWidget {
  const VoucherListScreen({super.key});

  @override
  ConsumerState<VoucherListScreen> createState() => _VoucherListScreenState();
}

class _VoucherListScreenState extends ConsumerState<VoucherListScreen> {
  late DateTime _fromDate;
  late DateTime _toDate;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Default: current month.
    final now = DateTime.now();
    _fromDate = DateTime(now.year, now.month, 1);
    _toDate = DateTime(now.year, now.month + 1, 0);
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  /// Scroll-end detection: jab list ke end ke paas pahunch jayein toh next
  /// page fetch karo (server-side pagination).
  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.extentAfter < 300) {
      final hospitalId = ref.read(authStateProvider).hospitalId;
      if (hospitalId == null || hospitalId.isEmpty) return;
      ref
          .read(
            voucherListProvider(
              VoucherFilter(
                hospitalId: hospitalId,
                from: _fromDate,
                to: _toDate,
              ),
            ).notifier,
          )
          .nextPage();
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _fromDate, end: _toDate),
      helpText: 'Select voucher date range',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fromDate = picked.start;
      _toDate = picked.end;
    });
  }

  String _formatDate(DateTime date) => DateFormat('dd MMM yyyy').format(date);

  String _formatCurrency(double value) =>
      NumberFormat.currency(locale: 'en_IN', symbol: '₹').format(value);

  double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Vouchers')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final filter = VoucherFilter(
      hospitalId: hospitalId,
      from: _fromDate,
      to: _toDate,
    );
    final vouchersState = ref.watch(voucherListProvider(filter));
    final summaryAsync = ref.watch(voucherRangeSummaryProvider(filter));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Vouchers'),
        actions: [
          IconButton(
            tooltip: 'Voucher Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/vouchers/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/vouchers/new'),
        icon: const Icon(Icons.add),
        label: const Text('New Voucher'),
      ),
      body: Column(
        children: [
          _buildFilterBar(context),
          Expanded(
            child: vouchersState.isLoading && vouchersState.items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : vouchersState.error != null && vouchersState.items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to load vouchers: ${vouchersState.error}'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () =>
                              ref.invalidate(voucherListProvider(filter)),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _buildVoucherList(filter, vouchersState, summaryAsync),
          ),
        ],
      ),
    );
  }

  Widget _buildVoucherList(
    VoucherFilter filter,
    PaginationState<Map<String, dynamic>> state,
    AsyncValue<Map<String, dynamic>> summaryAsync,
  ) {
    // Summary header is independent of loaded pages (full range total).
    final summary = summaryAsync.valueOrNull;
    final total = summary == null ? null : _toDouble(summary['total']);
    final count = summary == null ? null : (summary['count'] as int? ?? 0);

    // If the first page doesn't fill the viewport, load the next page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadMore();
    });

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(voucherListProvider(filter));
        ref.invalidate(voucherRangeSummaryProvider(filter));
      },
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: state.items.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            if (total == null || count == null) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              children: [
                _buildTotalCard(total, count),
                const SizedBox(height: 12),
                if (state.items.isEmpty && count == 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text('No vouchers found in this date range.'),
                    ),
                  ),
              ],
            );
          }
          final itemIndex = index - 1;
          if (itemIndex < state.items.length) {
            final voucher = state.items[itemIndex];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildVoucherCard(voucher),
            );
          }
          return _buildFooter(state);
        },
      ),
    );
  }

  Widget _buildFooter(PaginationState<Map<String, dynamic>> state) {
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
            onPressed: () => ref
                .read(voucherListProvider(VoucherFilter(
                  hospitalId: ref.read(authStateProvider).hospitalId ?? '',
                  from: _fromDate,
                  to: _toDate,
                )).notifier)
                .nextPage(),
            icon: const Icon(Icons.refresh),
            label: const Text('Failed to load more — Retry'),
          ),
        ),
      );
    }
    if (!state.hasMore && state.items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'No more vouchers',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }
    return const SizedBox(height: 16);
  }

  Widget _buildFilterBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: _pickDateRange,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.date_range_outlined),
              const SizedBox(width: 8),
              Text(
                '${_formatDate(_fromDate)}  →  ${_formatDate(_toDate)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              const Text('Change'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTotalCard(double total, int count) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.currency_rupee,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total Expenses (Selected Range)',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '$count voucher${count == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimaryContainer
                          .withValues(alpha: 0.75),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _formatCurrency(total),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoucherCard(Map<String, dynamic> voucher) {
    final amount = _toDouble(voucher['amount']);
    final voucherNumber = voucher['voucher_number']?.toString() ?? '-';
    final date = _formatDate(
      DateTime.tryParse(voucher['voucher_date']?.toString() ?? '') ??
          DateTime.now(),
    );
    final payee = voucher['payee_name']?.toString() ?? '-';
    final category = voucher['expense_category']?.toString() ?? '-';
    final paymentMode = voucher['payment_mode']?.toString() ?? '-';
    final voucherType = voucher['voucher_type']?.toString() ?? 'Expense';
    final description = voucher['description']?.toString() ?? '';
    final attachments = _attachmentsFromVoucher(voucher);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        voucherNumber,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$date  •  $payee',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text(
                  _formatCurrency(amount),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _voucherTypeColor(voucherType),
                      ),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(description, style: Theme.of(context).textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _chip(category, Colors.blueGrey),
                _chip(paymentMode, Colors.indigo),
                _chip(voucherType, _voucherTypeColor(voucherType)),
              ],
            ),
            if (attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.attach_file, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '${attachments.length} attachment'
                    '${attachments.length == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ...attachments.map(
                (attachment) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _openAttachment(
                      attachment['url']?.toString(),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _attachmentIcon(attachment['name']?.toString()),
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              attachment['name']?.toString() ?? 'Attachment',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _attachmentsFromVoucher(
    Map<String, dynamic> voucher,
  ) {
    final raw = voucher['attachments'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map(
            (item) => item.cast<String, dynamic>(),
          )
          .where((item) => (item['url']?.toString() ?? '').isNotEmpty)
          .toList();
    }
    return const [];
  }

  Future<void> _openAttachment(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Older browsers/devices sometimes reject external launches.
      try {
        await launchUrl(uri, mode: LaunchMode.inAppWebView);
      } catch (_) {
        // Ignore — user already has the URL visible.
      }
    }
  }

  IconData _attachmentIcon(String? fileName) {
    final extension = (fileName ?? '').toLowerCase().split('.').last;
    if (extension == 'pdf') return Icons.picture_as_pdf_outlined;
    if (const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension)) {
      return Icons.image_outlined;
    }
    if (const ['xls', 'xlsx', 'csv'].contains(extension)) {
      return Icons.table_chart_outlined;
    }
    if (const ['doc', 'docx'].contains(extension)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Color _voucherTypeColor(String type) {
    switch (type) {
      case 'Expense':
        return Colors.red;
      case 'Payment':
        return Colors.teal;
      case 'Adjustment':
        return Colors.purple;
      default:
        return Colors.blueGrey;
    }
  }
}
