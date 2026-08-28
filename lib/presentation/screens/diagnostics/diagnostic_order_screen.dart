import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/diagnostic_receipt_service.dart';
import '../../widgets/smart_navigation.dart';

/// Diagnostic test ordering screen — the cash-receipt workflow.
///
/// * Existing OPD/IPD patient can be searched by name/UHID/mobile.
/// * Walk-in (direct) patient gets a new UHID auto-generated from name +
///   mobile — the same UHID can later be used for OPD/IPD registration.
/// * On "Cut Receipt" the order + turnover billing (billing/billing_items +
///   daily_hisab income) is saved and a printed receipt is generated.
///
/// Route: `/diagnostics/order`
class DiagnosticOrderScreen extends ConsumerStatefulWidget {
  final String? patientId;
  final String? patientName;
  final String? uhid;

  const DiagnosticOrderScreen({
    super.key,
    this.patientId,
    this.patientName,
    this.uhid,
  });

  @override
  ConsumerState<DiagnosticOrderScreen> createState() =>
      _DiagnosticOrderScreenState();
}

class _DiagnosticOrderScreenState extends ConsumerState<DiagnosticOrderScreen> {
  final _searchController = TextEditingController();
  final _walkInFirstNameController = TextEditingController();
  final _walkInLastNameController = TextEditingController();
  final _walkInMobileController = TextEditingController();
  final _paidAmountController = TextEditingController();
  Timer? _debounce;

  bool _searching = false;
  bool _resolvingPatient = false;
  bool _creatingWalkIn = false;
  bool _submitting = false;

  String _patientMode = 'existing'; // existing | walkin
  String _debouncedQuery = '';
  List<Map<String, dynamic>> _searchResults = [];

  Map<String, dynamic>? _selectedPatient;
  final List<Map<String, dynamic>> _selectedTests = [];
  String _urgency = 'routine';
  String _paymentMode = 'cash';

  static const Map<String, String> _categoryLabels = {
    'pathology': 'Pathology',
    'radiology': 'Radiology',
    'cardiology': 'Cardiology',
    'other': 'Other',
  };

  double get _totalPrice => _selectedTests.fold<double>(
    0,
    (sum, test) => sum + (double.tryParse(test['price']?.toString() ?? '') ?? 0),
  );

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    Future.delayed(Duration.zero, () {
      if (mounted && widget.patientId != null && widget.patientId!.isNotEmpty) {
        _resolvePatient(widget.patientId!);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _walkInFirstNameController.dispose();
    _walkInLastNameController.dispose();
    _walkInMobileController.dispose();
    _paidAmountController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final query = _searchController.text.trim();
      if (query != _debouncedQuery) {
        setState(() => _debouncedQuery = query);
        _searchPatients(query);
      }
    });
  }

  Future<void> _searchPatients(String query) async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    setState(() => _searching = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final results = await db.searchPatients(query, hospitalId: hospitalId);
      if (!mounted) return;
      setState(() => _searchResults = results);
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchResults = []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _resolvePatient(String patientId) async {
    setState(() {
      _resolvingPatient = true;
      _selectedPatient = null;
    });

    try {
      final db = ref.read(databaseServiceProvider);
      final patient = await db.getById('patients', patientId);
      if (!mounted) return;
      if (patient == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Patient not found')));
        return;
      }
      setState(() {
        _selectedPatient = patient;
        _searchController.text = _patientName(patient);
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to load patient')));
    } finally {
      if (mounted) setState(() => _resolvingPatient = false);
    }
  }

  String _patientName(Map<String, dynamic> patient) {
    final first = patient['first_name']?.toString() ?? '';
    final last = patient['last_name']?.toString() ?? '';
    return '$first $last'.trim();
  }

  // ---------------------------------------------------------------------------
  // Walk-in patient: generate UHID from name + mobile
  // ---------------------------------------------------------------------------

  Future<void> _createWalkInPatient() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    final name = _walkInFirstNameController.text.trim();
    final mobile = _walkInMobileController.text.trim();

    if (hospitalId == null) {
      _showMessage('Hospital not assigned to this user.');
      return;
    }
    if (name.isEmpty) {
      _showMessage('Enter patient name.');
      return;
    }
    if (mobile.isEmpty || mobile.length < 10) {
      _showMessage('Enter a valid mobile number (min 10 digits).');
      return;
    }

    setState(() => _creatingWalkIn = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final patient = await db.registerWalkInPatient(
        hospitalId: hospitalId,
        firstName: name,
        lastName: _walkInLastNameController.text.trim(),
        mobileNumber: mobile,
      );

      if (!mounted) return;
      setState(() => _selectedPatient = patient);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Walk-in patient created. UHID: ${patient['uhid']}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to create patient: $e');
    } finally {
      if (mounted) setState(() => _creatingWalkIn = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Test selection
  // ---------------------------------------------------------------------------

  Future<void> _pickTests() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null) return;

    final allTests = await ref.read(
      activeDiagnosticTestsProvider(hospitalId).future,
    );
    if (!mounted) return;

    final chosen = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (context) => _TestPickerDialog(
        allTests: allTests,
        initialSelected: _selectedTests
            .map((t) => t['test_id']?.toString())
            .whereType<String>()
            .toSet(),
      ),
    );

    if (chosen != null && mounted) {
      setState(() {
        _selectedTests
          ..clear()
          ..addAll(chosen);
        _paidAmountController.text = _totalPrice.toStringAsFixed(2);
      });
    }
  }

  void _removeTest(int index) {
    setState(() {
      _selectedTests.removeAt(index);
      _paidAmountController.text = _totalPrice.toStringAsFixed(2);
    });
  }

  // ---------------------------------------------------------------------------
  // Submit + receipt
  // ---------------------------------------------------------------------------

  Future<void> _submitOrder() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    final patient = _selectedPatient;

    if (hospitalId == null) {
      _showMessage('Hospital not assigned to this user.');
      return;
    }
    if (patient == null) {
      _showMessage('Please select or create a patient.');
      return;
    }
    if (_selectedTests.isEmpty) {
      _showMessage('Please select at least one test.');
      return;
    }

    final paidAmount = double.tryParse(_paidAmountController.text.trim()) ?? 0;
    if (paidAmount < 0) {
      _showMessage('Enter a valid paid amount.');
      return;
    }

    setState(() => _submitting = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final currentUser = await db.getCurrentUserRecord();
      final doctorId = currentUser?['id']?.toString() ?? '';
      final doctorName = _doctorDisplayName(currentUser);

      final result = await db.createDiagnosticOrderWithBilling(
        hospitalId: hospitalId,
        patientId: patient['id'].toString(),
        doctorId: doctorId,
        urgency: _urgency,
        items: _selectedTests,
        paidAmount: paidAmount,
        paymentMode: _paymentMode,
      );

      // Hospital info for the printed receipt.
      final hospital = await db.getById('hospitals', hospitalId);
      final hospitalName = hospital?['name']?.toString() ?? 'Hospital';
      final hospitalAddress = [
        hospital?['address']?.toString() ?? '',
        hospital?['city']?.toString() ?? '',
      ].where((s) => s.isNotEmpty).join(', ');

      await DiagnosticReceiptService.printDiagnosticReceipt(
        hospitalName: hospitalName,
        hospitalAddress: hospitalAddress,
        receiptNumber: result['receipt_number']?.toString() ??
            'DIAG-${DateTime.now().millisecondsSinceEpoch}',
        date: DateTime.now(),
        patientName: _patientName(patient),
        uhid: patient['uhid']?.toString() ?? '-',
        mobileNumber: patient['mobile_number']?.toString() ?? '-',
        doctorName: doctorName,
        urgency: _urgency,
        tests: _selectedTests,
        totalAmount: _totalPrice,
        paidAmount: paidAmount,
        balanceAmount: _totalPrice - paidAmount,
        paymentMode: _paymentMode,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Receipt cut & order placed successfully')),
      );
      context.go('/diagnostics/results');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to place order: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _doctorDisplayName(Map<String, dynamic>? user) {
    if (user == null) return 'Self';
    final first = user['first_name']?.toString() ?? '';
    final last = user['last_name']?.toString() ?? '';
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    return user['name']?.toString() ?? 'Self';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Diagnostic Test Receipt'),
        actions: [
          AppRefreshButton(
            onRefresh: () {
              final hospitalId = ref.read(authStateProvider).hospitalId;
              if (hospitalId != null && hospitalId.isNotEmpty) {
                ref.invalidate(activeDiagnosticTestsProvider(hospitalId));
              }
              setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPatientSection(),
          const SizedBox(height: 20),
          _buildTestsSection(),
          const SizedBox(height: 20),
          _buildOrderDetails(),
          const SizedBox(height: 20),
          _buildPaymentSection(),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _submitting ? null : _submitOrder,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.receipt_long_outlined),
            label: Text(
              _submitting ? 'Cutting Receipt...' : 'Cut Receipt & Print',
              style: const TextStyle(fontSize: 16),
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Patient section
  // ---------------------------------------------------------------------------
  Widget _buildPatientSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Patient',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'existing',
              label: Text('Existing / OPD-IPD'),
              icon: Icon(Icons.person_search_outlined),
            ),
            ButtonSegment(
              value: 'walkin',
              label: Text('Walk-in (New UHID)'),
              icon: Icon(Icons.person_add_alt_outlined),
            ),
          ],
          selected: {_patientMode},
          onSelectionChanged: (selection) =>
              setState(() => _patientMode = selection.first),
        ),
        const SizedBox(height: 12),
        if (_selectedPatient != null)
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(
                _patientName(_selectedPatient!),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'UHID: ${_selectedPatient!['uhid'] ?? '-'} • '
                '${_selectedPatient!['mobile_number'] ?? 'No mobile'}',
              ),
              trailing: TextButton(
                onPressed: () {
                  setState(() {
                    _selectedPatient = null;
                    _searchController.clear();
                    _searchResults = [];
                    _paidAmountController.clear();
                  });
                },
                child: const Text('Change'),
              ),
            ),
          )
        else if (_patientMode == 'existing')
          _buildExistingPatientSearch()
        else
          _buildWalkInPatientForm(),
      ],
    );
  }

  Widget _buildExistingPatientSearch() {
    return Column(
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search patient by name / UHID / mobile',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_resolvingPatient)
          const Padding(
            padding: EdgeInsets.all(12),
            child: CircularProgressIndicator(),
          ),
        if (_debouncedQuery.isNotEmpty &&
            _searchResults.isEmpty &&
            !_searching)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No patients found. Use Walk-in mode to create one.'),
          ),
        if (_searchResults.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 8),
            child: Column(
              children: [
                for (final patient in _searchResults)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(_patientName(patient)),
                    subtitle: Text(
                      'UHID: ${patient['uhid'] ?? '-'} • '
                      '${patient['mobile_number'] ?? ''}',
                    ),
                    onTap: () {
                      setState(() {
                        _selectedPatient = patient;
                        _searchController.text = _patientName(patient);
                        _searchResults = [];
                      });
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildWalkInPatientForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Direct patient — UHID will be auto-generated. The same UHID / '
              'mobile number can later be used for OPD & IPD registration.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _walkInFirstNameController,
              decoration: const InputDecoration(
                labelText: 'Patient Name *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _walkInLastNameController,
              decoration: const InputDecoration(
                labelText: 'Last Name (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _walkInMobileController,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              decoration: const InputDecoration(
                labelText: 'Mobile Number *',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _creatingWalkIn ? null : _createWalkInPatient,
                icon: _creatingWalkIn
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.badge_outlined),
                label: const Text('Generate UHID & Use Patient'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tests section
  // ---------------------------------------------------------------------------
  Widget _buildTestsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Tests',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _pickTests,
              icon: const Icon(Icons.add),
              label: const Text('Add Tests'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_selectedTests.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text('No tests selected. Tap "Add Tests" to choose.'),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < _selectedTests.length; i++)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: _categoryColor(
                        _selectedTests[i]['category']?.toString() ?? 'other',
                      ).withValues(alpha: 0.15),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    title: Text(
                      _selectedTests[i]['test_name']?.toString() ?? '-',
                    ),
                    subtitle: Text(
                      '${_categoryLabels[_selectedTests[i]['category']] ?? 'Other'} • '
                      '₹ ${(double.tryParse(_selectedTests[i]['price']?.toString() ?? '') ?? 0).toStringAsFixed(2)}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _removeTest(i),
                    ),
                  ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '₹ ${_totalPrice.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Order details
  // ---------------------------------------------------------------------------
  Widget _buildOrderDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Order Details',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _urgency,
          decoration: const InputDecoration(
            labelText: 'Order Type',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'routine', child: Text('Routine')),
            DropdownMenuItem(value: 'urgent', child: Text('Urgent')),
            DropdownMenuItem(value: 'stat', child: Text('STAT')),
          ],
          onChanged: (value) => setState(() => _urgency = value ?? 'routine'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          readOnly: true,
          initialValue: DateTime.now().toDisplayDate,
          decoration: const InputDecoration(
            labelText: 'Order Date',
            prefixIcon: Icon(Icons.calendar_today_outlined),
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Payment section
  // ---------------------------------------------------------------------------
  Widget _buildPaymentSection() {
    final balance = _totalPrice -
        (double.tryParse(_paidAmountController.text.trim()) ?? 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Payment',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _paymentMode,
          decoration: const InputDecoration(
            labelText: 'Payment Mode',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'cash', child: Text('Cash')),
            DropdownMenuItem(value: 'card', child: Text('Card')),
            DropdownMenuItem(value: 'upi', child: Text('UPI')),
            DropdownMenuItem(value: 'online', child: Text('Online')),
            DropdownMenuItem(value: 'credit', child: Text('Credit')),
          ],
          onChanged: (value) => setState(() => _paymentMode = value ?? 'cash'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _paidAmountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Paid Amount (₹)',
            prefixText: '₹ ',
            border: const OutlineInputBorder(),
            helperText:
                balance >= 0 ? 'Balance: ₹ ${balance.toStringAsFixed(2)}' : '',
            suffixIcon: IconButton(
              tooltip: 'Full amount',
              onPressed: () => setState(() {
                _paidAmountController.text = _totalPrice.toStringAsFixed(2);
              }),
              icon: const Icon(Icons.all_inclusive),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Color _categoryColor(String category) {
    switch (category) {
      case 'pathology':
        return Colors.purple;
      case 'radiology':
        return Colors.blue;
      case 'cardiology':
        return Colors.red;
      default:
        return Colors.teal;
    }
  }
}

// -----------------------------------------------------------------------------
// Test picker dialog (category dropdown + multi-select list)
// -----------------------------------------------------------------------------
class _TestPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> allTests;
  final Set<String> initialSelected;

  const _TestPickerDialog({
    required this.allTests,
    required this.initialSelected,
  });

  @override
  State<_TestPickerDialog> createState() => _TestPickerDialogState();
}

class _TestPickerDialogState extends State<_TestPickerDialog> {
  String _category = 'all';
  String _query = '';
  late final Set<String> _selected = {...widget.initialSelected};

  @override
  Widget build(BuildContext context) {
    final filtered = widget.allTests.where((test) {
      final matchesCategory =
          _category == 'all' || test['category'] == _category;
      final matchesQuery =
          _query.isEmpty ||
          (test['test_name']?.toString().toLowerCase().contains(_query.toLowerCase()) ??
              false) ||
          (test['test_code']?.toString().toLowerCase().contains(_query.toLowerCase()) ??
              false);
      return matchesCategory && matchesQuery;
    }).toList();

    return AlertDialog(
      title: const Text('Select Tests'),
      content: SizedBox(
        width: 520,
        height: 500,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search test name or code',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All Categories')),
                DropdownMenuItem(value: 'pathology', child: Text('Pathology')),
                DropdownMenuItem(value: 'radiology', child: Text('Radiology')),
                DropdownMenuItem(value: 'cardiology', child: Text('Cardiology')),
                DropdownMenuItem(value: 'other', child: Text('Other Diagnostics')),
              ],
              onChanged: (value) => setState(() => _category = value ?? 'all'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No tests found.'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final test = filtered[index];
                        final id = test['id']?.toString() ?? '';
                        final isChecked = _selected.contains(id);
                        final price = double.tryParse(
                              test['price']?.toString() ?? '',
                            ) ??
                            0;
                        return CheckboxListTile(
                          value: isChecked,
                          onChanged: (checked) {
                            setState(() {
                              if (checked == true) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            });
                          },
                          title: Text(test['test_name']?.toString() ?? '-'),
                          subtitle: Text(
                            '${test['test_code'] ?? '-'} • ₹ ${price.toStringAsFixed(2)}',
                          ),
                          secondary: Icon(
                            _categoryIcon(test['category']?.toString()),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final chosen = widget.allTests
                .where((test) => _selected.contains(test['id']?.toString()))
                .map(
                  (test) => {
                    'test_id': test['id'],
                    'test_name': test['test_name'],
                    'category': test['category'],
                    'price': double.tryParse(test['price']?.toString() ?? '') ?? 0,
                  },
                )
                .toList();
            Navigator.pop(context, chosen);
          },
          child: Text('Add Selected (${_selected.length})'),
        ),
      ],
    );
  }

  IconData _categoryIcon(String? category) {
    switch (category) {
      case 'pathology':
        return Icons.biotech_outlined;
      case 'radiology':
        return Icons.image_search_outlined;
      case 'cardiology':
        return Icons.monitor_heart_outlined;
      default:
        return Icons.science_outlined;
    }
  }
}
