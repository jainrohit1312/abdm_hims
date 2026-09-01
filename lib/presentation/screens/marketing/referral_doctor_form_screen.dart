import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/constants/marketing_constants.dart';
import '../../../models/marketing_models.dart';
import '../../../repositories/marketing_area_repository.dart';
import '../../widgets/app_ui.dart';
import 'marketing_widgets.dart';

/// ---------------------------------------------------------------------------
/// Referral Doctor form (`/marketing/referral-doctors/new`,
/// `/marketing/referral-doctors/:id/edit`).
///
/// Explicitly labelled "Referral Doctor" everywhere — this master is a
/// completely separate domain from hospital doctors.
///
/// When latitude + longitude are supplied the official clinic location is
/// stored and `location_verified` is set. Normal visit punches NEVER
/// overwrite these master coordinates.
/// ---------------------------------------------------------------------------
class ReferralDoctorFormScreen extends ConsumerStatefulWidget {
  const ReferralDoctorFormScreen({super.key, this.doctorId});

  final String? doctorId;

  @override
  ConsumerState<ReferralDoctorFormScreen> createState() =>
      _ReferralDoctorFormScreenState();
}

class _ReferralDoctorFormScreenState
    extends ConsumerState<ReferralDoctorFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _clinicController;
  late final TextEditingController _registrationController;
  late final TextEditingController _mobileController;
  late final TextEditingController _alternateMobileController;
  late final TextEditingController _villageController;
  late final TextEditingController _addressController;
  late final TextEditingController _cityController;
  late final TextEditingController _pincodeController;
  late final TextEditingController _latitudeController;
  late final TextEditingController _longitudeController;
  late final TextEditingController _radiusController;
  late final TextEditingController _notesController;

  String _practitionerType = MarketingConstants.practitionerTypeClinic;
  String? _areaId;
  bool _isActive = true;
  bool _saving = false;

  ReferralDoctor? _existing;
  bool _loadingExisting = false;

  bool get _isEdit => widget.doctorId != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _clinicController = TextEditingController();
    _registrationController = TextEditingController();
    _mobileController = TextEditingController();
    _alternateMobileController = TextEditingController();
    _villageController = TextEditingController();
    _addressController = TextEditingController();
    _cityController = TextEditingController();
    _pincodeController = TextEditingController();
    _latitudeController = TextEditingController();
    _longitudeController = TextEditingController();
    _radiusController = TextEditingController(
      text: '${MarketingConstants.defaultGeofenceRadiusMeters}',
    );
    _notesController = TextEditingController();

    final id = widget.doctorId;
    if (id != null && id.isNotEmpty) {
      _loadingExisting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting(id));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _clinicController.dispose();
    _registrationController.dispose();
    _mobileController.dispose();
    _alternateMobileController.dispose();
    _villageController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _pincodeController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    _radiusController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadExisting(String id) async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty || !mounted) return;

    try {
      final doctor = await ref.read(
        referralDoctorByIdProvider(
          ReferralDoctorDetailParams(hospitalId: hospitalId, doctorId: id),
        ).future,
      );
      if (!mounted) return;
      if (doctor == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Referral doctor not found.')),
        );
        return;
      }
      setState(() {
        _existing = doctor;
        _nameController.text = doctor.name;
        _clinicController.text = doctor.clinicName ?? '';
        _registrationController.text = doctor.registrationNumber ?? '';
        _mobileController.text = doctor.mobileNumber ?? '';
        _alternateMobileController.text = doctor.alternateMobile ?? '';
        _villageController.text = doctor.village ?? '';
        _addressController.text = doctor.address ?? '';
        _cityController.text = doctor.city ?? '';
        _pincodeController.text = doctor.pincode ?? '';
        _latitudeController.text = doctor.latitude?.toString() ?? '';
        _longitudeController.text = doctor.longitude?.toString() ?? '';
        _radiusController.text = '${doctor.geoRadiusMeters}';
        _notesController.text = doctor.notes ?? '';
        _practitionerType = doctor.practitionerType;
        _areaId = doctor.areaId;
        _isActive = doctor.isActive;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load referral doctor: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final areasAsync = hospitalId == null
        ? null
        : ref.watch(marketingAreasProvider(hospitalId));
    final areas = areasAsync?.valueOrNull ?? const <MarketingArea>[];

    return AppPage(
      title: _isEdit ? 'Edit Referral Doctor' : 'Add Referral Doctor',
      isRootPage: false,
      children: [
        if (_loadingExisting)
          const Center(child: CircularProgressIndicator())
        else
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppInfoBanner(
                  message:
                      'Referral doctors are external doctors/clinics that refer '
                      'patients to your hospital. They are separate from '
                      'hospital doctors.',
                  icon: Icons.campaign_outlined,
                ),
                AppGap.md,
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Referral Doctor Name *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Referral doctor name is required'
                      : null,
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _clinicController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Clinic Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: _practitionerType,
                      decoration: const InputDecoration(
                        labelText: 'Practitioner Type',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final type in MarketingConstants.practitionerTypes)
                          DropdownMenuItem(
                            value: type,
                            child: Text(marketingPractitionerTypeLabel(type)),
                          ),
                      ],
                      onChanged: (value) => setState(
                        () => _practitionerType = value ??
                            MarketingConstants.practitionerTypeClinic,
                      ),
                    ),
                  ],
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _registrationController,
                      decoration: const InputDecoration(
                        labelText: 'Registration Number (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    TextFormField(
                      controller: _mobileController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Mobile',
                        border: OutlineInputBorder(),
                      ),
                      validator: _phoneValidator,
                    ),
                  ],
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _alternateMobileController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Alternate Mobile (optional)',
                        border: OutlineInputBorder(),
                      ),
                      validator: _phoneValidator,
                    ),
                    DropdownButtonFormField<String?>(
                      initialValue: _areaId,
                      decoration: const InputDecoration(
                        labelText: 'Marketing Area',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Select Area'),
                        ),
                        for (final area in areas)
                          DropdownMenuItem<String?>(
                            value: area.id,
                            child: Text(area.name),
                          ),
                      ],
                      onChanged: (value) => setState(() => _areaId = value),
                    ),
                  ],
                ),
                AppGap.sm,
                TextFormField(
                  controller: _villageController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Village',
                    border: OutlineInputBorder(),
                  ),
                ),
                AppGap.sm,
                TextFormField(
                  controller: _addressController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    border: OutlineInputBorder(),
                  ),
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _cityController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'City',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    TextFormField(
                      controller: _pincodeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Pincode',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
                AppGap.md,
                Text(
                  'Clinic Location (Geofence)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                AppGap.xs,
                Text(
                  'Stored once as the official geofence point. Visit punches '
                  'never overwrite these coordinates.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                AppGap.sm,
                AppFieldRow(
                  children: [
                    TextFormField(
                      controller: _latitudeController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Latitude',
                        border: OutlineInputBorder(),
                      ),
                      validator: _coordinateValidator,
                    ),
                    TextFormField(
                      controller: _longitudeController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Longitude',
                        border: OutlineInputBorder(),
                      ),
                      validator: _coordinateValidator,
                    ),
                  ],
                ),
                AppGap.sm,
                TextFormField(
                  controller: _radiusController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Geofence Radius (meters)',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) return 'Radius is required';
                    final parsed = int.tryParse(v);
                    if (parsed == null || parsed <= 0) {
                      return 'Enter a valid radius';
                    }
                    return null;
                  },
                ),
                AppGap.sm,
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Location Verified'),
                  subtitle: const Text(
                    'Auto-managed: set when latitude + longitude are '
                    'provided. Clear both coordinates to mark unverified.',
                  ),
                  value: _derivedLocationVerified,
                  onChanged: null,
                ),
                AppGap.xs,
                TextFormField(
                  controller: _notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                AppGap.xs,
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
                ),
                AppGap.md,
                AppSubmitButton(
                  label: _isEdit ? 'Save Changes' : 'Create Referral Doctor',
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

  bool get _derivedLocationVerified {
    final lat = double.tryParse(_latitudeController.text.trim());
    final lng = double.tryParse(_longitudeController.text.trim());
    return lat != null && lng != null;
  }

  String? _coordinateValidator(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    final parsed = double.tryParse(v);
    if (parsed == null) return 'Enter a valid number';
    if (parsed < -90 || parsed > 90) return 'Out of range';
    return null;
  }

  String? _phoneValidator(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    if (!RegExp(r'^\d{10,15}$').hasMatch(v)) {
      return 'Enter a valid mobile number';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

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

    final latText = _latitudeController.text.trim();
    final lngText = _longitudeController.text.trim();
    final lat = double.tryParse(latText);
    final lng = double.tryParse(lngText);
    final hasLocation = lat != null && lng != null;

    final now = DateTime.now().toUtc();
    final verifiedBy = await ref.read(currentPublicUserIdProvider.future);
    if (!mounted) return;

    final draft = ReferralDoctor(
      id: _existing?.id ?? '',
      hospitalId: hospitalId,
      name: _nameController.text.trim(),
      clinicName: _clinicController.text.trim().isEmpty
          ? null
          : _clinicController.text.trim(),
      practitionerType: _practitionerType,
      registrationNumber: _registrationController.text.trim().isEmpty
          ? null
          : _registrationController.text.trim(),
      mobileNumber: _mobileController.text.trim().isEmpty
          ? null
          : _mobileController.text.trim(),
      alternateMobile: _alternateMobileController.text.trim().isEmpty
          ? null
          : _alternateMobileController.text.trim(),
      areaId: _areaId,
      village: _villageController.text.trim().isEmpty
          ? null
          : _villageController.text.trim(),
      address: _addressController.text.trim().isEmpty
          ? null
          : _addressController.text.trim(),
      city: _cityController.text.trim().isEmpty
          ? null
          : _cityController.text.trim(),
      pincode: _pincodeController.text.trim().isEmpty
          ? null
          : _pincodeController.text.trim(),
      latitude: hasLocation ? lat : null,
      longitude: hasLocation ? lng : null,
      geoRadiusMeters:
          int.tryParse(_radiusController.text.trim()) ??
          MarketingConstants.defaultGeofenceRadiusMeters,
      locationVerified: hasLocation,
      locationVerifiedAt: hasLocation ? now : null,
      locationVerifiedBy: hasLocation ? verifiedBy : null,
      isActive: _isActive,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
    );

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final repository = ref.read(referralDoctorRepositoryProvider);
      if (_isEdit) {
        await repository.updateReferralDoctor(
          hospitalId: hospitalId,
          doctor: draft,
        );
      } else {
        await repository.createReferralDoctor(
          hospitalId: hospitalId,
          doctor: draft,
        );
      }

      ref.read(marketingRefreshProvider.notifier).state++;
      if (mounted) context.go('/marketing');
    } on MarketingRepositoryException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not save referral doctor. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
