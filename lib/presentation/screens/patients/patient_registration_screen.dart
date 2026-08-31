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

/// Family relationship labels offered during registration and tagging.
/// The order is also used for the family-tree grouping.
const List<String> kFamilyRelationships = [
  'Self',
  'Father',
  'Mother',
  'Wife',
  'Husband',
  'Son',
  'Daughter',
  'Brother',
  'Sister',
  'Grandfather',
  'Grandmother',
  'Grandson',
  'Granddaughter',
  'Other',
];

/// Sentinel returned by the relationship tagging sheet to clear a tag.
const String _kClearRelationship = '__clear_relationship__';

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

  /// Personalized (AI-flavoured) tag field for this patient.
  final _tagsKey = GlobalKey<PersonalizedTagFieldState>();

  String _selectedGender = 'Male';
  bool _isSubmitting = false;
  bool _isVerifyingAbha = false;
  bool _isAbhaVerified = false;
  bool _hasExistingAbha =
      false; // sub-option within ABHA method (left = I have ABHA ID)

  // ---------------------------------------------------------------------------
  // Mobile verification + family linking state (Step 1)
  // ---------------------------------------------------------------------------
  bool _isVerifyingMobile = false;

  /// The 10-digit number that was successfully verified in Step 1. Until this
  /// is set the registration form stays hidden.
  String? _verifiedMobile;

  /// All patients sharing [_verifiedMobile] (the family group).
  List<Map<String, dynamic>> _familyMembers = [];

  /// Whether the registration form is currently expanded.
  bool _showRegistrationForm = false;

  /// Relationship selected for the patient being registered.
  String? _selectedRelationship;

  RegistrationMethod _registrationMethod = RegistrationMethod.direct;
  AdmissionType _admissionType = AdmissionType.opd;

  bool get _hasFamily => _familyMembers.isNotEmpty;

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
    super.dispose();
  }

  /// Invalidates the verification whenever the user edits the mobile number so
  /// the registration form always matches the verified number.
  void _onMobileChanged(String value) {
    final trimmed = value.trim();
    if (_verifiedMobile != null && trimmed != _verifiedMobile) {
      setState(() {
        _verifiedMobile = null;
        _familyMembers = [];
        _showRegistrationForm = false;
        _selectedRelationship = null;
      });
    }
  }

  Future<void> _verifyMobileNumber({bool silent = false}) async {
    final phone = _mobileController.text.trim();
    if (phone.length != 10) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid 10-digit mobile number')),
        );
      }
      return;
    }

    setState(() {
      _isVerifyingMobile = true;
      _familyMembers = [];
      _showRegistrationForm = false;
    });

    try {
      final dbService = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final results = await dbService.searchPatientByPhone(
        phone,
        hospitalId: authState.hospitalId,
      );

      if (!mounted) return;

      setState(() {
        _isVerifyingMobile = false;
        _verifiedMobile = phone;
        _familyMembers = results;
        // No existing patient → straight to the registration form. Existing
        // family → show the family panel first; the user can then choose to
        // register another family member.
        _showRegistrationForm = results.isEmpty;
        _selectedRelationship = results.isEmpty ? 'Self' : null;
      });

      if (!silent) {
        final message = results.isEmpty
            ? 'No existing patient found. Please register below.'
            : '${results.length} family member${results.length == 1 ? '' : 's'} found for +91 $phone.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: results.isEmpty
                ? Theme.of(context).colorScheme.tertiary
                : const Color(0xFF66BB6A),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isVerifyingMobile = false;
        _verifiedMobile = null;
        _familyMembers = [];
      });
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verification failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _clearVerification() {
    setState(() {
      _verifiedMobile = null;
      _familyMembers = [];
      _showRegistrationForm = false;
      _selectedRelationship = null;
      _isVerifyingMobile = false;
    });
  }

  /// Expands the registration form so a new member can be added to the
  /// currently verified family (the mobile number stays inherited from Step 1).
  void _startFamilyMemberRegistration() {
    setState(() {
      _showRegistrationForm = true;
      _selectedRelationship = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Family helpers
  // ---------------------------------------------------------------------------

  String _relationshipOf(Map<String, dynamic> patient) {
    final tag = patient['family_relationship']?.toString().trim();
    if (tag != null && tag.isNotEmpty) return tag;
    return _familyMembers.length == 1 ? 'Self' : 'Member';
  }

  IconData _relationshipIcon(String relationship) {
    return switch (relationship) {
      'Father' => Icons.man,
      'Mother' => Icons.woman,
      'Son' => Icons.boy,
      'Daughter' => Icons.girl,
      'Wife' => Icons.favorite,
      'Husband' => Icons.favorite,
      'Brother' || 'Sister' => Icons.group,
      'Grandfather' || 'Grandmother' => Icons.elderly,
      'Grandson' || 'Granddaughter' => Icons.child_care,
      'Other' => Icons.person_outline,
      'Member' => Icons.person_outline,
      _ => Icons.person,
    };
  }

  /// Family members grouped by relationship for the family-tree view. Groups
  /// are ordered by [kFamilyRelationships]; untagged members sink to the end.
  List<MapEntry<String, List<Map<String, dynamic>>>> _groupedFamilyMembers() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final member in _familyMembers) {
      final relationship = _relationshipOf(member);
      (grouped[relationship] ??= []).add(member);
    }

    final order = <String>[...kFamilyRelationships, 'Member'];
    final entries = grouped.entries.toList()
      ..sort((a, b) {
        final ai = order.indexOf(a.key);
        final bi = order.indexOf(b.key);
        final aiNorm = ai < 0 ? order.length : ai;
        final biNorm = bi < 0 ? order.length : bi;
        return aiNorm.compareTo(biNorm);
      });
    return entries;
  }

  void _openPatientProfile(Map<String, dynamic> patient) {
    final id = patient['id']?.toString();
    if (id == null || id.isEmpty) return;
    context.push('/patients/$id');
  }

  /// Bottom sheet that lets the user tag (or clear) the relationship of an
  /// existing family member.
  Future<void> _tagFamilyMember(Map<String, dynamic> patient) async {
    final patientId = patient['id']?.toString();
    if (patientId == null || patientId.isEmpty) return;

    final current = _relationshipOf(patient);

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tag Family Relationship',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'
                      .trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final relationship in kFamilyRelationships)
                      ChoiceChip(
                        label: Text(relationship),
                        selected: relationship == current,
                        avatar: Icon(_relationshipIcon(relationship), size: 16),
                        onSelected: (_) =>
                            Navigator.pop(sheetContext, relationship),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () =>
                        Navigator.pop(sheetContext, _kClearRelationship),
                    icon: const Icon(Icons.clear, size: 16),
                    label: const Text('Clear tag'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selected == null || !mounted) return;

    final relationship = selected == _kClearRelationship ? null : selected;

    try {
      await ref
          .read(databaseServiceProvider)
          .updatePatientFamilyRelationship(patientId, relationship);
      if (!mounted) return;
      setState(() {
        _familyMembers = [
          for (final member in _familyMembers)
            if (member['id']?.toString() == patientId)
              {...member, 'family_relationship': relationship}
            else
              member,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            relationship == null
                ? 'Relationship tag cleared'
                : 'Tagged as $relationship',
          ),
          backgroundColor: const Color(0xFF66BB6A),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not update relationship: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
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
      final profile = await ref.read(abdmServiceProvider).verifyAbhaId(abhaId);

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
      _abhaAddressController.text = (profile['abhaAddress'] as String?) ?? '';
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
              // Step 1 — single mobile number field with Verify button.
              _buildMobileVerificationCard(theme),

              if (_verifiedMobile != null) ...[
                const SizedBox(height: 16),

                // Step 2 — family members sharing the verified number.
                if (_hasFamily) ...[
                  _buildFamilySection(theme),
                  const SizedBox(height: 16),
                ] else ...[
                  const AppInfoBanner(
                    message:
                        'No patient found with this mobile number. Fill in the '
                        'details below to register a new patient.',
                    tone: AppBannerTone.info,
                    icon: Icons.person_add_alt,
                  ),
                  const SizedBox(height: 16),
                ],

                // Step 3 — registration form (auto-shown when no family exists,
                // or after tapping "Register New Family Member").
                if (_showRegistrationForm) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  _buildRegistrationFormHeader(theme),
                  const SizedBox(height: 16),
                  _buildRegistrationForm(theme),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 1 — Mobile verification card
  // ---------------------------------------------------------------------------
  Widget _buildMobileVerificationCard(ThemeData theme) {
    final isVerified = _verifiedMobile != null;

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
                const Icon(Icons.phone_android, color: Color(0xFF1565C0)),
                const SizedBox(width: 8),
                Text(
                  'Step 1: Verify Mobile Number',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '•  Enter mobile number to search for an existing patient or register a new patient.\n'
              '•  Family members linked to the number will also be shown.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
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
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: (_isVerifyingMobile || isVerified)
                        ? null
                        : _verifyMobileNumber,
                    icon: _isVerifyingMobile
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user, size: 18),
                    label: Text(_isVerifyingMobile ? 'Verifying...' : 'Verify'),
                  ),
                ),
              ],
            ),
            if (isVerified) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      color: Color(0xFF43A047),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Verified: +91 $_verifiedMobile',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _clearVerification,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Change'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 2 — Family members (grouped by relationship = family tree)
  // ---------------------------------------------------------------------------
  Widget _buildFamilySection(ThemeData theme) {
    final groups = _groupedFamilyMembers();

    return AppSectionCard(
      title: 'Family Members (${_familyMembers.length})',
      subtitle: 'Patients linked to +91 $_verifiedMobile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppInfoBanner(
            message:
                'These patients share the same mobile number. Tap a member to '
                'open their profile, or use the edit icon to tag their '
                'relationship.',
            tone: AppBannerTone.info,
            icon: Icons.family_restroom,
          ),
          const SizedBox(height: 12),
          for (final group in groups)
            _buildFamilyGroup(theme, group.key, group.value),
          if (!_showRegistrationForm) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _startFamilyMemberRegistration,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Register New Family Member'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFamilyGroup(
    ThemeData theme,
    String relationship,
    List<Map<String, dynamic>> members,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Row(
            children: [
              Icon(
                _relationshipIcon(relationship),
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '$relationship (${members.length})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        for (final member in members) _buildFamilyMemberCard(theme, member),
      ],
    );
  }

  Widget _buildFamilyMemberCard(ThemeData theme, Map<String, dynamic> member) {
    final name = '${member['first_name'] ?? ''} ${member['last_name'] ?? ''}'
        .trim();
    final uhid = member['uhid']?.toString() ?? '';
    final gender = member['gender']?.toString() ?? '';
    final relationship = _relationshipOf(member);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            _relationshipIcon(relationship),
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('UHID: $uhid${gender.isNotEmpty ? '  •  $gender' : ''}'),
            const SizedBox(height: 6),
            _buildRelationshipChip(theme, member, relationship),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit_outlined, size: 20),
          tooltip: 'Tag relationship',
          onPressed: () => _tagFamilyMember(member),
        ),
        onTap: () => _openPatientProfile(member),
      ),
    );
  }

  Widget _buildRelationshipChip(
    ThemeData theme,
    Map<String, dynamic> member,
    String relationship,
  ) {
    return InkWell(
      onTap: () => _tagFamilyMember(member),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _relationshipIcon(relationship),
              size: 14,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 4),
            Text(
              relationship,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.edit,
              size: 12,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 3 — Registration form
  // ---------------------------------------------------------------------------
  Widget _buildRegistrationFormHeader(ThemeData theme) {
    final mobile = _verifiedMobile ?? _mobileController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _hasFamily ? 'Register New Family Member' : 'Patient Details',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.verified_user, size: 16, color: Color(0xFF43A047)),
            const SizedBox(width: 6),
            Text(
              'Mobile verified: +91 $mobile',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRegistrationForm(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildRegistrationMethodSelector(theme),
        const SizedBox(height: 16),

        if (_registrationMethod == RegistrationMethod.abha) ...[
          _buildAbhaSection(theme),
          const SizedBox(height: 16),
        ],

        _buildAdmissionTypeSelector(theme),
        const Divider(height: 32),

        // Family relationship tag — required when joining an existing family.
        _buildRelationshipField(theme),
        const SizedBox(height: 16),

        AppFieldRow(
          children: [
            TextFormField(
              controller: _firstNameController,
              decoration: const InputDecoration(labelText: 'First Name *'),
              validator: _registrationMethod == RegistrationMethod.direct
                  ? (v) => v?.isEmpty == true ? 'Required' : null
                  : null,
            ),
            TextFormField(
              controller: _lastNameController,
              decoration: const InputDecoration(labelText: 'Last Name *'),
              validator: _registrationMethod == RegistrationMethod.direct
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
          items: [
            'Male',
            'Female',
            'Other',
          ].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
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
          label: _hasFamily ? 'Register Family Member' : 'Register Patient',
          loading: _isSubmitting,
          onPressed: _submitForm,
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildAbhaSection(ThemeData theme) {
    return Column(
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
                            color: theme.colorScheme.onSecondaryContainer,
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_user, size: 18),
                  label: Text(_isVerifyingAbha ? 'Verifying...' : 'Verify'),
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
      ],
    );
  }

  /// Family relationship selector. For the first patient of a mobile number
  /// the default is "Self"; when joining an existing family the user must pick
  /// an explicit relationship.
  Widget _buildRelationshipField(ThemeData theme) {
    final options = _hasFamily
        ? kFamilyRelationships.where((r) => r != 'Self').toList()
        : kFamilyRelationships;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Family Relationship',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _selectedRelationship,
          decoration: InputDecoration(
            labelText: _hasFamily ? 'Relationship in Family *' : 'Relationship',
            hintText: _hasFamily
                ? 'e.g. Father, Mother, Wife...'
                : 'Defaults to Self (head of family)',
            prefixIcon: const Icon(Icons.family_restroom),
          ),
          items: [
            for (final relationship in options)
              DropdownMenuItem(
                value: relationship,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_relationshipIcon(relationship), size: 18),
                    const SizedBox(width: 8),
                    Text(relationship),
                  ],
                ),
              ),
          ],
          onChanged: (v) => setState(() => _selectedRelationship = v),
        ),
      ],
    );
  }

  bool validateStep() {
    // Mobile must still match the verified Step 1 number.
    final mobile = _mobileController.text.trim();
    if (_verifiedMobile == null || mobile != _verifiedMobile) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please verify the mobile number first')),
      );
      return false;
    }

    // Joining an existing family requires an explicit relationship tag.
    if (_hasFamily &&
        (_selectedRelationship == null || _selectedRelationship!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select the family relationship')),
      );
      return false;
    }

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
        // Family linking — the mobile number is already shared via Step 1.
        'family_relationship': _selectedRelationship ?? 'Self',
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
      final patientTags =
          _tagsKey.currentState?.selectedTags ?? const <String>[];
      if (patientTags.isNotEmpty) {
        try {
          final userId = await dbService.getCurrentUsersTableId();
          if (userId != null) {
            await ref
                .read(personalizedTagServiceProvider)
                .setEntityTags(
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
          final recordType = _admissionType == AdmissionType.ipd
              ? 'ipd_admission'
              : 'opd_visit';
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

      // Re-check after the best-effort ABDM/tag awaits above.
      if (!mounted) return;

      final relationshipLabel = _selectedRelationship ?? 'Self';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Patient registered! UHID: $uhid'
            '${relationshipLabel != 'Self' ? ' (Relationship: $relationshipLabel)' : ''}',
          ),
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
          'Step 1 — Enter the mobile number and tap Verify.\n\n'
          'If patients already exist for that number, their family members '
          'are shown grouped by relationship. You can open a member profile, '
          'tag a relationship, or register a new family member.\n\n'
          'If no patient is found, fill in the details to register.\n\n'
          'Choose registration method (ABHA or Direct) and admission type '
          '(OPD or IPD), then submit. For IPD admissions you will be '
          'redirected to the bed allocation screen after submission.',
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
