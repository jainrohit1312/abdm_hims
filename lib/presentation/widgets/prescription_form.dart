import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/constants/api_constants.dart';
import '../../models/prescription_models.dart';
import 'medicine_selection_dialog.dart';
import 'prescription_clinical_fields.dart';

/// Reusable doctor-friendly prescription form.
///
/// * Standalone use: `DoctorPrescriptionScreen` (OPD / IPD).
/// * Embedded use: OPD Consultation ke Prescription tab ke andar.
class DoctorPrescriptionForm extends ConsumerStatefulWidget {
  final String? patientId;
  final String? opdRegistrationId;
  final String? ipdAdmissionId;
  final String? patientName;
  final String? uhid;

  /// Standalone (full prescription) mode mein clinical sections
  /// (History / Vitals / Diagnosis / Investigations / Advice) render karne
  /// aur save karne ke liye. Embedded (OPD consultation) mode mein parent
  /// screen ye sections khud handle karti hai, isliye wahan null rehta hai.
  final PrescriptionClinicalController? clinicalController;

  /// Jab `true` ho (embedded), form apna patient card nahi dikhata aur save ke
  /// baad route pop nahi karta — form clear karke wahi ruk jata hai.
  final bool embedded;

  const DoctorPrescriptionForm({
    super.key,
    this.patientId,
    this.opdRegistrationId,
    this.ipdAdmissionId,
    this.patientName,
    this.uhid,
    this.clinicalController,
    this.embedded = false,
  });

  @override
  ConsumerState<DoctorPrescriptionForm> createState() =>
      DoctorPrescriptionFormState();
}

class DoctorPrescriptionFormState
    extends ConsumerState<DoctorPrescriptionForm>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isLoadingPatient = true;
  bool _isSaving = false;
  String? _patientError;

  String? _resolvedPatientId;
  Map<String, dynamic>? _patient;
  Map<String, dynamic>? _doctor;

  final List<_PrescriptionMedicineDraft> _medicines = [];

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () {
      if (mounted) _loadPatient();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// Parent screen (standalone AppBar) se reload karne ke liye.
  Future<void> reload() => _loadPatient();

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadPatient() async {
    final db = ref.read(databaseServiceProvider);

    setState(() {
      _isLoadingPatient = true;
      _patientError = null;
    });

    try {
      String? patientId = widget.patientId;

      // Resolve patient from the linked OPD registration, then IPD admission.
      if ((patientId == null || patientId.isEmpty) &&
          widget.opdRegistrationId != null) {
        final registration = await db.getById(
          ApiConstants.opdRegistrationsTable,
          widget.opdRegistrationId!,
        );
        patientId = registration?['patient_id']?.toString();
      }

      if ((patientId == null || patientId.isEmpty) &&
          widget.ipdAdmissionId != null) {
        final admission = await db.getById(
          ApiConstants.ipdAdmissionsTable,
          widget.ipdAdmissionId!,
        );
        patientId = admission?['patient_id']?.toString();
      }

      if (patientId == null || patientId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _patientError =
              'Patient not found. Please open this screen from an OPD '
              'consultation or an IPD admission.';
          _isLoadingPatient = false;
        });
        return;
      }

      final patient = await db.getById(ApiConstants.patientsTable, patientId);
      final doctor = await db.getCurrentUserRecord();

      if (!mounted) return;
      setState(() {
        _resolvedPatientId = patientId;
        _patient = patient;
        _doctor = doctor;
        _isLoadingPatient = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _patientError = 'Failed to load patient: $e';
        _isLoadingPatient = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Medicine addition (popup based — "Add & Continue" keeps the popup open)
  // ---------------------------------------------------------------------------

  /// Inventory mein naya medicine add hone ke baad use directly prescription
  /// list mein bhi daal deta hai.
  void _selectMedicine(Map<String, dynamic> medicine) {
    final draft = _PrescriptionMedicineDraft(
      medicineName: medicine['medicine_name']?.toString() ?? '',
      genericName: medicine['generic_name']?.toString(),
      strength: medicine['strength']?.toString(),
      route: medicine['route']?.toString() ?? 'Oral',
    );

    setState(() => _medicines.add(draft));
  }

  /// Popup ke "Add & Continue" se aaya hua fully-filled medicine draft
  /// prescription list mein add karta hai. Popup khula rehta hai, isliye
  /// background list turant update hoti rehti hai.
  void _addMedicineFromDialog(Map<String, dynamic> draft) {
    final medicine = _PrescriptionMedicineDraft(
      medicineName: draft['medicine_name']?.toString() ?? '',
      genericName: draft['generic_name']?.toString(),
      strength: draft['strength']?.toString(),
      route: draft['route']?.toString() ?? 'Oral',
    );
    medicine.dosage = draft['dosage']?.toString() ?? '1-0-0';
    medicine.frequency = draft['frequency']?.toString() ?? 'OD';
    medicine.duration = draft['duration']?.toString() ?? '5 Days';
    medicine.instructions = draft['instructions']?.toString() ?? '';
    medicine.customTimes =
        (draft['custom_times'] as List?)?.cast<String>() ?? const [];

    setState(() => _medicines.add(medicine));
  }

  void _removeMedicine(int index) {
    setState(() => _medicines.removeAt(index));
  }

  /// Medicine selection popup kholta hai. Popup "Done" dabane tak khula
  /// rehta hai; har "Add & Continue" ke saath [MedicineAddedCallback] fire
  /// hota hai aur neeche wali list update hoti rehti hai.
  Future<void> _openMedicineDialog() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) => MedicineSelectionDialog(
        onMedicineAdded: _addMedicineFromDialog,
      ),
    );
  }

  Future<void> _addNewMedicine() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const AddNewMedicineDialog(),
    );
    if (created == null || !mounted) return;

    // Naya medicine add hua hai — hospital-wise medicines cache refresh karo
    // taaki popup wali live alphabetical list turant update ho jaye.
    final hospitalId = ref.read(authStateProvider).hospitalId;
    ref.invalidate(medicinesCacheProvider(hospitalId));

    _selectMedicine(created);
  }

  // ---------------------------------------------------------------------------
  // Save + print
  // ---------------------------------------------------------------------------

  Future<void> _savePrescription() async {
    if (_resolvedPatientId == null) {
      _showMessage('Patient not loaded yet.');
      return;
    }

    // OPD -> full clinical document, IPD -> medicines only.
    final isIpd = widget.ipdAdmissionId != null &&
        widget.ipdAdmissionId!.isNotEmpty;
    final unifiedSections =
        widget.clinicalController?.toUnifiedJson() ?? const <String, dynamic>{};
    final history = (unifiedSections['history'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final investigations =
        (unifiedSections['investigations'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final advice =
        (unifiedSections['advice'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final hasClinicalData = history.isNotEmpty ||
        investigations.isNotEmpty ||
        advice.isNotEmpty;

    if (isIpd) {
      if (_medicines.isEmpty) {
        _showMessage('Add at least one medicine before saving.');
        return;
      }
    } else {
      if (_medicines.isEmpty && !hasClinicalData) {
        _showMessage(
          'Add at least one medicine or fill any clinical detail '
          'before saving.',
        );
        return;
      }
    }

    final medicinesError = validateMedicines();
    if (medicinesError != null) {
      _showMessage(medicinesError);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);
      final doctor = _doctor ?? await db.getCurrentUserRecord();
      final doctorId = doctor?['id']?.toString();
      if (doctorId == null || doctorId.isEmpty) {
        throw Exception(
          'Doctor record not found. Please re-login and try again.',
        );
      }

      await db.savePrescription(
        patientId: _resolvedPatientId!,
        doctorId: doctorId,
        hospitalId: authState.hospitalId,
        opdRegistrationId: widget.opdRegistrationId,
        ipdAdmissionId: widget.ipdAdmissionId,
        visitType: isIpd ? VisitType.ipd.value : VisitType.opd.value,
        medicines: collectMedicines(),
        history: history,
        investigations: investigations,
        advice: advice,
      );

      if (!mounted) return;

      // Smart OPD workflow: prescription banne ke baad queue/status refresh
      // karo taaki OPD registration turant Completed dikhe.
      ref.invalidate(opdQueueProvider);
      if (widget.opdRegistrationId != null) {
        ref.invalidate(opdPrescriptionsProvider(widget.opdRegistrationId!));
      }
      if (widget.ipdAdmissionId != null) {
        ref.invalidate(ipdPrescriptionsProvider(widget.ipdAdmissionId!));
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prescription saved successfully.')),
      );

      if (widget.embedded) {
        resetAfterSave();
      } else {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
        } else {
          resetAfterSave();
        }
      }
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to save prescription: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Returns an error message when any medicine draft is incomplete,
  /// otherwise `null`. (Parent OPD flow ke liye empty list valid hai —
  /// wahan clinical notes bhi save hote hain.)
  String? validateMedicines() {
    final incomplete = _medicines.where((m) {
      return m.medicineName.trim().isEmpty ||
          m.dosage.trim().isEmpty ||
          m.duration.trim().isEmpty;
    }).toList();
    if (incomplete.isNotEmpty) {
      return 'Set medicine name, dosage and duration for '
          '"${incomplete.first.medicineName}".';
    }
    return null;
  }

  /// Current medicine drafts as DB-ready maps.
  List<Map<String, dynamic>> collectMedicines() {
    return _medicines
        .map(
          (m) => {
            'medicine_name': m.medicineName,
            'generic_name': m.genericName,
            'strength': m.strength,
            'dosage': m.dosage,
            'frequency': m.frequency,
            'duration': m.duration,
            'route': m.route,
            'instructions': m.instructions,
            'custom_times': m.customTimes,
          },
        )
        .toList();
  }

  /// Save ke baad medicine form wapas blank ho jata hai.
  void resetAfterSave() {
    if (!mounted) return;
    setState(() {
      _medicines.clear();
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    if (_isLoadingPatient) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_patientError != null) {
      return _ErrorView(message: _patientError!, onRetry: _loadPatient);
    }

    final clinicalController = widget.clinicalController;
    // Unified module rule: OPD ko poori clinical document milti hai, IPD ko
    // sirf medicines (History / Investigations / Advice IPD mein dusre
    // modules handle karte hain).
    final isIpd = widget.ipdAdmissionId != null &&
        widget.ipdAdmissionId!.isNotEmpty;
    final showClinicalSections =
        !widget.embedded && clinicalController != null && !isIpd;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.embedded) ...[
          _buildPatientCard(theme),
          const SizedBox(height: 16),
        ],
        if (isIpd && !widget.embedded) ...[
          _buildIpdMedicinesOnlyBanner(theme),
          const SizedBox(height: 16),
        ],
        if (showClinicalSections) ...[
          PrescriptionHistoryFields(controller: clinicalController),
          const SizedBox(height: 16),
        ],
        _buildAddMedicineCard(theme),
        const SizedBox(height: 16),
        _buildMedicineListCard(theme),
        if (showClinicalSections) ...[
          const SizedBox(height: 16),
          PrescriptionInvestigationsFields(controller: clinicalController),
          const SizedBox(height: 16),
          PrescriptionAdviceFollowUpFields(controller: clinicalController),
        ],
        if (!widget.embedded) ...[
          const SizedBox(height: 24),
          _buildSaveButton(theme),
        ],
      ],
    );

    if (widget.embedded) return content;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: content,
    );
  }

  Widget _buildPatientCard(ThemeData theme) {
    final patient = _patient ?? const <String, dynamic>{};
    final name = _patientDisplayName(patient);
    final uhid = patient['uhid']?.toString() ?? widget.uhid ?? 'N/A';
    final gender = patient['gender']?.toString();
    final age = patient['age']?.toString();
    final source = widget.opdRegistrationId != null
        ? 'OPD'
        : widget.ipdAdmissionId != null
        ? 'IPD'
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
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
                    name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'UHID: $uhid${gender != null ? ' • $gender' : ''}${age != null ? ' • $age yrs' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (source != null)
                    Text(
                      'Source: $source${source == 'IPD' ? ' (Medicines only)' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// IPD context mein clinical sections chhupa diye jaate hain — ye banner
  /// doctor ko batata hai ki IPD prescription medicines-only hai.
  Widget _buildIpdMedicinesOnlyBanner(ThemeData theme) {
    return Card(
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'IPD prescription contains medicines only. History, '
                'investigations and advice for this admission are recorded '
                'in the IPD patient dashboard.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddMedicineCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Medicines',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Search and add medicines through the popup. You can keep '
              'adding multiple medicines before pressing Done.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _openMedicineDialog,
                icon: const Icon(Icons.medication),
                label: const Text('Add Medicine'),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _addNewMedicine,
                icon: const Icon(Icons.add),
                label: const Text('Add New Medicine'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedicineListCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Prescribed Medicines (${_medicines.length})',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_medicines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('No medicines added yet.')),
              )
            else
              for (var i = 0; i < _medicines.length; i++)
                _PrescriptionMedicineCard(
                  key: ObjectKey(_medicines[i]),
                  medicine: _medicines[i],
                  onChanged: () => setState(() {}),
                  onDelete: () => _removeMedicine(i),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: _isSaving ? null : _savePrescription,
        icon: _isSaving
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save),
        label: const Text('Save Prescription'),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _patientDisplayName(Map<String, dynamic> patient) {
    final first = patient['first_name']?.toString() ?? '';
    final last = patient['last_name']?.toString() ?? '';
    final name = '$first $last'.trim();
    if (name.isNotEmpty) return name;
    return widget.patientName ?? 'Unknown Patient';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

// -----------------------------------------------------------------------------
// Medicine draft model (mutable — inline controls isi ko update karte hain)
// -----------------------------------------------------------------------------

class _PrescriptionMedicineDraft {
  String medicineName;
  String? genericName;
  String? strength;
  String dosage = '1-0-0';
  String frequency = 'OD';
  List<String> customTimes = const [];
  String duration = '5 Days';
  String route = 'Oral';
  String instructions = '';

  _PrescriptionMedicineDraft({
    required this.medicineName,
    this.genericName,
    this.strength,
    this.route = 'Oral',
  });
}

// -----------------------------------------------------------------------------
// Inline prescription medicine card
// (frequency chips + editable dosage + duration dropdown + edit/delete)
// -----------------------------------------------------------------------------

class _PrescriptionMedicineCard extends StatefulWidget {
  final _PrescriptionMedicineDraft medicine;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  const _PrescriptionMedicineCard({
    super.key,
    required this.medicine,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  State<_PrescriptionMedicineCard> createState() =>
      _PrescriptionMedicineCardState();
}

class _PrescriptionMedicineCardState extends State<_PrescriptionMedicineCard> {
  late final TextEditingController _dosageController;
  late final TextEditingController _customDurationController;
  late final TextEditingController _nameController;
  late final TextEditingController _strengthController;
  late final TextEditingController _instructionsController;

  bool _showDetails = false;

  String get _durationDropdownValue {
    final duration = widget.medicine.duration;
    return medicineDurationOptions.contains(duration) ? duration : 'Custom';
  }

  @override
  void initState() {
    super.initState();
    final medicine = widget.medicine;
    _dosageController = TextEditingController(text: medicine.dosage);
    _customDurationController = TextEditingController(
      text: medicineDurationOptions.contains(medicine.duration)
          ? ''
          : medicine.duration,
    );
    _nameController = TextEditingController(text: medicine.medicineName);
    _strengthController = TextEditingController(text: medicine.strength ?? '');
    _instructionsController = TextEditingController(
      text: medicine.instructions,
    );
  }

  @override
  void dispose() {
    _dosageController.dispose();
    _customDurationController.dispose();
    _nameController.dispose();
    _strengthController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  void _selectFrequency(String frequency) {
    setState(() {
      widget.medicine.frequency = frequency;
      final autoDosage = autoDosageByFrequency[frequency];
      if (autoDosage != null) {
        widget.medicine.dosage = autoDosage;
        _dosageController.text = autoDosage;
      }
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final medicine = widget.medicine;

    final strengthText = medicine.strength ?? '';
    final title = strengthText.isEmpty
        ? medicine.medicineName
        : '${medicine.medicineName} ($strengthText)';

    final descriptionParts = <String>[
      if (medicine.genericName != null && medicine.genericName!.isNotEmpty)
        medicine.genericName!,
      medicineFrequencyDescription(medicine.frequency),
      if (medicine.route.isNotEmpty) 'Route: ${medicine.route}',
    ]..removeWhere((part) => part.isEmpty);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.medication,
                    size: 18,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (descriptionParts.isNotEmpty)
                        Text(
                          descriptionParts.join(' • '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  color: _showDetails
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  tooltip: 'Edit medicine details',
                  onPressed: () => setState(() => _showDetails = !_showDetails),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: theme.colorScheme.error,
                  tooltip: 'Remove medicine',
                  onPressed: widget.onDelete,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Frequency',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final frequency in medicineFrequencyOptions)
                  ChoiceChip(
                    label: Text(frequency),
                    selected: medicine.frequency == frequency,
                    onSelected: (_) => _selectFrequency(frequency),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: medicine.frequency == frequency
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _dosageController,
                    decoration: InputDecoration(
                      labelText: 'Dosage',
                      hintText: '1-0-1',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (value) {
                      widget.medicine.dosage = value.trim();
                      widget.onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(
                      'duration_${medicine.hashCode}_${medicine.duration}',
                    ),
                    initialValue: _durationDropdownValue,
                    decoration: InputDecoration(
                      labelText: 'Duration',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    items: medicineDurationOptions
                        .map(
                          (duration) => DropdownMenuItem(
                            value: duration,
                            child: Text(
                              duration == 'Custom' ? 'Custom…' : duration,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        if (value == 'Custom') {
                          widget.medicine.duration = _customDurationController
                              .text
                              .trim();
                        } else {
                          widget.medicine.duration = value;
                        }
                      });
                      widget.onChanged();
                    },
                  ),
                ),
              ],
            ),
            if (_durationDropdownValue == 'Custom') ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _customDurationController,
                decoration: InputDecoration(
                  labelText: 'Custom Duration',
                  hintText: 'e.g. 21 Days / 2 Weeks / 6 Months',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (value) {
                  widget.medicine.duration = value.trim();
                  widget.onChanged();
                },
              ),
            ],
            if (_showDetails) ...[
              const SizedBox(height: 10),
              Text(
                'Medicine Details',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Medicine Name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (value) {
                  widget.medicine.medicineName = value.trim();
                  widget.onChanged();
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _strengthController,
                decoration: InputDecoration(
                  labelText: 'Strength',
                  hintText: 'e.g. 500mg',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (value) {
                  widget.medicine.strength = value.trim().isEmpty
                      ? null
                      : value.trim();
                  widget.onChanged();
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('route_${widget.medicine.hashCode}_${widget.medicine.route}'),
                initialValue: medicineRouteOptions.contains(widget.medicine.route)
                    ? widget.medicine.route
                    : 'Other',
                decoration: InputDecoration(
                  labelText: 'Route',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                items: medicineRouteOptions
                    .map(
                      (route) => DropdownMenuItem(
                        value: route,
                        child: Text(route),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  widget.medicine.route = value;
                  widget.onChanged();
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _instructionsController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Instructions',
                  hintText: 'e.g. With water, After food',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (value) {
                  widget.medicine.instructions = value.trim();
                  widget.onChanged();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Error view
// -----------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
