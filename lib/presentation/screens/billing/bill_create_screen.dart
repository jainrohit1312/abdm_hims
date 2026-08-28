import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// Create a manual bill (`source_type = manual`) from the unified billing
/// module. Patient search, line items, discount, notes and an optional
/// up-front payment are all captured here before calling
/// [DatabaseService.createManualBill].
class BillCreateScreen extends ConsumerStatefulWidget {
  const BillCreateScreen({super.key});

  @override
  ConsumerState<BillCreateScreen> createState() => _BillCreateScreenState();
}

class _BillCreateScreenState extends ConsumerState<BillCreateScreen> {
  final _patientSearchController = TextEditingController();
  final _itemNameController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  final _priceController = TextEditingController();
  final _discountController = TextEditingController();
  final _discountReasonController = TextEditingController();
  final _notesController = TextEditingController();
  final _paidAmountController = TextEditingController();
  final _transactionRefController = TextEditingController();

  String _patientQuery = '';
  Map<String, dynamic>? _selectedPatient;
  String _itemType = 'others';
  String _paymentMode = 'cash';
  bool _busy = false;

  final List<Map<String, dynamic>> _items = [];
  int _itemSeq = 0;

  final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

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
    _patientSearchController.dispose();
    _itemNameController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    _discountController.dispose();
    _discountReasonController.dispose();
    _notesController.dispose();
    _paidAmountController.dispose();
    _transactionRefController.dispose();
    super.dispose();
  }

  double _toDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;

  String _inr(double value) => _currency.format(value);

  double get _subtotal => _items.fold(0, (sum, i) => sum + _toDouble(i['total_price']));

  double get _discount => _toDouble(_discountController.text);

  double get _net => _subtotal - _discount;

  double get _paid => _toDouble(_paidAmountController.text);

  double get _balance => _net - _paid;

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    return Scaffold(
      appBar: SmartAppBar(title: const Text('New Manual Bill')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPatientCard(context),
            const SizedBox(height: 16),
            _buildItemsCard(context),
            const SizedBox(height: 16),
            _buildAdjustmentsCard(context),
            const SizedBox(height: 16),
            _buildPaymentCard(context),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : FilledButton.icon(
                      onPressed: hospitalId == null || hospitalId.isEmpty
                          ? null
                          : _save,
                      icon: const Icon(Icons.save),
                      label: const Text('Create Bill'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Patient
  // ---------------------------------------------------------------------------

  Widget _buildPatientCard(BuildContext context) {
    final theme = Theme.of(context);
    final hospitalId = ref.read(authStateProvider).hospitalId;
    final searchAsync = _patientQuery.trim().isEmpty
        ? null
        : ref.watch(
            combinedPatientSearchProvider(
              CombinedPatientSearchParams(
                query: _patientQuery.trim(),
                hospitalId: hospitalId,
              ),
            ),
          );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Patient',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (_selectedPatient != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person),
                title: Text(
                  _selectedPatient!['first_name']?.toString().isNotEmpty == true
                      ? '${_selectedPatient!['first_name']} ${_selectedPatient!['last_name'] ?? ''}'.trim()
                      : _selectedPatient!['patient_name']?.toString() ?? 'Patient',
                ),
                subtitle: Text(
                  'UHID: ${_selectedPatient!['uhid']?.toString() ?? 'N/A'}',
                ),
                trailing: TextButton(
                  onPressed: () => setState(() => _selectedPatient = null),
                  child: const Text('Change'),
                ),
              ),
            ] else ...[
              TextField(
                controller: _patientSearchController,
                decoration: const InputDecoration(
                  labelText: 'Search patient by name / UHID / mobile',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _patientQuery = value),
              ),
              if (searchAsync != null)
                searchAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(),
                  ),
                  error: (e, _) => Text('Search failed: $e'),
                  data: (patients) => patients.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No patients found.'),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final patient in patients.take(8))
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.person_outline),
                                title: Text(
                                  '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim(),
                                ),
                                subtitle: Text(
                                  'UHID: ${patient['uhid']?.toString() ?? 'N/A'}',
                                ),
                                onTap: () {
                                  setState(() {
                                    _selectedPatient = patient;
                                    _patientSearchController.text =
                                        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
                                    _patientQuery = '';
                                  });
                                },
                              ),
                          ],
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------

  Widget _buildItemsCard(BuildContext context) {
    final theme = Theme.of(context);
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
            for (final item in _items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(item['item_name']?.toString() ?? 'Item'),
                subtitle: Text(
                  '${item['quantity'] ?? 1} × ${_inr(_toDouble(item['unit_price']))}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _inr(_toDouble(item['total_price'])),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => setState(
                        () => _items.removeWhere(
                          (i) => i['_key'] == item['_key'],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No items yet.'),
              ),
            const Divider(),
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
              onChanged: (value) =>
                  setState(() => _itemType = value ?? 'others'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _itemNameController,
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _addItem,
                icon: const Icon(Icons.add),
                label: const Text('Add Item'),
              ),
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Subtotal', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_inr(_subtotal), style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdjustmentsCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Discount & Notes',
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
            TextField(
              controller: _notesController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Payment (optional)',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Net Amount', style: theme.textTheme.bodyMedium),
                Text(
                  _inr(_net),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _paidAmountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Paid Amount (₹)',
                prefixIcon: Icon(Icons.payments_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _paymentMode,
                    decoration: const InputDecoration(
                      labelText: 'Payment Mode',
                      border: OutlineInputBorder(),
                    ),
                    items: ['cash', 'card', 'upi', 'online', 'cheque']
                        .map(
                          (mode) => DropdownMenuItem(
                            value: mode,
                            child: Text(mode.toUpperCase()),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _paymentMode = value ?? 'cash'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _transactionRefController,
                    decoration: const InputDecoration(
                      labelText: 'Transaction Ref (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Balance'),
                Text(
                  _inr(_balance),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _balance > 0 ? Colors.red : Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _addItem() {
    final name = _itemNameController.text.trim();
    final qty = int.tryParse(_qtyController.text) ?? 0;
    final price = _toDouble(_priceController.text);
    if (name.isEmpty || qty <= 0 || price <= 0) {
      _showMessage('Enter valid name, quantity and price.');
      return;
    }
    setState(() {
      _items.add({
        '_key': 'item_${_itemSeq++}',
        'item_type': _itemType,
        'item_name': name,
        'quantity': qty,
        'unit_price': price,
        'total_price': (qty * price).roundToDouble(),
      });
      _itemNameController.clear();
      _priceController.clear();
      _qtyController.text = '1';
    });
  }

  Future<void> _save() async {
    final patient = _selectedPatient;
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (patient == null) {
      _showMessage('Select a patient first.');
      return;
    }
    if (_items.isEmpty) {
      _showMessage('Add at least one bill item.');
      return;
    }
    if (_discount > _subtotal) {
      _showMessage('Discount cannot exceed the subtotal.');
      return;
    }
    if (_paid < 0) {
      _showMessage('Paid amount cannot be negative.');
      return;
    }

    setState(() => _busy = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final bill = await db.createManualBill(
        hospitalId: hospitalId!,
        patientId: patient['id'].toString(),
        items: [
          for (final item in _items)
            {
              'item_type': item['item_type'],
              'item_name': item['item_name'],
              'quantity': item['quantity'],
              'unit_price': item['unit_price'],
              'total_price': item['total_price'],
            },
        ],
        discountAmount: _discount,
        discountReason: _discountReasonController.text.trim().isEmpty
            ? null
            : _discountReasonController.text.trim(),
        paidAmount: _paid,
        paymentMode: _paid > 0 ? _paymentMode : null,
        transactionReference: _transactionRefController.text.trim().isEmpty
            ? null
            : _transactionRefController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      ref.invalidate(allBillsProvider(BillingFilter(hospitalId: hospitalId)));
      ref.invalidate(
        allBillsProvider(
          BillingFilter(hospitalId: hospitalId, sourceType: 'manual'),
        ),
      );

      if (!mounted) return;
      _showMessage('Manual bill created.');
      context.go('/billing/edit/${bill['id']}');
    } catch (e) {
      _showMessage('Failed to create bill: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
