import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/abdm_service.dart';
import '../../widgets/smart_navigation.dart';

/// ABHA module hub covering M1 (verify/search/address/card/QR), M2 (care
/// context + consent as HIP) and M3 (consent request + record fetch as HIU).
class ABHAVerifyScreen extends ConsumerStatefulWidget {
  const ABHAVerifyScreen({super.key, this.initialTab = 0, this.patientId});

  final int initialTab;
  final String? patientId;

  @override
  ConsumerState<ABHAVerifyScreen> createState() => _ABHAVerifyScreenState();
}

enum _SearchMode { abhaId, mobile, abhaAddress }

class _ABHAVerifyScreenState extends ConsumerState<ABHAVerifyScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _abhaIdController = TextEditingController();
  final _mobileController = TextEditingController();
  final _abhaAddressController = TextEditingController();
  final _otpController = TextEditingController();

  final _patientIdController = TextEditingController();
  final _recordIdController = TextEditingController();
  final _purposeController = TextEditingController(text: 'Treatment / Care Management');

  _SearchMode _searchMode = _SearchMode.abhaId;
  String _recordType = 'opd_visit';
  DateTime? _fromDate;
  DateTime? _toDate;

  bool _isBusy = false;
  Map<String, dynamic>? _verifyResult;
  String? _scanResult;

  String? get _patientId {
    final value = _patientIdController.text.trim();
    return value.isEmpty ? null : value;
  }

  AbdmService get _abdm => ref.read(abdmServiceProvider);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 3).toInt(),
    );
    if (widget.patientId != null) {
      _patientIdController.text = widget.patientId!;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _abhaIdController.dispose();
    _mobileController.dispose();
    _abhaAddressController.dispose();
    _otpController.dispose();
    _patientIdController.dispose();
    _recordIdController.dispose();
    _purposeController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _verify() async {
    setState(() {
      _isBusy = true;
      _verifyResult = null;
    });

    try {
      Map<String, dynamic> result;
      switch (_searchMode) {
        case _SearchMode.abhaId:
          result = await _abdm.verifyAbhaId(
            _abhaIdController.text,
            otp: _otpController.text,
          );
          break;
        case _SearchMode.mobile:
          result = await _abdm.searchAbhaByMobile(_mobileController.text);
          break;
        case _SearchMode.abhaAddress:
          result = await _abdm.verifyAbhaAddress(_abhaAddressController.text);
          break;
      }

      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _verifyResult = result;
      });
      _showSnack('ABHA verified successfully');
    } catch (e) {
      _handleError(e, 'Verification failed');
    }
  }

  Future<void> _downloadCard() async {
    final address = _verifyResult?['abhaAddress'] as String?;
    if (address == null || address.isEmpty) {
      _showSnack('Verify an ABHA address first', isError: true);
      return;
    }
    try {
      final bytes = await _abdm.downloadAbhaCardPng(address);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('ABHA Card'),
          content: SizedBox(
            width: 320,
            height: 320,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      _handleError(e, 'Card download failed');
    }
  }

  Future<void> _showQrCode() async {
    final address = _verifyResult?['abhaAddress'] as String?;
    if (address == null || address.isEmpty) {
      _showSnack('Verify an ABHA address first', isError: true);
      return;
    }
    try {
      final bytes = await _abdm.getAbhaQrCode(address);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('ABHA QR Code'),
          content: SizedBox(
            width: 280,
            height: 280,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      _handleError(e, 'Could not fetch QR code');
    }
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const _QrScannerScreen(),
        fullscreenDialog: true,
      ),
    );
    if (raw == null || !mounted) return;

    try {
      final parsed = await _abdm.processScanAndShare(raw, patientId: _patientId);
      if (!mounted) return;
      setState(() => _scanResult = raw);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Scan-and-Share'),
          content: Text(
            'ABHA Address: ${parsed['abhaAddress']}\n'
            'Request ID: ${parsed['requestId']}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      _handleError(e, 'Could not process QR');
    }
  }

  Future<void> _linkCareContext() async {
    final patientId = _patientId;
    final abhaId = _abhaIdController.text.trim();
    final recordId = _recordIdController.text.trim();

    if (patientId == null) {
      _showSnack('Enter a Patient ID', isError: true);
      return;
    }
    if (abhaId.isEmpty) {
      _showSnack('Enter the patient ABHA ID', isError: true);
      return;
    }
    if (recordId.isEmpty) {
      _showSnack('Enter a record ID (visit/prescription/lab id)', isError: true);
      return;
    }

    setState(() => _isBusy = true);
    try {
      final careContextId = _abdm.buildCareContextId(
        recordType: _recordType,
        recordId: recordId,
      );
      await _abdm.linkCareContext(
        abhaId: abhaId,
        careContextId: careContextId,
        patientId: patientId,
        recordType: _recordType,
        recordId: recordId,
        display: '$_recordType $recordId',
      );
      if (!mounted) return;
      ref.invalidate(patientCareContextsProvider(patientId));
      setState(() => _isBusy = false);
      _showSnack('Care context linked: $careContextId');
    } catch (e) {
      _handleError(e, 'Care context linking failed');
    }
  }

  Future<void> _requestConsent() async {
    final patientId = _patientId;
    final abhaId = _abhaIdController.text.trim();
    if (patientId == null || abhaId.isEmpty) {
      _showSnack('Patient ID and ABHA ID are required', isError: true);
      return;
    }
    final from = _fromDate ?? DateTime.now().subtract(const Duration(days: 365));
    final to = _toDate ?? DateTime.now().add(const Duration(days: 30));

    setState(() => _isBusy = true);
    try {
      final result = await _abdm.requestConsent(
        patientId: patientId,
        abhaId: abhaId,
        purpose: _purposeController.text.trim(),
        dataFrom: from,
        dataTo: to,
        abhaAddress: _verifyResult?['abhaAddress'] as String?,
      );
      if (!mounted) return;
      ref.invalidate(patientConsentsProvider(patientId));
      setState(() => _isBusy = false);
      _showSnack('Consent requested: ${result['consent_id'] ?? 'see list below'}');
    } catch (e) {
      _handleError(e, 'Consent request failed');
    }
  }

  Future<void> _fetchRecordsForConsent(Map<String, dynamic> consent) async {
    final patientId = _patientId;
    if (patientId == null) {
      _showSnack('Enter a Patient ID', isError: true);
      return;
    }
    final consentId = consent['consent_id'] as String?;
    if (consentId == null) {
      _showSnack('Consent id missing', isError: true);
      return;
    }
    setState(() => _isBusy = true);
    try {
      final result = await _abdm.fetchHealthRecords(
        patientId: patientId,
        consentId: consentId,
        abhaId: consent['abha_id'] as String?,
      );
      if (!mounted) return;
      ref.invalidate(patientFhirRecordsProvider(patientId));
      setState(() => _isBusy = false);
      _showSnack('Records fetched: ${result['status'] ?? 'success'}');
    } catch (e) {
      _handleError(e, 'Record fetch failed');
    }
  }

  void _handleError(Object e, String fallback) {
    if (!mounted) return;
    setState(() => _isBusy = false);
    final message = e is AbdmException ? e.message : '$fallback: $e';
    _showSnack(message, isError: true);
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('ABHA / ABDM'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Verify ABHA'),
            Tab(text: 'Care Contexts'),
            Tab(text: 'Consent'),
            Tab(text: 'Records'),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/abha/create'),
            icon: const Icon(Icons.add),
            label: const Text('Create ABHA'),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildVerifyTab(),
          _buildCareContextTab(),
          _buildConsentTab(),
          _buildRecordsTab(),
        ],
      ),
    );
  }

  Widget _buildVerifyTab() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'ABHA (Ayushman Bharat Health Account) is India\'s digital '
                      'health ID for accessing and sharing health records securely.',
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<_SearchMode>(
            segments: const [
              ButtonSegment(
                value: _SearchMode.abhaId,
                label: Text('ABHA ID'),
                icon: Icon(Icons.credit_card),
              ),
              ButtonSegment(
                value: _SearchMode.mobile,
                label: Text('Mobile'),
                icon: Icon(Icons.phone),
              ),
              ButtonSegment(
                value: _SearchMode.abhaAddress,
                label: Text('ABHA Address'),
                icon: Icon(Icons.alternate_email),
              ),
            ],
            selected: {_searchMode},
            onSelectionChanged: (v) => setState(() {
              _searchMode = v.first;
              _verifyResult = null;
            }),
          ),
          const SizedBox(height: 16),
          if (_searchMode == _SearchMode.abhaId) ...[
            TextField(
              controller: _abhaIdController,
              decoration: const InputDecoration(
                labelText: 'ABHA Health ID',
                hintText: 'e.g. 91-1234-5678-9012',
                prefixIcon: Icon(Icons.credit_card),
                              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'OTP (optional)',
                hintText: 'OTP if ABHA app asked for verification',
                counterText: '',
                prefixIcon: Icon(Icons.security),
                              ),
            ),
          ] else if (_searchMode == _SearchMode.mobile) ...[
            TextField(
              controller: _mobileController,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              decoration: const InputDecoration(
                labelText: 'Mobile Number',
                hintText: '10-digit mobile linked to ABHA',
                counterText: '',
                prefixText: '+91 ',
                              ),
            ),
          ] else ...[
            TextField(
              controller: _abhaAddressController,
              decoration: const InputDecoration(
                labelText: 'ABHA Address',
                hintText: 'e.g. rahul9012@abdm',
                prefixIcon: Icon(Icons.alternate_email),
                              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _verify,
              icon: _isBusy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user),
              label: Text(_isBusy ? 'Verifying...' : 'Verify / Search'),
            ),
          ),
          if (_verifyResult != null) ...[
            const SizedBox(height: 16),
            _buildVerifyResultCard(),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _downloadCard,
                  icon: const Icon(Icons.download),
                  label: const Text('ABHA Card'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _showQrCode,
                  icon: const Icon(Icons.qr_code),
                  label: const Text('ABHA QR'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scanQr,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
              ),
            ],
          ),
          if (_scanResult != null) ...[
            const SizedBox(height: 8),
            Text(
              'Last scan: $_scanResult',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVerifyResultCard() {
    final result = _verifyResult!;
    final theme = Theme.of(context);
    final healthId = result['healthId'] ?? result['healthIdNumber'] ?? '-';
    final address = result['abhaAddress'] ?? '-';
    final name = result['name'] ?? '-';
    final gender = result['gender'] ?? '-';

    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text(
                  'ABHA Verified!',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                ),
              ],
            ),
            const Divider(),
            _resultRow('Name', name),
            _resultRow('ABHA ID', healthId),
            _resultRow('ABHA Address', address),
            _resultRow('Gender', gender),
            if (result['dateOfBirth'] != null)
              _resultRow('DOB', result['dateOfBirth'].toString()),
            if (result['mobileNumber'] != null)
              _resultRow('Mobile', result['mobileNumber'].toString()),
            if (result['isMock'] == true)
              Text(
                'Mock sandbox profile',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label)),
          const Text(': '),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _buildCareContextTab() {
    final patientId = _patientId;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _patientIdController,
            decoration: const InputDecoration(
              labelText: 'Patient ID',
              hintText: 'MediFlux patient UUID',
              prefixIcon: Icon(Icons.person_search),
                          ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _abhaIdController,
            decoration: const InputDecoration(
              labelText: 'Patient ABHA ID',
              hintText: 'e.g. 91-1234-5678-9012',
              prefixIcon: Icon(Icons.fingerprint),
                          ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _recordType,
            decoration: const InputDecoration(
              labelText: 'Record Type',
                          ),
            items: const [
              DropdownMenuItem(value: 'opd_visit', child: Text('OPD Visit')),
              DropdownMenuItem(value: 'ipd_admission', child: Text('IPD Admission')),
              DropdownMenuItem(value: 'prescription', child: Text('Prescription')),
              DropdownMenuItem(value: 'lab_report', child: Text('Lab Report')),
              DropdownMenuItem(
                value: 'discharge_summary',
                child: Text('Discharge Summary'),
              ),
              DropdownMenuItem(
                value: 'diagnostic_report',
                child: Text('Diagnostic Report'),
              ),
            ],
            onChanged: (v) => setState(() => _recordType = v!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _recordIdController,
            decoration: const InputDecoration(
              labelText: 'Record ID',
              hintText: 'OPD/IPD/lab/prescription record id',
              prefixIcon: Icon(Icons.link),
                          ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _linkCareContext,
              icon: _isBusy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(_isBusy ? 'Linking...' : 'Link Care Context'),
            ),
          ),
          const SizedBox(height: 24),
          if (patientId != null) _buildCareContextList(patientId),
        ],
      ),
    );
  }

  Widget _buildCareContextList(String patientId) {
    final async = ref.watch(patientCareContextsProvider(patientId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Linked Care Contexts',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        async.when(
          data: (rows) => rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No care contexts linked yet.'),
                )
              : Column(
                  children: [
                    for (final row in rows)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            row['is_linked'] == true
                                ? Icons.check_circle
                                : Icons.pending,
                            color: row['is_linked'] == true
                                ? Colors.green
                                : Colors.orange,
                          ),
                          title: Text(row['care_context_id']?.toString() ?? '-'),
                          subtitle: Text(
                            '${row['record_type'] ?? ''} · ${row['record_id'] ?? ''}',
                          ),
                        ),
                      ),
                  ],
                ),
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load care contexts: $e'),
          ),
        ),
      ],
    );
  }

  Widget _buildConsentTab() {
    final patientId = _patientId;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _patientIdController,
            decoration: const InputDecoration(
              labelText: 'Patient ID',
              prefixIcon: Icon(Icons.person_search),
                          ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _abhaIdController,
            decoration: const InputDecoration(
              labelText: 'Patient ABHA ID',
              prefixIcon: Icon(Icons.fingerprint),
                          ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _purposeController,
            decoration: const InputDecoration(
              labelText: 'Purpose',
              prefixIcon: Icon(Icons.assignment),
                          ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Data From',
                  value: _fromDate,
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now().subtract(
                        const Duration(days: 365),
                      ),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _fromDate = picked);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateField(
                  label: 'Data To',
                  value: _toDate,
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _toDate = picked);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _requestConsent,
              icon: _isBusy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check),
              label: Text(_isBusy ? 'Requesting...' : 'Request Consent'),
            ),
          ),
          const SizedBox(height: 24),
          if (patientId != null) _buildConsentList(patientId),
        ],
      ),
    );
  }

  Widget _buildConsentList(String patientId) {
    final async = ref.watch(patientConsentsProvider(patientId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Consent Artefacts',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        async.when(
          data: (rows) => rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No consent requests yet.'),
                )
              : Column(
                  children: [
                    for (final row in rows)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: _ConsentStatusIcon(status: row['status']?.toString()),
                          title: Text(row['purpose']?.toString() ?? '-'),
                          subtitle: Text(
                            '${row['consent_id']} · ${row['status'] ?? ''}\n'
                            'Expires: ${row['expires_at'] ?? '-'}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Fetch records',
                            icon: const Icon(Icons.cloud_download),
                            onPressed: () => _fetchRecordsForConsent(row),
                          ),
                        ),
                      ),
                  ],
                ),
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load consents: $e'),
          ),
        ),
      ],
    );
  }

  Widget _buildRecordsTab() {
    final patientId = _patientId;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _patientIdController,
            decoration: const InputDecoration(
              labelText: 'Patient ID',
              prefixIcon: Icon(Icons.person_search),
                          ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (patientId == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Enter a Patient ID to load ABDM records and audit logs.'),
            )
          else ...[
            Text(
              'FHIR Records',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildFhirList(patientId),
            const SizedBox(height: 24),
            Text(
              'Data Flow Logs',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildDataFlowList(patientId),
          ],
        ],
      ),
    );
  }

  Widget _buildFhirList(String patientId) {
    final async = ref.watch(patientFhirRecordsProvider(patientId));
    return async.when(
      data: (rows) => rows.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No FHIR records stored yet.'),
            )
          : Column(
              children: [
                for (final row in rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ExpansionTile(
                      leading: const Icon(Icons.description),
                      title: Text(
                        '${row['record_type'] ?? 'record'} · ${row['record_id'] ?? ''}',
                      ),
                      subtitle: Text(
                        'ABHA: ${row['abha_id'] ?? '-'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      childrenPadding: const EdgeInsets.all(12),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          const JsonEncoder.withIndent('  ').convert(
                            row['fhir_bundle'] ?? const {},
                          ),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Could not load FHIR records: $e'),
      ),
    );
  }

  Widget _buildDataFlowList(String patientId) {
    final async = ref.watch(patientDataFlowLogsProvider(patientId));
    return async.when(
      data: (rows) => rows.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No data-flow logs yet.'),
            )
          : Column(
              children: [
                for (final row in rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                        row['status'] == 'success'
                            ? Icons.check_circle
                            : Icons.error,
                        color: row['status'] == 'success'
                            ? Colors.green
                            : Colors.red,
                      ),
                      title: Text(row['transaction_id']?.toString() ?? '-'),
                      subtitle: Text(
                        '${row['status'] ?? ''} · ${row['created_at'] ?? ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Could not load data-flow logs: $e'),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap});

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
                    suffixIcon: const Icon(Icons.calendar_today),
        ),
        child: Text(value?.toDateString ?? 'Select date'),
      ),
    );
  }
}

class _ConsentStatusIcon extends StatelessWidget {
  const _ConsentStatusIcon({required this.status});

  final String? status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status?.toLowerCase()) {
      'granted' => (Icons.check_circle, Colors.green),
      'denied' || 'revoked' || 'expired' => (Icons.cancel, Colors.red),
      _ => (Icons.schedule, Colors.orange),
    };
    return Icon(icon, color: color);
  }
}

/// Full-screen QR scanner used by scan-and-share.
class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(title: const Text('Scan ABHA / Scan-and-Share QR')),
      body: MobileScanner(
        onDetect: (BarcodeCapture capture) {
          final barcodes = capture.barcodes;
          if (barcodes.isEmpty) return;
          final raw = barcodes.first.rawValue;
          if (raw == null || raw.isEmpty) return;
          Navigator.of(context).pop(raw);
        },
      ),
    );
  }
}
