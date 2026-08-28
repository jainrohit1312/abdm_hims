import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../widgets/app_ui.dart';

/// Hospital Registration screen (`/register`).
///
/// Collects the hospital details + the first admin account, then calls
/// [AuthService.registerHospital] which creates the hospital and admin in one
/// flow. On success the admin is signed in and redirected to the dashboard
/// (or to `/login` when email confirmation is enabled).
class HospitalRegistrationScreen extends ConsumerStatefulWidget {
  const HospitalRegistrationScreen({super.key});

  @override
  ConsumerState<HospitalRegistrationScreen> createState() =>
      _HospitalRegistrationScreenState();
}

class _HospitalRegistrationScreenState
    extends ConsumerState<HospitalRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();

  // Hospital fields
  final _hospitalNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _pincodeController = TextEditingController();
  final _phoneController = TextEditingController();
  final _hospitalEmailController = TextEditingController();
  final _registrationNumberController = TextEditingController();

  // Admin fields
  final _adminFirstNameController = TextEditingController();
  final _adminLastNameController = TextEditingController();
  final _adminEmailController = TextEditingController();
  final _adminPasswordController = TextEditingController();
  final _adminConfirmPasswordController = TextEditingController();

  File? _logoFile;
  bool _submitting = false;

  @override
  void dispose() {
    _hospitalNameController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _pincodeController.dispose();
    _phoneController.dispose();
    _hospitalEmailController.dispose();
    _registrationNumberController.dispose();
    _adminFirstNameController.dispose();
    _adminLastNameController.dispose();
    _adminEmailController.dispose();
    _adminPasswordController.dispose();
    _adminConfirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked != null && mounted) {
        setState(() => _logoFile = File(picked.path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not pick logo: $e')));
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);

    try {
      final authService = ref.read(authServiceProvider);

      final result = await authService.registerHospital({
        'hospital_name': _hospitalNameController.text.trim(),
        'address': _addressController.text.trim(),
        'city': _cityController.text.trim(),
        'state': _stateController.text.trim(),
        'pincode': _pincodeController.text.trim(),
        'phone': _phoneController.text.trim(),
        'email': _hospitalEmailController.text.trim(),
        'registration_number': _registrationNumberController.text.trim(),
        'admin_first_name': _adminFirstNameController.text.trim(),
        'admin_last_name': _adminLastNameController.text.trim(),
        'admin_email': _adminEmailController.text.trim(),
        'admin_password': _adminPasswordController.text.trim(),
        'admin_role': 'super_admin',
      });

      // Optional logo upload (best-effort; registration is already complete).
      final hospitalId = (result['hospital'] as Map<String, dynamic>)['id'];
      if (_logoFile != null && hospitalId != null) {
        try {
          final storageService = ref.read(storageServiceProvider);
          final logoUrl = await storageService.uploadFile(
            path: 'hospital-logos',
            file: _logoFile!,
          );
          final dbService = ref.read(databaseServiceProvider);
          await dbService.update(ApiConstants.hospitalsTable, hospitalId as String, {
            'logo_url': logoUrl,
          });
        } catch (e) {
          debugPrint('Logo upload skipped: $e');
        }
      }

      if (!mounted) return;

      // Sync Riverpod auth state with the freshly created admin session.
      await ref.read(authStateProvider.notifier).checkAuthStatus();
      if (!mounted) return;

      final authState = ref.read(authStateProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Hospital registered successfully!')),
      );

      if (authState.isAuthenticated &&
          authState.hospitalId != null &&
          authState.hospitalId!.isNotEmpty) {
        context.go('/dashboard');
      } else {
        context.go('/login');
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(_friendlyRegistrationError(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Converts raw Supabase Auth exceptions into short, actionable messages.
  String _friendlyRegistrationError(dynamic e) {
    final text = e.toString();
    if (text.contains('over_email_send_rate_limit') ||
        text.contains('email rate limit')) {
      return 'Supabase email limit khatam ho gayi hai.\n'
          'Authentication → Providers → Email → "Confirm email" OFF karo, '
          'phir dobara try karo.';
    }
    if (text.contains('already registered') ||
        text.contains('already been registered')) {
      return 'Ye admin email pehle se registered hai.\n'
          'Login karo ya dusra email use karo.';
    }
    if (text.contains('valid email') || text.contains('invalid email')) {
      return 'Admin email galat format mein hai. Sahi email daalo (e.g. name@gmail.com).';
    }
    return 'Registration failed: $e';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Hospital Registration')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sectionHeader(theme, 'Hospital Details'),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _hospitalNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Hospital Name *',
                    prefixIcon: Icon(Icons.local_hospital_outlined),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Hospital name is required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _addressController,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Hospital Address',
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _cityController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'City *'),
                      validator: (value) => value == null || value.trim().isEmpty
                          ? 'City is required'
                          : null,
                    ),
                    TextFormField(
                      controller: _stateController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'State *'),
                      validator: (value) => value == null || value.trim().isEmpty
                          ? 'State is required'
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _pincodeController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      decoration: const InputDecoration(
                        labelText: 'Pincode *',
                        counterText: '',
                        prefixIcon: Icon(Icons.pin_drop_outlined),
                      ),
                      validator: (value) {
                        final v = value?.trim() ?? '';
                        if (v.isEmpty) return 'Pincode is required';
                        if (!RegExp(r'^\d{6}$').hasMatch(v)) {
                          return 'Enter a valid 6-digit pincode';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number *',
                        counterText: '',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      validator: (value) {
                        final v = value?.trim() ?? '';
                        if (v.isEmpty) return 'Phone is required';
                        if (!RegExp(r'^\d{10}$').hasMatch(v)) {
                          return 'Enter a valid 10-digit number';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _hospitalEmailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Hospital Email',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return null;
                    if (!v.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _registrationNumberController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Registration Number (Govt. License) *',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                      ? 'Registration number is required'
                      : null,
                ),
                const SizedBox(height: 12),
                _buildLogoPicker(theme),
                const SizedBox(height: 24),
                _sectionHeader(theme, 'Admin User Creation'),
                const SizedBox(height: 12),
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _adminFirstNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'First Name *',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'First name is required'
                          : null,
                    ),
                    TextFormField(
                      controller: _adminLastNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Last Name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _adminEmailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Admin Email *',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return 'Admin email is required';
                    if (!v.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _adminPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password *',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      validator: (value) {
                        final v = value ?? '';
                        if (v.isEmpty) return 'Password is required';
                        if (v.length < 6) {
                          return 'Minimum 6 characters';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: _adminConfirmPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm Password *',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Confirm password';
                        }
                        if (value != _adminPasswordController.text) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.35,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outline),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.admin_panel_settings_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Role: Super Admin',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Hospital owner — Super Admin is assigned by default.',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Submit Registration'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildLogoPicker(ThemeData theme) {
    return InkWell(
      onTap: _pickLogo,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outline),
        ),
        child: Row(
          children: [
            _logoFile != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      _logoFile!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  )
                : Icon(
                    Icons.add_photo_alternate_outlined,
                    color: theme.colorScheme.primary,
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _logoFile == null
                    ? 'Upload Hospital Logo (Optional)'
                    : _logoFile!.path.split(Platform.pathSeparator).last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
