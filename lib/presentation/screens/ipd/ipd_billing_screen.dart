import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/ipd_bill_service.dart';
import '../../widgets/smart_navigation.dart';

class IPDBillingScreen extends ConsumerStatefulWidget {
  final String? admissionId;
  const IPDBillingScreen({super.key, this.admissionId});

  @override
  ConsumerState<IPDBillingScreen> createState() => _IPDBillingScreenState();
}

class _IPDBillingScreenState extends ConsumerState<IPDBillingScreen> {
  late final TextEditingController _admissionIdController =
      TextEditingController(text: widget.admissionId ?? '');
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController();
  final _visitCountController = TextEditingController(text: '0');
  final _visitFeeController = TextEditingController(text: '500');
  final _paidAmountController = TextEditingController();
  final _transactionRefController = TextEditingController();

  String? _loadedAdmissionId;
  Map<String, dynamic>? _details;
  Map<String, dynamic>? _finalBill;

  String _chargeType = 'lab';
  String _paymentStatus = 'unpaid';
  String _paymentMode = 'cash';
  bool _isLoading = false;
  bool _isGenerating = false;
  int _addDropdownEpoch = 0;

  final List<Map<String, dynamic>> _manualItems = [];
  int _manualItemSeq = 0;

  static const Map<String, String> _chargeTypeLabels = {
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

  final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_US',
    symbol: '₹',
    decimalDigits: 0,
  );

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
    _descriptionController.dispose();
    _amountController.dispose();
    _visitCountController.dispose();
    _visitFeeController.dispose();
    _paidAmountController.dispose();
    _transactionRefController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Billing helpers
  // ---------------------------------------------------------------------------

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }

  double get _manualTotal =>
      _manualItems.fold(0, (sum, item) => sum + _toDouble(item['total_price']));

  double get _wardTotal => _toDouble(_finalBill?['ward_total']);

  double get _savedChargesTotal => _toDouble(_finalBill?['other_total']);

  double get _totalAmount =>
      _toDouble(_finalBill?['total_amount']) + _manualTotal;

  double get _paidAmount => _toDouble(_paidAmountController.text);

  double get _balanceAmount => _totalAmount - _paidAmount;

  String _inr(double value) => _currency.format(value);

  List<Map<String, dynamic>> _collectBillItems() {
    final items = <Map<String, dynamic>>[];

    final segments = ((_finalBill?['ward_segments'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (final segment in segments) {
      items.add({
        'item_type': 'room_charge',
        'item_name':
            'Ward Charges - ${_formatWardType(segment['ward_type']?.toString() ?? 'Ward')}',
        'quantity': segment['days'] ?? 1,
        'unit_price': segment['daily_rate'] ?? 0,
        'total_price': segment['amount'] ?? 0,
      });
    }

    final savedCharges = ((_finalBill?['other_charges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (final charge in savedCharges) {
      items.add({
        'item_type': _itemTypeForCharge(charge['charge_type']),
        'item_name':
            charge['charge_description']?.toString() ??
            _chargeTypeLabel(charge['charge_type']),
        'quantity': 1,
        'unit_price': charge['amount'] ?? 0,
        'total_price': charge['amount'] ?? 0,
      });
    }

    items.addAll(_manualItems);
    return items;
  }

  String _itemTypeForCharge(dynamic chargeType) {
    switch (chargeType?.toString()) {
      case 'pharmacy':
        return 'medicine';
      case 'lab':
        return 'lab_test';
      case 'ot_charges':
      case 'anesthesia':
      case 'nebulization':
      case 'blood_transfusion':
        return 'procedure';
      case 'doctor_visit':
        return 'consultation';
      case 'package':
      case 'service':
        return 'others';
      default:
        return 'others';
    }
  }

  String _chargeTypeLabel(dynamic chargeType) {
    return _chargeTypeLabels[chargeType?.toString()] ??
        chargeType?.toString() ??
        'Charge';
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  String _formatWardType(String wardType) {
    final words = wardType.split('_').where((w) => w.isNotEmpty).toList();
    final formatted = words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    return formatted.isEmpty ? 'General' : formatted;
  }

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
      _manualItems.clear();
      _paidAmountController.clear();
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
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to load admission: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _generateBill() async {
    final admissionId = _loadedAdmissionId;
    if (admissionId == null) {
      _showMessage('Load an admission first.');
      return;
    }
    if (_totalAmount <= 0) {
      _showMessage('Bill has no items.');
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
      body: SingleChildScrollView(
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
              const SizedBox(height: 16),
              _buildPatientCard(theme),
              const SizedBox(height: 16),
              _buildBillItemsCard(theme),
              const SizedBox(height: 16),
              _buildAddItemsCard(theme),
              const SizedBox(height: 16),
              _buildPaymentCard(theme),
              const SizedBox(height: 16),
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

  Widget _buildBillItemsCard(ThemeData theme) {
    final segments = ((_finalBill?['ward_segments'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final savedCharges = ((_finalBill?['other_charges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Billing Items',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (segments.isEmpty &&
                savedCharges.isEmpty &&
                _manualItems.isEmpty)
              const Text('No items yet. Add items below.')
            else ...[
              for (final segment in segments)
                _itemTile(
                  theme,
                  title:
                      'Ward Charges - ${_formatWardType(segment['ward_type']?.toString() ?? 'Ward')}',
                  subtitle:
                      '${segment['days']} day(s) × ${_inr(_toDouble(segment['daily_rate']))}',
                  amount: _toDouble(segment['amount']),
                ),
              for (final charge in savedCharges)
                _itemTile(
                  theme,
                  title:
                      charge['charge_description']?.toString() ??
                      _chargeTypeLabel(charge['charge_type']),
                  subtitle: _chargeTypeLabel(charge['charge_type']),
                  amount: _toDouble(charge['amount']),
                ),
              for (final item in _manualItems)
                _itemTile(
                  theme,
                  title: item['item_name']?.toString() ?? 'Item',
                  subtitle: _chargeTypeLabel(item['item_type']),
                  amount: _toDouble(item['total_price']),
                  onDelete: () => setState(
                    () => _manualItems.removeWhere(
                      (m) => m['_key'] == item['_key'],
                    ),
                  ),
                ),
              const Divider(),
              _totalRow(theme, 'Total Bill Amount', _totalAmount, bold: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAddItemsCard(ThemeData theme) {
    final services = ((_details?['service_master'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final packages = ((_details?['packages'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add Billing Items',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            // Doctor visits
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _visitCountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Doctor Visits',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _visitFeeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Fee / Visit (₹)',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Add doctor visit charge',
                  onPressed: _addDoctorVisitItem,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Package quick-add
            DropdownButtonFormField<String>(
              key: ValueKey('pkg_$_addDropdownEpoch'),
              initialValue: null,
              decoration: const InputDecoration(labelText: 'Operation Package'),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Select package'),
                ),
                for (final package in packages)
                  DropdownMenuItem<String>(
                    value: package['id']?.toString(),
                    child: Text(
                      '${package['name']} - ${_inr(_toDouble(package['package_amount']))}',
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                final package = packages.firstWhere(
                  (p) => p['id']?.toString() == v,
                  orElse: () => const {},
                );
                if (package.isNotEmpty) _addPackageItem(package);
              },
            ),
            const SizedBox(height: 12),

            // Service quick-add
            DropdownButtonFormField<String>(
              key: ValueKey('svc_$_addDropdownEpoch'),
              initialValue: null,
              decoration: const InputDecoration(
                labelText: 'Custom Service (Service Master)',
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Select service'),
                ),
                for (final service in services)
                  DropdownMenuItem<String>(
                    value: service['id']?.toString(),
                    child: Text(
                      '${service['name']} - ${_inr(_toDouble(service['default_charge']))}',
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                final service = services.firstWhere(
                  (s) => s['id']?.toString() == v,
                  orElse: () => const {},
                );
                if (service.isNotEmpty) _addServiceItem(service);
              },
            ),
            const SizedBox(height: 12),

            // Manual item row
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: _chargeType,
                    decoration: const InputDecoration(labelText: 'Charge Type'),
                    items: _chargeTypeLabels.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _chargeType = v!),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _amountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Amount (₹)'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Add item',
                  onPressed: _addManualItem,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ),
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
            _totalRow(theme, 'Ward Charges', _wardTotal),
            _totalRow(theme, 'Saved Charges', _savedChargesTotal),
            _totalRow(theme, 'New Items', _manualTotal),
            const Divider(),
            _totalRow(theme, 'Total Amount', _totalAmount, bold: true),
            const SizedBox(height: 8),
            TextField(
              controller: _paidAmountController,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Paid Amount (₹)',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
            _totalRow(theme, 'Balance Amount', _balanceAmount, bold: true),
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

  Widget _itemTile(
    ThemeData theme, {
    required String title,
    required String subtitle,
    required double amount,
    VoidCallback? onDelete,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _inr(amount),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

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
  // Actions
  // ---------------------------------------------------------------------------

  void _addManualItem() {
    final description = _descriptionController.text.trim();
    final amount = _toDouble(_amountController.text);
    if (description.isEmpty || amount <= 0) {
      _showMessage('Enter a description and a valid amount.');
      return;
    }
    setState(() {
      _manualItems.add({
        '_key': 'manual_${_manualItemSeq++}',
        'item_type': _chargeType,
        'item_name': description,
        'quantity': 1,
        'unit_price': amount,
        'total_price': amount,
      });
      _descriptionController.clear();
      _amountController.clear();
    });
  }

  void _addDoctorVisitItem() {
    final visits = int.tryParse(_visitCountController.text) ?? 0;
    final fee = _toDouble(_visitFeeController.text);
    if (visits <= 0 || fee <= 0) {
      _showMessage('Enter valid visit count and fee.');
      return;
    }
    setState(() {
      _manualItems.add({
        '_key': 'manual_${_manualItemSeq++}',
        'item_type': 'doctor_visit',
        'item_name': 'Doctor Visits ($visits × ${_inr(fee)})',
        'quantity': visits,
        'unit_price': fee,
        'total_price': (visits * fee).roundToDouble(),
      });
    });
  }

  void _addPackageItem(Map<String, dynamic> package) {
    setState(() {
      _manualItems.add({
        '_key': 'manual_${_manualItemSeq++}',
        'item_type': 'package',
        'item_name': '${package['name']} (Package)',
        'quantity': 1,
        'unit_price': _toDouble(package['package_amount']),
        'total_price': _toDouble(package['package_amount']),
      });
      _addDropdownEpoch++;
    });
  }

  void _addServiceItem(Map<String, dynamic> service) {
    setState(() {
      _manualItems.add({
        '_key': 'manual_${_manualItemSeq++}',
        'item_type': 'service',
        'item_name': service['name']?.toString() ?? 'Service',
        'quantity': 1,
        'unit_price': _toDouble(service['default_charge']),
        'total_price': _toDouble(service['default_charge']),
      });
      _addDropdownEpoch++;
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
