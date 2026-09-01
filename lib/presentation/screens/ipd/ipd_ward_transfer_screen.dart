import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../widgets/app_page_content.dart';
import '../../widgets/smart_navigation.dart';

class IPDWardTransferScreen extends ConsumerStatefulWidget {
  final String? admissionId;
  const IPDWardTransferScreen({super.key, this.admissionId});

  @override
  ConsumerState<IPDWardTransferScreen> createState() =>
      _IPDWardTransferScreenState();
}

class _IPDWardTransferScreenState extends ConsumerState<IPDWardTransferScreen> {
  late final TextEditingController _admissionIdController =
      TextEditingController(text: widget.admissionId ?? '');
  final _reasonController = TextEditingController();

  String? _loadedAdmissionId;
  Map<String, dynamic>? _details;
  String _selectedWardType = '';
  String? _selectedBedId;
  List<Map<String, dynamic>> _availableBeds = [];
  bool _isLoading = false;
  bool _isSubmitting = false;

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
    _reasonController.dispose();
    super.dispose();
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
      _selectedBedId = null;
      _availableBeds = [];
      _selectedWardType = '';
    });

    try {
      final db = ref.read(databaseServiceProvider);
      final details = await db.getIPDChargeDetails(id);
      if (!mounted) return;
      setState(() {
        _details = details;
        _loadedAdmissionId = id;
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to load admission: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadAvailableBeds(String wardType) async {
    final db = ref.read(databaseServiceProvider);
    final hospitalId = ref.read(authStateProvider).hospitalId;
    try {
      final beds = await db.getBedsByStatus(
        'available',
        hospitalId: hospitalId,
        wardType: wardType,
      );
      if (!mounted) return;
      setState(() {
        _availableBeds = beds;
        _selectedBedId = null;
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to load beds: $e');
    }
  }

  Future<void> _submitTransfer() async {
    final admissionId = _loadedAdmissionId;
    if (admissionId == null) {
      _showMessage('Load an admission first.');
      return;
    }
    if (_selectedWardType.isEmpty || _selectedBedId == null) {
      _showMessage('Select a ward and a bed.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final db = ref.read(databaseServiceProvider);
      await db.transferPatient(
        admissionId,
        newWardType: _selectedWardType,
        newBedId: _selectedBedId!,
        reason: _reasonController.text.trim(),
      );

      ref.invalidate(ipdChargeDetailsProvider(admissionId));
      ref.invalidate(ipdTransferHistoryProvider(admissionId));
      ref.invalidate(ipdBillsProvider(admissionId));

      // Ward screen bed list bhi refresh karo — old bed ab available aur
      // new bed occupied dikhna chahiye.
      final hospitalId = ref.read(authStateProvider).hospitalId;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        ref.invalidate(hospitalBedsProvider(hospitalId));
      }

      if (!mounted) return;
      _showMessage('Patient transferred successfully!');
      _reasonController.clear();
      setState(() {
        _details = null;
        _loadedAdmissionId = null;
        _selectedBedId = null;
        _availableBeds = [];
        _selectedWardType = '';
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('Transfer failed: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SmartAppBar(title: const Text('IPD Ward Transfer')),
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
              const SizedBox(height: 16),
              _buildCurrentAdmissionCard(theme),
              const SizedBox(height: 16),
              _buildTransferFormCard(theme),
              const SizedBox(height: 16),
              _buildTransferHistoryCard(theme),
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

  Widget _buildCurrentAdmissionCard(ThemeData theme) {
    final admission =
        (_details?['admission'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final patient =
        (_details?['patient'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final doctor =
        (_details?['doctor'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final bed =
        (_details?['bed'] as Map?)?.cast<String, dynamic>() ??
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
              'Current Admission',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _infoRow(
              theme,
              Icons.person,
              'Patient',
              patientName.isEmpty ? 'Unknown' : patientName,
            ),
            _infoRow(
              theme,
              Icons.badge_outlined,
              'UHID',
              patient['uhid']?.toString() ?? 'N/A',
            ),
            _infoRow(
              theme,
              Icons.calendar_today,
              'Admission Date',
              _parseDate(admission['admission_date'])?.toDisplayDate ?? 'N/A',
            ),
            _infoRow(
              theme,
              Icons.meeting_room,
              'Current Ward',
              _formatWardType(
                admission['ward_type']?.toString() ??
                    bed['ward_type']?.toString() ??
                    'general',
              ),
            ),
            _infoRow(
              theme,
              Icons.bed,
              'Current Bed',
              bed['bed_number']?.toString() ?? 'N/A',
            ),
            _infoRow(theme, Icons.medical_services, 'Doctor', doctorName),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferFormCard(ThemeData theme) {
    final hospitalId = ref.read(authStateProvider).hospitalId!;
    final wardsAsync = ref.watch(hospitalWardsProvider(hospitalId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transfer To',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            wardsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Failed to load wards: $e')),
              data: (wards) {
                if (wards.isEmpty) {
                  return const Text('No wards configured for this hospital.');
                }
                return Column(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _selectedWardType.isEmpty
                          ? null
                          : _selectedWardType,
                      decoration: const InputDecoration(
                        labelText: 'New Ward Type',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Select ward'),
                        ),
                        for (final ward in wards)
                          DropdownMenuItem(
                            value: ward,
                            child: Text(_formatWardType(ward)),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _selectedWardType = v);
                        _loadAvailableBeds(v);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('bed_$_selectedWardType'),
                      initialValue: _selectedBedId,
                      decoration: const InputDecoration(
                        labelText: 'Available Bed',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Select bed'),
                        ),
                        for (final bed in _availableBeds)
                          DropdownMenuItem(
                            value: bed['id']?.toString(),
                            child: Text(
                              '${bed['bed_number']} '
                              '(${_formatWardType(bed['ward_type']?.toString() ?? '')})',
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _selectedBedId = v),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Transfer Reason',
                hintText:
                    'e.g. ICU se General ward mein shift - condition stable',
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Purana bed available hoga, naya bed occupied hoga aur '
                      'transfer record ward_transfers table mein save hoga.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: _isSubmitting
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton.icon(
                      onPressed: _submitTransfer,
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Transfer Patient'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferHistoryCard(ThemeData theme) {
    final admissionId = _loadedAdmissionId;
    if (admissionId == null) return const SizedBox.shrink();

    final historyAsync = ref.watch(ipdTransferHistoryProvider(admissionId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transfer History',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            historyAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('Failed to load history: $e'),
              data: (history) {
                if (history.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No transfers yet.'),
                  );
                }
                return Column(
                  children: [
                    for (final transfer in history)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.swap_horiz),
                        title: Text(
                          '${_formatWardType(transfer['old_ward_type']?.toString() ?? '?')}'
                          ' → ${_formatWardType(transfer['new_ward_type']?.toString() ?? '?')}',
                        ),
                        subtitle: Text(
                          '${_parseDate(transfer['transfer_date'])?.toDisplayDate ?? 'N/A'}'
                          '${transfer['transfer_reason']?.toString().isNotEmpty == true ? ' • ${transfer['transfer_reason']}' : ''}',
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
