import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../core/utils/display_names.dart';
import '../../../services/discharge_summary_service.dart';
import '../../widgets/smart_navigation.dart';

/// Clinical IPD discharge screen.
///
/// Billing is intentionally NOT part of this screen. Financials live in the
/// separate IPD Billing screen; this screen only shows whether a bill has
/// already been generated for the admission.
class IPDDischargeScreen extends ConsumerStatefulWidget {
  final String admissionId;
  const IPDDischargeScreen({super.key, required this.admissionId});

  @override
  ConsumerState<IPDDischargeScreen> createState() => _IPDDischargeScreenState();
}

class _IPDDischargeScreenState extends ConsumerState<IPDDischargeScreen> {
  final _summaryController = TextEditingController();
  final _adviceController = TextEditingController();

  String _dischargeType = 'Routine';
  DateTime _dischargeDate = DateTime.now();
  bool _confirmDischarge = false;
  bool _isDischarging = false;

  @override
  void dispose() {
    _summaryController.dispose();
    _adviceController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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

  int _lengthOfStay(DateTime? admissionDate) {
    if (admissionDate == null) return 1;
    final a = DateTime(
      admissionDate.year,
      admissionDate.month,
      admissionDate.day,
    );
    final b = DateTime(
      _dischargeDate.year,
      _dischargeDate.month,
      _dischargeDate.day,
    );
    final days = b.difference(a).inDays;
    return days < 1 ? 1 : days;
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
      appBar: SmartAppBar(title: const Text('IPD Discharge')),
      body: detailsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildError(context, e),
        data: (details) => _buildContent(context, details),
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
          const SizedBox(height: 12),
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
          const SizedBox(height: 12),
          _buildBillStatusCard(theme),
          const SizedBox(height: 12),
          _buildDischargeCard(theme, details),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isDischarging
                  ? null
                  : () => _printDischargeSummary(details),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Discharge Summary PDF'),
            ),
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
    final rawDoctorName = doctor['first_name'] != null
        ? '${doctor['first_name']} ${doctor['last_name'] ?? ''}'.trim()
        : (doctor['name']?.toString() ?? '');
    final doctorName = cleanDoctorDisplayName(rawDoctorName);
    final doctorDisplay = doctorName.isEmpty ? 'N/A' : 'Dr. $doctorName';
    final compact = MediaQuery.sizeOf(context).width < 600;
    final cardPadding = compact
        ? const EdgeInsets.fromLTRB(12, 10, 12, 10)
        : const EdgeInsets.all(16);
    final avatarRadius = compact ? 18.0 : 24.0;

    return Card(
      child: Padding(
        padding: cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: avatarRadius,
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
            _infoRow(theme, Icons.medical_services, 'Doctor', doctorDisplay),
            _infoRow(
              theme,
              Icons.timelapse,
              'Length of Stay (LOS)',
              '${_lengthOfStay(admissionDate)} day(s)',
            ),
          ],
        ),
      ),
    );
  }

  // -- Bill status indicator (read-only) --------------------------------------

  Widget _buildBillStatusCard(ThemeData theme) {
    final billsAsync = ref.watch(ipdBillsProvider(widget.admissionId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: billsAsync.when(
          loading: () => Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                'Checking bill status...',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          error: (e, _) => Row(
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Could not check bill status.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          data: (bills) {
            if (bills.isEmpty) {
              return Row(
                children: [
                  Icon(
                    Icons.cancel_outlined,
                    color: theme.colorScheme.error,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bill Not Generated',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.error,
                          ),
                        ),
                        Text(
                          'Generate the bill from the Billing screen.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.push(
                      '/ipd/billing?admissionId=${widget.admissionId}',
                    ),
                    child: const Text('Go to Billing'),
                  ),
                ],
              );
            }

            final latest = bills.first;
            final billNumber = latest['bill_number']?.toString() ?? 'Bill';
            final total = _toDouble(latest['total_amount']);
            return Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bill Generated',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                      Text(
                        '$billNumber • ₹${total.toStringAsFixed(0)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => context.push(
                    '/ipd/billing?admissionId=${widget.admissionId}',
                  ),
                  child: const Text('View Billing'),
                ),
              ],
            );
          },
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
            const SizedBox(height: 4),
            Text(
              'Clinical discharge only. Billing is handled separately.',
              style: theme.textTheme.bodySmall,
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
            const SizedBox(height: 8),
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

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

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
      'lengthOfStay':
          '${_lengthOfStay(_parseDate(admission['admission_date']))} day(s)',
    });
  }

  Future<void> _submitDischarge(Map<String, dynamic> details) async {
    setState(() => _isDischarging = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final dischargeDate = _dischargeDate.toIso8601String().split('T')[0];

      // Clinical discharge only — no charges, no bill generation here.
      await db.dischargePatient(widget.admissionId, {
        'discharge_type': _dischargeType,
        'discharge_summary': _summaryController.text.trim(),
        'discharge_instructions': _adviceController.text.trim(),
        'discharge_date': dischargeDate,
      });

      // Refresh the ward screen's cached bed list so the freed bed shows as
      // available immediately.
      final hospitalId = ref.read(authStateProvider).hospitalId;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        ref.invalidate(hospitalBedsProvider(hospitalId));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Patient discharged successfully!')),
      );

      await _printDischargeSummary(details);

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
