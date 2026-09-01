import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../../models/personalized_tag_models.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/personalized_tag_field.dart';
import '../../widgets/smart_navigation.dart';
import 'opd_slip_print.dart';

class OPDRegistrationScreen extends ConsumerStatefulWidget {
  final String? patientId;
  final String? uhid;
  final String? patientName;

  const OPDRegistrationScreen({
    super.key,
    this.patientId,
    this.uhid,
    this.patientName,
  });

  @override
  ConsumerState<OPDRegistrationScreen> createState() =>
      _OPDRegistrationScreenState();
}

class _OPDRegistrationScreenState extends ConsumerState<OPDRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _vitalsBPController = TextEditingController();
  final _vitalsPulseController = TextEditingController();
  final _vitalsTempController = TextEditingController();
  final _vitalsSpO2Controller = TextEditingController();
  final _ageController = TextEditingController();
  final _feeController = TextEditingController();
  final _discountController = TextEditingController();

  // Department & Doctor State
  String _selectedDepartmentId = '';
  String _selectedDoctorId = '';
  String _selectedDoctorName = '';
  double _consultationFee = 0;
  double _discount = 0;
  bool _isEmergency = false;
  bool _whatsappOptIn = false;
  List<Map<String, dynamic>> _departments = [];
  List<Map<String, dynamic>> _doctors = [];

  bool _isSubmitting = false;
  bool _isLoadingPatient = false;
  String _selectedBloodGroup = 'O+';

  /// Personalized (AI-flavoured) tag field for this OPD visit.
  final _tagsKey = GlobalKey<PersonalizedTagFieldState>();

  // Smart OPD Payment
  static const _paymentModes = ['Cash', 'Card', 'UPI', 'Insurance'];
  String _paymentMode = 'Cash';

  String get _paymentModeValue => _paymentMode.toLowerCase();

  bool get _hasPreSelectedPatient =>
      widget.patientId != null &&
      widget.patientId!.isNotEmpty &&
      widget.uhid != null &&
      widget.uhid!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadDepartments();
    if (_hasPreSelectedPatient) {
      _loadPatientData();
    }
  }

  @override
  void dispose() {
    _vitalsBPController.dispose();
    _vitalsPulseController.dispose();
    _vitalsTempController.dispose();
    _vitalsSpO2Controller.dispose();
    _ageController.dispose();
    _feeController.dispose();
    _discountController.dispose();
    super.dispose();
  }

  // --- Department & Doctor Logic ---
  Future<void> _loadDepartments() async {
    final db = ref.read(databaseServiceProvider);
    final auth = ref.read(authStateProvider);
    try {
      final depts = await db.getCachedDepartments(hospitalId: auth.hospitalId);
      if (mounted) {
        setState(() {
          _departments = depts;
          if (depts.isNotEmpty) {
            _selectedDepartmentId = depts.first['id'];
            _loadDoctors();
          }
        });
      }
    } catch (e) {
      // Handle error silently
    }
  }

  Future<void> _loadDoctors() async {
    final db = ref.read(databaseServiceProvider);
    final auth = ref.read(authStateProvider);
    print('🟡 Fetching doctors for department ID: $_selectedDepartmentId');
    try {
      final docs = await db.getCachedDoctorsByDepartment(
        _selectedDepartmentId,
        hospitalId: auth.hospitalId,
      );
      print('🟢 Doctors found: ${docs.length}');
      print('🟢 Doctor details: $docs');
      print('🟢 DB Response: $docs');

      if (mounted) {
        setState(() {
          _doctors = docs;
          if (docs.isNotEmpty) {
            _selectedDoctorId = docs.first['id'];
            _updateFee();
          } else {
            _selectedDoctorId = '';
            _consultationFee = 0;
          }
        });
      }
    } catch (e) {
      print('🔴 Error: $e');
    }
  }

  void _updateFee() {
    final selected = _doctors.firstWhere(
      (d) => d['id'].toString() == _selectedDoctorId,
      orElse: () => {},
    );
    if (selected.isNotEmpty) {
      _selectedDoctorName = selected['name']?.toString() ?? '';
      double opdFee = 0;
      double emergencyFee = 0;

      if (selected['opd_fee'] != null) {
        opdFee = double.tryParse(selected['opd_fee'].toString()) ?? 0;
      }
      if (selected['emergency_fee'] != null) {
        emergencyFee =
            double.tryParse(selected['emergency_fee'].toString()) ?? 0;
      }

      if (_isEmergency) {
        _consultationFee = emergencyFee;
      } else {
        _consultationFee = opdFee;
      }

      _feeController.text = _consultationFee > 0
          ? _consultationFee.toStringAsFixed(0)
          : '';
      _discountController.clear();
      _discount = 0;
    } else {
      _consultationFee = 0;
      _feeController.clear();
      _discountController.clear();
      _discount = 0;
    }
  }

  // --- Patient Data Load ---
  int _calculateAge(String dobString) {
    try {
      final dob = DateTime.parse(dobString);
      final now = DateTime.now();
      int age = now.year - dob.year;
      if (now.month < dob.month ||
          (now.month == dob.month && now.day < dob.day)) {
        age--;
      }
      return age;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _loadPatientData() async {
    setState(() => _isLoadingPatient = true);
    try {
      final dbService = ref.read(databaseServiceProvider);
      final patient = await dbService.getById(
        ApiConstants.patientsTable,
        widget.patientId!,
      );
      if (patient != null && mounted) {
        final dob = patient['date_of_birth'] as String?;
        if (dob != null && dob.isNotEmpty) {
          final age = _calculateAge(dob);
          _ageController.text = age.toString();
        }
        final bloodGroup = patient['blood_group'] as String?;
        if (bloodGroup != null && bloodGroup.isNotEmpty) {
          _selectedBloodGroup = bloodGroup;
        }
        setState(() {});
      }
    } catch (_) {
      // Silently fail
    } finally {
      if (mounted) setState(() => _isLoadingPatient = false);
    }
  }

  // --- Slip Data ---
  Widget _amountRow(
    String label,
    double value, {
    bool bold = false,
    Color? color,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: bold ? 16 : 14,
            fontWeight: bold ? FontWeight.bold : FontWeight.w500,
            color: color ?? const Color(0xFF2E7D32),
          ),
        ),
        Text(
          '₹ ${value.toStringAsFixed(0)}',
          style: TextStyle(
            fontSize: bold ? 18 : 15,
            fontWeight: bold ? FontWeight.bold : FontWeight.w500,
            color: color ?? const Color(0xFF2E7D32),
          ),
        ),
      ],
    );
  }

  /// Registration ke baad print dialog ke liye slip data taiyar karta hai.
  /// PDF generator [OPDSlipPrintService] A5 page format use karta hai jisse
  /// A5 thermal/paper par print ho aur page waste na ho.
  Future<Map<String, dynamic>> _buildSlipData(
    Map<String, dynamic> slipRow,
    String opdId,
  ) async {
    final dbService = ref.read(databaseServiceProvider);
    final authState = ref.read(authStateProvider);

    final patients =
        (slipRow['patients'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final patientName = [
      patients['first_name'],
      patients['last_name'],
    ].where((n) => n != null && n.toString().isNotEmpty).join(' ').trim();

    Map<String, dynamic>? hospital;
    final hospitalId = authState.hospitalId;
    if (hospitalId != null && hospitalId.isNotEmpty) {
      hospital = await dbService.getById(
        ApiConstants.hospitalsTable,
        hospitalId,
      );
    }

    var departmentName = 'N/A';
    for (final dept in _departments) {
      if (dept['id'].toString() == _selectedDepartmentId) {
        departmentName = dept['name']?.toString() ?? 'N/A';
        break;
      }
    }

    final slipNumber =
        'OPD-${(opdId.length >= 8 ? opdId.substring(0, 8) : opdId).toUpperCase()}';

    final grossFee = double.tryParse(
          slipRow['consultation_fee']?.toString() ?? '',
        ) ??
        0;
    final netPayable = double.tryParse(
          slipRow['payment_amount']?.toString() ?? '',
        ) ??
        0;
    final paidAmount = double.tryParse(
          slipRow['paid_amount']?.toString() ?? '',
        ) ??
        netPayable;
    final balanceAmount = double.tryParse(
          slipRow['balance_amount']?.toString() ?? '',
        ) ??
        (netPayable - paidAmount);

    return <String, dynamic>{
      'hospitalName': hospital?['name']?.toString() ?? 'HIMS Hospital',
      'hospitalAddress':
          hospital?['address']?.toString() ??
          '123, Healthcare Avenue, New Delhi',
      'patientName': patientName.isEmpty
          ? (widget.patientName ?? 'Unknown Patient')
          : patientName,
      'uhid': patients['uhid']?.toString() ?? widget.uhid ?? 'N/A',
      'doctorName': _selectedDoctorName.isEmpty ? 'N/A' : _selectedDoctorName,
      'department': departmentName,
      'consultationFee': grossFee,
      'discount': grossFee - netPayable,
      'netPayable': netPayable,
      'paymentAmount': netPayable,
      'paidAmount': paidAmount,
      'balanceAmount': balanceAmount,
      'paymentMode': _paymentMode,
      'paymentStatus': 'Paid',
      'date': DateTime.now(),
      'slipNumber': slipNumber,
    };
  }

  // --- Submit Logic ---
  Future<void> _submitOPDRegistration() async {
    if (!_hasPreSelectedPatient) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No patient selected. Please register a patient first.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_selectedDoctorId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a doctor.')));
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final createdById = await dbService.getCurrentUsersTableId();
      if (!mounted) return;

      if (createdById == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your session is invalid. Please log out and log in again.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isSubmitting = false);
        return;
      }

      final bpText = _vitalsBPController.text.trim();
      final systolic = bpText.contains('/')
          ? int.tryParse(bpText.split('/').first)
          : null;
      final diastolic = bpText.contains('/')
          ? int.tryParse(bpText.split('/').last)
          : null;

      final pulse = int.tryParse(_vitalsPulseController.text.trim());
      final temp = double.tryParse(_vitalsTempController.text.trim());
      final spo2 = double.tryParse(_vitalsSpO2Controller.text.trim());

      final vitalSigns = <String, dynamic>{
        'blood_pressure_systolic': systolic,
        'blood_pressure_diastolic': diastolic,
        'pulse_rate': pulse,
        'temperature': temp,
        'spo2': spo2,
      };

      final ageText = _ageController.text.trim();
      final age = ageText.isNotEmpty ? int.tryParse(ageText) : null;

      final double grossFee = _consultationFee;
      final double discount = double.tryParse(
            _discountController.text.trim(),
          ) ??
          _discount;
      if (discount < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Discount cannot be negative.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      if (discount > grossFee) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Discount cannot exceed the consultation fee.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      final double finalFee =
          ((grossFee - discount) * 100).roundToDouble() / 100;

      var selectedDepartmentName = '';
      for (final dept in _departments) {
        if (dept['id'].toString() == _selectedDepartmentId) {
          selectedDepartmentName = dept['name']?.toString() ?? '';
          break;
        }
      }

      final opdData = <String, dynamic>{
        'hospital_id': authState.hospitalId,
        'patient_id': widget.patientId,
        'department_id': _selectedDepartmentId,
        'department_name': selectedDepartmentName,
        'visit_date': DateTime.now().toIso8601String().split('T')[0],
        'visit_time': DateTime.now()
            .toIso8601String()
            .split('T')[1]
            .substring(0, 8),
        'vital_signs': vitalSigns,
        'age': age,
        'blood_group': _selectedBloodGroup,
        'created_by': createdById,
        'is_emergency': _isEmergency,
        'whatsapp_opt_in': _whatsappOptIn,
        'consultation_fee': grossFee, // Original/gross consultation fee
        'doctor_name': _selectedDoctorName,
      };

      // Smart workflow: doctor ki prescription_mode ke hisaab se OPD status
      // `pending` ya `completed` set hota hai aur payment columns
      // (payment_amount / payment_status unpaid) save hote hain.
      final created = await dbService.createOPDRegistration(
        opdData,
        hospitalId: authState.hospitalId,
        doctorId: _selectedDoctorId,
        discountAmount: discount,
      );

      final opdId = created['id']?.toString() ?? '';

      // Personalized tags — per logged-in user (best-effort; tag failure
      // must never block OPD registration).
      final visitTags = _tagsKey.currentState?.selectedTags ?? const <String>[];
      if (opdId.isNotEmpty && visitTags.isNotEmpty) {
        try {
          await ref.read(personalizedTagServiceProvider).setEntityTags(
            userId: createdById,
            fieldKey: PersonalizedTagFields.opd,
            entityType: PersonalizedTagEntityTypes.opdRegistration,
            entityId: opdId,
            names: visitTags,
          );
        } catch (e) {
          debugPrint('OPD tags save failed (non-blocking): $e');
        }
      }

      // Registration ke time payment collect -> slip generate -> paid.
      // Returned row mein patients ka naam/uhid embedded hota hai jo slip
      // print karne ke kaam aata hai.
      final slipRow = await dbService.generateOPDSlip(
        patientId: widget.patientId!,
        paymentAmount: finalFee,
        paymentMode: _paymentModeValue,
        opdRegistrationId: opdId,
        discountAmount: discount,
      );

      // WhatsApp opt-in consent ko patient master par bhi mirror karo.
      if (widget.patientId != null && widget.patientId!.isNotEmpty) {
        await dbService.update(
          ApiConstants.patientsTable,
          widget.patientId!,
          {'whatsapp_opt_in': _whatsappOptIn},
          hospitalId: authState.hospitalId,
        );
      }

      if (!mounted) return;

      // Payment slip (A5) ka print dialog turant kholo taaki slip print ho
      // sake. Print cancel/fail ho tab bhi aage OPD queue par le jaao.
      final slipData = await _buildSlipData(slipRow, opdId);
      if (mounted) {
        try {
          await OPDSlipPrintService.printSlip(slipData);
        } catch (_) {
          // Printer available nahi ho ya user cancel kare to ignore karo.
        }
      }

      if (!mounted) return;

      // Queue ko refresh karo taaki naya status (Pending/Completed) dikhe.
      ref.invalidate(opdQueueProvider);

      // Unified billing: slip ne ab `billing` + `payment_logs` bhi bana diye
      // hain, isliye billing tabs ko refresh karo taaki naya OPD bill turant
      // dikhe.
      final hospitalId = authState.hospitalId;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        for (final sourceType in <String?>[null, 'opd']) {
          ref.invalidate(
            allBillsProvider(
              BillingFilter(hospitalId: hospitalId, sourceType: sourceType),
            ),
          );
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'OPD Registration successful! UHID: ${widget.uhid} • '
            '$_paymentMode Paid • Bill synced to Billing',
          ),
          backgroundColor: const Color(0xFF66BB6A),
        ),
      );

      // Print ke baad seedha OPD queue kholo. Queue ke har patient card par
      // print icon se dobara slip print ki ja sakti hai.
      context.go('/opd/queue');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('OPD Registration failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // --- UI Build ---
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('OPD Registration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: () => context.push('/opd/queue'),
            tooltip: 'View Queue',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_hasPreSelectedPatient) ...[
                Text(
                  'Selected Patient',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: theme.colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: theme.colorScheme.primary,
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.patientName ?? 'Patient',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'UHID: ${widget.uhid}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Patient Details',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (_isLoadingPatient)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else ...[
                  AppFieldRow(
                    children: [
                      TextFormField(
                        controller: _ageController,
                        decoration: const InputDecoration(
                          labelText: 'Age',
                          hintText: 'Auto-calculated from DOB',
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v?.isEmpty == true) return 'Required';
                          final age = int.tryParse(v!);
                          if (age == null || age < 0 || age > 150) {
                            return 'Enter valid age';
                          }
                          return null;
                        },
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedBloodGroup,
                        decoration: const InputDecoration(
                          labelText: 'Blood Group',
                        ),
                        items:
                            ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']
                                .map(
                                  (bg) => DropdownMenuItem(
                                    value: bg,
                                    child: Text(bg),
                                  ),
                                )
                                .toList(),
                        onChanged: (v) =>
                            setState(() => _selectedBloodGroup = v!),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
              ] else ...[
                AppInfoBanner(
                  message:
                      'No patient selected. Please register a patient first.',
                  tone: AppBannerTone.error,
                  padding: const EdgeInsets.all(14),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => context.push('/patients/register'),
                    icon: const Icon(Icons.person_add, size: 18),
                    label: const Text('Register a new patient'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                'Vitals',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              AppFieldRow(
                children: [
                  TextFormField(
                    controller: _vitalsBPController,
                    decoration: const InputDecoration(
                      labelText: 'BP (mmHg)',
                      hintText: '120/80',
                    ),
                    keyboardType: TextInputType.text,
                  ),
                  TextFormField(
                    controller: _vitalsPulseController,
                    decoration: const InputDecoration(
                      labelText: 'Pulse (bpm)',
                      hintText: '72',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppFieldRow(
                children: [
                  TextFormField(
                    controller: _vitalsTempController,
                    decoration: const InputDecoration(
                      labelText: 'Temp (°F)',
                      hintText: '98.6',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  TextFormField(
                    controller: _vitalsSpO2Controller,
                    decoration: const InputDecoration(
                      labelText: 'SpO2 (%)',
                      hintText: '98',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Department & Doctor',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),

              // Department Dropdown (Dynamic from DB)
              DropdownButtonFormField<String>(
                value: _selectedDepartmentId.isNotEmpty
                    ? _selectedDepartmentId
                    : null,
                decoration: const InputDecoration(labelText: 'Department'),
                items: _departments.map<DropdownMenuItem<String>>((dept) {
                  return DropdownMenuItem<String>(
                    value: dept['id'].toString(),
                    child: Text(dept['name']),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedDepartmentId = val!;
                    _selectedDoctorId = '';
                    _consultationFee = 0;
                    _loadDoctors();
                  });
                },
              ),
              const SizedBox(height: 12),

              // Doctor Dropdown (Dynamic based on Department)
              if (_selectedDepartmentId.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _selectedDoctorId.isNotEmpty
                      ? _selectedDoctorId
                      : null,
                  decoration: const InputDecoration(labelText: 'Doctor'),
                  items: _doctors.map((doc) {
                    final String docId = doc['id'].toString();
                    print('Adding Doctor: $docId - ${doc['name']}');
                    return DropdownMenuItem<String>(
                      value: docId,
                      child: Text(doc['name']),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedDoctorId = val!;
                      _updateFee();
                    });
                  },
                ),

              const SizedBox(height: 12),

              // Consultation Fee (Auto-fetched + Editable)
              TextFormField(
                controller: _feeController,
                decoration: InputDecoration(
                  labelText: 'Consultation Fee (₹)',
                  prefixText: '₹ ',
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (val) {
                  final newFee = double.tryParse(val);
                  if (newFee != null) {
                    setState(() {
                      _consultationFee = newFee;
                    });
                  }
                },
              ),

              const SizedBox(height: 12),

              // Discount Field
              TextFormField(
                controller: _discountController,
                decoration: InputDecoration(
                  labelText: 'Discount (₹)',
                  prefixText: '₹ ',
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (val) {
                  final newDiscount = double.tryParse(val);
                  setState(() {
                    _discount = newDiscount ?? 0;
                  });
                },
              ),

              const SizedBox(height: 8),

              // Amount Summary (Auto-calculated)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF66BB6A)),
                ),
                child: Column(
                  children: [
                    _amountRow('Consultation Fee', _consultationFee),
                    const SizedBox(height: 8),
                    _amountRow('Discount', _discount),
                    const Divider(height: 16, color: Color(0xFFA5D6A7)),
                    _amountRow(
                      'Net Payable',
                      _consultationFee - _discount,
                      bold: true,
                      color: const Color(0xFF2E7D32),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              Text(
                'Payment Details',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _paymentMode,
                decoration: InputDecoration(
                  labelText: 'Payment Mode',
                  prefixIcon: const Icon(Icons.payments_outlined),
                                  ),
                items: _paymentModes
                    .map(
                      (mode) =>
                          DropdownMenuItem(value: mode, child: Text(mode)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _paymentMode = value);
                  }
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Mark as Emergency Case'),
                subtitle: const Text(
                  'Prioritise this patient in the OPD queue',
                ),
                value: _isEmergency,
                onChanged: (val) {
                  setState(() {
                    _isEmergency = val;
                    _updateFee();
                  });
                },
                contentPadding: EdgeInsets.zero,
              ),
              // WhatsApp Marketing opt-in (consent captured at registration).
              SwitchListTile(
                title: const Text('WhatsApp Marketing Opt-In'),
                subtitle: const Text(
                  'Allow promotional/transactional WhatsApp messages to this patient',
                ),
                value: _whatsappOptIn,
                onChanged: (val) {
                  setState(() {
                    _whatsappOptIn = val;
                  });
                },
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.chat_outlined),
              ),
              const SizedBox(height: 16),

              // Personalized tags — per logged-in user, context-aware (opd).
              PersonalizedTagField(
                key: _tagsKey,
                fieldKey: PersonalizedTagFields.opd,
                entityType: PersonalizedTagEntityTypes.opdRegistration,
                label: 'Visit Tags',
                hint: 'e.g. Review, High BP, Insurance...',
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting
                      ? null
                      : () {
                          if (_formKey.currentState?.validate() == true) {
                            _submitOPDRegistration();
                          }
                        },
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Generate Slip'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
