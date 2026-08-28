import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../widgets/smart_navigation.dart';

/// Edit / modify an existing bill (`/billing/edit/:billId`).
///
/// Supports:
/// * add / remove line items (Lab test, Medicine, manual items)
/// * discount + extra-charge adjustments
/// * payment status updates (Unpaid → Partial → Paid)
/// * payment recording (Cash / Card / UPI) with transaction history
/// * `bill_edits` audit logging for every change
class BillEditScreen extends ConsumerStatefulWidget {
  const BillEditScreen({required this.billId, super.key});

  final String billId;

  @override
  ConsumerState<BillEditScreen> createState() => _BillEditScreenState();
}

class _BillEditScreenState extends ConsumerState<BillEditScreen> {
  final _discountController = TextEditingController();
  final _discountReasonController = TextEditingController();

  bool _busy = false;

  final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  @override
  void dispose() {
    _discountController.dispose();
    _discountReasonController.dispose();
    super.dispose();
  }

  double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  String _inr(double value) => _currency.format(value);

  @override
  Widget build(BuildContext context) {
    final billAsync = ref.watch(billDetailProvider(widget.billId));

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Edit Bill')),
      body: billAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to load bill: $error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(billDetailProvider(widget.billId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (bill) {
          if (bill == null) {
            return const Center(child: Text('Bill not found.'));
          }
          return _buildContent(bill);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Content
  // ---------------------------------------------------------------------------

  Widget _buildContent(Map<String, dynamic> bill) {
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
    final source = bill['source']?.toString() ?? 'billing';
    final sourceType = bill['source_type']?.toString() ?? source;

    _discountController.text = discount > 0 ? discount.toStringAsFixed(0) : '';
    _discountReasonController.text =
        bill['discount_reason']?.toString() ?? '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (sourceType == 'opd') ...[
          _infoBanner(
            theme,
            'This OPD bill is sourced from an OPD registration. '
            'Any item / discount edit will convert it into a permanent '
            'billing record automatically.',
          ),
          const SizedBox(height: 12),
        ] else if (sourceType == 'ipd') ...[
          _infoBanner(
            theme,
            'This bill was generated from an IPD admission / discharge. '
            'Edits here are recorded against the billing record and visible '
            'in the audit trail.',
          ),
          const SizedBox(height: 12),
        ] else if (sourceType == 'lab') ...[
          _infoBanner(
            theme,
            'This bill originated from the Lab / Diagnostics module.',
          ),
          const SizedBox(height: 12),
        ] else if (sourceType == 'manual') ...[
          _infoBanner(
            theme,
            'This is a manual bill created from the billing module.',
          ),
          const SizedBox(height: 12),
        ],
        _buildHeaderCard(theme, bill),
        const SizedBox(height: 12),
        _buildSourceCard(theme, bill, sourceType),
        const SizedBox(height: 12),
        _buildAmountSummaryCard(
          theme,
          total: total,
          discount: discount,
          net: net,
          paid: paid,
          balance: balance,
          status: status,
          bill: bill,
        ),
        const SizedBox(height: 12),
        _buildItemsCard(theme, bill, items),
        const SizedBox(height: 12),
        _buildAdjustmentsCard(theme, bill),
        const SizedBox(height: 12),
        _buildNotesCard(theme, bill),
        const SizedBox(height: 12),
        _buildPaymentCard(theme, bill, logs, balance, status),
        const SizedBox(height: 12),
        _buildEditHistoryCard(theme, edits),
        const SizedBox(height: 12),
        _buildBillingAuditCard(theme, audits),
      ],
    );
  }

  Widget _infoBanner(ThemeData theme, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: theme.colorScheme.tertiary),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(ThemeData theme, Map<String, dynamic> bill) {
    final visitType = bill['visit_type']?.toString() ?? 'opd';
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
            _headerRow(theme, 'Visit Type', _visitTypeLabel(visitType)),
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

  /// Shows where the bill came from and the linked visit/admission ids so
  /// the unified billing module exposes the full OPD ↔ Bill ↔ IPD chain.
  Widget _buildSourceCard(
    ThemeData theme,
    Map<String, dynamic> bill,
    String sourceType,
  ) {
    final opdId = bill['opd_registration_id']?.toString();
    final ipdId = bill['ipd_admission_id']?.toString();
    final diagnosticOrderId = bill['diagnostic_order_id']?.toString();
    if (opdId == null &&
        ipdId == null &&
        diagnosticOrderId == null &&
        sourceType == 'manual') {
      return Card(
        child: ListTile(
          leading: Icon(Icons.edit_note_outlined,
              color: theme.colorScheme.primary),
          title: const Text('Manual Bill'),
          subtitle: const Text('Created directly from the billing module'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bill Source & Linking',
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

  Widget _buildNotesCard(ThemeData theme, Map<String, dynamic> bill) {
    final notesController = TextEditingController(
      text: bill['notes']?.toString() ?? '',
    );
    final internalController = TextEditingController(
      text: bill['internal_notes']?.toString() ?? '',
    );

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
            TextField(
              controller: notesController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Bill notes (visible on bill)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: internalController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Internal notes (not visible on bill)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _saveNotes(bill, {
                  'notes': notesController.text.trim().isEmpty
                      ? null
                      : notesController.text.trim(),
                  'internal_notes': internalController.text.trim().isEmpty
                      ? null
                      : internalController.text.trim(),
                }),
                icon: const Icon(Icons.save),
                label: const Text('Save Notes'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBillingAuditCard(
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

  Future<void> _saveNotes(
    Map<String, dynamic> bill,
    Map<String, dynamic> notes,
  ) async {
    final editableId = await _editableBillId(bill);
    if (editableId == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.updateBill(editableId, notes);
      _refresh(editableId);
      _showMessage('Notes saved.');
    } catch (e) {
      _showMessage('Failed to save notes: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildAmountSummaryCard(
    ThemeData theme, {
    required double total,
    required double discount,
    required double net,
    required double paid,
    required double balance,
    required String status,
    required Map<String, dynamic> bill,
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
            DropdownButtonFormField<String>(
              initialValue: const ['unpaid', 'partially_paid', 'paid']
                      .contains(status)
                  ? status
                  : 'unpaid',
              decoration: const InputDecoration(
                labelText: 'Payment Status',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'unpaid', child: Text('Unpaid')),
                DropdownMenuItem(
                  value: 'partially_paid',
                  child: Text('Partial'),
                ),
                DropdownMenuItem(value: 'paid', child: Text('Paid')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => _onPaymentStatusChanged(bill, value),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemsCard(
    ThemeData theme,
    Map<String, dynamic> bill,
    List<Map<String, dynamic>> items,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Bill Items',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _openAddItemSheet(bill),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Item'),
                ),
              ],
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
                  leading: Icon(
                    _itemTypeIcon(item['item_type']),
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(item['item_name']?.toString() ?? 'Item'),
                  subtitle: Text(
                    '${item['quantity']?.toString() ?? 1} × '
                    '${_inr(_toDouble(item['unit_price']))}   •   '
                    '${_itemTypeLabel(item['item_type'])}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _inr(_toDouble(item['total_price'])),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        tooltip: 'Remove item',
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        onPressed: _busy
                            ? null
                            : () => _removeItem(bill, item),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdjustmentsCard(ThemeData theme, Map<String, dynamic> bill) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Adjustments',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _discountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Discount (₹)',
                      prefixIcon: Icon(Icons.percent),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _discountReasonController,
                    decoration: const InputDecoration(
                      labelText: 'Discount reason',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _applyDiscount(bill),
                    icon: const Icon(Icons.savings_outlined),
                    label: const Text('Apply Discount'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _openExtraChargeSheet(bill),
                    icon: const Icon(Icons.add_card),
                    label: const Text('Extra Charge'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentCard(
    ThemeData theme,
    Map<String, dynamic> bill,
    List<Map<String, dynamic>> logs,
    double balance,
    String status,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Payments & Transaction History',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _openRecordPaymentSheet(bill),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Record Payment'),
                ),
              ],
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
                    '${_inr(_toDouble(log['amount_paid']))}   •   '
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

  Widget _buildEditHistoryCard(ThemeData theme, List<Map<String, dynamic>> edits) {
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

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Returns the billing-backed id that can receive item/discount edits.
  /// OPD-sourced bills are materialised into `billing` first; the screen then
  /// navigates to the new bill id and the caller should abort.
  Future<String?> _editableBillId(Map<String, dynamic> bill) async {
    if (bill['source']?.toString() == 'billing') {
      return bill['id']?.toString();
    }

    final db = ref.read(databaseServiceProvider);
    final materialized = await db.updateBill(bill['id'].toString(), {
      'total_amount': _toDouble(bill['total_amount']),
      'paid_amount': _toDouble(bill['paid_amount']),
      'payment_status': bill['payment_status'],
      'payment_mode': bill['payment_mode'],
    });

    final newId = materialized['id']?.toString();
    if (mounted && newId != null) {
      context.replace('/billing/edit/$newId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'OPD bill converted into a billing record. Please repeat your edit.',
          ),
        ),
      );
    }
    return null;
  }

  Future<void> _openAddItemSheet(Map<String, dynamic> bill) async {
    final editableId = await _editableBillId(bill);
    if (editableId == null || !mounted) return;

    final hospitalId = ref.read(authStateProvider).hospitalId;
    final item = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddItemSheet(hospitalId: hospitalId),
    );

    if (item == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final oldTotal = _toDouble(bill['total_amount']);
      await db.addBillItem(editableId, item);
      await db.recordBillEdit(
        billId: editableId,
        oldAmount: oldTotal,
        newAmount: oldTotal + _toDouble(item['total_price']),
        editReason: 'Added item: ${item['item_name']}',
      );
      _refresh(editableId);
      _showMessage('Item added.');
    } catch (e) {
      _showMessage('Failed to add item: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeItem(
    Map<String, dynamic> bill,
    Map<String, dynamic> item,
  ) async {
    final itemId = item['id']?.toString();
    if (itemId == null) return;

    final editableId = await _editableBillId(bill);
    if (editableId == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove Item'),
        content: Text(
          'Remove "${item['item_name']}" from this bill?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final oldTotal = _toDouble(bill['total_amount']);
      await db.deleteBillItem(editableId, itemId);
      await db.recordBillEdit(
        billId: editableId,
        oldAmount: oldTotal,
        newAmount: oldTotal - _toDouble(item['total_price']),
        editReason: 'Removed item: ${item['item_name']}',
      );
      _refresh(editableId);
      _showMessage('Item removed.');
    } catch (e) {
      _showMessage('Failed to remove item: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyDiscount(Map<String, dynamic> bill) async {
    final editableId = await _editableBillId(bill);
    if (editableId == null || !mounted) return;

    final discount = _toDouble(_discountController.text);
    final reason = _discountReasonController.text.trim();
    final total = _toDouble(bill['total_amount']);
    if (discount < 0) {
      _showMessage('Discount cannot be negative.');
      return;
    }
    if (discount > total) {
      _showMessage('Discount cannot exceed the total amount.');
      return;
    }

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.updateBill(editableId, {
        'discount_amount': discount,
        'discount_reason': reason.isEmpty ? null : reason,
      });
      await db.recalculateBill(editableId);
      await db.recordBillEdit(
        billId: editableId,
        oldAmount: total,
        newAmount: total - discount,
        editReason: 'Discount applied: ${reason.isEmpty ? 'Adjustment' : reason}',
      );
      _refresh(editableId);
      _showMessage('Discount applied.');
    } catch (e) {
      _showMessage('Failed to apply discount: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openExtraChargeSheet(Map<String, dynamic> bill) async {
    final editableId = await _editableBillId(bill);
    if (editableId == null || !mounted) return;

    final entry = await _showExtraChargeDialog();
    if (entry == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final oldTotal = _toDouble(bill['total_amount']);
      final amount = entry['amount'] as double;
      await db.addBillItem(editableId, {
        'item_type': 'others',
        'item_name': entry['name'] as String,
        'quantity': 1,
        'unit_price': amount,
        'total_price': amount,
      });
      await db.recordBillEdit(
        billId: editableId,
        oldAmount: oldTotal,
        newAmount: oldTotal + amount,
        editReason: 'Extra charge: ${entry['name']}',
      );
      _refresh(editableId);
      _showMessage('Extra charge added.');
    } catch (e) {
      _showMessage('Failed to add extra charge: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>?> _showExtraChargeDialog() async {
    final nameController = TextEditingController();
    final amountController = TextEditingController();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Extra Charge'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Charge name',
                hintText: 'e.g. Dressing charge',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount (₹)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final amount = double.tryParse(amountController.text) ?? 0;
              final name = nameController.text.trim();
              if (name.isEmpty || amount <= 0) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Enter a valid name and amount.'),
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext, {
                'name': name,
                'amount': amount,
              });
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    nameController.dispose();
    amountController.dispose();
    return result;
  }

  Future<void> _onPaymentStatusChanged(
    Map<String, dynamic> bill,
    String? newStatus,
  ) async {
    if (newStatus == null) return;
    final currentStatus = bill['payment_status']?.toString() ?? 'unpaid';
    if (newStatus == currentStatus) return;

    final total = _toDouble(bill['total_amount']);
    final paid = _toDouble(bill['paid_amount']);
    final balance = total - paid;

    // Moving to Paid with an outstanding balance -> record the balance as a
    // payment first (this also updates the status automatically).
    if (newStatus == 'paid' && balance > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Mark as Paid'),
          content: Text(
            'An outstanding balance of ${_inr(balance)} exists. '
            'Record it as a payment now?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Record Payment'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _recordPayment(bill, amount: balance, mode: 'cash');
      return;
    }

    final editableId = await _editableBillId(bill);
    if (editableId == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.updateBill(editableId, {'payment_status': newStatus});
      await db.recordBillEdit(
        billId: editableId,
        oldAmount: paid,
        newAmount: paid,
        editReason: 'Payment status changed from $currentStatus to $newStatus',
      );
      _refresh(editableId);
      _showMessage('Payment status updated.');
    } catch (e) {
      _showMessage('Failed to update status: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRecordPaymentSheet(Map<String, dynamic> bill) async {
    final balance = _toDouble(bill['balance_amount']);
    final result = await showModalBottomSheet<_PaymentEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RecordPaymentSheet(balance: balance),
    );

    if (result == null || !mounted) return;
    await _recordPayment(
      bill,
      amount: result.amount,
      mode: result.mode,
      paidBy: result.paidBy,
    );
  }

  Future<void> _recordPayment(
    Map<String, dynamic> bill, {
    required double amount,
    required String mode,
    String? paidBy,
  }) async {
    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final oldPaid = _toDouble(bill['paid_amount']);
      final updated = await db.recordPayment(
        billId: widget.billId,
        amountPaid: amount,
        paymentMode: mode,
        paidBy: paidBy,
      );
      final updatedBillId = updated['id']?.toString() ?? widget.billId;
      await db.recordBillEdit(
        billId: updatedBillId,
        oldAmount: oldPaid,
        newAmount: oldPaid + amount,
        editReason: 'Payment of ${_inr(amount)} received via ${mode.toUpperCase()}',
      );

      if (updatedBillId != widget.billId && mounted) {
        context.replace('/billing/edit/$updatedBillId');
        _showMessage('Payment recorded.');
        return;
      }

      _refresh(updatedBillId);
      _showMessage('Payment recorded.');
    } catch (e) {
      _showMessage('Failed to record payment: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refresh(String billId) {
    ref.invalidate(billDetailProvider(billId));
    ref.invalidate(billPaymentLogsProvider(billId));
    ref.invalidate(billEditHistoryProvider(billId));
    ref.invalidate(billAuditProvider(billId));
    final hospitalId = ref.read(authStateProvider).hospitalId;
    ref.invalidate(allBillsProvider(BillingFilter(hospitalId: hospitalId)));
    // Also invalidate per-source tabs so every tab reflects the change.
    for (final sourceType in <String?>[null, 'opd', 'ipd', 'lab', 'manual']) {
      ref.invalidate(
        allBillsProvider(
          BillingFilter(hospitalId: hospitalId, sourceType: sourceType),
        ),
      );
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String _formatDateTime(dynamic value) {
    final date = _parseDate(value);
    if (date == null) return 'N/A';
    return DateFormat('dd/MM/yyyy hh:mm a').format(date);
  }

  static String _visitTypeLabel(String visitType) {
    switch (visitType) {
      case 'ipd':
        return 'IPD';
      case 'lab':
        return 'Lab-Diagnostics';
      default:
        return 'OPD';
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

  static IconData _itemTypeIcon(dynamic itemType) {
    switch (itemType?.toString()) {
      case 'consultation':
        return Icons.medical_services_outlined;
      case 'lab':
      case 'lab_test':
        return Icons.biotech_outlined;
      case 'medicine':
        return Icons.medication_outlined;
      case 'room':
      case 'room_charge':
        return Icons.meeting_room_outlined;
      case 'procedure':
        return Icons.medical_services_outlined;
      default:
        return Icons.receipt_long_outlined;
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
}

// -----------------------------------------------------------------------------
// Bottom sheets
// -----------------------------------------------------------------------------

class _PaymentEntry {
  final double amount;
  final String mode;
  final String? paidBy;

  const _PaymentEntry({required this.amount, required this.mode, this.paidBy});
}

class _RecordPaymentSheet extends ConsumerStatefulWidget {
  const _RecordPaymentSheet({required this.balance});

  final double balance;

  @override
  ConsumerState<_RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends ConsumerState<_RecordPaymentSheet> {
  late final TextEditingController _amountController = TextEditingController(
    text: widget.balance > 0 ? widget.balance.toStringAsFixed(0) : '',
  );
  final _paidByController = TextEditingController();
  String _mode = 'cash';

  @override
  void dispose() {
    _amountController.dispose();
    _paidByController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Record Payment',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amountController,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount (₹)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: 'Payment Mode',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('Cash')),
              DropdownMenuItem(value: 'card', child: Text('Card')),
              DropdownMenuItem(value: 'upi', child: Text('UPI')),
              DropdownMenuItem(value: 'online', child: Text('Online')),
              DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
            ],
            onChanged: (value) => setState(() => _mode = value ?? 'cash'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _paidByController,
            decoration: const InputDecoration(
              labelText: 'Paid By (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                final amount = double.tryParse(_amountController.text) ?? 0;
                if (amount <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enter a valid amount.')),
                  );
                  return;
                }
                Navigator.pop(
                  context,
                  _PaymentEntry(
                    amount: amount,
                    mode: _mode,
                    paidBy: _paidByController.text.trim().isEmpty
                        ? null
                        : _paidByController.text.trim(),
                  ),
                );
              },
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Record Payment'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Add-item sheet: manual entry + quick picks for Lab tests and Medicines.
class _AddItemSheet extends ConsumerStatefulWidget {
  const _AddItemSheet({this.hospitalId});

  final String? hospitalId;

  @override
  ConsumerState<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends ConsumerState<_AddItemSheet> {
  final _nameController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  final _priceController = TextEditingController();
  final _medicineSearchController = TextEditingController();

  String _itemType = 'consultation';
  String _medicineQuery = '';
  int _labDropdownEpoch = 0;

  static const List<(String, String)> _itemTypes = [
    ('consultation', 'Consultation'),
    ('lab', 'Lab Test'),
    ('medicine', 'Medicine'),
    ('room', 'Room Charge'),
    ('procedure', 'Procedure'),
    ('others', 'Other'),
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _medicineSearchController.dispose();
    super.dispose();
  }

  double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  @override
  Widget build(BuildContext context) {
    final testsAsync = ref.watch(
      activeDiagnosticTestsProvider(widget.hospitalId),
    );
    final medicinesAsync = _medicineQuery.trim().isEmpty
        ? null
        : ref.watch(
            medicineSearchProvider(
              MedicineSearchParams(
                query: _medicineQuery.trim(),
                hospitalId: widget.hospitalId,
              ),
            ),
          );

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add Bill Item',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _itemType,
              decoration: const InputDecoration(
                labelText: 'Item Type',
                border: OutlineInputBorder(),
              ),
              items: _itemTypes
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.$1,
                      child: Text(entry.$2),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _itemType = value ?? 'others'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Item name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _qtyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _priceController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Unit Price (₹)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            Text(
              'Quick add from Lab Tests',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            testsAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (error, _) => Text('Failed to load tests: $error'),
              data: (tests) => DropdownButtonFormField<String>(
                key: ValueKey('lab_$_labDropdownEpoch'),
                initialValue: null,
                decoration: const InputDecoration(
                  labelText: 'Select a lab test',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('Select a lab test'),
                  ),
                  for (final test in tests)
                    DropdownMenuItem<String>(
                      value: test['id']?.toString(),
                      child: Text(
                        '${test['test_name'] ?? 'Test'} (₹${_toDouble(test['price'])})',
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final test = tests.firstWhere(
                    (t) => t['id']?.toString() == value,
                    orElse: () => const {},
                  );
                  if (test.isNotEmpty) {
                    setState(() {
                      _itemType = 'lab';
                      _nameController.text =
                          test['test_name']?.toString() ?? 'Lab Test';
                      _qtyController.text = '1';
                      _priceController.text = _toDouble(
                        test['price'],
                      ).toStringAsFixed(2);
                      _labDropdownEpoch++;
                    });
                  }
                },
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Quick add from Medicines',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _medicineSearchController,
              onChanged: (value) => setState(() => _medicineQuery = value),
              decoration: const InputDecoration(
                labelText: 'Search medicine',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
            ),
            if (medicinesAsync != null)
              medicinesAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(),
                ),
                error: (error, _) => Text('Search failed: $error'),
                data: (medicines) => medicines.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('No medicines found.'),
                      )
                    : SizedBox(
                        height: 180,
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: medicines.length,
                          itemBuilder: (context, index) {
                            final medicine = medicines[index];
                            final price = _toDouble(
                              medicine['selling_price'] ??
                                  medicine['mrp'],
                            );
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                medicine['medicine_name']?.toString() ??
                                    'Medicine',
                              ),
                              subtitle: Text(
                                '${medicine['strength']?.toString() ?? ''} '
                                '${medicine['drug_form']?.toString() ?? ''}'
                                .trim(),
                              ),
                              trailing: Text('₹${price.toStringAsFixed(2)}'),
                              onTap: () {
                                setState(() {
                                  _itemType = 'medicine';
                                  _nameController.text = medicine['medicine_name']
                                      ?.toString() ??
                                      'Medicine';
                                  _qtyController.text = '1';
                                  _priceController.text =
                                      price.toStringAsFixed(2);
                                });
                              },
                            );
                          },
                        ),
                      ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  final name = _nameController.text.trim();
                  final qty = int.tryParse(_qtyController.text) ?? 0;
                  final price = _toDouble(_priceController.text);
                  if (name.isEmpty || qty <= 0 || price <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Enter valid name, quantity and price.'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(context, {
                    'item_type': _itemType,
                    'item_name': name,
                    'quantity': qty,
                    'unit_price': price,
                    'total_price': (qty * price),
                  });
                },
                icon: const Icon(Icons.add),
                label: const Text('Add Item'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
