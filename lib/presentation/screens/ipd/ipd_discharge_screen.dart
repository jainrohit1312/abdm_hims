import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/discharge_summary_service.dart';
import '../../../services/ipd_bill_service.dart';
import '../../widgets/smart_navigation.dart';

class IPDDischargeScreen extends ConsumerStatefulWidget {
  final String admissionId;
  const IPDDischargeScreen({super.key, required this.admissionId});

  @override
  ConsumerState<IPDDischargeScreen> createState() => _IPDDischargeScreenState();
}

class _IPDDischargeScreenState extends ConsumerState<IPDDischargeScreen> {
  final _summaryController = TextEditingController();
  final _adviceController = TextEditingController();
  final _advanceController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController();
  final _visitCountController = TextEditingController(text: '0');
  final _visitFeeController = TextEditingController(text: '500');

  String _dischargeType = 'Routine';
  DateTime _dischargeDate = DateTime.now();
  String _chargeType = 'ot_charges';
  bool _confirmDischarge = false;
  bool _isDischarging = false;
  bool _initializedForAdmission = false;
  int _addDropdownEpoch = 0;

  /// Bill computed by [DatabaseService.calculateFinalBill] (DB backed).
  Map<String, dynamic>? _finalBill;

  /// Charges added manually on this screen (not saved to DB yet).
  final List<Map<String, dynamic>> _manualCharges = [];
  int _manualChargeSeq = 0;

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
  void dispose() {
    _summaryController.dispose();
    _adviceController.dispose();
    _advanceController.dispose();
    _descriptionController.dispose();
    _amountController.dispose();
    _visitCountController.dispose();
    _visitFeeController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Billing helpers
  // ---------------------------------------------------------------------------

  double get _manualTotal =>
      _manualCharges.fold(0, (sum, c) => sum + _toDouble(c['amount']));

  double get _wardTotal => _toDouble(_finalBill?['ward_total']);

  double get _dbTotal => _toDouble(_finalBill?['total_amount']);

  double get _dbOtherTotal => _toDouble(_finalBill?['other_total']);

  double get _advanceValue => _toDouble(_advanceController.text);

  double get _grandTotal => _dbTotal + _manualTotal;

  double get _finalPayable => _grandTotal - _advanceValue;

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  String _formatDate(DateTime? date) =>
      date == null ? 'N/A' : date.toDisplayDate;

  String _inr(double value) => _currency.format(value);

  String get _paymentStatus {
    if (_grandTotal <= 0) return 'unpaid';
    if (_finalPayable <= 0) return 'paid';
    if (_advanceValue > 0) return 'partially_paid';
    return 'unpaid';
  }

  /// Builds line items for the Final Bill PDF from the DB-calculated bill and
  /// any charges added manually on this screen.
  List<Map<String, dynamic>> _collectBillItems() {
    final items = <Map<String, dynamic>>[];

    final segments = ((_finalBill?['ward_segments'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (final segment in segments) {
      final wardLabel = _formatWardType(
        segment['ward_type']?.toString() ?? 'Ward',
      );
      final bedNumber = segment['bed_number']?.toString() ?? '';
      items.add({
        'item_type': 'room_charge',
        'item_name': bedNumber.isEmpty
            ? 'Ward Charges - $wardLabel'
            : 'Ward Charges - $wardLabel ($bedNumber)',
        'quantity': segment['days'] ?? 1,
        'unit_price': segment['daily_rate'] ?? 0,
        'total_price': segment['amount'] ?? 0,
      });
    }

    final savedCharges = ((_finalBill?['other_charges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (final charge in savedCharges) {
      items.add({
        'item_type': charge['charge_type'] ?? 'others',
        'item_name':
            charge['charge_description']?.toString() ??
            _chargeTypeLabel(charge['charge_type']),
        'quantity': 1,
        'unit_price': charge['amount'] ?? 0,
        'total_price': charge['amount'] ?? 0,
      });
    }

    for (final charge in _manualCharges) {
      items.add({
        'item_type': charge['charge_type'] ?? 'others',
        'item_name':
            charge['charge_description']?.toString() ??
            _chargeTypeLabel(charge['charge_type']),
        'quantity': 1,
        'unit_price': charge['amount'] ?? 0,
        'total_price': charge['amount'] ?? 0,
      });
    }

    return items;
  }

  Future<void> _recalculateBill() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final bill = await db.calculateFinalBill(
        widget.admissionId,
        dischargeDate: _dischargeDate,
      );
      if (mounted) setState(() => _finalBill = bill);
    } catch (e) {
      AppLoggerCompat.log('Recalculate bill failed: $e');
    }
  }

  void _initFromDetails(Map<String, dynamic> details) {
    final admission = details['admission'] as Map<String, dynamic>;
    final advance = _toDouble(admission['advance_payment']);
    _advanceController.text = advance == 0 ? '' : advance.toStringAsFixed(2);

    final visitCount = details['doctor_visit_count'] ?? 0;
    _visitCountController.text = '$visitCount';

    // Prefill doctor visit fee from service master if "Doctor Visit" exists.
    final services = (details['service_master'] as List)
        .cast<Map<String, dynamic>>();
    for (final service in services) {
      final name = service['name']?.toString().toLowerCase() ?? '';
      if (name.contains('doctor') && name.contains('visit')) {
        final fee = _toDouble(service['default_charge']);
        if (fee > 0) _visitFeeController.text = fee.toStringAsFixed(0);
        break;
      }
    }
    _recalculateBill();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final detailsAsync = ref.watch(
      ipdChargeDetailsProvider(widget.admissionId),
    );

    return Scaffold(
      appBar: SmartAppBar(title: const Text('IPD Discharge & Billing')),
      body: detailsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildError(context, e),
        data: (details) {
          if (!_initializedForAdmission) {
            _initializedForAdmission = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _initFromDetails(details);
            });
          }
          return _buildContent(context, details);
        },
      ),
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Failed to load discharge data.\n$error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: () =>
                  ref.invalidate(ipdChargeDetailsProvider(widget.admissionId)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Map<String, dynamic> details) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPatientCard(theme, details),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push(
                    '/ipd/transfer?admissionId=${widget.admissionId}',
                  ),
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Transfer Ward'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push(
                    '/ipd/billing?admissionId=${widget.admissionId}',
                  ),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Billing'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildDischargeCard(theme, details),
          const SizedBox(height: 16),
          _buildWardChargesCard(theme),
          const SizedBox(height: 16),
          _buildOtherChargesCard(theme, details),
          const SizedBox(height: 16),
          _buildBillingSummaryCard(theme, details),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isDischarging
                      ? null
                      : () => _printDischargeSummary(details),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Discharge Summary PDF'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isDischarging
                      ? null
                      : () => _printFinalBill(details),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Final Bill PDF'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: _isDischarging
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton.icon(
                    onPressed: _confirmDischarge
                        ? () => _submitDischarge(details)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.logout),
                    label: const Text('Discharge Patient'),
                  ),
          ),
        ],
      ),
    );
  }

  // -- Patient & admission details -------------------------------------------

  Widget _buildPatientCard(ThemeData theme, Map<String, dynamic> details) {
    final admission = details['admission'] as Map<String, dynamic>;
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
    final uhid = patient['uhid']?.toString() ?? 'N/A';
    final admissionDate = _parseDate(admission['admission_date']);
    final wardType =
        admission['ward_type']?.toString() ??
        bed['ward_type']?.toString() ??
        'N/A';
    final bedNumber = bed['bed_number']?.toString() ?? 'N/A';
    final doctorName = doctor['first_name'] != null
        ? 'Dr. ${doctor['first_name']} ${doctor['last_name'] ?? ''}'.trim()
        : 'N/A';
    final los = _finalBill?['length_of_stay'] ?? 1;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        patientName.isEmpty ? 'Unknown Patient' : patientName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('UHID: $uhid', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _infoRow(
              theme,
              Icons.calendar_today,
              'Admission Date',
              _formatDate(admissionDate),
            ),
            _infoRow(
              theme,
              Icons.meeting_room,
              'Ward',
              _formatWardType(wardType),
            ),
            _infoRow(theme, Icons.bed, 'Bed', bedNumber),
            _infoRow(theme, Icons.medical_services, 'Doctor', doctorName),
            _infoRow(
              theme,
              Icons.timelapse,
              'Length of Stay (LOS)',
              '$los day(s)',
            ),
          ],
        ),
      ),
    );
  }

  // -- Discharge information --------------------------------------------------

  Widget _buildDischargeCard(ThemeData theme, Map<String, dynamic> details) {
    final admission = details['admission'] as Map<String, dynamic>;
    final admissionDate =
        _parseDate(admission['admission_date']) ?? DateTime(2000);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Discharge Details',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _dischargeDate,
                  firstDate: admissionDate,
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null) {
                  setState(() => _dischargeDate = picked);
                  _recalculateBill();
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Discharge Date',
                  suffixIcon: Icon(Icons.calendar_month),
                ),
                child: Text(_dischargeDate.toDisplayDate),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _dischargeType,
              decoration: const InputDecoration(labelText: 'Discharge Type'),
              items: [
                'Routine',
                'LAMA',
                'DOR',
                'Death',
              ].map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
              onChanged: (v) => setState(() => _dischargeType = v!),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _summaryController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Treatment / Discharge Summary',
                hintText: 'Enter treatment summary...',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _adviceController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Discharge Advice',
                hintText:
                    'Enter discharge advice and follow-up instructions...',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -- Ward charges -----------------------------------------------------------

  Widget _buildWardChargesCard(ThemeData theme) {
    final segments = ((_finalBill?['ward_segments'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ward Charges (Auto Calculated)',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Total = Sum of (Days in Ward × Ward Daily Rate)',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (segments.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('No ward segments found.'),
              )
            else
              for (final segment in segments)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.meeting_room_outlined),
                  title: Text(
                    '${_formatWardType(segment['ward_type']?.toString() ?? 'Ward')}'
                    '${segment['bed_number']?.toString().isNotEmpty == true ? ' - ${segment['bed_number']}' : ''}',
                  ),
                  subtitle: Text(
                    '${segment['days']} day(s) × ${_inr(_toDouble(segment['daily_rate']))}',
                  ),
                  trailing: Text(
                    _inr(_toDouble(segment['amount'])),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Ward Total',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  _inr(_wardTotal),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -- Other charges ----------------------------------------------------------

  Widget _buildOtherChargesCard(ThemeData theme, Map<String, dynamic> details) {
    final dbCharges = ((details['charges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final services = ((details['service_master'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final packages = ((details['packages'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Other Charges (OT, Pharmacy, Lab, Services...)',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (dbCharges.isEmpty && _manualCharges.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No charges added yet.'),
              )
            else ...[
              for (final charge in dbCharges)
                _chargeTile(
                  theme,
                  description:
                      charge['charge_description']?.toString() ??
                      _chargeTypeLabel(charge['charge_type']),
                  typeLabel: _chargeTypeLabel(charge['charge_type']),
                  amount: _toDouble(charge['amount']),
                  onDelete: () => _deleteDbCharge(charge['id']?.toString()),
                ),
              for (final charge in _manualCharges)
                _chargeTile(
                  theme,
                  description: charge['charge_description']?.toString() ?? '',
                  typeLabel: _chargeTypeLabel(charge['charge_type']),
                  amount: _toDouble(charge['amount']),
                  onDelete: () => setState(
                    () => _manualCharges.removeWhere(
                      (c) => c['_key'] == charge['_key'],
                    ),
                  ),
                ),
            ],
            const Divider(),
            const SizedBox(height: 4),

            // Doctor visit quick-add
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
                  onPressed: _addDoctorVisitCharge,
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
                if (package.isNotEmpty) _addPackageCharge(package);
              },
            ),
            const SizedBox(height: 12),

            // Custom service quick-add
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
                if (service.isNotEmpty) _addServiceCharge(service);
              },
            ),
            const SizedBox(height: 12),

            // Manual charge row
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
                  tooltip: 'Add charge',
                  onPressed: _addManualCharge,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chargeTile(
    ThemeData theme, {
    required String description,
    required String typeLabel,
    required double amount,
    required VoidCallback onDelete,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(description),
      subtitle: Text(typeLabel),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _inr(amount),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  // -- Final billing summary --------------------------------------------------

  Widget _buildBillingSummaryCard(
    ThemeData theme,
    Map<String, dynamic> details,
  ) {
    final dbOtherCharges = ((details['charges'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Final Bill',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _totalRow('Ward Charges', _wardTotal),
            _totalRow('Other Charges (saved)', _dbOtherTotal),
            _totalRow('Other Charges (new)', _manualTotal),
            const Divider(),
            _totalRow('Total Amount', _grandTotal, bold: true),
            const SizedBox(height: 8),
            TextField(
              controller: _advanceController,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Advance Payment (₹)',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 8),
            _totalRow('Final Payable Amount', _finalPayable, bold: true),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Advance: ${_inr(_advanceValue)}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  'Saved charges: ${dbOtherCharges.length}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const Divider(height: 24),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('I confirm the discharge of this patient'),
              value: _confirmDischarge,
              onChanged: (v) => setState(() => _confirmDischarge = v!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _totalRow(String label, double value, {bool bold = false}) {
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
  // Actions
  // ---------------------------------------------------------------------------

  void _addManualCharge() {
    final description = _descriptionController.text.trim();
    final amount = _toDouble(_amountController.text);
    if (description.isEmpty || amount <= 0) {
      _showMessage('Enter a description and a valid amount.');
      return;
    }
    setState(() {
      _manualCharges.add({
        '_key': 'manual_${_manualChargeSeq++}',
        'charge_type': _chargeType,
        'charge_description': description,
        'amount': amount,
      });
      _descriptionController.clear();
      _amountController.clear();
    });
  }

  void _addDoctorVisitCharge() {
    final visits = int.tryParse(_visitCountController.text) ?? 0;
    final fee = _toDouble(_visitFeeController.text);
    if (visits <= 0 || fee <= 0) {
      _showMessage('Enter valid visit count and fee.');
      return;
    }
    setState(() {
      _manualCharges.add({
        '_key': 'manual_${_manualChargeSeq++}',
        'charge_type': 'doctor_visit',
        'charge_description': 'Doctor Visits ($visits × ${_inr(fee)})',
        'amount': (visits * fee).roundToDouble(),
      });
    });
  }

  void _addPackageCharge(Map<String, dynamic> package) {
    setState(() {
      _manualCharges.add({
        '_key': 'manual_${_manualChargeSeq++}',
        'charge_type': 'package',
        'charge_description': '${package['name']} (Package)',
        'amount': _toDouble(package['package_amount']),
      });
      _addDropdownEpoch++;
    });
  }

  void _addServiceCharge(Map<String, dynamic> service) {
    setState(() {
      _manualCharges.add({
        '_key': 'manual_${_manualChargeSeq++}',
        'charge_type': 'service',
        'charge_description': service['name']?.toString() ?? 'Service',
        'amount': _toDouble(service['default_charge']),
      });
      _addDropdownEpoch++;
    });
  }

  Future<void> _deleteDbCharge(String? chargeId) async {
    if (chargeId == null) return;
    try {
      await ref.read(databaseServiceProvider).deleteIPDCharge(chargeId);
      ref.invalidate(ipdChargeDetailsProvider(widget.admissionId));
      await _recalculateBill();
    } catch (e) {
      _showMessage('Failed to delete charge: $e');
    }
  }

  Future<void> _printDischargeSummary(Map<String, dynamic> details) async {
    final admission = details['admission'] as Map<String, dynamic>;
    final patient =
        (details['patient'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final doctor =
        (details['doctor'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final hospital =
        (details['hospital'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final bed =
        (details['bed'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    final patientName =
        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
    final doctorName = doctor['first_name'] != null
        ? 'Dr. ${doctor['first_name']} ${doctor['last_name'] ?? ''}'.trim()
        : 'N/A';
    final wardType = bed['ward_type']?.toString() ?? 'N/A';
    final bedNumber = bed['bed_number']?.toString() ?? 'N/A';
    final los = _finalBill?['length_of_stay'] ?? 1;

    await DischargeSummaryService.printIPDDischargeSummary({
      'hospitalName': hospital['name']?.toString() ?? 'HIMS Hospital',
      'hospitalAddress': hospital['address']?.toString(),
      'hospitalPhone': hospital['phone']?.toString(),
      'patientName': patientName.isEmpty ? 'Unknown' : patientName,
      'uhid': patient['uhid']?.toString() ?? 'N/A',
      'patientAge': patient['age']?.toString(),
      'patientGender': patient['gender']?.toString(),
      'admissionDate': _formatDate(_parseDate(admission['admission_date'])),
      'dischargeDate': _dischargeDate.toDisplayDate,
      'dischargeType': _dischargeType,
      'diagnosis':
          admission['diagnosis']?.toString() ??
          admission['primary_diagnosis']?.toString() ??
          '',
      'treatmentSummary': _summaryController.text.trim(),
      'dischargeAdvice': _adviceController.text.trim(),
      'doctorName': doctorName,
      'ward': _formatWardType(wardType),
      'bedNumber': bedNumber,
      'lengthOfStay': '$los day(s)',
    });
  }

  Future<void> _printFinalBill(
    Map<String, dynamic> details, [
    Map<String, dynamic>? generatedBill,
  ]) async {
    if (_grandTotal <= 0) {
      _showMessage('Bill has no items to print yet.');
      return;
    }

    final admission = details['admission'] as Map<String, dynamic>;
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
      'admissionDate': _formatDate(_parseDate(admission['admission_date'])),
      'billNumber': generatedBill?['bill_number']?.toString() ?? 'Draft',
      'billDate':
          generatedBill?['bill_date']?.toString() ?? _dischargeDate.toDisplayDate,
      'items': _collectBillItems(),
      'totalAmount': _grandTotal,
      'paidAmount': _advanceValue,
      'balanceAmount': _finalPayable,
      'paymentStatus': _paymentStatus,
    });
  }

  Future<void> _submitDischarge(Map<String, dynamic> details) async {
    setState(() => _isDischarging = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final chargeDate = _dischargeDate.toIso8601String().split('T')[0];
      final createdBy = await db.getCurrentUsersTableId();

      // 1. Persist ward charge segments so the bill history is complete.
      final segments = ((_finalBill?['ward_segments'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      for (final segment in segments) {
        await db.insertIPDCharge({
          'admission_id': widget.admissionId,
          'charge_type': 'ward_charge',
          'charge_description':
              '${_formatWardType(segment['ward_type']?.toString() ?? 'Ward')} '
              '- ${segment['days']} day(s) × ${_inr(_toDouble(segment['daily_rate']))}',
          'amount': segment['amount'],
          'charge_date': chargeDate,
          'created_by': createdBy,
        });
      }

      // 2. Persist manually added charges.
      for (final charge in _manualCharges) {
        await db.insertIPDCharge({
          'admission_id': widget.admissionId,
          'charge_type': charge['charge_type'],
          'charge_description': charge['charge_description'],
          'amount': charge['amount'],
          'charge_date': chargeDate,
          'created_by': createdBy,
        });
      }

      // 3. Mark the admission as discharged (frees the bed too).
      await db.dischargePatient(widget.admissionId, {
        'discharge_type': _dischargeType,
        'discharge_summary': _summaryController.text.trim(),
        'discharge_instructions': _adviceController.text.trim(),
        'discharge_date': chargeDate,
        'advance_payment': _advanceValue,
      });

      // 4. Unified billing integration: generate the final bill in `billing`
      //    (source_type = ipd) with items, payment log and audit trail.
      Map<String, dynamic>? ipdBill;
      if (_grandTotal > 0) {
        ipdBill = await db.generateIPDBill(
          admissionId: widget.admissionId,
          items: _collectBillItems(),
          totalAmount: _grandTotal,
          paidAmount: _advanceValue,
          paymentStatus: _paymentStatus,
          paymentMode: _advanceValue > 0 ? 'cash' : null,
        );

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
        ref.invalidate(ipdBillsProvider(widget.admissionId));
      }

      // Refresh the ward screen's cached bed list so the freed bed shows
      // as available immediately.
      final hospitalId = ref.read(authStateProvider).hospitalId;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        ref.invalidate(hospitalBedsProvider(hospitalId));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ipdBill != null
                ? 'Patient discharged successfully! Final bill ${ipdBill['bill_number'] ?? ''} generated.'
                : 'Patient discharged successfully!',
          ),
        ),
      );

      // 5. Generate & show the clinical discharge summary PDF, followed by
      //    the final bill PDF (using the generated bill number).
      await _printDischargeSummary(details);
      if (ipdBill != null) {
        await _printFinalBill(details, ipdBill);
      }

      if (!mounted) return;
      context.go('/ipd/queue');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Discharge failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isDischarging = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

  String _formatWardType(String wardType) {
    final words = wardType.split('_').where((w) => w.isNotEmpty).toList();
    final formatted = words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    return formatted.isEmpty ? 'General' : formatted;
  }

  String _chargeTypeLabel(dynamic chargeType) {
    return _chargeTypeLabels[chargeType?.toString()] ??
        chargeType?.toString() ??
        'Charge';
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
}

/// Tiny logger shim so the screen does not depend on the app logger util.
class AppLoggerCompat {
  static void log(String message) {
    // ignore: avoid_print
    debugPrint(message);
  }
}
