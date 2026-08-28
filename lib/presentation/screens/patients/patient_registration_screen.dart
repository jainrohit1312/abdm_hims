import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../app/providers.dart';
import '../../../services/abdm_service.dart';
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
                    color: Colors.blue[700],
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
                    const Text(
                      'ABHA Option',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.grey[200],
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'I have ABHA ID',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Switch(
                            value: _hasExistingAbha,
                            onChanged: (val) {
                              setState(() => _hasExistingAbha = val);
                            },
                            activeTrackColor: Colors.blue,
                            inactiveTrackColor: Colors.blue,
                            thumbColor: WidgetStateProperty.all(Colors.white),
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Create via Aadhaar/DL',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: Colors.black,
                            ),
                          ),
                        ],
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

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstNameController,
                      decoration: const InputDecoration(
                        labelText: 'First Name *',
                      ),
                      validator:
                          _registrationMethod == RegistrationMethod.direct
                          ? (v) => v?.isEmpty == true ? 'Required' : null
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lastNameController,
                      decoration: const InputDecoration(
                        labelText: 'Last Name *',
                      ),
                      validator:
                          _registrationMethod == RegistrationMethod.direct
                          ? (v) => v?.isEmpty == true ? 'Required' : null
                          : null,
                    ),
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
              const SizedBox(height: 24),

              // Submit button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitForm,
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Submit',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
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
    final isAbha = _registrationMethod == RegistrationMethod.abha;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select Registration Method',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Colors.grey[200],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Direct',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: isAbha,
                onChanged: (val) {
                  setState(() {
                    _registrationMethod = val
                        ? RegistrationMethod.abha
                        : RegistrationMethod.direct;
                    _isAbhaVerified = false;
                  });
                },
                activeTrackColor: Colors.blue,
                inactiveTrackColor: Colors.blue,
                thumbColor: WidgetStateProperty.all(Colors.white),
              ),
              const SizedBox(width: 12),
              const Text(
                'ABHA',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdmissionTypeSelector(ThemeData theme) {
    final isIpd = _admissionType == AdmissionType.ipd;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select Admission Type',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Colors.grey[200],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'OPD',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: isIpd,
                onChanged: (val) {
                  setState(() {
                    _admissionType = val
                        ? AdmissionType.ipd
                        : AdmissionType.opd;
                  });
                },
                activeTrackColor: Colors.green,
                inactiveTrackColor: Colors.green,
                thumbColor: WidgetStateProperty.all(Colors.white),
              ),
              const SizedBox(width: 12),
              const Text(
                'IPD',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.black,
                ),
              ),
            ],
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
                      border: OutlineInputBorder(),
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
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange[200]!),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange[700], size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No patient found with this number. You can enter details manually below.',
                style: TextStyle(color: Colors.orange[800], fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    if (_searchResults.length == 1) {
      final patient = _searchResults.first;
      final name =
          '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
      final uhid = patient['uhid'] as String? ?? '';

      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue[50],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue[200]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person, color: Colors.blue[700], size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: Colors.blue[900],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'UHID: $uhid',
              style: TextStyle(fontSize: 13, color: Colors.blue[700]),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _selectPatient(patient),
                icon: const Icon(Icons.check_circle, size: 18),
                label: const Text('Select This Patient'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue[700],
                  foregroundColor: Colors.white,
                ),
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
                backgroundColor: Colors.blue[100],
                child: Icon(Icons.person, color: Colors.blue[700]),
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
