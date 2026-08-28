import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../app/providers.dart';
import '../../../models/personalized_tag_models.dart';
import '../../../services/abdm_service.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/personalized_tag_field.dart';
import '../../widgets/smart_navigation.dart';

enum RegistrationMethod { abha, direct }

enum AdmissionType { opd, ipd }

class PatientRegistrationScreen extends ConsumerStatefulWidget {
  const PatientRegistrationScreen({super.key});

  @override
  ConsumerState<PatientRegistrationScreen> createState() =>
      _PatientRegistrationScreenState();
}

class _PatientRegistrationScreenState
    extends ConsumerState<PatientRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _dobController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _addressController = TextEditingController();
  final _abhaController = TextEditingController();
  final _abhaAddressController = TextEditingController();
  final _phoneSearchController = TextEditingController();

  /// Personalized (AI-flavoured) tag field for this patient.
  final _tagsKey = GlobalKey<PersonalizedTagFieldState>();

  String _selectedGender = 'Male';
  bool _isSubmitting = false;
  bool _isVerifyingAbha = false;
  bool _isAbhaVerified = false;
  bool _hasExistingAbha =
      false; // sub-option within ABHA method (left = I have ABHA ID)
  bool _isSearchingPatient = false;
  bool _isManualEntry = false;
  List<Map<String, dynamic>> _searchResults = [];

  RegistrationMethod _registrationMethod = RegistrationMethod.direct;
  AdmissionType _admissionType = AdmissionType.opd;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _dobController.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _abhaController.dispose();
    _abhaAddressController.dispose();
    _phoneSearchController.dispose();
    super.dispose();
  }

  void _onMobileChanged(String value) {
    // This is kept for the mobile field; phone search has its own field
    debugPrint('Mobile number entered: $value');
  }

  Future<void> _searchPatientByPhone() async {
    final phone = _phoneSearchController.text.trim();
    if (phone.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid 10-digit phone number')),
      );
      return;
    }

    setState(() {
      _isSearchingPatient = true;
      _searchResults = [];
      _isManualEntry = false;
    });

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final results = await dbService.searchPatientByPhone(
        phone,
        hospitalId: authState.hospitalId,
      );

      if (!mounted) return;

      if (results.isEmpty) {
        setState(() {
          _isSearchingPatient = false;
          _isManualEntry = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No existing patient found. Please enter details manually.',
            ),
          ),
        );
      } else if (results.length == 1) {
        setState(() {
          _isSearchingPatient = false;
          _searchResults = results;
        });
        // Show the single result but allow user to select
      } else {
        setState(() {
          _isSearchingPatient = false;
          _searchResults = results;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearchingPatient = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Search failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _selectPatient(Map<String, dynamic> patient) {
    _firstNameController.text = patient['first_name'] as String? ?? '';
    _lastNameController.text = patient['last_name'] as String? ?? '';
    _dobController.text = patient['date_of_birth'] as String? ?? '';
    final gender = patient['gender'] as String?;
    if (gender != null && ['Male', 'Female', 'Other'].contains(gender)) {
      _selectedGender = gender;
    }
    _mobileController.text = patient['mobile_number'] as String? ?? '';
    _addressController.text = patient['address_line1'] as String? ?? '';
    final abhaId = patient['abha_id'] as String?;
    if (abhaId != null && abhaId.isNotEmpty) {
      _abhaController.text = abhaId;
      _abhaAddressController.text = patient['abha_address'] as String? ?? '';
      _registrationMethod = RegistrationMethod.abha;
      _hasExistingAbha = true;
      _isAbhaVerified = true;
    } else {
      _abhaController.clear();
      _abhaAddressController.clear();
      _registrationMethod = RegistrationMethod.direct;
      _hasExistingAbha = false;
      _isAbhaVerified = false;
    }

    final name = '${_firstNameController.text} ${_lastNameController.text}'
        .trim();
    final uhid = patient['uhid'] as String? ?? '';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Selected: $name (UHID: $uhid)'),
        backgroundColor: const Color(0xFF66BB6A),
      ),
    );

    setState(() {
      _searchResults = [];
      _isManualEntry = false;
    });
  }

  void _clearAndEnableManualEntry() {
    _firstNameController.clear();
    _lastNameController.clear();
    _dobController.clear();
    _selectedGender = 'Male';
    _mobileController.clear();
    _emailController.clear();
    _addressController.clear();
    _abhaController.clear();
    _abhaAddressController.clear();
    _registrationMethod = RegistrationMethod.direct;
    _hasExistingAbha = false;
    _isAbhaVerified = false;

    setState(() {
      _isManualEntry = true;
      _searchResults = [];
    });
  }

  String _generateUHID() {
    final now = DateTime.now();
    final prefix = _admissionType == AdmissionType.ipd ? 'IPD' : 'OPD';
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return '$prefix$timestamp';
  }

  Future<void> _verifyAbha() async {
    final abhaId = _abhaController.text.trim();
    if (abhaId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter an ABHA ID')));
      return;
    }

    setState(() => _isVerifyingAbha = true);

    try {
      // Real gateway call (mock mode returns a sandbox fixture automatically).
      final profile = await ref
          .read(abdmServiceProvider)
          .verifyAbhaId(abhaId);

      if (!mounted) return;

      final name = (profile['name'] as String?) ?? '';
      final nameParts = name.trim().split(' ');
      final gender = (profile['gender'] as String?)?.toUpperCase();

      if (name.isNotEmpty) {
        _firstNameController.text = nameParts.first;
        _lastNameController.text = nameParts.length > 1
            ? nameParts.sublist(1).join(' ')
            : '';
      }
      if ((profile['dateOfBirth'] as String?)?.isNotEmpty == true) {
        _dobController.text = profile['dateOfBirth'] as String;
      }
      _selectedGender = switch (gender) {
        'F' => 'Female',
        'O' => 'Other',
        _ => _selectedGender,
      };
      if ((profile['mobileNumber'] as String?)?.isNotEmpty == true &&
          _mobileController.text.isEmpty) {
        _mobileController.text = profile['mobileNumber'] as String;
      }
      _abhaAddressController.text =
          (profile['abhaAddress'] as String?) ?? '';
      _isAbhaVerified = true;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ABHA verified! Details auto-filled.'),
          backgroundColor: Color(0xFF66BB6A),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ABHA verification failed: ${e is AbdmException ? e.message : e}',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isVerifyingAbha = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Patient Registration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => _showHelpDialog(context),
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
              // Phone Search — at the very top
              _buildPhoneSearchSection(theme),
              const SizedBox(height: 16),

              // "New Patient? Click here to enter details manually" link
              GestureDetector(
                onTap: _clearAndEnableManualEntry,
                child: Text(
                  'New Patient? Click here to enter details manually',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),

              _buildRegistrationMethodSelector(theme),
              const SizedBox(height: 16),

              if (_registrationMethod == RegistrationMethod.abha) ...[
                // Sub-option: Has existing ABHA or needs to create one
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ABHA Option',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: true,
                            label: Text('I have ABHA ID'),
                            icon: Icon(Icons.fingerprint, size: 18),
                          ),
                          ButtonSegment(
                            value: false,
                            label: Text('Create via Aadhaar/DL'),
                            icon: Icon(Icons.add_card, size: 18),
                          ),
                        ],
                        selected: {_hasExistingAbha},
                        onSelectionChanged: (selection) {
                          setState(() => _hasExistingAbha = selection.first);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_hasExistingAbha) ...[
                  // Create ABHA option — navigate to ABHA create screen
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.add_circle_outline,
                                color: theme.colorScheme.onSecondaryContainer,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Create new ABHA Health ID using Aadhaar Card or Driving Licence',
                                  style: TextStyle(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                // Navigate to ABHA create screen; on return, if
                                // ABHA was created, populate the ABHA fields here.
                                final result = await context.push<Map<String, dynamic>>(
                                  '/abha/create',
                                );
                                if (result != null && mounted) {
                                  _abhaController.text =
                                      (result['abhaId'] as String?) ??
                                      (result['abhaNumber'] as String?) ??
                                      '';
                                  _abhaAddressController.text =
                                      (result['abhaAddress'] as String?) ?? '';
                                  _isAbhaVerified = true;
                                  setState(() => _hasExistingAbha = false);
                                }
                              },
                              icon: const Icon(Icons.arrow_forward, size: 18),
                              label: const Text('Proceed to Create ABHA'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _abhaController,
                          decoration: InputDecoration(
                            labelText: 'ABHA ID',
                            hintText: 'Enter 14-digit ABHA ID',
                            prefixIcon: const Icon(Icons.fingerprint),
                          ),
                          keyboardType: TextInputType.text,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _isVerifyingAbha ? null : _verifyAbha,
                          icon: _isVerifyingAbha
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.verified_user, size: 18),
                          label: Text(
                            _isVerifyingAbha ? 'Verifying...' : 'Verify',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _abhaAddressController,
                    decoration: const InputDecoration(
                      labelText: 'ABHA Address',
                      hintText: 'Auto-filled after verification (e.g. rahul9012@abdm)',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ],

              _buildAdmissionTypeSelector(theme),
              const Divider(height: 32),

              // Mobile Number — important identification key, placed at top
              TextFormField(
                controller: _mobileController,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: 'Mobile Number *',
                  hintText: 'Enter 10-digit mobile number',
                  prefixText: '+91 ',
                  counterText: '',
                ),
                onChanged: _onMobileChanged,
              ),
              const SizedBox(height: 16),

              AppFieldRow(
                children: [
                  TextFormField(
                    controller: _firstNameController,
                    decoration: const InputDecoration(
                      labelText: 'First Name *',
                    ),
                    validator:
                        _registrationMethod == RegistrationMethod.direct
                        ? (v) => v?.isEmpty == true ? 'Required' : null
                        : null,
                  ),
                  TextFormField(
                    controller: _lastNameController,
                    decoration: const InputDecoration(
                      labelText: 'Last Name *',
                    ),
                    validator:
                        _registrationMethod == RegistrationMethod.direct
                        ? (v) => v?.isEmpty == true ? 'Required' : null
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _dobController,
                decoration: const InputDecoration(
                  labelText: 'Date of Birth',
                  suffixIcon: Icon(Icons.calendar_today),
                ),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now().subtract(
                      const Duration(days: 365 * 30),
                    ),
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) {
                    _dobController.text = date.toDateString;
                  }
                },
                readOnly: true,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedGender,
                decoration: const InputDecoration(labelText: 'Gender'),
                items: ['Male', 'Female', 'Other']
                    .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                    .toList(),
                onChanged: (v) => setState(() => _selectedGender = v!),
              ),
              const SizedBox(height: 16),

              // Email field
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) {
                  if (v?.isNotEmpty == true && !v!.contains('@')) {
                    return 'Invalid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Address field
              TextFormField(
                controller: _addressController,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Address'),
              ),
              const SizedBox(height: 20),

              // Personalized tags — stored per logged-in user, not per hospital.
              PersonalizedTagField(
                key: _tagsKey,
                fieldKey: PersonalizedTagFields.patient,
                entityType: PersonalizedTagEntityTypes.patient,
                label: 'Patient Tags',
                hint: 'e.g. VIP, Diabetic, Follow-up...',
              ),
              const SizedBox(height: 24),

              // Submit button
              AppSubmitButton(
                label: 'Submit',
                loading: _isSubmitting,
                onPressed: _submitForm,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  bool validateStep() {
    // Validate all fields (single step form)
    if (_registrationMethod == RegistrationMethod.abha && !_isAbhaVerified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please verify your ABHA ID first')),
      );
      return false;
    }
    if (_registrationMethod == RegistrationMethod.direct) {
      if (_firstNameController.text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('First Name is required')));
        return false;
      }
      if (_lastNameController.text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Last Name is required')));
        return false;
      }
    }
    if (_mobileController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mobile Number is required')),
      );
      return false;
    }
    if (_mobileController.text.trim().length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter valid 10-digit mobile number')),
      );
      return false;
    }
    if (_emailController.text.trim().isNotEmpty &&
        !_emailController.text.trim().contains('@')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid email address')));
      return false;
    }
    return true;
  }

  void _submitForm() {
    if (!validateStep()) return;
    _submitRegistration();
  }

  Widget _buildRegistrationMethodSelector(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select Registration Method',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<RegistrationMethod>(
            segments: const [
              ButtonSegment(
                value: RegistrationMethod.direct,
                label: Text('Direct'),
                icon: Icon(Icons.edit_note, size: 18),
              ),
              ButtonSegment(
                value: RegistrationMethod.abha,
                label: Text('ABHA'),
                icon: Icon(Icons.fingerprint, size: 18),
              ),
            ],
            selected: {_registrationMethod},
            onSelectionChanged: (selection) {
              setState(() {
                _registrationMethod = selection.first;
                _isAbhaVerified = false;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAdmissionTypeSelector(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select Admission Type',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<AdmissionType>(
            segments: const [
              ButtonSegment(
                value: AdmissionType.opd,
                label: Text('OPD'),
                icon: Icon(Icons.local_hospital_outlined, size: 18),
              ),
              ButtonSegment(
                value: AdmissionType.ipd,
                label: Text('IPD'),
                icon: Icon(Icons.local_hotel_outlined, size: 18),
              ),
            ],
            selected: {_admissionType},
            onSelectionChanged: (selection) {
              setState(() => _admissionType = selection.first);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPhoneSearchSection(ThemeData theme) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.search, color: Color(0xFF1565C0)),
                const SizedBox(width: 8),
                Text(
                  'Search Existing Patient',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _phoneSearchController,
                    keyboardType: TextInputType.phone,
                    maxLength: 10,
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      hintText: 'Enter 10-digit number',
                      prefixText: '+91 ',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _isSearchingPatient
                        ? null
                        : _searchPatientByPhone,
                    icon: _isSearchingPatient
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search, size: 18),
                    label: Text(
                      _isSearchingPatient ? 'Searching...' : 'Search',
                    ),
                  ),
                ),
              ],
            ),
            if (_searchResults.isNotEmpty || _isManualEntry) ...[
              const SizedBox(height: 12),
              _buildSearchResults(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(ThemeData theme) {
    if (_isManualEntry) {
      return const AppInfoBanner(
        message:
            'No patient found with this number. You can enter details manually below.',
        tone: AppBannerTone.warning,
      );
    }

    if (_searchResults.length == 1) {
      final patient = _searchResults.first;
      final name =
          '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
      final uhid = patient['uhid'] as String? ?? '';

      return AppSectionCard(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.person,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'UHID: $uhid',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _selectPatient(patient),
                icon: const Icon(Icons.check_circle, size: 18),
                label: const Text('Select This Patient'),
              ),
            ),
          ],
        ),
      );
    }

    // Multiple results
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_searchResults.length} patients found. Select one:',
          style: TextStyle(fontSize: 13, color: Colors.grey[700]),
        ),
        const SizedBox(height: 8),
        ..._searchResults.map((patient) {
          final name =
              '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'
                  .trim();
          final uhid = patient['uhid'] as String? ?? '';

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.person,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              title: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('UHID: $uhid'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => _selectPatient(patient),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _submitRegistration() async {
    if (_registrationMethod == RegistrationMethod.direct &&
        _firstNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('First Name is required')));
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final uhid = _generateUHID();

      final patientData = <String, dynamic>{
        'hospital_id': authState.hospitalId,
        'uhid': uhid,
        'first_name': _firstNameController.text.trim(),
        'last_name': _lastNameController.text.trim(),
        'date_of_birth': _dobController.text.isNotEmpty
            ? _dobController.text
            : null,
        'gender': _selectedGender,
        'mobile_number': _mobileController.text.trim(),
        'email': _emailController.text.trim(),
        'address_line1': _addressController.text.trim(),
        'registration_date': DateTime.now().toDateString,
        'registration_method': _registrationMethod.name,
        'admission_type': _admissionType.name,
      };

      final abhaId = _abhaController.text.trim();
      final abhaAddress = _abhaAddressController.text.trim();

      if (_registrationMethod == RegistrationMethod.abha) {
        patientData['abha_id'] = abhaId;
        patientData['abha_address'] = abhaAddress.isEmpty ? null : abhaAddress;
        patientData['abha_linked'] = true;
      }

      final result = await dbService.registerPatient(patientData);

      if (!mounted) return;

      // Invalidate patient list provider to refresh the list
      ref.invalidate(patientListProvider);

      final patientId = result['id'] as String;

      // ---------------------------------------------------------------------
      // Personalized tags — store per logged-in user (best-effort; a tag
      // failure must never block the patient registration).
      // ---------------------------------------------------------------------
      final patientTags = _tagsKey.currentState?.selectedTags ?? const <String>[];
      if (patientTags.isNotEmpty) {
        try {
          final userId = await dbService.getCurrentUsersTableId();
          if (userId != null) {
            await ref.read(personalizedTagServiceProvider).setEntityTags(
              userId: userId,
              fieldKey: PersonalizedTagFields.patient,
              entityType: PersonalizedTagEntityTypes.patient,
              entityId: patientId,
              names: patientTags,
            );
          }
        } catch (e) {
          debugPrint('Patient tags save failed (non-blocking): $e');
        }
      }

      // ---------------------------------------------------------------------
      // ABDM (M1 + M2): persist ABHA profile and link the first care context
      // for this OPD/IPD registration. These are best-effort so a gateway
      // hiccup never blocks the hospital registration.
      // ---------------------------------------------------------------------
      if (_registrationMethod == RegistrationMethod.abha && abhaId.isNotEmpty) {
        final abdm = ref.read(abdmServiceProvider);
        try {
          await abdm.upsertAbhaProfile(
            patientId: patientId,
            abhaId: abhaId,
            abhaAddress: abhaAddress.isEmpty ? null : abhaAddress,
            isVerified: true,
          );
        } catch (e) {
          debugPrint('ABHA profile save failed: $e');
        }

        try {
          final recordType =
              _admissionType == AdmissionType.ipd ? 'ipd_admission' : 'opd_visit';
          await abdm.linkCareContext(
            abhaId: abhaId,
            careContextId: abdm.buildCareContextId(
              recordType: recordType,
              recordId: patientId,
            ),
            patientId: patientId,
            recordType: recordType,
            recordId: patientId,
            display: '$recordType $uhid',
          );
        } catch (e) {
          debugPrint('Care context link failed (non-blocking): $e');
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Patient registered! UHID: $uhid'),
          backgroundColor: const Color(0xFF66BB6A),
        ),
      );

      final fullName =
          '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}';

      if (_admissionType == AdmissionType.ipd) {
        context.go('/ipd/admit?patientId=$patientId');
      } else {
        context.goNamed(
          'opd-register',
          queryParameters: {
            'patientId': patientId,
            'uhid': uhid,
            'patientName': fullName,
          },
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Registration failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Registration Help'),
        content: const Text(
          'Choose registration method (ABHA or Manual) and admission type (OPD or IPD).\n\n'
          'Fill in patient details, contact information, and address, then submit.\n\n'
          'For IPD admissions, you will be redirected to the bed allocation screen after submission.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
