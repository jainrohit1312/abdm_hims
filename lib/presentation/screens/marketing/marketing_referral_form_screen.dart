import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/constants/marketing_constants.dart';
import '../../../models/employee_model.dart';
import '../../../models/marketing_models.dart';
import '../../../repositories/marketing_area_repository.dart';
import '../../widgets/app_ui.dart';

/// ---------------------------------------------------------------------------
/// HIMS Referral entry (`/marketing/referrals/new`).
///
/// Selects an existing patient (never duplicates the patient master), a
/// referral doctor, referral date, optional OPD/IPD link, marketing employee
/// and notes. Writes into `patient_referrals` — the event-based history table.
/// The patient master is NOT modified with a permanent referral-doctor field.
/// ---------------------------------------------------------------------------
class MarketingReferralFormScreen extends ConsumerStatefulWidget {
  const MarketingReferralFormScreen({super.key});

  @override
  ConsumerState<MarketingReferralFormScreen> createState() =>
      _MarketingReferralFormScreenState();
}

class _MarketingReferralFormScreenState
    extends ConsumerState<MarketingReferralFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  String? _doctorId;
  String? _employeeId;
  late DateTime _referralDate;
  Map<String, dynamic>? _selectedPatient;
  String? _opdRegistrationId;
  String? _ipdAdmissionId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _referralDate = DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final doctorsAsync = hospitalId == null
        ? null
        : ref.watch(referralDoctorsProvider(hospitalId));
    final employeesAsync = hospitalId == null
        ? null
        : ref.watch(employeesProvider(hospitalId));

    final doctors = doctorsAsync?.valueOrNull ?? const <ReferralDoctor>[];
    final employees = employeesAsync?.valueOrNull ?? const <Employee>[];

    return AppPage(
      title: 'Add Patient Referral',
      isRootPage: false,
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppInfoBanner(
                message:
                    'Referral attribution is event based. The patient master '
                    'is never changed — this saves a referral history record.',
                icon: Icons.people_outline,
              ),
              AppGap.md,
              _buildPatientPicker(context, hospitalId),
              AppGap.sm,
              DropdownButtonFormField<String?>(
                initialValue: _doctorId,
                decoration: const InputDecoration(
                  labelText: 'Referral Doctor *',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Select Referral Doctor'),
                  ),
                  for (final doctor in doctors)
                    DropdownMenuItem<String?>(
                      value: doctor.id,
                      child: Text(
                        '${doctor.name}'
                        '${doctor.clinicName == null ? '' : ' — ${doctor.clinicName}'}',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _doctorId = value),
                validator: (value) =>
                    value == null ? 'Select a referral doctor' : null,
              ),
              AppGap.sm,
              AppFieldRow(
                children: [
                  _DateField(
                    label: 'Referral Date *',
                    value: DateFormat('dd MMM yyyy').format(_referralDate),
                    onTap: _pickDate,
                  ),
                  DropdownButtonFormField<String?>(
                    initialValue: _employeeId,
                    decoration: const InputDecoration(
                      labelText: 'Marketing Employee',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Select Employee'),
                      ),
                      for (final employee in employees)
                        DropdownMenuItem<String?>(
                          value: employee.id,
                          child: Text(
                            '${employee.fullName} (${employee.employeeCode})',
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _employeeId = value),
                  ),
                ],
              ),
              if (_selectedPatient != null) ...[
                AppGap.sm,
                AppFieldRow(
                  children: [
                    _buildVisitLinkDropdown(
                      label: 'OPD Registration (optional)',
                      value: _opdRegistrationId,
                      rows: _opdVisits,
                      onChanged: (value) =>
                          setState(() => _opdRegistrationId = value),
                    ),
                    _buildVisitLinkDropdown(
                      label: 'IPD Admission (optional)',
                      value: _ipdAdmissionId,
                      rows: _ipdAdmissions,
                      onChanged: (value) =>
                          setState(() => _ipdAdmissionId = value),
                    ),
                  ],
                ),
              ],
              AppGap.sm,
              TextFormField(
                controller: _notesController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              AppGap.md,
              AppSubmitButton(
                label: 'Save Referral',
                loading: _saving,
                onPressed: _submit,
                icon: Icons.save_outlined,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> get _opdVisits {
    final visits = _selectedPatient?['opd_visits'];
    if (visits is List) return visits.cast<Map<String, dynamic>>();
    return const [];
  }

  List<Map<String, dynamic>> get _ipdAdmissions {
    final visits = _selectedPatient?['ipd_admissions'];
    if (visits is List) return visits.cast<Map<String, dynamic>>();
    return const [];
  }

  Widget _buildPatientPicker(BuildContext context, String? hospitalId) {
    final theme = Theme.of(context);

    if (hospitalId == null) {
      return const Text('Hospital not assigned to this user.');
    }

    final searchAsync = ref.watch(
      marketingPatientSearchProvider(
        MarketingPatientSearchParams(
          query: _searchController.text.trim(),
          hospitalId: hospitalId,
        ),
      ),
    );

    final results = searchAsync.valueOrNull ?? const <Map<String, dynamic>>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            labelText: 'Search Existing Patient (UHID / Name / Mobile) *',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {
            _selectedPatient = null;
            _opdRegistrationId = null;
            _ipdAdmissionId = null;
          }),
        ),
        if (searchAsync.isLoading)
          const Padding(
            padding: EdgeInsets.all(8),
            child: LinearProgressIndicator(),
          )
        else if (results.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 8),
            child: Column(
              children: [
                for (final patient in results.take(5))
                  ListTile(
                    dense: true,
                    title: Text(
                      _patientLabel(patient),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('UHID: ${patient['uhid'] ?? '—'}'),
                    trailing: _selectedPatient?['id'] == patient['id']
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null,
                    onTap: () => setState(() {
                      _selectedPatient = patient;
                      _opdRegistrationId = null;
                      _ipdAdmissionId = null;
                    }),
                  ),
              ],
            ),
          ),
        if (_selectedPatient != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Selected: ${_patientLabel(_selectedPatient!)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  String _patientLabel(Map<String, dynamic> patient) {
    final first = patient['first_name']?.toString() ?? '';
    final last = patient['last_name']?.toString() ?? '';
    final name = '$first $last'.trim();
    if (name.isEmpty) return patient['uhid']?.toString() ?? 'Patient';
    return name;
  }

  Widget _buildVisitLinkDropdown({
    required String label,
    required String? value,
    required List<Map<String, dynamic>> rows,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('None')),
        for (final row in rows)
          DropdownMenuItem<String?>(
            value: row['id']?.toString(),
            child: Text(_visitLabel(row)),
          ),
      ],
      onChanged: onChanged,
    );
  }

  String _visitLabel(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    final date = row['visit_date'] ?? row['admission_date'];
    final dateText = date == null ? '' : ' • $date';
    final status = row['status']?.toString() ?? '';
    return '$id$dateText${status.isEmpty ? '' : ' • $status'}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _referralDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _referralDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final patient = _selectedPatient;
    if (patient == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select an existing patient first.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hospital not assigned to this user.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final referral = PatientReferral(
        id: '',
        hospitalId: hospitalId,
        patientId: patient['id'].toString(),
        referralDoctorId: _doctorId!,
        marketingEmployeeId: _employeeId,
        referralDate: _referralDate,
        opdRegistrationId: _opdRegistrationId,
        ipdAdmissionId: _ipdAdmissionId,
        source: MarketingConstants.referralSourceAdminEntry,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      await ref
          .read(patientReferralRepositoryProvider)
          .createReferral(hospitalId: hospitalId, referral: referral);

      ref.read(marketingRefreshProvider.notifier).state++;
      messenger.showSnackBar(
        const SnackBar(content: Text('Referral saved!')),
      );
      if (mounted) context.go('/marketing');
    } on MarketingRepositoryException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not save referral. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(value),
      ),
    );
  }
}
