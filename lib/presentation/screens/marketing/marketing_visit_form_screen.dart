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
/// HIMS admin manual visit entry (`/marketing/visits/new`).
///
/// Manual entries always use `visit_source = admin_entry`. `geo_verified` is
/// only set when actual coordinates are supplied AND the geofence check
/// passes against the referral doctor's stored clinic location.
/// ---------------------------------------------------------------------------
class MarketingVisitFormScreen extends ConsumerStatefulWidget {
  const MarketingVisitFormScreen({super.key});

  @override
  ConsumerState<MarketingVisitFormScreen> createState() =>
      _MarketingVisitFormScreenState();
}

class _MarketingVisitFormScreenState
    extends ConsumerState<MarketingVisitFormScreen> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();
  final TextEditingController _purposeController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  String? _employeeId;
  String? _doctorId;
  late DateTime _visitedDate;
  late TimeOfDay _visitedTime;
  DateTime? _followUpDate;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visitedDate = DateTime(now.year, now.month, now.day);
    _visitedTime = TimeOfDay.fromDateTime(now);
  }

  @override
  void dispose() {
    _latitudeController.dispose();
    _longitudeController.dispose();
    _purposeController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  DateTime get _visitedAt {
    return DateTime(
      _visitedDate.year,
      _visitedDate.month,
      _visitedDate.day,
      _visitedTime.hour,
      _visitedTime.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final employeesAsync = hospitalId == null
        ? null
        : ref.watch(employeesProvider(hospitalId));
    final doctorsAsync = hospitalId == null
        ? null
        : ref.watch(referralDoctorsProvider(hospitalId));

    final employees = employeesAsync?.valueOrNull ?? const <Employee>[];
    final doctors = doctorsAsync?.valueOrNull ?? const <ReferralDoctor>[];

    return AppPage(
      title: 'Add Visit (Admin Entry)',
      isRootPage: false,
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppInfoBanner(
                message:
                    'Manual entries are recorded with source "admin_entry". '
                    'Geo verification is only applied when coordinates are '
                    'supplied and pass the geofence check.',
                icon: Icons.info_outline,
              ),
              AppGap.md,
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
                onChanged: (value) => setState(() => _employeeId = value),
              ),
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
                validator: (value) => value == null
                    ? 'Select a referral doctor'
                    : null,
              ),
              AppGap.sm,
              AppFieldRow(
                children: [
                  _DateField(
                    label: 'Visit Date *',
                    value: DateFormat('dd MMM yyyy').format(_visitedDate),
                    onTap: _pickDate,
                  ),
                  _DateField(
                    label: 'Visit Time *',
                    value: _visitedTime.format(context),
                    onTap: _pickTime,
                  ),
                ],
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
                      labelText: 'Latitude (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextFormField(
                    controller: _longitudeController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Longitude (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              AppGap.sm,
              TextFormField(
                controller: _purposeController,
                decoration: const InputDecoration(
                  labelText: 'Visit Purpose (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              AppGap.sm,
              TextFormField(
                controller: _notesController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Visit Notes (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              AppGap.sm,
              _DateField(
                label: 'Next Follow-up Date (optional)',
                value: _followUpDate == null
                    ? 'Not set'
                    : DateFormat('dd MMM yyyy').format(_followUpDate!),
                onTap: _pickFollowUpDate,
                onClear: _followUpDate == null
                    ? null
                    : () => setState(() => _followUpDate = null),
              ),
              AppGap.md,
              AppSubmitButton(
                label: 'Save Visit',
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

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _visitedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _visitedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _visitedTime,
    );
    if (picked != null && mounted) setState(() => _visitedTime = picked);
  }

  Future<void> _pickFollowUpDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _followUpDate ?? _visitedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _followUpDate = picked);
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

    final doctor = await ref.read(
      referralDoctorByIdProvider(
        ReferralDoctorDetailParams(
          hospitalId: hospitalId,
          doctorId: _doctorId!,
        ),
      ).future,
    );
    if (!mounted) return;
    if (doctor == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Referral doctor not found.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final latText = _latitudeController.text.trim();
    final lngText = _longitudeController.text.trim();
    final lat = double.tryParse(latText);
    final lng = double.tryParse(lngText);
    final hasCoordinates = lat != null && lng != null;

    double? distance;
    int? radius;
    var geoVerified = false;

    if (hasCoordinates) {
      if (doctor.hasLocation) {
        final result = ref.read(geofenceServiceProvider).check(
          doctorLatitude: doctor.latitude!,
          doctorLongitude: doctor.longitude!,
          employeeLatitude: lat,
          employeeLongitude: lng,
          allowedRadiusMeters: doctor.geoRadiusMeters.toDouble(),
        );
        if (!result.isInside) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "You are outside this referral doctor's location.",
              ),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        distance = result.distanceMeters;
        radius = doctor.geoRadiusMeters;
        geoVerified = true;
      } else {
        // The doctor has no stored clinic location, so geofence verification
        // is impossible — the visit stays unverified (geo_verified = false).
        distance = null;
        radius = doctor.geoRadiusMeters;
      }
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final visit = MarketingVisit(
        id: '',
        hospitalId: hospitalId,
        marketingEmployeeId: _employeeId,
        referralDoctorId: _doctorId!,
        areaId: doctor.areaId,
        visitedAt: _visitedAt,
        latitude: hasCoordinates ? lat : null,
        longitude: hasCoordinates ? lng : null,
        distanceFromDoctorMeters: distance,
        geofenceRadiusMeters: radius,
        geoVerified: geoVerified,
        visitSource: MarketingConstants.visitSourceAdminEntry,
        visitPurpose: _purposeController.text.trim().isEmpty
            ? null
            : _purposeController.text.trim(),
        visitNotes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        nextFollowUpDate: _followUpDate,
      );

      await ref
          .read(marketingVisitRepositoryProvider)
          .createVisit(hospitalId: hospitalId, visit: visit);

      ref.read(marketingRefreshProvider.notifier).state++;
      messenger.showSnackBar(
        const SnackBar(content: Text('Visit saved!')),
      );
      if (mounted) context.go('/marketing');
    } on MarketingRepositoryException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not save visit. Please try again.'),
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
    this.onClear,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: onClear == null
              ? const Icon(Icons.calendar_today_outlined, size: 18)
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear',
                  onPressed: onClear,
                ),
        ),
        child: Text(value),
      ),
    );
  }
}
