import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../widgets/smart_navigation.dart';

/// Read-only bill detail (`/billing/view/:billId`).
///
/// Used for historical manual/legacy bills that have no source workflow to
/// open. There are no editing controls here — the unified billing screen is a
/// history/navigation hub, not an editing workflow.
class BillDetailScreen extends ConsumerWidget {
  const BillDetailScreen({super.key, required this.billId});

  final String billId;

  static final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billAsync = ref.watch(billDetailProvider(billId));

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Bill Details')),
      body: billAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to load bill: $error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(billDetailProvider(billId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (bill) {
          if (bill == null) {
            return const Center(child: Text('Bill not found.'));
          }
          return _BillDetailContent(bill: bill);
        },
      ),
    );
  }
}

class _BillDetailContent extends StatelessWidget {
  const _BillDetailContent({required this.bill});

  final Map<String, dynamic> bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = ((bill['billing_items'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final logs = ((bill['payment_logs'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final edits = ((bill['bill_edits'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final audits = ((bill['billing_audit'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    final total = _toDouble(bill['total_amount']);
    final discount = _toDouble(bill['discount_amount']);
    final net = _toDouble(bill['net_amount']);
    final paid = _toDouble(bill['paid_amount']);
    final balance = _toDouble(bill['balance_amount']);
    final status = bill['payment_status']?.toString() ?? 'unpaid';
    final sourceType = bill['source_type']?.toString() ?? 'manual';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildHeaderCard(theme),
        const SizedBox(height: 12),
        _buildSourceCard(theme, sourceType),
        const SizedBox(height: 12),
        _buildAmountSummaryCard(
          theme,
          total: total,
          discount: discount,
          net: net,
          paid: paid,
          balance: balance,
          status: status,
        ),
        const SizedBox(height: 12),
        _buildItemsCard(theme, items),
        const SizedBox(height: 12),
        if (bill['notes']?.toString().isNotEmpty == true ||
            bill['internal_notes']?.toString().isNotEmpty == true) ...[
          _buildNotesCard(theme),
          const SizedBox(height: 12),
        ],
        _buildPaymentsCard(theme, logs),
        const SizedBox(height: 12),
        _buildEditHistoryCard(theme, edits),
        const SizedBox(height: 12),
        _buildAuditCard(theme, audits),
      ],
    );
  }

  Widget _buildHeaderCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bill['patient_name']?.toString() ?? 'Unknown Patient',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            _headerRow(theme, 'UHID', bill['uhid']?.toString() ?? 'N/A'),
            _headerRow(
              theme,
              'Bill No.',
              bill['bill_number']?.toString() ?? 'N/A',
            ),
            _headerRow(
              theme,
              'Date',
              _parseDate(bill['bill_date'])?.toDisplayDate ?? 'N/A',
            ),
            _headerRow(theme, 'Visit Type', _visitTypeLabel(bill)),
          ],
        ),
      ),
    );
  }

  Widget _headerRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(ThemeData theme, String sourceType) {
    final opdId = bill['opd_registration_id']?.toString();
    final ipdId = bill['ipd_admission_id']?.toString();
    final diagnosticOrderId = bill['diagnostic_order_id']?.toString();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bill Source',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _headerRow(theme, 'Source', _sourceTypeLabel(sourceType)),
            if (opdId != null && opdId.isNotEmpty)
              _headerRow(theme, 'OPD Visit', opdId),
            if (ipdId != null && ipdId.isNotEmpty)
              _headerRow(theme, 'IPD Admission', ipdId),
            if (diagnosticOrderId != null && diagnosticOrderId.isNotEmpty)
              _headerRow(theme, 'Diagnostic Order', diagnosticOrderId),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountSummaryCard(
    ThemeData theme, {
    required double total,
    required double discount,
    required double net,
    required double paid,
    required double balance,
    required String status,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Amount Summary',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _totalRow(theme, 'Total Amount', total),
            if (discount > 0) _totalRow(theme, 'Discount', -discount),
            _totalRow(theme, 'Net Amount', net, bold: true),
            const Divider(),
            _totalRow(theme, 'Paid Amount', paid),
            _totalRow(theme, 'Balance Amount', balance, bold: true),
            const SizedBox(height: 12),
            _StatusChip(status: status),
          ],
        ),
      ),
    );
  }

  Widget _buildItemsCard(
    ThemeData theme,
    List<Map<String, dynamic>> items,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bill Items',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No items on this bill.'),
              )
            else
              for (final item in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(item['item_name']?.toString() ?? 'Item'),
                  subtitle: Text(
                    '${item['quantity']?.toString() ?? 1} × '
                    '${_inr(_toDouble(item['unit_price']))}   •   '
                    '${_itemTypeLabel(item['item_type'])}',
                  ),
                  trailing: Text(
                    _inr(_toDouble(item['total_price'])),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Notes',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (bill['notes']?.toString().isNotEmpty == true) ...[
              Text('Bill notes', style: theme.textTheme.bodySmall),
              Text(bill['notes'].toString()),
              const SizedBox(height: 8),
            ],
            if (bill['internal_notes']?.toString().isNotEmpty == true) ...[
              Text('Internal notes', style: theme.textTheme.bodySmall),
              Text(bill['internal_notes'].toString()),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentsCard(
    ThemeData theme,
    List<Map<String, dynamic>> logs,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Payments & Transaction History',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (logs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No payments recorded yet.'),
              )
            else
              for (final log in logs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.payments_outlined),
                  title: Text(
                    '${_inr(_toDouble(log['amount_paid'] ?? log['payment_amount']))}'
                    '   •   '
                    '${(log['payment_mode']?.toString() ?? 'cash').toUpperCase()}',
                  ),
                  subtitle: Text(
                    '${_formatDateTime(log['payment_date'])}'
                    '${log['paid_by']?.toString().isNotEmpty == true ? '   •   Paid by: ${log['paid_by']}' : ''}',
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditHistoryCard(
    ThemeData theme,
    List<Map<String, dynamic>> edits,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit History',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (edits.isEmpty)
              const Text('No edits recorded yet.')
            else
              for (final edit in edits)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(edit['edit_reason']?.toString() ?? 'Bill edited'),
                  subtitle: Text(
                    '${_formatDateTime(edit['edit_date'])}'
                    '${_editorName(edit)}',
                  ),
                  trailing: Text(
                    '${_inr(_toDouble(edit['old_amount']))} → '
                    '${_inr(_toDouble(edit['new_amount']))}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuditCard(
    ThemeData theme,
    List<Map<String, dynamic>> audits,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Billing Audit Trail',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (audits.isEmpty)
              const Text('No audit entries recorded yet.')
            else
              for (final audit in audits)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _auditActionIcon(audit['action']),
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(
                    audit['description']?.toString() ??
                        _auditActionLabel(audit['action']),
                  ),
                  subtitle: Text(
                    '${_formatDateTime(audit['performed_at'])}'
                    '${_auditPerformerName(audit)}',
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _totalRow(ThemeData theme, String label, double value, {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontSize: bold ? 16 : 14,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(_inr(value), style: style),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  static double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  static String _inr(double value) => BillDetailScreen._currency.format(value);

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String _formatDateTime(dynamic value) {
    final date = _parseDate(value);
    if (date == null) return 'N/A';
    return DateFormat('dd/MM/yyyy hh:mm a').format(date);
  }

  static String _visitTypeLabel(Map<String, dynamic> bill) {
    final visitType = bill['visit_type']?.toString() ?? 'opd';
    switch (visitType) {
      case 'ipd':
        return 'IPD';
      case 'lab':
        return 'Lab-Diagnostics';
      default:
        return 'OPD';
    }
  }

  static String _sourceTypeLabel(String sourceType) {
    switch (sourceType) {
      case 'opd':
        return 'OPD Slip';
      case 'ipd':
        return 'IPD Discharge';
      case 'lab':
        return 'Lab-Diagnostics';
      case 'pharmacy':
        return 'Pharmacy';
      default:
        return 'Manual';
    }
  }

  static String _itemTypeLabel(dynamic itemType) {
    switch (itemType?.toString()) {
      case 'consultation':
        return 'Consultation';
      case 'lab':
      case 'lab_test':
        return 'Lab Test';
      case 'medicine':
        return 'Medicine';
      case 'room':
      case 'room_charge':
        return 'Room Charge';
      case 'procedure':
        return 'Procedure';
      default:
        return 'Other';
    }
  }

  static String _auditActionLabel(dynamic action) {
    switch (action?.toString()) {
      case 'created':
        return 'Bill created';
      case 'item_added':
        return 'Item added';
      case 'item_removed':
        return 'Item removed';
      case 'item_updated':
        return 'Item updated';
      case 'discount_applied':
        return 'Discount applied';
      case 'payment_added':
        return 'Payment recorded';
      case 'status_changed':
        return 'Status changed';
      default:
        return 'Bill edited';
    }
  }

  static IconData _auditActionIcon(dynamic action) {
    switch (action?.toString()) {
      case 'created':
        return Icons.add_circle_outline;
      case 'item_added':
        return Icons.playlist_add;
      case 'item_removed':
        return Icons.playlist_remove;
      case 'discount_applied':
        return Icons.savings_outlined;
      case 'payment_added':
        return Icons.payments_outlined;
      case 'status_changed':
        return Icons.swap_horiz;
      default:
        return Icons.history;
    }
  }

  String _auditPerformerName(Map<String, dynamic> audit) {
    final user =
        (audit['users'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final name =
        '${user['first_name'] ?? ''} ${user['last_name'] ?? ''}'.trim();
    return name.isEmpty ? '' : '   •   By $name';
  }

  String _editorName(Map<String, dynamic> edit) {
    final user =
        (edit['users'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final name =
        '${user['first_name'] ?? ''} ${user['last_name'] ?? ''}'.trim();
    return name.isEmpty ? '' : '   •   By $name';
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
