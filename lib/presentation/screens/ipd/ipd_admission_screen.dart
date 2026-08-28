import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../../models/personalized_tag_models.dart';
import '../../../services/database_service.dart';
import '../../widgets/personalized_tag_field.dart';
import '../../widgets/smart_navigation.dart';

class IPDAdmissionScreen extends ConsumerStatefulWidget {
  final String? patientId;

  const IPDAdmissionScreen({super.key, this.patientId});

  @override
  ConsumerState<IPDAdmissionScreen> createState() => _IPDAdmissionScreenState();
}

class _IPDAdmissionScreenState extends ConsumerState<IPDAdmissionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _diagnosisController = TextEditingController();
  final _remarksController = TextEditingController();

  // Dynamic Wards & Beds
  String _selectedWardType = '';
  String? _selectedBedId;
  List<Map<String, dynamic>> _availableBeds = [];
  bool _wardsInitialized = false;

  // Doctor & Department State
  List<Map<String, dynamic>> _doctors = [];
  List<Map<String, dynamic>> _departments = [];
  String? _selectedDoctorId;
  Map<String, dynamic> _selectedDoctor = const <String, dynamic>{};
  String _selectedDepartmentId = '';
  String _selectedDepartmentName = '';
  bool _loadingDoctors = false;
  bool _doctorsInitialized = false;

  String _admissionType = 'Emergency';
  bool _isEmergency = true;
  bool _whatsappOptIn = false;
  bool _isLoading = false;

  /// Personalized (AI-flavoured) tag field for this admission.
  final _tagsKey = GlobalKey<PersonalizedTagFieldState>();

  @override
  void initState() {
    super.initState();
    _loadDoctorsAndDepartments();
  }

  @override
  void dispose() {
    _diagnosisController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Doctor & Department Loading
  // ---------------------------------------------------------------------------
  Future<void> _loadDoctorsAndDepartments() async {
    final db = ref.read(databaseServiceProvider);
    final hospitalId = ref.read(authStateProvider).hospitalId;
    setState(() => _loadingDoctors = true);
    try {
      final results = await Future.wait([
        db.getCachedDoctors(hospitalId: hospitalId),
        db.getCachedDepartments(hospitalId: hospitalId),
      ]);
      final doctors = (results[0] as List)
          .cast<Map<String, dynamic>>()
          .where((d) => d['is_active'] == null || d['is_active'] != false)
          .toList();
      final departments = (results[1] as List).cast<Map<String, dynamic>>();
      if (mounted) {
        setState(() {
          _doctors = doctors;
          _departments = departments;
          _loadingDoctors = false;
          _doctorsInitialized = true;
        });
      }
    } catch (_) {
      // Cache-first fetch failed — show the retry state in the UI.
      if (mounted) {
        setState(() {
          _loadingDoctors = false;
          _doctorsInitialized = true;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Doctor-wise charges (dynamic from doctors table)
  // ---------------------------------------------------------------------------
  double _doctorCharge(String key) {
    final value = _selectedDoctor[key];
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }

  double get _roundCharge => _doctorCharge('round_charge');
  double get _consultationFee => _doctorCharge('consultation_fee');
  double get _emergencyFee => _doctorCharge('emergency_fee');
  double get _icuVisitCharge => _doctorCharge('icu_visit_charge');
  double get _surgeryCharge => _doctorCharge('surgery_charge');
  double get _followupCharge => _doctorCharge('followup_charge');
  double get _homeVisitCharge => _doctorCharge('home_visit_charge');

  /// Total of all doctor-wise charge categories shown in the breakdown.
  double get _estimatedDoctorCharges =>
      _roundCharge +
      _consultationFee +
      _emergencyFee +
      _icuVisitCharge +
      _surgeryCharge +
      _followupCharge +
      _homeVisitCharge;

  /// Fee that applies at admission time (emergency or routine consultation).
  double get _admissionBaseFee =>
      _isEmergency ? _emergencyFee : _consultationFee;

  String get _doctorDisplayName {
    final name = _selectedDoctor['name']?.toString().trim() ?? '';
    return name.isEmpty ? 'Not selected' : name;
  }

  String get _doctorSpecialization =>
      _selectedDoctor['specialization']?.toString().trim() ?? '';

  String _formatCurrency(double value) {
    if (value == value.roundToDouble()) {
      return '₹${value.toStringAsFixed(0)}';
    }
    return '₹${value.toStringAsFixed(2)}';
  }

  /// Returns the department id only when it is present in the loaded
  /// department list, so the dropdown never receives an invalid value.
  String? get _selectedDepartmentValue {
    if (_selectedDepartmentId.isEmpty) return null;
    final exists = _departments.any(
      (d) => d['id'].toString() == _selectedDepartmentId,
    );
    return exists ? _selectedDepartmentId : null;
  }

  // ---------------------------------------------------------------------------
  // Doctor availability
  // ---------------------------------------------------------------------------
  int get _maxPatientsPerDay {
    final value = _selectedDoctor['max_patients_per_day'];
    return int.tryParse(value?.toString() ?? '') ?? 20;
  }

  int get _currentPatients {
    final value = _selectedDoctor['current_patients'];
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool get _hasDoctorAvailabilityData =>
      _selectedDoctor['max_patients_per_day'] != null ||
      _selectedDoctor['current_patients'] != null;

  bool get _isDoctorAvailable => _currentPatients < _maxPatientsPerDay;

  int get _availableSlots {
    final slots = _maxPatientsPerDay - _currentPatients;
    return slots > 0 ? slots : 0;
  }

  // ---------------------------------------------------------------------------
  // Selection Handlers
  // ---------------------------------------------------------------------------
  void _onDoctorSelected(String? doctorId) {
    if (doctorId == null || doctorId.isEmpty) return;
    final doctor = _doctors.firstWhere(
      (d) => d['id'].toString() == doctorId,
      orElse: () => <String, dynamic>{},
    );
    setState(() {
      _selectedDoctorId = doctorId;
      _selectedDoctor = doctor;

      // Auto-populate department from the selected doctor's department_id.
      final deptId = doctor['department_id']?.toString() ?? '';
      if (deptId.isNotEmpty) {
        _selectedDepartmentId = deptId;
        final dept = _departments.firstWhere(
          (d) => d['id'].toString() == deptId,
          orElse: () => <String, dynamic>{},
        );
        _selectedDepartmentName = dept['name']?.toString() ?? '';
      }
    });
  }

  void _onDepartmentSelected(String? departmentId) {
    if (departmentId == null) return;
    setState(() {
      _selectedDepartmentId = departmentId;
      final dept = _departments.firstWhere(
        (d) => d['id'].toString() == departmentId,
        orElse: () => <String, dynamic>{},
      );
      _selectedDepartmentName = dept['name']?.toString() ?? '';
    });
  }

  // Load Available Beds for Selected Ward
  Future<void> _loadAvailableBeds() async {
    final db = ref.read(databaseServiceProvider);
    try {
      final beds = await db.getBedsByStatus(
        'available',
        hospitalId: ref.read(authStateProvider).hospitalId,
        wardType: _selectedWardType,
      );
      if (mounted) {
        setState(() {
          _availableBeds = beds;
          _selectedBedId = null;
        });
      }
    } catch (e) {
      // Handle error silently
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Bootstrap se hospitalId hamesha available rahega
    final hospitalId = ref.read(authStateProvider).hospitalId!;
    final wardsAsync = ref.watch(hospitalWardsProvider(hospitalId));

    // Auto-select the first ward and load available beds once wards arrive.
    final wards = wardsAsync.valueOrNull ?? const <String>[];
    if (!_wardsInitialized && wards.isNotEmpty) {
      _wardsInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          if (_selectedWardType.isEmpty) {
            _selectedWardType = wards.first;
          }
        });
        _loadAvailableBeds();
      });
    }

    ref.listen(authStateProvider, (previous, next) {
      if (!next.isLoading && !next.isAuthenticated) {
        context.go('/login');
      }
    });

    return Scaffold(
      appBar: SmartAppBar(title: const Text('IPD Admission')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Patient Selection',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (widget.patientId != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Patient pre-selected (ID: ${widget.patientId!.substring(0, 8)}...)',
                                  style: TextStyle(
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        InkWell(
                          onTap: () => context.push('/patients/register'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'No patient selected. Click here to register a patient.',
                              style: TextStyle(
                                color: Colors.blue,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor: Colors.blue,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Admission Details',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        title: const Text('Emergency Admission'),
                        value: _isEmergency,
                        onChanged: (v) => setState(() => _isEmergency = v),
                      ),
                      // WhatsApp Marketing opt-in captured at admission time.
                      SwitchListTile(
                        title: const Text('WhatsApp Marketing Opt-In'),
                        subtitle: const Text(
                          'Allow promotional/transactional WhatsApp messages to this patient',
                        ),
                        value: _whatsappOptIn,
                        onChanged: (v) => setState(() => _whatsappOptIn = v),
                        secondary: const Icon(Icons.chat_outlined),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: _admissionType,
                        decoration: const InputDecoration(
                          labelText: 'Admission Type',
                        ),
                        items: ['Emergency', 'Planned', 'OPD Converted']
                            .map(
                              (t) => DropdownMenuItem(value: t, child: Text(t)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _admissionType = v!),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _diagnosisController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Diagnosis / Reason for Admission *',
                          hintText:
                              'Enter diagnosis or reason for admission...',
                        ),
                        validator: (v) =>
                            v?.isEmpty == true ? 'Required' : null,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // -----------------------------------------------------------------
              // Doctor Selection & Doctor-Wise Charges (mandatory)
              // -----------------------------------------------------------------
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.medical_services,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Doctor Selection *',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'All charges (round charges, consultation fee, etc.) are doctor-wise.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_loadingDoctors)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      else if (_doctorsInitialized && _doctors.isEmpty)
                        _buildDoctorsError(theme)
                      else ...[
                        // Doctor dropdown (mandatory, validated).
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'doctor_dropdown_${_selectedDoctorId ?? 'none'}',
                          ),
                          initialValue: _selectedDoctorId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Select Doctor *',
                            prefixIcon: Icon(Icons.person_search),
                          ),
                          items: _doctors.map((doc) {
                            final docId = doc['id'].toString();
                            final name =
                                doc['name']?.toString() ?? 'Unknown Doctor';
                            final specialization =
                                doc['specialization']?.toString() ?? '';
                            return DropdownMenuItem<String>(
                              value: docId,
                              child: Text(
                                specialization.isEmpty
                                    ? name
                                    : '$name — $specialization',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _onDoctorSelected,
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Please select a doctor'
                              : null,
                        ),
                        if (_selectedDoctorId != null) ...[
                          const SizedBox(height: 12),
                          _buildDoctorAvailabilityCard(theme),
                          const SizedBox(height: 12),
                          // Department dropdown (auto-filled from doctor, still
                          // editable in case the doctor covers multiple wards).
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'department_dropdown_$_selectedDepartmentId',
                            ),
                            initialValue: _selectedDepartmentValue,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Department (auto-filled)',
                              prefixIcon: Icon(Icons.apartment),
                            ),
                            items: _departments.map((dept) {
                              final deptId = dept['id'].toString();
                              final deptName =
                                  dept['name']?.toString() ?? 'Unknown';
                              return DropdownMenuItem<String>(
                                value: deptId,
                                child: Text(
                                  deptName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                            onChanged: _onDepartmentSelected,
                          ),
                          const SizedBox(height: 12),
                          _buildChargeBreakdownCard(theme),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bed Allocation',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      wardsAsync.when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) =>
                            Center(child: Text('Failed to load wards: $e')),
                        data: (wards) {
                          if (wards.isEmpty) {
                            return const Center(
                              child: Text(
                                'Hospital ID is missing or no wards found. Unable to load wards. Please contact the administrator.',
                                textAlign: TextAlign.center,
                              ),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Dynamic Ward Dropdown
                              DropdownButtonFormField<String>(
                                key: ValueKey(
                                  'ward_dropdown_$_selectedWardType',
                                ),
                                initialValue: _selectedWardType.isEmpty
                                    ? null
                                    : _selectedWardType,
                                decoration: const InputDecoration(
                                  labelText: 'Ward Type',
                                ),
                                items: wards.map((w) {
                                  return DropdownMenuItem(
                                    value: w,
                                    child: Text(w),
                                  );
                                }).toList(),
                                onChanged: (v) {
                                  setState(() {
                                    _selectedWardType = v!;
                                    _selectedBedId = null;
                                    _loadAvailableBeds();
                                  });
                                },
                              ),
                              const SizedBox(height: 12),
                              InkWell(
                                onTap: () {
                                  _showBedSelectionDialog(context);
                                },
                                child: InputDecorator(
                                  decoration: InputDecoration(
                                    labelText: 'Select Bed',
                                    suffixIcon: const Icon(Icons.bed),
                                                                      ),
                                  child: Text(
                                    _selectedBedId == null
                                        ? 'Tap to select a bed'
                                        : 'Bed selected (ID: ${_selectedBedId!.substring(0, 8)})',
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _remarksController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Remarks',
                  hintText: 'Any additional notes...',
                ),
              ),
              const SizedBox(height: 20),

              // Personalized tags — per logged-in user, context-aware (ipd).
              PersonalizedTagField(
                key: _tagsKey,
                fieldKey: PersonalizedTagFields.ipd,
                entityType: PersonalizedTagEntityTypes.ipdAdmission,
                label: 'Admission Tags',
                hint: 'e.g. Critical, Post-op, Insurance...',
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submitAdmission,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Admit Patient'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDoctorsError(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: theme.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No active doctors found for this hospital. Please add doctors first.',
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: _loadDoctorsAndDepartments,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildDoctorAvailabilityCard(ThemeData theme) {
    final available = _isDoctorAvailable;
    final color = available ? const Color(0xFF2E7D32) : const Color(0xFFE65100);
    final background = available
        ? const Color(0xFFE8F5E9)
        : const Color(0xFFFFF3E0);
    final icon = available ? Icons.check_circle : Icons.event_busy;
    final title = available
        ? 'Available for new admission'
        : 'Daily limit reached';
    final loadText = _hasDoctorAvailabilityData
        ? 'Current patient load: $_currentPatients / $_maxPatientsPerDay'
        : 'Patient load not configured for this doctor';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  available
                      ? '$loadText • $_availableSlots slot(s) left today'
                      : loadText,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChargeBreakdownCard(ThemeData theme) {
    final lines = <_ChargeLine>[
      _ChargeLine(
        'Round Charge (per visit)',
        Icons.medical_services,
        _roundCharge,
        true,
      ),
      _ChargeLine(
        'Consultation Fee (OPD)',
        Icons.person_search,
        _consultationFee,
        !_isEmergency,
      ),
      _ChargeLine(
        'Emergency Consultation Fee',
        Icons.emergency,
        _emergencyFee,
        _isEmergency,
      ),
      _ChargeLine(
        'ICU Visit Charge',
        Icons.monitor_heart,
        _icuVisitCharge,
        false,
      ),
      _ChargeLine(
        'Surgery / Procedure Charge',
        Icons.content_cut,
        _surgeryCharge,
        false,
      ),
      _ChargeLine(
        'Follow-up Visit Charge',
        Icons.event_repeat,
        _followupCharge,
        false,
      ),
      _ChargeLine(
        'Home Visit Charge',
        Icons.home_work,
        _homeVisitCharge,
        false,
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Doctor-Wise Charges — $_doctorDisplayName',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (_doctorSpecialization.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              _doctorSpecialization,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const Divider(height: 20),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(line.icon, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line.label)),
                  Text(
                    _formatCurrency(line.amount),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: line.amount > 0
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (line.isActiveBasis) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Applies',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Total Estimated Doctor Charges',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                _formatCurrency(_estimatedDoctorCharges),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Emergency fee applies for emergency admissions; ICU, surgery, '
            'follow-up and home-visit charges are added only when those '
            'services are used during the stay.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showBedSelectionDialog(BuildContext context) {
    if (_availableBeds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No beds available in this ward.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Available Beds'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _availableBeds.length,
            itemBuilder: (context, index) {
              final bed = _availableBeds[index];
              final bedId = bed['id'] as String;
              final bedNumber = bed['bed_number'] as String;
              return ListTile(
                title: Text(bedNumber),
                subtitle: Text('$_selectedWardType Ward - Available'),
                onTap: () {
                  setState(() {
                    _selectedBedId = bedId;
                  });
                  Navigator.pop(context);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Admission ke turant baad doctor-wise charges ko ipd_charges mein add
  /// karta hai taaki billing automatically populate ho jaye.
  Future<void> _applyDoctorChargesToBilling(
    DatabaseService dbService,
    String admissionId,
  ) async {
    final today = DateTime.now().toIso8601String().split('T')[0];
    final charges = <Map<String, dynamic>>[];

    if (_roundCharge > 0) {
      charges.add({
        'admission_id': admissionId,
        'charge_type': 'doctor_visit',
        'charge_description': 'Doctor Round Charge — $_doctorDisplayName',
        'amount': _roundCharge,
        'charge_date': today,
      });
    }

    if (_admissionBaseFee > 0) {
      charges.add({
        'admission_id': admissionId,
        'charge_type': 'doctor_visit',
        'charge_description': _isEmergency
            ? 'Doctor Emergency Consultation — $_doctorDisplayName'
            : 'Doctor Consultation Fee — $_doctorDisplayName',
        'amount': _admissionBaseFee,
        'charge_date': today,
      });
    }

    for (final charge in charges) {
      await dbService.insertIPDCharge(charge);
    }
  }

  Future<void> _submitAdmission() async {
    if (_formKey.currentState?.validate() != true) return;
    if (_selectedDoctorId == null || _selectedDoctorId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a doctor before admitting.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (_selectedBedId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a bed')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final admissionData = <String, dynamic>{
        'hospital_id': authState.hospitalId,
        'patient_id': widget.patientId,
        'doctor_id': _selectedDoctorId,
        'doctor_name': _doctorDisplayName,
        'department_id': _selectedDepartmentId.isEmpty
            ? null
            : _selectedDepartmentId,
        'department_name': _selectedDepartmentName.isEmpty
            ? null
            : _selectedDepartmentName,
        'diagnosis': _diagnosisController.text.trim(),
        'ward_type': _selectedWardType,
        'bed_id': _selectedBedId,
        'admission_type': _admissionType,
        'is_emergency': _isEmergency,
        'whatsapp_opt_in': _whatsappOptIn,
        'status': 'admitted',
        'admission_date': DateTime.now().toIso8601String(),
        'remarks': _remarksController.text.trim(),
      };

      final admission = await dbService.admitIPDPatient(admissionData);

      // Personalized tags — per logged-in user (best-effort; tag failure
      // must never block the admission).
      final admissionId = admission['id']?.toString() ?? '';
      final admissionTags =
          _tagsKey.currentState?.selectedTags ?? const <String>[];
      if (admissionId.isNotEmpty && admissionTags.isNotEmpty) {
        try {
          final userId = await dbService.getCurrentUsersTableId();
          if (userId != null) {
            await ref.read(personalizedTagServiceProvider).setEntityTags(
              userId: userId,
              fieldKey: PersonalizedTagFields.ipd,
              entityType: PersonalizedTagEntityTypes.ipdAdmission,
              entityId: admissionId,
              names: admissionTags,
            );
          }
        } catch (e) {
          debugPrint('IPD tags save failed (non-blocking): $e');
        }
      }

      // ✅ Bed ko occupied mark karo
      await dbService.updateBedStatus(_selectedBedId!, 'occupied');

      // ✅ Bed allocation table mein entry add karo (admission se linked)
      final allocationData = <String, dynamic>{
        'bed_id': _selectedBedId,
        'patient_id': widget.patientId,
        'hospital_id': authState.hospitalId,
        'ipd_admission_id': admission['id'],
        'status': 'active',
        'allocation_date': DateTime.now().toIso8601String(),
      };
      final allocation = await dbService.create(
        ApiConstants.bedAllocationsTable,
        allocationData,
      );

      // ✅ Admission ko allocation se link karo taaki discharge par ward
      //    transfer history + bed free karna sahi kaam kare.
      if (admission['id'] != null && allocation['id'] != null) {
        await dbService.update(
          ApiConstants.ipdAdmissionsTable,
          admission['id'] as String,
          {'bed_allocation_id': allocation['id']},
        );
      }

      // ✅ Doctor-wise charges billing mein automatically add karo.
      if (admission['id'] != null) {
        await _applyDoctorChargesToBilling(
          dbService,
          admission['id'] as String,
        );
      }

      // WhatsApp opt-in consent ko patient master par mirror karo.
      if (widget.patientId != null && widget.patientId!.isNotEmpty) {
        await dbService.update(
          ApiConstants.patientsTable,
          widget.patientId!,
          {'whatsapp_opt_in': _whatsappOptIn},
          hospitalId: authState.hospitalId,
        );
      }

      if (!mounted) return;

      // Ward screen bed list refresh karo taaki naya admission turant
      // occupied dikhe.
      final hospitalId = ref.read(authStateProvider).hospitalId;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        ref.invalidate(hospitalBedsProvider(hospitalId));
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IPD Admission successful!')),
      );
      context.go('/ipd/queue');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Admission failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

/// Small immutable holder for one row of the doctor charge breakdown.
class _ChargeLine {
  final String label;
  final IconData icon;
  final double amount;

  /// True when this fee is the active basis for the current admission
  /// (consultation fee for routine admissions, emergency fee for emergency).
  final bool isActiveBasis;

  const _ChargeLine(this.label, this.icon, this.amount, this.isActiveBasis);
}
