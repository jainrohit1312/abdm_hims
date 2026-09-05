import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../services/abdm_service.dart';
import '../../widgets/smart_navigation.dart';

/// M1 – ABHA creation via the Aadhaar OTP flow.
///
/// Flow: Aadhaar number -> generate OTP -> verify OTP -> pre-fill KYC ->
/// create ABHA Health ID -> show ABHA number + ABHA address. The result is
/// returned to the calling screen via `Navigator.pop` so patient registration
/// can consume the freshly created ABHA.
class ABHACreateScreen extends ConsumerStatefulWidget {
  const ABHACreateScreen({super.key});

  @override
  ConsumerState<ABHACreateScreen> createState() => _ABHACreateScreenState();
}

class _ABHACreateScreenState extends ConsumerState<ABHACreateScreen> {
  final _aadhaarController = TextEditingController();
  final _otpController = TextEditingController();
  final _nameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _preferredAbhaAddressController = TextEditingController();

  int _currentStep = 0;
  bool _consentGiven = false;
  bool _isDrivingLicenceMode = false;

  bool _isGeneratingOtp = false;
  bool _isVerifyingOtp = false;
  bool _isCreating = false;

  String? _txnId;
  String? _aadhaarLastFour;
  String? _error;
  String _selectedGender = 'Male';

  AbdmM1Profile? _createdProfile;

  /// Exact consent wording shown to the patient. It describes ABHA
  /// creation/verification only — it must NOT claim general health-record
  /// sharing consent.
  static const String _consentText =
      'I consent to the creation of an ABHA (Ayushman Bharat Health Account) '
      'using my Aadhaar e-KYC details for identification. I understand that '
      'an OTP will be used to verify my Aadhaar and that my ABHA number and '
      'ABHA address will be created in the ABDM Sandbox. This consent is '
      'limited to ABHA creation/verification and does not authorise sharing '
      'of my health records.';
  static const String _consentVersion = '1.0';

  @override
  void dispose() {
    _aadhaarController.dispose();
    _otpController.dispose();
    _nameController.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _preferredAbhaAddressController.dispose();
    super.dispose();
  }

  AbdmService get _abdm => ref.read(abdmServiceProvider);

  void _clearSensitiveFields() {
    _otpController.clear();
    if (_currentStep >= 3) {
      _aadhaarController.clear();
    }
  }

  Future<void> _generateOtp() async {
    if (_isDrivingLicenceMode) {
      _showSnack(
        'Driving Licence mode is not available in ABDM sandbox yet. Please use Aadhaar.',
        isError: true,
      );
      return;
    }

    final aadhaar = _aadhaarController.text.trim();
    if (!RegExp(r'^\d{12}$').hasMatch(aadhaar)) {
      _showSnack('Enter a valid 12-digit Aadhaar number', isError: true);
      return;
    }

    setState(() {
      _isGeneratingOtp = true;
      _error = null;
    });

    try {
      final txn = await _abdm.generateAadhaarOtp(aadhaar);
      if (!mounted) return;
      setState(() {
        _txnId = txn.txnId;
        // SECURITY: the final four Aadhaar digits are shown only as a
        // reference for the Aadhaar itself — never presented as a masked
        // mobile number.
        _aadhaarLastFour = aadhaar.substring(aadhaar.length - 4);
        _currentStep = 1;
        _isGeneratingOtp = false;
      });
      _showSnack('OTP sent to the mobile linked with this Aadhaar');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isGeneratingOtp = false;
        _error = e is AbdmException ? e.message : e.toString();
      });
      _showSnack(_error!, isError: true);
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
      _showSnack('Enter the 6-digit OTP', isError: true);
      return;
    }
    final txnId = _txnId;
    if (txnId == null || txnId.isEmpty) {
      _showSnack(
        'Transaction id missing. Please generate OTP again.',
        isError: true,
      );
      return;
    }

    setState(() {
      _isVerifyingOtp = true;
      _error = null;
    });

    try {
      final kyc = await _abdm.verifyAadhaarOtp(txnId: txnId, otp: otp);
      if (!mounted) return;

      final name = kyc.displayName;
      if (_nameController.text.isEmpty) {
        _nameController.text = name;
      }
      if (_mobileController.text.isEmpty) {
        _mobileController.text = kyc.mobileNumber ?? '';
      }
      final gender = kyc.gender?.toUpperCase();
      _selectedGender = switch (gender) {
        'F' => 'Female',
        'O' => 'Other',
        _ => 'Male',
      };

      setState(() {
        _currentStep = 2;
        _isVerifyingOtp = false;
      });
      _clearSensitiveFields();
      _showSnack('OTP verified. Please review your details.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isVerifyingOtp = false;
        _error = e is AbdmException ? e.message : e.toString();
      });
      _showSnack(_error!, isError: true);
    }
  }

  Future<void> _createAbha() async {
    if (_nameController.text.trim().isEmpty) {
      _showSnack('Name is required', isError: true);
      return;
    }
    if (!_consentGiven) {
      _showSnack(
        'Consent is required to create an ABHA Health ID',
        isError: true,
      );
      return;
    }

    setState(() {
      _isCreating = true;
      _error = null;
    });

    try {
      // Non-sensitive consent evidence for the M1 operation. Best-effort so a
      // local audit write can never block the ABDM flow.
      final txnId = _txnId;
      if (txnId != null && txnId.isNotEmpty) {
        await _abdm.recordAbhaConsentEvidence(
          purpose: 'ABHA_CREATION',
          consentText: _consentText,
          consentVersion: _consentVersion,
          abdmTransactionId: txnId,
        );
      }

      final profile = await _abdm.createAbhaId(
        txnId: _txnId!,
        preferredAbhaAddress: _preferredAbhaAddressController.text.trim(),
        email: _emailController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _createdProfile = profile;
        _currentStep = 3;
        _isCreating = false;
      });
      _clearSensitiveFields();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCreating = false;
        _error = e is AbdmException ? e.message : e.toString();
      });
      _showSnack(_error!, isError: true);
    }
  }

  Future<void> _downloadCard() async {
    final address = _createdProfile?.abhaAddress;
    if (address == null || address.isEmpty) {
      _showSnack('ABHA address not found in profile', isError: true);
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
      if (!mounted) return;
      _showSnack(
        e is AbdmException ? e.message : 'Card download failed',
        isError: true,
      );
    }
  }

  void _useForRegistration() {
    final profile = _createdProfile;
    if (profile == null) return;
    context.pop({
      'abhaId': profile.healthId,
      'abhaNumber': profile.abhaNumber,
      'abhaAddress': profile.abhaAddress,
      'name': profile.displayName.isEmpty
          ? _nameController.text.trim()
          : profile.displayName,
      'mobile': profile.mobileNumber ?? _mobileController.text.trim(),
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Create ABHA Health ID')),
      body: Column(
        children: [
          if (_abdm.isMockMode)
            Container(
              width: double.infinity,
              color: theme.colorScheme.tertiaryContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                'Mock/demo mode — ABHA results are simulated and are not a '
                'live ABDM verification.',
                style: TextStyle(
                  color: theme.colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Expanded(
            child: Stepper(
              currentStep: _currentStep,
              onStepContinue: () async {
                switch (_currentStep) {
                  case 0:
                    await _generateOtp();
                    break;
                  case 1:
                    await _verifyOtp();
                    break;
                  case 2:
                    await _createAbha();
                    break;
                }
              },
              onStepCancel: () {
                if (_currentStep > 0) setState(() => _currentStep--);
              },
              controlsBuilder: (context, details) {
                final isBusy =
                    _isGeneratingOtp || _isVerifyingOtp || _isCreating;
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      ElevatedButton(
                        onPressed: isBusy ? null : details.onStepContinue,
                        child: isBusy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_stepActionLabel),
                      ),
                      if (_currentStep > 0 && _currentStep < 3) ...[
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: isBusy ? null : details.onStepCancel,
                          child: const Text('Back'),
                        ),
                      ],
                    ],
                  ),
                );
              },
              steps: [
                Step(
                  title: const Text('Aadhaar Verification'),
                  isActive: _currentStep >= 0,
                  state: _currentStep > 0
                      ? StepState.complete
                      : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildModeToggle(theme),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _aadhaarController,
                        keyboardType: TextInputType.number,
                        maxLength: 12,
                        decoration: InputDecoration(
                          labelText: _isDrivingLicenceMode
                              ? 'Driving Licence Number'
                              : 'Aadhaar Number',
                          hintText: _isDrivingLicenceMode
                              ? 'Enter Driving Licence number'
                              : 'Enter 12-digit Aadhaar number',
                          counterText: '',
                          prefixIcon: Icon(
                            _isDrivingLicenceMode
                                ? Icons.badge
                                : Icons.credit_card,
                          ),
                        ),
                      ),
                      if (_aadhaarLastFour != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Aadhaar ending $_aadhaarLastFour · OTP is sent to the '
                          'mobile number linked with this Aadhaar.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                Step(
                  title: const Text('OTP Verification'),
                  isActive: _currentStep >= 1,
                  state: _currentStep > 1
                      ? StepState.complete
                      : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Enter the OTP sent to your Aadhaar-linked mobile number.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _otpController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'OTP',
                          hintText: 'Enter 6-digit OTP',
                          counterText: '',
                          prefixIcon: Icon(Icons.security),
                        ),
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('Personal Details'),
                  isActive: _currentStep >= 2,
                  state: _currentStep > 2
                      ? StepState.complete
                      : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Full Name (as per Aadhaar)',
                          prefixIcon: Icon(Icons.person),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _mobileController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Mobile Number',
                          prefixIcon: Icon(Icons.phone),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedGender,
                        decoration: const InputDecoration(labelText: 'Gender'),
                        items: ['Male', 'Female', 'Other']
                            .map(
                              (g) => DropdownMenuItem(value: g, child: Text(g)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _selectedGender = v!),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _preferredAbhaAddressController,
                        decoration: const InputDecoration(
                          labelText: 'Preferred ABHA Address (optional)',
                          hintText: 'e.g. rahul9012@abdm',
                          prefixIcon: Icon(Icons.alternate_email),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email (optional)',
                          prefixIcon: Icon(Icons.email),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Card(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ABHA Consent',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'This consent is limited to ABHA creation/verification '
                                'using Aadhaar e-KYC. It does not authorise sharing '
                                'of your health records through ABDM.',
                              ),
                            ],
                          ),
                        ),
                      ),
                      CheckboxListTile(
                        title: const Text(
                          'I consent to the creation of ABHA Health ID',
                        ),
                        value: _consentGiven,
                        onChanged: (v) => setState(() => _consentGiven = v!),
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('Confirmation'),
                  isActive: _currentStep >= 3,
                  content: Column(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        size: 64,
                        color: Colors.green,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'ABHA Health ID Created!',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_createdProfile != null)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.green),
                          ),
                          child: Column(
                            children: [
                              const Text('Your ABHA Number:'),
                              const SizedBox(height: 4),
                              Text(
                                _createdProfile!.abhaNumber ?? '-',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text('ABHA Address:'),
                              const SizedBox(height: 4),
                              Text(
                                _createdProfile!.abhaAddress ?? '-',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_abdm.isMockMode) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Mock/demo result — not a live ABDM verification.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        onPressed: _downloadCard,
                        icon: const Icon(Icons.download),
                        label: const Text('Download ABHA Card'),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _useForRegistration,
                        child: const Text('Use this ABHA for Registration'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _stepActionLabel {
    switch (_currentStep) {
      case 0:
        return 'Generate OTP';
      case 1:
        return 'Verify OTP';
      case 2:
        return 'Create ABHA';
      default:
        return 'Done';
    }
  }

  Widget _buildModeToggle(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        children: [
          Expanded(
            child: _modeSegment(
              label: 'Aadhaar',
              selected: !_isDrivingLicenceMode,
              onTap: () => setState(() => _isDrivingLicenceMode = false),
            ),
          ),
          Expanded(
            child: _modeSegment(
              label: 'Driving Licence',
              selected: _isDrivingLicenceMode,
              onTap: () => setState(() => _isDrivingLicenceMode = true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSegment({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.white,
          ),
        ),
      ),
    );
  }
}
