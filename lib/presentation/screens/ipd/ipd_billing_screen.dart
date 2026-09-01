import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/ipd_bill_service.dart';
import '../../widgets/app_page_content.dart';
import '../../widgets/smart_navigation.dart';

// ---------------------------------------------------------------------------
// Shared formatting helpers
// ---------------------------------------------------------------------------

final NumberFormat _currency = NumberFormat.currency(
  locale: 'en_US',
  symbol: '₹',
  decimalDigits: 0,
);

double _toDouble(dynamic value) {
  if (value == null) return 0;
  return double.tryParse(value.toString()) ?? 0;
}

String _inr(double value) => _currency.format(value);

/// Plain number text for text fields (no thousands separators, no ₹).
String _money(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// The ONLY two things a user can add to an IPD bill.
enum _AddMode { services, packages }

/// One editable line on the bill.
///
/// Every line follows the same simple rule:
///     Amount = Rate × Frequency
class _BillLine {
  _BillLine({
    required this.key,
    required this.itemType,
    required this.name,
    required this.rate,
    required this.frequency,
  });

  final String key;
  final String itemType;
  final String name;
  double rate;
  int frequency;

  double get total => (rate * frequency * 100).roundToDouble() / 100;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class IPDBillingScreen extends ConsumerStatefulWidget {
  final String? admissionId;
  const IPDBillingScreen({super.key, this.admissionId});

  @override
  ConsumerState<IPDBillingScreen> createState() => _IPDBillingScreenState();
}

class _IPDBillingScreenState extends ConsumerState<IPDBillingScreen> {
  late final TextEditingController _admissionIdController =
      TextEditingController(text: widget.admissionId ?? '');

  // Add-item form (rate is always pre-filled from Settings master data and
  // remains editable per patient).
  final _rateController = TextEditingController();
  final _frequencyController = TextEditingController(text: '1');

  // Payment
  final _paidAmountController = TextEditingController();
  final _transactionRefController = TextEditingController();
  final _discountController = TextEditingController();
  final _discountReasonController = TextEditingController();

  String? _loadedAdmissionId;
  Map<String, dynamic>? _details;
  Map<String, dynamic>? _finalBill;

  /// The single source of truth for the bill preview. Room charges (auto
  /// calculated from admission date range), saved charges and newly added
  /// services/packages all live in this list.
  final List<_BillLine> _items = [];

  _AddMode _addMode = _AddMode.services;
  String? _selectedServiceId;
  String? _selectedPackageId;
  String _paymentStatus = 'unpaid';
  String _paymentMode = 'cash';
  bool _isLoading = false;
  bool _isGenerating = false;
  int _addDropdownEpoch = 0;
  int _itemSeq = 0;

  @override
  void initState() {
    super.initState();
    if (widget.admissionId != null && widget.admissionId!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAdmission());
    }
  }

  @override
  void dispose() {
    _admissionIdController.dispose();
    _rateController.dispose();
    _frequencyController.dispose();
    _paidAmountController.dispose();
    _transactionRefController.dispose();
    _discountController.dispose();
    _discountReasonController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data access
  // ---------------------------------------------------------------------------

  List<Map<String, dynamic>> get _services =>
      ((_details?['service_master'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> get _packages =>
      ((_details?['packages'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> get _currentOptions =>
      _addMode == _AddMode.services ? _services : _packages;

  double get _roomTotal => _items
      .where((i) => i.itemType == 'room_charge')
      .fold(0, (sum, i) => sum + i.total);

  double get _otherTotal => _items
      .where((i) => i.itemType != 'room_charge')
      .fold(0, (sum, i) => sum + i.total);

  double get _totalAmount =>
      ((_roomTotal + _otherTotal) * 100).roundToDouble() / 100;

  double get _paidAmount => _toDouble(_paidAmountController.text);

  double get _discountAmount => _toDouble(_discountController.text);

  double get _netPayable {
    final net = _totalAmount - _discountAmount;
    return net < 0 ? 0 : (net * 100).roundToDouble() / 100;
  }

  double get _balanceAmount {
    final balance = _netPayable - _paidAmount;
    return (balance * 100).roundToDouble() / 100;
  }

  double get _previewAmount {
    final rate = _toDouble(_rateController.text);
    final frequency = int.tryParse(_frequencyController.text.trim()) ?? 0;
    return (rate * frequency * 100).roundToDouble() / 100;
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  Future<void> _loadAdmission() async {
    final id = _admissionIdController.text.trim();
    if (id.isEmpty) {
      _showMessage('Enter an admission ID first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _details = null;
      _finalBill = null;
      _items.clear();
      _paidAmountController.clear();
      _discountController.clear();
      _discountReasonController.clear();
      _resetAddForm();
    });

    try {
      final db = ref.read(databaseServiceProvider);
      final details = await db.getIPDChargeDetails(id);
      final bill = await db.calculateFinalBill(
        id,
        dischargeDate: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _details = details;
        _finalBill = bill;
        _loadedAdmissionId = id;
        _items
          ..clear()
          ..addAll(_buildInitialItems(bill));
        final advance = _toDouble(bill['advance_payment']);
        _paidAmountController.text = advance == 0 ? '' : _money(advance);
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to load admission: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Room charges come from the auto-calculated ward segments; saved charges
  /// come from `ipd_charges`. Both become plain editable bill lines.
  List<_BillLine> _buildInitialItems(Map<String, dynamic> bill) {
    final items = <_BillLine>[];

    final segments = ((bill['ward_segments'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final ward = _formatWardType(segment['ward_type']?.toString() ?? 'Ward');
      final bedNumber = segment['bed_number']?.toString() ?? '';
      final name = bedNumber.isEmpty
          ? 'Room Charges - $ward'
          : 'Room Charges - $ward (Bed $bedNumber)';
      items.add(
        _BillLine(
          key: 'room_$i',
          itemType: 'room_charge',
          name: name,
          rate: _toDouble(segment['daily_rate']),
          frequency: _toInt(segment['days'], fallback: 1),
        ),
      );
    }

    final savedCharges = ((bill['other_charges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (var i = 0; i < savedCharges.length; i++) {
      final charge = savedCharges[i];
      // Ward charges are already auto-calculated from the admission date
      // range above; ignore any ward rows saved inside ipd_charges to avoid
      // double counting.
      final chargeType = charge['charge_type']?.toString() ?? 'service';
      if (chargeType == 'ward_charge') continue;
      final amount = _toDouble(charge['amount']);
      if (amount <= 0) continue;
      items.add(
        _BillLine(
          key: 'saved_${charge['id'] ?? i}',
          itemType: chargeType,
          name:
              charge['charge_description']?.toString() ??
              _chargeTypeLabel(chargeType),
          rate: amount,
          frequency: 1,
        ),
      );
    }

    return items;
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _onOptionSelected(String id) {
    final option = _currentOptions.firstWhere(
      (o) => o['id']?.toString() == id,
      orElse: () => const {},
    );
    if (option.isEmpty) return;
    final defaultRate = _addMode == _AddMode.services
        ? _toDouble(option['default_charge'])
        : _toDouble(option['package_amount']);
    setState(() {
      if (_addMode == _AddMode.services) {
        _selectedServiceId = id;
      } else {
        _selectedPackageId = id;
      }
      _rateController.text = _money(defaultRate);
      _frequencyController.text = '1';
    });
  }

  void _addSelectedItem() {
    final selectedId = _addMode == _AddMode.services
        ? _selectedServiceId
        : _selectedPackageId;
    if (selectedId == null) {
      _showMessage(
        _addMode == _AddMode.services
            ? 'Select a service first.'
            : 'Select a package first.',
      );
      return;
    }

    final option = _currentOptions.firstWhere(
      (o) => o['id']?.toString() == selectedId,
      orElse: () => const {},
    );
    if (option.isEmpty) {
      _showMessage('Selected item not found. Please reload the admission.');
      return;
    }

    final rate = _toDouble(_rateController.text);
    final frequency = int.tryParse(_frequencyController.text.trim()) ?? 0;
    if (rate <= 0 || frequency <= 0) {
      _showMessage('Enter a valid rate and frequency (both must be > 0).');
      return;
    }

    final isService = _addMode == _AddMode.services;
    setState(() {
      _items.add(
        _BillLine(
          key: 'item_${_itemSeq++}',
          itemType: isService ? 'service' : 'package',
          name:
              option['name']?.toString() ?? (isService ? 'Service' : 'Package'),
          rate: rate,
          frequency: frequency,
        ),
      );
      _resetAddForm();
    });
  }

  Future<void> _editItem(_BillLine item) async {
    final result = await showDialog<({double rate, int frequency})>(
      context: context,
      builder: (_) => _EditItemDialog(item: item),
    );
    if (result == null) return;
    setState(() {
      item.rate = result.rate;
      item.frequency = result.frequency;
    });
  }

  void _resetAddForm() {
    _selectedServiceId = null;
    _selectedPackageId = null;
    _rateController.clear();
    _frequencyController.text = '1';
    _addDropdownEpoch++;
  }

  List<Map<String, dynamic>> _collectBillItems() {
    return [
      for (final item in _items)
        {
          'item_type': item.itemType,
          'item_name': item.name,
          'quantity': item.frequency,
          'unit_price': item.rate,
          'total_price': item.total,
        },
    ];
  }

  Future<void> _generateBill() async {
    final admissionId = _loadedAdmissionId;
    if (admissionId == null) {
      _showMessage('Load an admission first.');
      return;
    }
    if (_items.isEmpty || _totalAmount <= 0) {
      _showMessage('Bill has no items.');
      return;
    }
    if (_discountAmount < 0) {
      _showMessage('Discount cannot be negative.');
      return;
    }
    if (_discountAmount > _totalAmount) {
      _showMessage('Discount cannot exceed the subtotal.');
      return;
    }

    setState(() => _isGenerating = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final bill = await db.generateIPDBill(
        admissionId: admissionId,
        items: _collectBillItems(),
        totalAmount: _totalAmount,
        paidAmount: _paidAmount,
        paymentStatus: _paymentStatus,
        paymentMode: _paymentMode,
        transactionReference: _transactionRefController.text.trim(),
        discountAmount: _discountAmount,
        discountReason: _discountReasonController.text.trim(),
      );

      ref.invalidate(ipdBillsProvider(admissionId));

      // Unified billing tabs reflect the freshly generated IPD bill.
      final hospitalId = ref.read(authStateProvider).hospitalId;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        for (final sourceType in <String?>[null, 'ipd']) {
          ref.invalidate(
            allBillsProvider(
              BillingFilter(hospitalId: hospitalId, sourceType: sourceType),
            ),
          );
        }
      }

      if (!mounted) return;
      _showMessage('Bill generated successfully!');
      await _printBill(bill);
    } catch (e) {
      if (!mounted) return;
      _showMessage('Bill generation failed: $e');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<void> _printBill([Map<String, dynamic>? generatedBill]) async {
    final admissionId = _loadedAdmissionId;
    if (admissionId == null) return;
    final details = _details;
    if (details == null) return;

    final admission =
        (details['admission'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final patient =
        (details['patient'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final hospital =
        (details['hospital'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    final patientName =
        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();

    await IPDBillService.printBill({
      'hospitalName': hospital['name']?.toString() ?? 'HIMS Hospital',
      'hospitalAddress': hospital['address']?.toString(),
      'hospitalPhone': hospital['phone']?.toString(),
      'patientName': patientName.isEmpty ? 'Unknown' : patientName,
      'uhid': patient['uhid']?.toString() ?? 'N/A',
      'admissionDate':
          _parseDate(admission['admission_date'])?.toDisplayDate ?? 'N/A',
      'billNumber': generatedBill?['bill_number']?.toString() ?? 'Draft',
      'billDate':
          generatedBill?['bill_date']?.toString() ??
          DateTime.now().toDisplayDate,
      'items': _collectBillItems(),
      'totalAmount': _totalAmount,
      'discountAmount': _discountAmount,
      'netPayable': _netPayable,
      'paidAmount': _paidAmount,
      'balanceAmount': _balanceAmount,
      'paymentStatus': _paymentStatus,
    });
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SmartAppBar(title: const Text('IPD Billing')),
      body: AppPageScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAdmissionLookupCard(theme),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_details != null) ...[
              const SizedBox(height: 12),
              _buildPatientCard(theme),
              const SizedBox(height: 12),
              _buildAddChargesCard(theme),
              const SizedBox(height: 12),
              _buildBillItemsCard(theme),
              const SizedBox(height: 12),
              _buildPaymentCard(theme),
              const SizedBox(height: 12),
              _buildExistingBillsCard(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAdmissionLookupCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Admission',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _admissionIdController,
                    decoration: const InputDecoration(
                      labelText: 'Admission ID',
                      hintText: 'Paste admission UUID',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _loadAdmission,
                  icon: const Icon(Icons.search),
                  label: const Text('Load'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPatientCard(ThemeData theme) {
    final details = _details!;
    final admission =
        (details['admission'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final patient =
        (details['patient'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final doctor =
        (details['doctor'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final bed =
        (details['bed'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    final patientName =
        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
    final doctorName = doctor['first_name'] != null
        ? 'Dr. ${doctor['first_name']} ${doctor['last_name'] ?? ''}'.trim()
        : 'N/A';

    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              patientName.isEmpty ? 'Unknown Patient' : patientName,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'UHID: ${patient['uhid']?.toString() ?? 'N/A'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _infoRow(
              theme,
              Icons.calendar_today,
              'Admission Date',
              _parseDate(admission['admission_date'])?.toDisplayDate ?? 'N/A',
            ),
            _infoRow(
              theme,
              Icons.timelapse,
              'Length of Stay',
              '${_finalBill?['length_of_stay'] ?? 1} day(s)',
            ),
            _infoRow(
              theme,
              Icons.meeting_room,
              'Ward',
              _formatWardType(
                admission['ward_type']?.toString() ??
                    bed['ward_type']?.toString() ??
                    'general',
              ),
            ),
            _infoRow(
              theme,
              Icons.bed,
              'Bed',
              bed['bed_number']?.toString() ?? 'N/A',
            ),
            _infoRow(theme, Icons.medical_services, 'Doctor', doctorName),
          ],
        ),
      ),
    );
  }

  Widget _buildAddChargesCard(ThemeData theme) {
    final options = _currentOptions;
    final isService = _addMode == _AddMode.services;
    final label = isService ? 'Service' : 'Package';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add Charges',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Everything comes from Settings. Rate and frequency are editable '
              'for this patient.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<_AddMode>(
              segments: const [
                ButtonSegment(
                  value: _AddMode.services,
                  label: Text('Services'),
                  icon: Icon(Icons.miscellaneous_services_outlined),
                ),
                ButtonSegment(
                  value: _AddMode.packages,
                  label: Text('Packages'),
                  icon: Icon(Icons.inventory_2_outlined),
                ),
              ],
              selected: {_addMode},
              onSelectionChanged: (selection) {
                setState(() {
                  _addMode = selection.first;
                  _resetAddForm();
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('add_${_addMode.name}_$_addDropdownEpoch'),
              initialValue: null,
              decoration: InputDecoration(
                labelText: 'Select $label',
                hintText: options.isEmpty
                    ? 'Nothing configured in Settings'
                    : 'Choose from your Settings list',
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Select'),
                ),
                for (final option in options)
                  DropdownMenuItem<String>(
                    value: option['id']?.toString(),
                    child: Text(
                      '${option['name']} — ${_inr(_optionDefaultRate(option))}',
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) _onOptionSelected(value);
              },
            ),
            if (options.isEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'No ${isService ? 'services' : 'packages'} configured yet. '
                      'Add them from Settings → IPD Billing Masters.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rateController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Rate (₹)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _frequencyController,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Frequency',
                      helperText: 'Number of times / days',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Amount = Rate × Frequency'),
                  Text(
                    _inr(_previewAmount),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _addSelectedItem,
                icon: const Icon(Icons.add),
                label: Text('Add $label to Bill'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _optionDefaultRate(Map<String, dynamic> option) {
    return _addMode == _AddMode.services
        ? _toDouble(option['default_charge'])
        : _toDouble(option['package_amount']);
  }

  Widget _buildBillItemsCard(ThemeData theme) {
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
            const SizedBox(height: 4),
            Text(
              'Room charges are auto-calculated from the admission date range. '
              'Tap any item to edit its rate or frequency.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No items yet. Add Services or Packages above.'),
              )
            else ...[
              for (final item in _items) _buildItemTile(theme, item),
              const Divider(),
              _totalRow(theme, 'Room Charges (auto)', _roomTotal),
              _totalRow(theme, 'Services & Packages', _otherTotal),
              const SizedBox(height: 4),
              _totalRow(theme, 'Total Amount', _totalAmount, bold: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildItemTile(ThemeData theme, _BillLine item) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_iconForType(item.itemType)),
      title: Text(item.name),
      subtitle: Text(
        '${_inr(item.rate)} × ${item.frequency} = ${_inr(item.total)}',
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _inr(item.total),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Edit rate / frequency',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => _editItem(item),
              ),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Colors.red,
                ),
                onPressed: () => setState(
                  () => _items.removeWhere((i) => i.key == item.key),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Payment',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _totalRow(theme, 'Room Charges', _roomTotal),
            _totalRow(theme, 'Services & Packages', _otherTotal),
            const Divider(),
            _totalRow(theme, 'Subtotal', _totalAmount, bold: true),
            const SizedBox(height: 8),
            TextField(
              controller: _discountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Discount Amount (₹)',
                prefixIcon: Icon(Icons.savings_outlined),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _discountReasonController,
              decoration: const InputDecoration(
                labelText: 'Discount Reason (optional)',
              ),
            ),
            const SizedBox(height: 8),
            _totalRow(theme, 'Net Payable', _netPayable, bold: true),
            const SizedBox(height: 8),
            TextField(
              controller: _paidAmountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Paid Amount (₹)',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 8),
            _totalRow(theme, 'Balance Amount', _balanceAmount, bold: true),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _paymentStatus,
                    decoration: const InputDecoration(
                      labelText: 'Payment Status',
                    ),
                    items:
                        [
                              ('unpaid', 'Unpaid'),
                              ('partially_paid', 'Partial'),
                              ('paid', 'Paid'),
                            ]
                            .map(
                              (entry) => DropdownMenuItem(
                                value: entry.$1,
                                child: Text(entry.$2),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => setState(() => _paymentStatus = v!),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _paymentMode,
                    decoration: const InputDecoration(
                      labelText: 'Payment Mode',
                    ),
                    items:
                        ['cash', 'card', 'upi', 'online', 'insurance', 'cheque']
                            .map(
                              (mode) => DropdownMenuItem(
                                value: mode,
                                child: Text(mode.toUpperCase()),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => setState(() => _paymentMode = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _transactionRefController,
              decoration: const InputDecoration(
                labelText: 'Transaction Reference (optional)',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isGenerating ? null : _printBill,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Print Bill'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: _isGenerating
                        ? const Center(child: CircularProgressIndicator())
                        : ElevatedButton.icon(
                            onPressed: _generateBill,
                            icon: const Icon(Icons.receipt_long),
                            label: const Text('Generate Bill'),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExistingBillsCard(ThemeData theme) {
    final admissionId = _loadedAdmissionId;
    if (admissionId == null) return const SizedBox.shrink();

    final billsAsync = ref.watch(ipdBillsProvider(admissionId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Generated Bills',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            billsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Failed to load bills: $e'),
              data: (bills) {
                if (bills.isEmpty) {
                  return const Text('No bills generated yet.');
                }
                return Column(
                  children: [
                    for (final bill in bills)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: Text(bill['bill_number']?.toString() ?? 'Bill'),
                        subtitle: Text(
                          '${bill['bill_date']?.toString() ?? ''} • '
                          '${bill['payment_status']?.toString() ?? ''}',
                        ),
                        trailing: Text(
                          _inr(_toDouble(bill['total_amount'])),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Small widgets
  // ---------------------------------------------------------------------------

  Widget _totalRow(
    ThemeData theme,
    String label,
    double value, {
    bool bold = false,
  }) {
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

  Widget _infoRow(ThemeData theme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
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

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  int _toInt(dynamic value, {required int fallback}) {
    if (value == null) return fallback;
    return int.tryParse(value.toString()) ?? fallback;
  }

  String _formatWardType(String wardType) {
    final words = wardType.split('_').where((w) => w.isNotEmpty).toList();
    final formatted = words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    return formatted.isEmpty ? 'General' : formatted;
  }

  String _chargeTypeLabel(String chargeType) {
    const labels = {
      'ot_charges': 'OT Charges',
      'anesthesia': 'Anesthesia Charge',
      'nebulization': 'Nebulization Charge',
      'blood_transfusion': 'Blood Transfusion Charge',
      'doctor_visit': 'Doctor Visit Charges',
      'pharmacy': 'Pharmacy Charges',
      'lab': 'Lab Charges',
      'package': 'Package Charges',
      'service': 'Service Charges',
      'misc': 'Other Charges',
    };
    return labels[chargeType] ?? chargeType;
  }

  IconData _iconForType(String itemType) {
    switch (itemType) {
      case 'room_charge':
        return Icons.meeting_room_outlined;
      case 'package':
        return Icons.inventory_2_outlined;
      case 'service':
        return Icons.miscellaneous_services_outlined;
      default:
        return Icons.receipt_long_outlined;
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// Edit rate / frequency dialog
// ---------------------------------------------------------------------------

class _EditItemDialog extends StatefulWidget {
  final _BillLine item;
  const _EditItemDialog({required this.item});

  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  late final TextEditingController _rateController;
  late final TextEditingController _frequencyController;

  @override
  void initState() {
    super.initState();
    _rateController = TextEditingController(text: _money(widget.item.rate));
    _frequencyController = TextEditingController(
      text: '${widget.item.frequency}',
    );
  }

  @override
  void dispose() {
    _rateController.dispose();
    _frequencyController.dispose();
    super.dispose();
  }

  double get _total {
    final rate = _toDouble(_rateController.text);
    final frequency = int.tryParse(_frequencyController.text.trim()) ?? 0;
    return (rate * frequency * 100).roundToDouble() / 100;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _rateController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Rate (₹)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _frequencyController,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Frequency'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Total: ${_inr(_total)}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final rate = _toDouble(_rateController.text);
            final frequency =
                int.tryParse(_frequencyController.text.trim()) ?? 0;
            if (rate <= 0 || frequency <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Enter a valid rate and frequency.'),
                ),
              );
              return;
            }
            Navigator.pop(context, (rate: rate, frequency: frequency));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
