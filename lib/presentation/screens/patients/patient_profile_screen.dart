import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';
import '../../widgets/whatsapp_patient_opt_toggle.dart';

/// ---------------------------------------------------------------------------
/// Patient Profile Screen
/// ---------------------------------------------------------------------------
/// Full 360° view of a patient. One aggregated provider
/// (`patientFullProfileProvider`) loads every patient-scoped record in
/// parallel and the screen renders them across five tabs:
///
///  * Overview  – demographics, contact, emergency, insurance, stats
///  * Clinical  – OPD visits, IPD admissions, prescriptions, diagnostics,
///                vitals, progress notes, WhatsApp history
///  * Billing   – bills + line items + payment logs
///  * ABHA/ABDM – ABHA profile, care contexts, consents, FHIR records,
///                data-flow audit trail
///  * Files     – patient photo, investigation result files, diagnostic
///                images and IPD reports
/// ---------------------------------------------------------------------------
class PatientProfileScreen extends ConsumerWidget {
  final String patientId;
  const PatientProfileScreen({super.key, required this.patientId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(patientFullProfileProvider(patientId));

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Patient Profile')),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: 'Could not load patient profile.',
          detail: error.toString(),
          onRetry: () => ref.invalidate(patientFullProfileProvider(patientId)),
        ),
        data: (profile) {
          final patient = profile['patient'] as Map<String, dynamic>?;
          if (patient == null) {
            return const _ErrorState(
              message: 'Patient not found.',
              detail:
                  'This patient may have been deleted or you do not have '
                  'access to their records.',
            );
          }
          return _ProfileTabs(patientId: patientId, profile: profile);
        },
      ),
    );
  }
}

// ===========================================================================
// Tabbed profile shell
// ===========================================================================

class _ProfileTabs extends StatelessWidget {
  const _ProfileTabs({required this.patientId, required this.profile});

  final String patientId;
  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasRegistration = _hasAnyRegistration(profile);

    return DefaultTabController(
      length: 6,
      child: Column(
        children: [
          _PatientHeader(patientId: patientId, profile: profile),
          Material(
            color: theme.colorScheme.surface,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const [
                Tab(
                  icon: Icon(Icons.person_outline, size: 20),
                  text: 'Overview',
                ),
                Tab(icon: Icon(Icons.history, size: 20), text: 'Visits'),
                Tab(
                  icon: Icon(Icons.medical_services_outlined, size: 20),
                  text: 'Clinical',
                ),
                Tab(
                  icon: Icon(Icons.receipt_long_outlined, size: 20),
                  text: 'Billing',
                ),
                Tab(
                  icon: Icon(Icons.fingerprint, size: 20),
                  text: 'ABHA / ABDM',
                ),
                Tab(icon: Icon(Icons.folder_outlined, size: 20), text: 'Files'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(profile: profile),
                _VisitsTab(profile: profile),
                _ClinicalTab(profile: profile),
                if (hasRegistration)
                  _BillingTab(profile: profile)
                else
                  const _LockedTab(
                    icon: Icons.receipt_long_outlined,
                    title: 'Billing locked',
                    subtitle:
                        'Billing history appears only after the patient has '
                        'at least one OPD visit or IPD admission. Register a '
                        'visit to unlock billing records.',
                  ),
                _AbhaTab(profile: profile),
                _FilesTab(profile: profile),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Header
// ===========================================================================

class _PatientHeader extends ConsumerWidget {
  const _PatientHeader({required this.patientId, required this.profile});

  final String patientId;
  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final patient = profile['patient'] as Map<String, dynamic>;
    final name = _fullName(patient);
    final uhid = patient['uhid']?.toString() ?? 'N/A';
    final photoUrl = patient['photo_url']?.toString();
    final mobile = patient['mobile_number']?.toString() ?? '';

    final opdVisits = (profile['opd_visits'] as List)
        .cast<Map<String, dynamic>>();
    final admissions = (profile['ipd_admissions'] as List)
        .cast<Map<String, dynamic>>();
    final hasAnyRegistration = opdVisits.isNotEmpty || admissions.isNotEmpty;
    final activeAdmission = _activeAdmission(admissions);
    final activeOpd = _activeOpd(opdVisits);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PatientAvatar(name: name, photoUrl: photoUrl),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Unknown Patient' : name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('UHID: $uhid', style: theme.textTheme.bodyMedium),
                      Text(
                        'Patient ID: $patientId',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _HeaderChip(
                            icon: Icons.person,
                            label: _orDash(patient['gender']),
                          ),
                          _HeaderChip(
                            icon: Icons.cake_outlined,
                            label: '${_ageOf(patient)} yrs',
                          ),
                          _HeaderChip(
                            icon: Icons.bloodtype_outlined,
                            label: _orDash(patient['blood_group']),
                          ),
                          if (mobile.isNotEmpty)
                            _HeaderChip(icon: Icons.phone, label: mobile),
                          if (_isAbhaLinked(patient))
                            _HeaderChip(
                              icon: Icons.verified,
                              label: 'ABHA Linked',
                              color: theme.colorScheme.primary,
                            ),
                        ],
                      ),
                      if (activeAdmission != null || activeOpd != null) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (activeAdmission != null)
                              _HeaderChip(
                                icon: Icons.bed,
                                label:
                                    'Currently Admitted • Ward ${_orDash(activeAdmission['ward_type'])}',
                                color: const Color(0xFF2E7D32),
                              ),
                            if (activeOpd != null)
                              _HeaderChip(
                                icon: Icons.event_available,
                                label: 'In OPD Queue',
                                color: const Color(0xFF1565C0),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    final nameParam = Uri.encodeComponent(name);
                    final uhidParam = Uri.encodeComponent(uhid);
                    context.push(
                      '/opd/register?patientId=$patientId'
                      '&uhid=$uhidParam&patientName=$nameParam',
                    );
                  },
                  icon: const Icon(Icons.event_available, size: 18),
                  label: const Text('New OPD Visit'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () =>
                      context.push('/ipd/admit?patientId=$patientId'),
                  icon: const Icon(Icons.bed_outlined, size: 18),
                  label: const Text('New IPD Admission'),
                ),
                FilledButton.tonalIcon(
                  onPressed: hasAnyRegistration
                      ? () => DefaultTabController.of(context).animateTo(2)
                      : null,
                  icon: Icon(
                    hasAnyRegistration
                        ? Icons.medication_outlined
                        : Icons.lock_outline,
                    size: 18,
                  ),
                  label: const Text('View Prescriptions'),
                ),
                FilledButton.tonalIcon(
                  onPressed: hasAnyRegistration
                      ? () => DefaultTabController.of(context).animateTo(3)
                      : null,
                  icon: Icon(
                    hasAnyRegistration
                        ? Icons.receipt_long_outlined
                        : Icons.lock_outline,
                    size: 18,
                  ),
                  label: const Text('View Billing'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    final nameParam = Uri.encodeComponent(name);
                    final uhidParam = Uri.encodeComponent(uhid);
                    context.push(
                      '/diagnostics/order?patientId=$patientId'
                      '&patientName=$nameParam&uhid=$uhidParam',
                    );
                  },
                  icon: const Icon(Icons.biotech_outlined, size: 18),
                  label: const Text('Order Diagnostics'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            WhatsappPatientOptToggle(patientId: patientId, phoneNumber: mobile),
          ],
        ),
      ),
    );
  }
}

class _PatientAvatar extends StatelessWidget {
  const _PatientAvatar({required this.name, required this.photoUrl});

  final String name;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initials(name);

    if (photoUrl != null && photoUrl!.trim().isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: photoUrl!.trim(),
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          placeholder: (context, url) => Container(
            width: 64,
            height: 64,
            color: theme.colorScheme.primaryContainer,
            child: const Icon(Icons.person, size: 36),
          ),
          errorWidget: (context, url, error) =>
              _avatarFallback(theme, initials),
        ),
      );
    }

    return _avatarFallback(theme, initials);
  }

  Widget _avatarFallback(ThemeData theme, String initials) {
    return CircleAvatar(
      radius: 32,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: effectiveColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: effectiveColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Overview tab
// ===========================================================================

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final patient = profile['patient'] as Map<String, dynamic>;
    final insurances = (profile['insurances'] as List)
        .cast<Map<String, dynamic>>();
    final abhaProfile = profile['abha_profile'] as Map<String, dynamic>?;
    final vitals = (profile['vitals'] as List).cast<Map<String, dynamic>>();
    final opdVisits = (profile['opd_visits'] as List)
        .cast<Map<String, dynamic>>();
    final admissions = (profile['ipd_admissions'] as List)
        .cast<Map<String, dynamic>>();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _SectionCard(
          title: 'Personal Details',
          icon: Icons.badge_outlined,
          child: _LabelValueGrid(
            entries: [
              ('First Name', _orDash(patient['first_name'])),
              ('Middle Name', _orDash(patient['middle_name'])),
              ('Last Name', _orDash(patient['last_name'])),
              ('Date of Birth', _formatDate(patient['date_of_birth'])),
              ('Age', '${_ageOf(patient)} yrs'),
              ('Gender', _orDash(patient['gender'])),
              ('Blood Group', _orDash(patient['blood_group'])),
              ('Marital Status', _orDash(patient['marital_status'])),
              ('Registered On', _formatDate(patient['registration_date'])),
              (
                'Status',
                (patient['is_active'] == false) ? 'Inactive' : 'Active',
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Registration Summary',
          icon: Icons.fact_check_outlined,
          child: _RegistrationSummarySection(
            profile: profile,
            opdVisits: opdVisits,
            admissions: admissions,
            vitals: vitals,
          ),
        ),
        _SectionCard(
          title: 'Contact & Address',
          icon: Icons.contact_phone_outlined,
          child: _LabelValueGrid(
            entries: [
              ('Mobile', _orDash(patient['mobile_number'])),
              ('Alternate Mobile', _orDash(patient['alternate_mobile'])),
              ('Email', _orDash(patient['email'])),
              ('Address Line 1', _orDash(patient['address_line1'])),
              ('Address Line 2', _orDash(patient['address_line2'])),
              ('City', _orDash(patient['city'])),
              ('State', _orDash(patient['state'])),
              ('Pincode', _orDash(patient['pincode'])),
              ('Country', _orDash(patient['country'])),
            ],
          ),
        ),
        _SectionCard(
          title: 'Emergency Contact',
          icon: Icons.emergency_outlined,
          child: _LabelValueGrid(
            entries: [
              ('Contact Name', _orDash(patient['emergency_contact_name'])),
              ('Contact Number', _orDash(patient['emergency_contact_number'])),
              ('Relation', _orDash(patient['emergency_contact_relation'])),
            ],
          ),
        ),
        _SectionCard(
          title: 'ABHA / ABDM Summary',
          icon: Icons.fingerprint,
          child: _LabelValueGrid(
            entries: [
              (
                'ABHA ID',
                _orDash(patient['abha_id'] ?? patient['abha_number']),
              ),
              ('ABHA Address', _orDash(patient['abha_address'])),
              ('ABHA Linked', _isAbhaLinked(patient) ? 'Yes' : 'No'),
              (
                'ABHA Verified',
                abhaProfile == null
                    ? 'Not verified'
                    : (abhaProfile['is_verified'] == true ? 'Yes' : 'No'),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Record Summary',
          icon: Icons.insert_chart_outlined,
          child: _StatsRow(profile: profile),
        ),
        if (insurances.isNotEmpty)
          _SectionCard(
            title: 'Insurance (${insurances.length})',
            icon: Icons.health_and_safety_outlined,
            child: Column(
              children: [
                for (var i = 0; i < insurances.length; i++) ...[
                  if (i > 0) const Divider(),
                  _InsuranceTile(insurance: insurances[i]),
                ],
              ],
            ),
          ),
        _SectionCard(
          title: 'Latest Vitals',
          icon: Icons.monitor_heart_outlined,
          child: vitals.isEmpty
              ? const _EmptyLine(text: 'No vitals recorded yet.')
              : _VitalsTile(vitals: vitals.first),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final stats = <(IconData, String, int)>[
      (
        Icons.event_available,
        'OPD Visits',
        (profile['opd_visits'] as List).length,
      ),
      (Icons.bed, 'IPD Admissions', (profile['ipd_admissions'] as List).length),
      (
        Icons.medication_outlined,
        'Prescriptions',
        (profile['prescriptions'] as List).length,
      ),
      (
        Icons.biotech,
        'Diagnostics',
        (profile['diagnostic_orders'] as List).length,
      ),
      (Icons.receipt_long, 'Bills', (profile['bills'] as List).length),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 900 ? 6 : 3;
        final width = constraints.maxWidth / columns;

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (icon, label, value) in stats)
              Container(
                width: width - 8,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Icon(icon, color: theme.colorScheme.primary, size: 24),
                    const SizedBox(height: 6),
                    Text(
                      '$value',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

// ===========================================================================
// Registration summary (dynamic OPD / IPD sections)
// ===========================================================================

class _RegistrationSummarySection extends StatelessWidget {
  const _RegistrationSummarySection({
    required this.profile,
    required this.opdVisits,
    required this.admissions,
    required this.vitals,
  });

  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> opdVisits;
  final List<Map<String, dynamic>> admissions;
  final List<Map<String, dynamic>> vitals;

  @override
  Widget build(BuildContext context) {
    if (opdVisits.isEmpty && admissions.isEmpty) {
      return const _EmptyLine(
        text:
            'No registrations yet. Use the quick actions above to create '
            'an OPD visit or IPD admission — prescriptions and billing '
            'unlock automatically after the first registration.',
      );
    }

    final opdSorted = _sortedByDateDesc(opdVisits, 'visit_date');
    final ipdSorted = _sortedByDateDesc(admissions, 'admission_date');
    final latestOpd = opdSorted.isEmpty ? null : opdSorted.first;
    final latestIpd = ipdSorted.isEmpty ? null : ipdSorted.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (latestOpd != null) ...[
          _OpdRegistrationCard(
            visit: latestOpd,
            latestVitals: vitals.isEmpty ? null : vitals.first,
          ),
          if (latestIpd != null) const SizedBox(height: 10),
        ],
        if (latestIpd != null)
          _IpdAdmissionCard(
            admission: latestIpd,
            bedNumber: _bedForAdmission(profile, latestIpd),
          ),
      ],
    );
  }
}

class _OpdRegistrationCard extends StatelessWidget {
  const _OpdRegistrationCard({required this.visit, this.latestVitals});

  final Map<String, dynamic> visit;
  final Map<String, dynamic>? latestVitals;

  static const _opdBlue = Color(0xFF1565C0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _opdBlue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _opdBlue.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_hospital, size: 20, color: _opdBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Latest OPD Registration',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _opdBlue,
                  ),
                ),
              ),
              _StatusChip(status: _text(visit['status'], fallback: 'waiting')),
            ],
          ),
          const SizedBox(height: 10),
          _LabelValueGrid(
            entries: [
              ('Visit Date', _formatDate(visit['visit_date'])),
              ('Doctor', _orDash(visit['doctor_name'])),
              ('Department', _orDash(visit['department_name'])),
              ('Consultation Type', _orDash(visit['consultation_type'])),
              ('Consultation Fee', _money(visit['consultation_fee'])),
              (
                'Payment Status',
                _labelize(_text(visit['payment_status'], fallback: 'unpaid')),
              ),
              ('Chief Complaint', _orDash(visit['chief_complaint'])),
              ('Diagnosis', _orDash(visit['diagnosis'])),
            ],
          ),
          if (latestVitals != null) ...[
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 4),
            _VitalsTile(vitals: latestVitals!),
          ],
        ],
      ),
    );
  }
}

class _IpdAdmissionCard extends StatelessWidget {
  const _IpdAdmissionCard({required this.admission, this.bedNumber});

  final Map<String, dynamic> admission;
  final String? bedNumber;

  static const _ipdGreen = Color(0xFF2E7D32);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _ipdGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _ipdGreen.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bed, size: 20, color: _ipdGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Latest IPD Admission',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _ipdGreen,
                  ),
                ),
              ),
              _StatusChip(
                status: _text(admission['status'], fallback: 'admitted'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _LabelValueGrid(
            entries: [
              ('Admission Date', _formatDate(admission['admission_date'])),
              ('Discharge Date', _formatDate(admission['discharge_date'])),
              ('Ward', _orDash(admission['ward_type'])),
              ('Bed', _orDash(bedNumber)),
              ('Admission Type', _orDash(admission['admission_type'])),
              ('Doctor', _orDash(admission['doctor_name'])),
              ('Department', _orDash(admission['department_name'])),
              ('Primary Diagnosis', _orDash(admission['primary_diagnosis'])),
              (
                'Length of Stay',
                _lengthOfStay(
                  admission['admission_date'],
                  admission['discharge_date'],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Visit history stacking (chronological, newest first, color coded)
// ===========================================================================

enum _VisitType { opd, ipd }

class _VisitEntry {
  const _VisitEntry({required this.type, required this.data, this.bedNumber});

  final _VisitType type;
  final Map<String, dynamic> data;
  final String? bedNumber;

  DateTime? get date => type == _VisitType.opd
      ? DateTime.tryParse(data['visit_date']?.toString() ?? '')
      : DateTime.tryParse(data['admission_date']?.toString() ?? '');

  String get typeLabel =>
      type == _VisitType.opd ? 'OPD Visit' : 'IPD Admission';

  IconData get icon =>
      type == _VisitType.opd ? Icons.local_hospital : Icons.bed;

  Color get color => type == _VisitType.opd
      ? const Color(0xFF1565C0)
      : const Color(0xFF2E7D32);
}

class _VisitsTab extends StatelessWidget {
  const _VisitsTab({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opdVisits = (profile['opd_visits'] as List)
        .cast<Map<String, dynamic>>();
    final admissions = (profile['ipd_admissions'] as List)
        .cast<Map<String, dynamic>>();

    final entries = <_VisitEntry>[
      for (final visit in opdVisits)
        _VisitEntry(type: _VisitType.opd, data: visit),
      for (final admission in admissions)
        _VisitEntry(
          type: _VisitType.ipd,
          data: admission,
          bedNumber: _bedForAdmission(profile, admission),
        ),
    ];

    entries.sort((a, b) {
      final ad = a.date;
      final bd = b.date;
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return bd.compareTo(ad);
    });

    if (entries.isEmpty) {
      return const _EmptyTab(
        icon: Icons.history,
        title: 'No visits yet',
        subtitle:
            'OPD visits and IPD admissions stack here chronologically once '
            'the patient is registered.',
      );
    }

    final opdCount = entries.where((e) => e.type == _VisitType.opd).length;
    final ipdCount = entries.where((e) => e.type == _VisitType.ipd).length;
    final last = entries.first;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Visit History',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _MiniStat(
                      label: 'Total Visits',
                      value: '${entries.length}',
                    ),
                    _MiniStat(
                      label: 'OPD',
                      value: '$opdCount',
                      color: const Color(0xFF1565C0),
                    ),
                    _MiniStat(
                      label: 'IPD',
                      value: '$ipdCount',
                      color: const Color(0xFF2E7D32),
                    ),
                    _MiniStat(
                      label: 'Last Visit',
                      value: last.date == null ? '—' : _formatDate(last.date),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final entry in entries) _VisitCard(entry: entry),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.entry});

  final _VisitEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = entry.color;
    final data = entry.data;

    final status = entry.type == _VisitType.opd
        ? _text(data['status'], fallback: 'waiting')
        : _text(data['status'], fallback: 'admitted');
    final date = _formatDate(entry.date);

    final doctor = data['doctor_name']?.toString();
    final department = data['department_name']?.toString();
    final dischargeDate = data['discharge_date']?.toString();

    final subtitleParts = <String>[
      if (doctor != null && doctor.isNotEmpty) 'Doctor: $doctor',
      if (department != null && department.isNotEmpty)
        'Department: $department',
      if (entry.type == _VisitType.opd)
        'Fee: ${_money(data['consultation_fee'])} • Payment: '
            '${_labelize(_text(data['payment_status'], fallback: 'unpaid'))}'
      else ...[
        'Ward: ${_orDash(data['ward_type'])} • Bed: ${_orDash(entry.bedNumber)}',
        if (dischargeDate != null && dischargeDate.isNotEmpty)
          'Discharged: ${_formatDate(dischargeDate)}',
        'Stay: ${_lengthOfStay(data['admission_date'], data['discharge_date'])}',
      ],
    ];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showVisitDetailDialog(context, entry),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(entry.icon, size: 22, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            entry.typeLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            date,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        _StatusChip(status: status),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitleParts.join('\n'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Registration-locked placeholders
// ===========================================================================

class _LockedTab extends StatelessWidget {
  const _LockedTab({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 56,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Icon(
              icon,
              size: 28,
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedSection extends StatelessWidget {
  const _LockedSection({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsuranceTile extends StatelessWidget {
  const _InsuranceTile({required this.insurance});

  final Map<String, dynamic> insurance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = _orDash(insurance['insurance_provider']);
    final policy = _orDash(insurance['policy_number']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  provider,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (insurance['is_active'] == false)
                Text(
                  'Inactive',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _LabelValueGrid(
            entries: [
              ('Policy Number', policy),
              ('Policy Holder', _orDash(insurance['policy_holder_name'])),
              ('Holder Relation', _orDash(insurance['policy_holder_relation'])),
              ('Insurance Type', _orDash(insurance['insurance_type'])),
              ('Coverage Amount', _money(insurance['coverage_amount'])),
              ('Valid From', _formatDate(insurance['valid_from'])),
              ('Valid To', _formatDate(insurance['valid_to'])),
              ('TPA Name', _orDash(insurance['tpa_name'])),
              ('TPA Code', _orDash(insurance['tpa_code'])),
            ],
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Clinical tab
// ===========================================================================

class _ClinicalTab extends StatelessWidget {
  const _ClinicalTab({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final opdVisits = (profile['opd_visits'] as List)
        .cast<Map<String, dynamic>>();
    final admissions = (profile['ipd_admissions'] as List)
        .cast<Map<String, dynamic>>();
    final prescriptions = (profile['prescriptions'] as List)
        .cast<Map<String, dynamic>>();
    final diagnosticOrders = (profile['diagnostic_orders'] as List)
        .cast<Map<String, dynamic>>();
    final labOrders = (profile['lab_orders'] as List)
        .cast<Map<String, dynamic>>();
    final investigations = (profile['investigations'] as List)
        .cast<Map<String, dynamic>>();
    final vitals = (profile['vitals'] as List).cast<Map<String, dynamic>>();
    final notes = (profile['progress_notes'] as List)
        .cast<Map<String, dynamic>>();
    final whatsapp = (profile['whatsapp_messages'] as List)
        .cast<Map<String, dynamic>>();
    final hasRegistration = _hasAnyRegistration(profile);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _SectionCard(
          title: 'OPD Visits (${opdVisits.length})',
          icon: Icons.event_available,
          child: opdVisits.isEmpty
              ? const _EmptyLine(text: 'No OPD visits recorded.')
              : Column(
                  children: [
                    for (final visit in opdVisits) _OpdVisitTile(visit: visit),
                  ],
                ),
        ),
        _SectionCard(
          title: 'IPD Admissions (${admissions.length})',
          icon: Icons.bed,
          child: admissions.isEmpty
              ? const _EmptyLine(text: 'No IPD admissions recorded.')
              : Column(
                  children: [
                    for (final admission in admissions)
                      _IpdAdmissionTile(admission: admission),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Prescriptions (${prescriptions.length})',
          icon: Icons.medication_outlined,
          child: !hasRegistration
              ? const _LockedSection(
                  message:
                      'Prescriptions unlock after the patient has at '
                      'least one OPD visit or IPD admission.',
                )
              : prescriptions.isEmpty
              ? const _EmptyLine(text: 'No prescriptions recorded.')
              : Column(
                  children: [
                    for (final prescription in prescriptions)
                      _PrescriptionTile(prescription: prescription),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Diagnostic Orders (${diagnosticOrders.length})',
          icon: Icons.biotech,
          child: diagnosticOrders.isEmpty
              ? const _EmptyLine(text: 'No diagnostic orders recorded.')
              : Column(
                  children: [
                    for (final order in diagnosticOrders)
                      _DiagnosticOrderTile(order: order),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Lab Orders (${labOrders.length})',
          icon: Icons.science_outlined,
          child: labOrders.isEmpty
              ? const _EmptyLine(text: 'No lab orders recorded.')
              : Column(
                  children: [
                    for (final order in labOrders) _LabOrderTile(order: order),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Investigations (${investigations.length})',
          icon: Icons.medical_information_outlined,
          child: investigations.isEmpty
              ? const _EmptyLine(text: 'No investigations recorded.')
              : Column(
                  children: [
                    for (final investigation in investigations)
                      _InvestigationTile(investigation: investigation),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Vitals History (${vitals.length})',
          icon: Icons.monitor_heart_outlined,
          child: vitals.isEmpty
              ? const _EmptyLine(text: 'No vitals recorded.')
              : Column(
                  children: [
                    for (final vital in vitals.take(10))
                      _VitalsTile(vitals: vital, showDate: true),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Progress Notes (${notes.length})',
          icon: Icons.notes_outlined,
          child: notes.isEmpty
              ? const _EmptyLine(text: 'No progress notes recorded.')
              : Column(
                  children: [
                    for (final note in notes) _ProgressNoteTile(note: note),
                  ],
                ),
        ),
        _SectionCard(
          title: 'WhatsApp Communication (${whatsapp.length})',
          icon: Icons.chat_outlined,
          child: whatsapp.isEmpty
              ? const _EmptyLine(text: 'No WhatsApp messages exchanged.')
              : Column(
                  children: [
                    for (final message in whatsapp.take(20))
                      _WhatsappMessageTile(message: message),
                  ],
                ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _OpdVisitTile extends StatelessWidget {
  const _OpdVisitTile({required this.visit});

  final Map<String, dynamic> visit;

  @override
  Widget build(BuildContext context) {
    return _RecordTile(
      leading: Icons.local_hospital,
      title:
          '${_formatDate(visit['visit_date'])} • ${_orDash(visit['consultation_type'])}',
      subtitle: [
        if (_text(visit['chief_complaint']).isNotEmpty)
          'Complaint: ${_text(visit['chief_complaint'])}',
        if (_text(visit['diagnosis']).isNotEmpty)
          'Diagnosis: ${_text(visit['diagnosis'])}',
        if (_text(visit['treatment_advice']).isNotEmpty)
          'Advice: ${_text(visit['treatment_advice'])}',
      ].join('\n'),
      trailing: _StatusChip(
        status: _text(visit['status'], fallback: 'waiting'),
      ),
    );
  }
}

class _IpdAdmissionTile extends StatelessWidget {
  const _IpdAdmissionTile({required this.admission});

  final Map<String, dynamic> admission;

  @override
  Widget build(BuildContext context) {
    final status = _text(admission['status'], fallback: 'admitted');
    final admissionId = admission['id']?.toString() ?? '';

    final dateText = [
      _formatDate(admission['admission_date']),
      if (_text(admission['discharge_date']).isNotEmpty)
        '→ ${_formatDate(admission['discharge_date'])}',
    ].join(' ');

    return _RecordTile(
      leading: Icons.bed,
      title: '$dateText • ${_orDash(admission['admission_type'])}',
      subtitle: [
        if (_text(admission['primary_diagnosis']).isNotEmpty)
          'Primary Dx: ${_text(admission['primary_diagnosis'])}',
        if (_text(admission['ward_type']).isNotEmpty)
          'Ward: ${_text(admission['ward_type'])}',
        if (_text(admission['discharge_summary']).isNotEmpty)
          'Discharge: ${_text(admission['discharge_summary'])}',
      ].join('\n'),
      trailing: _StatusChip(status: status),
      onTap: admissionId.isEmpty
          ? null
          : () => context.push('/ipd/patient/$admissionId'),
    );
  }
}

class _PrescriptionTile extends StatelessWidget {
  const _PrescriptionTile({required this.prescription});

  final Map<String, dynamic> prescription;

  @override
  Widget build(BuildContext context) {
    final items =
        (prescription['prescription_items'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final itemTexts = <String>[];
    if (items.isNotEmpty) {
      for (final item in items) {
        final line = [
          _text(item['medicine_name']),
          if (_text(item['dosage']).isNotEmpty) _text(item['dosage']),
          if (_text(item['frequency']).isNotEmpty) _text(item['frequency']),
          if (_text(item['duration']).isNotEmpty) _text(item['duration']),
        ].join(' — ');
        itemTexts.add(line);
      }
    } else {
      itemTexts.add(
        [
          _text(prescription['medicine_name']),
          if (_text(prescription['dosage']).isNotEmpty)
            _text(prescription['dosage']),
          if (_text(prescription['frequency']).isNotEmpty)
            _text(prescription['frequency']),
          if (_text(prescription['duration']).isNotEmpty)
            _text(prescription['duration']),
        ].join(' — '),
      );
    }

    return _RecordTile(
      leading: Icons.medication,
      title: _formatDate(prescription['prescription_date']),
      subtitle: [
        ...itemTexts,
        if (_text(prescription['instructions']).isNotEmpty)
          'Instructions: ${_text(prescription['instructions'])}',
      ].join('\n'),
      trailing: _StatusChip(
        status: _text(prescription['status'], fallback: 'active'),
      ),
    );
  }
}

class _DiagnosticOrderTile extends StatelessWidget {
  const _DiagnosticOrderTile({required this.order});

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final items =
        (order['diagnostic_order_items'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final itemTexts = <String>[];
    for (final item in items) {
      final results =
          (item['diagnostic_results'] as List?)?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      final result = results.isEmpty ? null : results.first;

      final parts = <String>[
        _text(item['test_name'], fallback: 'Test'),
        if (_money(item['price']) != '₹0.00') _money(item['price']),
      ];

      if (result != null) {
        if (_text(result['result_value']).isNotEmpty) {
          parts.add('Result: ${_text(result['result_value'])}');
        }
        if (_text(result['findings']).isNotEmpty) {
          parts.add('Findings: ${_text(result['findings'])}');
        }
        if (_text(result['impression']).isNotEmpty) {
          parts.add('Impression: ${_text(result['impression'])}');
        }
      }
      itemTexts.add(parts.join(' — '));
    }

    return _RecordTile(
      leading: Icons.biotech,
      title:
          '${_formatDate(order['order_date'])} • ${_orDash(order['urgency'])}',
      subtitle: [
        if (itemTexts.isNotEmpty) ...itemTexts,
        'Total: ${_money(order['total_amount'])}',
      ].join('\n'),
      trailing: _StatusChip(
        status: _text(order['status'], fallback: 'pending'),
      ),
    );
  }
}

class _LabOrderTile extends StatelessWidget {
  const _LabOrderTile({required this.order});

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final results =
        (order['lab_results'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final resultTexts = <String>[];
    for (final result in results) {
      final line = [
        if (_text(result['result_value']).isNotEmpty)
          'Value: ${_text(result['result_value'])}',
        if (result['is_abnormal'] == true) '(Abnormal)',
        if (_text(result['reference_range']).isNotEmpty)
          'Ref: ${_text(result['reference_range'])}',
      ].join(' ');
      resultTexts.add(line);
    }

    return _RecordTile(
      leading: Icons.science,
      title:
          '${_formatDate(order['order_date'])} • ${_orDash(order['urgency'])}',
      subtitle: [
        if (_text(order['clinical_diagnosis']).isNotEmpty)
          'Dx: ${_text(order['clinical_diagnosis'])}',
        if (resultTexts.isNotEmpty) ...resultTexts,
      ].join('\n'),
      trailing: _StatusChip(
        status: _text(order['status'], fallback: 'ordered'),
      ),
    );
  }
}

class _InvestigationTile extends StatelessWidget {
  const _InvestigationTile({required this.investigation});

  final Map<String, dynamic> investigation;

  @override
  Widget build(BuildContext context) {
    final results =
        (investigation['investigation_results'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final resultTexts = <String>[];
    for (final result in results) {
      final parts = <String>[
        if (_text(result['result_text']).isNotEmpty)
          'Result: ${_text(result['result_text'])}',
        if (_text(result['findings']).isNotEmpty)
          'Findings: ${_text(result['findings'])}',
        if (_text(result['impression']).isNotEmpty)
          'Impression: ${_text(result['impression'])}',
      ];
      if (parts.isNotEmpty) resultTexts.add(parts.join('\n'));
    }

    return _RecordTile(
      leading: Icons.medical_information_outlined,
      title:
          '${_orDash(investigation['investigation_name'])} • ${_orDash(investigation['investigation_type'])}',
      subtitle: [
        'Ordered: ${_formatDate(investigation['ordered_date'])}',
        if (_text(investigation['body_part']).isNotEmpty)
          'Body part: ${_text(investigation['body_part'])}',
        if (_text(investigation['urgency']).isNotEmpty)
          'Urgency: ${_text(investigation['urgency'])}',
        ...resultTexts,
      ].join('\n'),
      trailing: _StatusChip(
        status: _text(investigation['status'], fallback: 'ordered'),
      ),
    );
  }
}

class _VitalsTile extends StatelessWidget {
  const _VitalsTile({required this.vitals, this.showDate = false});

  final Map<String, dynamic> vitals;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final parts = <String>[
      if (_text(vitals['temperature']).isNotEmpty)
        'Temp: ${_text(vitals['temperature'])}°C',
      if (_text(vitals['pulse_rate']).isNotEmpty)
        'Pulse: ${_text(vitals['pulse_rate'])} bpm',
      if (_text(vitals['blood_pressure_systolic']).isNotEmpty &&
          _text(vitals['blood_pressure_diastolic']).isNotEmpty)
        'BP: ${_text(vitals['blood_pressure_systolic'])}/${_text(vitals['blood_pressure_diastolic'])} mmHg',
      if (_text(vitals['spo2']).isNotEmpty) 'SpO2: ${_text(vitals['spo2'])}%',
      if (_text(vitals['blood_sugar']).isNotEmpty)
        'Sugar: ${_text(vitals['blood_sugar'])} mg/dL',
      if (_text(vitals['weight']).isNotEmpty)
        'Weight: ${_text(vitals['weight'])} kg',
      if (_text(vitals['height']).isNotEmpty)
        'Height: ${_text(vitals['height'])} cm',
      if (_text(vitals['bmi']).isNotEmpty) 'BMI: ${_text(vitals['bmi'])}',
      if (_text(vitals['pain_score']).isNotEmpty)
        'Pain: ${_text(vitals['pain_score'])}/10',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.favorite, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showDate)
                  Text(
                    _formatDateTime(vitals['recorded_at']),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  parts.isEmpty ? 'No readings recorded.' : parts.join('  •  '),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressNoteTile extends StatelessWidget {
  const _ProgressNoteTile({required this.note});

  final Map<String, dynamic> note;

  @override
  Widget build(BuildContext context) {
    return _RecordTile(
      leading: Icons.notes,
      title:
          '${_formatDate(note['note_date'])} • ${_orDash(note['note_type'])}',
      subtitle: [
        if (_text(note['subjective']).isNotEmpty)
          'S: ${_text(note['subjective'])}',
        if (_text(note['objective']).isNotEmpty)
          'O: ${_text(note['objective'])}',
        if (_text(note['assessment']).isNotEmpty)
          'A: ${_text(note['assessment'])}',
        if (_text(note['plan']).isNotEmpty) 'P: ${_text(note['plan'])}',
      ].join('\n'),
    );
  }
}

class _WhatsappMessageTile extends StatelessWidget {
  const _WhatsappMessageTile({required this.message});

  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _text(message['status'], fallback: 'sent');
    final body = _text(message['message_body']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.chat, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_orDash(message['phone_number'])} • ${_formatDateTime(message['sent_at'] ?? message['created_at'])}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _StatusChip(status: status),
                  ],
                ),
                if (body.isNotEmpty)
                  Text(
                    body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                if (_text(message['error_message']).isNotEmpty)
                  Text(
                    'Error: ${_text(message['error_message'])}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Billing tab
// ===========================================================================

class _BillingTab extends StatelessWidget {
  const _BillingTab({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bills = (profile['bills'] as List).cast<Map<String, dynamic>>();

    if (bills.isEmpty) {
      return const _EmptyTab(
        icon: Icons.receipt_long_outlined,
        title: 'No bills yet',
        subtitle: 'Bills raised for this patient will appear here.',
      );
    }

    var totalBilled = 0.0;
    var totalPaid = 0.0;
    for (final bill in bills) {
      totalBilled += _toDouble(bill['total_amount'] ?? bill['net_amount']);
      totalPaid += _toDouble(bill['paid_amount']);
    }
    final totalBalance = totalBilled - totalPaid;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Billing Summary',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _BillSummaryStat(label: 'Bills', value: '${bills.length}'),
                    _BillSummaryStat(
                      label: 'Total Billed',
                      value: _money(totalBilled),
                    ),
                    _BillSummaryStat(
                      label: 'Total Paid',
                      value: _money(totalPaid),
                    ),
                    _BillSummaryStat(
                      label: 'Outstanding',
                      value: _money(totalBalance),
                      highlight: totalBalance > 0,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final bill in bills) _BillTile(bill: bill),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _BillSummaryStat extends StatelessWidget {
  const _BillSummaryStat({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: highlight ? theme.colorScheme.error : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _BillTile extends StatelessWidget {
  const _BillTile({required this.bill});

  final Map<String, dynamic> bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items =
        (bill['billing_items'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final paymentLogs =
        (bill['payment_logs'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final itemTexts = items
        .map(
          (item) =>
              '${_orDash(item['item_name'])} × ${_text(item['quantity'], fallback: '1')} = ${_money(item['total_price'] ?? item['unit_price'])}',
        )
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_orDash(bill['bill_number'])} • ${_formatDate(bill['bill_date'])}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _StatusChip(
                  status: _text(bill['payment_status'], fallback: 'unpaid'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Type: ${_orDash(bill['visit_type'] ?? bill['bill_type'])}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _AmountLabel(
                  label: 'Total',
                  value: _money(bill['total_amount']),
                ),
                _AmountLabel(
                  label: 'Discount',
                  value: _money(bill['discount_amount']),
                ),
                _AmountLabel(label: 'Net', value: _money(bill['net_amount'])),
                _AmountLabel(label: 'Paid', value: _money(bill['paid_amount'])),
                _AmountLabel(
                  label: 'Balance',
                  value: _money(bill['balance_amount']),
                  highlight: true,
                ),
              ],
            ),
            if (itemTexts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Items',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              for (final text in itemTexts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $text', style: theme.textTheme.bodySmall),
                ),
            ],
            if (paymentLogs.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Payments',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              for (final log in paymentLogs)
                Text(
                  '• ${_formatDateTime(log['payment_date'])} — '
                  '${_money(log['amount_paid'])} via ${_orDash(log['payment_mode'])}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AmountLabel extends StatelessWidget {
  const _AmountLabel({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        text: '$label: ',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        children: [
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: highlight ? theme.colorScheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// ABHA / ABDM tab
// ===========================================================================

class _AbhaTab extends StatelessWidget {
  const _AbhaTab({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final abhaProfile = profile['abha_profile'] as Map<String, dynamic>?;
    final careContexts = (profile['care_contexts'] as List)
        .cast<Map<String, dynamic>>();
    final consents = (profile['consent_artefacts'] as List)
        .cast<Map<String, dynamic>>();
    final fhirRecords = (profile['fhir_records'] as List)
        .cast<Map<String, dynamic>>();
    final dataFlowLogs = (profile['data_flow_logs'] as List)
        .cast<Map<String, dynamic>>();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _SectionCard(
          title: 'ABHA Profile',
          icon: Icons.fingerprint,
          child: abhaProfile == null
              ? const _EmptyLine(
                  text: 'No ABHA profile linked for this patient.',
                )
              : _LabelValueGrid(
                  entries: [
                    ('ABHA ID', _orDash(abhaProfile['abha_id'])),
                    ('ABHA Address', _orDash(abhaProfile['abha_address'])),
                    (
                      'Verified',
                      abhaProfile['is_verified'] == true ? 'Yes' : 'No',
                    ),
                    ('Created At', _formatDateTime(abhaProfile['created_at'])),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Care Contexts (${careContexts.length})',
          icon: Icons.link,
          child: careContexts.isEmpty
              ? const _EmptyLine(text: 'No care contexts linked yet.')
              : Column(
                  children: [
                    for (final context in careContexts)
                      _RecordTile(
                        leading: context['is_linked'] == true
                            ? Icons.link
                            : Icons.link_off,
                        title: _orDash(
                          context['care_context_id'] ??
                              context['abdm_care_context_id'],
                        ),
                        subtitle: [
                          'Type: ${_orDash(context['record_type'] ?? context['care_context_type'])}',
                          'Record: ${_orDash(context['record_id'] ?? context['care_context_reference_id'])}',
                          'Linked: ${context['is_linked'] == true ? 'Yes' : 'No'}',
                        ].join('\n'),
                      ),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Consent Artefacts (${consents.length})',
          icon: Icons.fact_check_outlined,
          child: consents.isEmpty
              ? const _EmptyLine(text: 'No consent artefacts recorded.')
              : Column(
                  children: [
                    for (final consent in consents)
                      _RecordTile(
                        leading: Icons.fact_check_outlined,
                        title: _orDash(consent['consent_id']),
                        subtitle: [
                          'Purpose: ${_orDash(consent['purpose'])}',
                          'Granted: ${_formatDateTime(consent['granted_at'])}',
                          'Expires: ${_formatDateTime(consent['expires_at'])}',
                        ].join('\n'),
                        trailing: _StatusChip(
                          status: _text(
                            consent['status'],
                            fallback: 'requested',
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        _SectionCard(
          title: 'FHIR Records (${fhirRecords.length})',
          icon: Icons.storage_outlined,
          child: fhirRecords.isEmpty
              ? const _EmptyLine(text: 'No FHIR records stored.')
              : Column(
                  children: [
                    for (final record in fhirRecords)
                      _RecordTile(
                        leading: Icons.description_outlined,
                        title:
                            '${_orDash(record['record_type'])} • ${_orDash(record['record_id'])}',
                        subtitle:
                            'Stored: ${_formatDateTime(record['created_at'])}',
                        trailing: IconButton(
                          tooltip: 'View FHIR bundle',
                          icon: const Icon(Icons.visibility_outlined, size: 20),
                          onPressed: () => _showJsonDialog(
                            context,
                            title: 'FHIR Bundle',
                            json: record['fhir_bundle'],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        _SectionCard(
          title: 'Data Flow Audit (${dataFlowLogs.length})',
          icon: Icons.history,
          child: dataFlowLogs.isEmpty
              ? const _EmptyLine(text: 'No ABDM data flow logs recorded.')
              : Column(
                  children: [
                    for (final log in dataFlowLogs.take(30))
                      _RecordTile(
                        leading: Icons.swap_vert,
                        title: _orDash(log['transaction_id']),
                        subtitle:
                            '${_formatDateTime(log['created_at'])} — ${_orDash(log['status'])}',
                        trailing: IconButton(
                          tooltip: 'View payload',
                          icon: const Icon(Icons.visibility_outlined, size: 20),
                          onPressed: () => _showLogDialog(context, log),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===========================================================================
// Files tab
// ===========================================================================

class _FilesTab extends StatelessWidget {
  const _FilesTab({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final patient = profile['patient'] as Map<String, dynamic>;
    final photoUrl = patient['photo_url']?.toString();
    final investigations = (profile['investigations'] as List)
        .cast<Map<String, dynamic>>();
    final diagnosticOrders = (profile['diagnostic_orders'] as List)
        .cast<Map<String, dynamic>>();
    final admissions = (profile['ipd_admissions'] as List)
        .cast<Map<String, dynamic>>();
    final reportsByAdmission = (profile['ipd_reports_by_admission'] as Map)
        .cast<String, dynamic>();

    final fileTiles = <Widget>[];

    // 1. Patient photo.
    if (photoUrl != null && photoUrl.trim().isNotEmpty) {
      fileTiles.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: photoUrl.trim(),
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) => Container(
                      width: 96,
                      height: 96,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.person, size: 40),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Patient Photo',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Stored in the patient master record.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Open photo',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => _openUrl(context, photoUrl),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 2. Investigation result files (radiology/pathology reports).
    for (final investigation in investigations) {
      final results =
          (investigation['investigation_results'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      for (final result in results) {
        final fileUrl = result['result_file_url']?.toString();
        if (fileUrl == null || fileUrl.isEmpty) continue;
        fileTiles.add(
          _FileTile(
            icon: Icons.picture_as_pdf_outlined,
            title: _orDash(investigation['investigation_name']),
            subtitle:
                '${_orDash(investigation['investigation_type'])} • '
                '${_formatDate(result['result_date'])}',
            url: fileUrl,
          ),
        );
      }
    }

    // 3. Diagnostic result images (radiology/cardiology).
    for (final order in diagnosticOrders) {
      final items =
          (order['diagnostic_order_items'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      for (final item in items) {
        final results =
            (item['diagnostic_results'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];
        for (final result in results) {
          final imageUrl = result['image_url']?.toString();
          if (imageUrl == null || imageUrl.isEmpty) continue;
          fileTiles.add(
            _FileTile(
              icon: Icons.image_outlined,
              title: _orDash(item['test_name']),
              subtitle:
                  'Diagnostic image • ${_formatDate(result['result_date'])}',
              url: imageUrl,
            ),
          );
        }
      }
    }

    // 4. IPD reports.
    for (final admission in admissions) {
      final admissionId = admission['id']?.toString() ?? '';
      final reports =
          (reportsByAdmission[admissionId] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      for (final report in reports) {
        final reportUrl = report['report_url']?.toString();
        if (reportUrl == null || reportUrl.isEmpty) continue;
        fileTiles.add(
          _FileTile(
            icon: Icons.description_outlined,
            title: _orDash(report['report_type']),
            subtitle: 'IPD report • ${_formatDate(report['report_date'])}',
            url: reportUrl,
          ),
        );
      }
    }

    if (fileTiles.isEmpty) {
      return const _EmptyTab(
        icon: Icons.folder_off_outlined,
        title: 'No files available',
        subtitle:
            'Patient photo, investigation result files, diagnostic images '
            'and IPD reports will appear here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [...fileTiles, const SizedBox(height: 24)],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.url,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: IconButton(
          tooltip: 'Open file',
          icon: const Icon(Icons.open_in_new),
          onPressed: () => _openUrl(context, url),
        ),
      ),
    );
  }
}

// ===========================================================================
// Shared building blocks
// ===========================================================================

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _LabelValueGrid extends StatelessWidget {
  const _LabelValueGrid({required this.entries});

  final List<(String, String)> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 800 ? 2 : 1;
        final rows = (entries.length / columns).ceil();

        return Column(
          children: [
            for (var row = 0; row < rows; row++)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < columns; col++)
                      if (row * columns + col < entries.length)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              bottom: row == rows - 1 ? 0 : 8,
                              right: col == columns - 1 ? 0 : 16,
                            ),
                            child: _labelValueRow(
                              theme,
                              entries[row * columns + col].$1,
                              entries[row * columns + col].$2,
                            ),
                          ),
                        ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _labelValueRow(ThemeData theme, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(leading, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
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
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = status.toLowerCase();
    final color = _statusColor(theme, normalized);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _labelize(status),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, this.detail, this.onRetry});

  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Formatting helpers
// ===========================================================================

String _text(dynamic value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String _orDash(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? '—' : text;
}

String _fullName(Map<String, dynamic> patient) {
  final parts = [
    patient['first_name'],
    patient['middle_name'],
    patient['last_name'],
  ];
  return parts
      .where((s) => s?.toString().trim().isNotEmpty == true)
      .map((s) => s!.toString().trim())
      .join(' ');
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
  if (parts.isEmpty) return '';
  final first = parts.first;
  final last = parts.length > 1 ? parts.last : '';
  return '${first.isNotEmpty ? first[0] : ''}'
          '${last.isNotEmpty ? last[0] : ''}'
      .toUpperCase();
}

String _ageOf(Map<String, dynamic> patient) {
  final age = patient['age']?.toString();
  if (age != null && age.isNotEmpty && age != '0') return age;

  final dobText = patient['date_of_birth']?.toString() ?? '';
  final dob = DateTime.tryParse(dobText);
  if (dob == null) return '—';

  final now = DateTime.now();
  var years = now.year - dob.year;
  if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) {
    years--;
  }
  return years >= 0 ? years.toString() : '—';
}

bool _isAbhaLinked(Map<String, dynamic> patient) {
  return patient['abha_linked'] == true ||
      _text(patient['abha_id']).isNotEmpty ||
      _text(patient['abha_number']).isNotEmpty ||
      _text(patient['abha_address']).isNotEmpty;
}

bool _hasAnyRegistration(Map<String, dynamic> profile) {
  final opd = profile['opd_visits'] as List? ?? const [];
  final ipd = profile['ipd_admissions'] as List? ?? const [];
  return opd.isNotEmpty || ipd.isNotEmpty;
}

Map<String, dynamic>? _activeAdmission(List<Map<String, dynamic>> admissions) {
  for (final admission in admissions) {
    final status = _text(admission['status'], fallback: '').toLowerCase();
    if (status == 'admitted') return admission;
  }
  return null;
}

Map<String, dynamic>? _activeOpd(List<Map<String, dynamic>> visits) {
  for (final visit in visits) {
    final status = _text(visit['status'], fallback: '').toLowerCase();
    if (status == 'waiting' ||
        status == 'pending' ||
        status == 'in_consultation') {
      return visit;
    }
  }
  return null;
}

List<Map<String, dynamic>> _sortedByDateDesc(
  List<Map<String, dynamic>> rows,
  String column,
) {
  final copy = [...rows];
  copy.sort((a, b) {
    final ad = DateTime.tryParse(a[column]?.toString() ?? '');
    final bd = DateTime.tryParse(b[column]?.toString() ?? '');
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad);
  });
  return copy;
}

String _bedForAdmission(
  Map<String, dynamic> profile,
  Map<String, dynamic> admission,
) {
  final bedsByAdmission =
      (profile['admission_beds'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  final admissionId = admission['id']?.toString() ?? '';
  return bedsByAdmission[admissionId] ?? '';
}

String _lengthOfStay(dynamic admissionDate, dynamic dischargeDate) {
  final start = DateTime.tryParse(admissionDate?.toString() ?? '');
  if (start == null) return '—';
  final endText = dischargeDate?.toString() ?? '';
  final end = DateTime.tryParse(endText);
  final effectiveEnd = end ?? DateTime.now();
  final days = effectiveEnd.difference(start).inDays;
  if (days < 0) return '—';
  if (days == 0) return 'Same day';
  return '$days day${days == 1 ? '' : 's'}';
}

String _formatDate(dynamic value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) return '—';
  final date = DateTime.tryParse(text);
  if (date == null) return text;
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$day-$month-${date.year}';
}

String _formatDateTime(dynamic value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) return '—';
  final date = DateTime.tryParse(text);
  if (date == null) return text;
  final local = date.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$day-$month-${local.year} $hour:$minute';
}

String _money(dynamic value) {
  final amount = _toDouble(value);
  return '₹${amount.toStringAsFixed(2)}';
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  return double.tryParse(value.toString()) ?? 0;
}

String _labelize(String status) {
  final trimmed = status.trim();
  if (trimmed.isEmpty) return 'Unknown';
  return trimmed
      .split('_')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
      )
      .join(' ');
}

Color _statusColor(ThemeData theme, String status) {
  switch (status) {
    case 'completed':
    case 'paid':
    case 'success':
    case 'active':
    case 'final':
    case 'sent':
    case 'delivered':
    case 'admitted':
    case 'linked':
    case 'granted':
      return const Color(0xFF2E7D32);
    case 'pending':
    case 'requested':
    case 'waiting':
    case 'in_progress':
    case 'in_consultation':
    case 'sample_collected':
    case 'ordered':
    case 'read':
      return const Color(0xFFF57F17);
    case 'cancelled':
    case 'failed':
    case 'expired':
    case 'discontinued':
    case 'no_show':
      return theme.colorScheme.error;
    case 'partially_paid':
    case 'draft':
    case 'amended':
    case 'generated':
    case 'unpaid':
      return const Color(0xFFE65100);
    case 'discharged':
    case 'transfer_out':
      return const Color(0xFF1565C0);
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

// ===========================================================================
// URL / dialog helpers
// ===========================================================================

Future<void> _openUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This file does not have a valid URL.')),
    );
    return;
  }

  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open the file.')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open the file: $e')));
    }
  }
}

void _showVisitDetailDialog(BuildContext context, _VisitEntry entry) {
  final data = entry.data;
  final entries = entry.type == _VisitType.opd
      ? <(String, String)>[
          ('Visit Type', 'OPD'),
          ('Visit Date', _formatDate(data['visit_date'])),
          ('Doctor', _orDash(data['doctor_name'])),
          ('Department', _orDash(data['department_name'])),
          ('Consultation Type', _orDash(data['consultation_type'])),
          ('Consultation Fee', _money(data['consultation_fee'])),
          (
            'Payment Status',
            _labelize(_text(data['payment_status'], fallback: 'unpaid')),
          ),
          ('Chief Complaint', _orDash(data['chief_complaint'])),
          ('Symptoms', _orDash(data['symptoms'])),
          ('Diagnosis', _orDash(data['diagnosis'])),
          ('Treatment Advice', _orDash(data['treatment_advice'])),
          ('Follow-up Date', _formatDate(data['follow_up_date'])),
          ('Status', _labelize(_text(data['status'], fallback: 'waiting'))),
        ]
      : <(String, String)>[
          ('Visit Type', 'IPD'),
          ('Admission Date', _formatDate(data['admission_date'])),
          ('Discharge Date', _formatDate(data['discharge_date'])),
          ('Ward', _orDash(data['ward_type'])),
          ('Bed', _orDash(entry.bedNumber)),
          ('Admission Type', _orDash(data['admission_type'])),
          ('Doctor', _orDash(data['doctor_name'])),
          ('Department', _orDash(data['department_name'])),
          ('Primary Diagnosis', _orDash(data['primary_diagnosis'])),
          ('Secondary Diagnosis', _orDash(data['secondary_diagnosis'])),
          ('Treatment Plan', _orDash(data['treatment_plan'])),
          ('Discharge Summary', _orDash(data['discharge_summary'])),
          ('Discharge Instructions', _orDash(data['discharge_instructions'])),
          (
            'Length of Stay',
            _lengthOfStay(data['admission_date'], data['discharge_date']),
          ),
          ('Status', _labelize(_text(data['status'], fallback: 'admitted'))),
        ];

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(entry.typeLabel),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(child: _LabelValueGrid(entries: entries)),
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

void _showJsonDialog(
  BuildContext context, {
  required String title,
  required dynamic json,
}) {
  final encoder = const JsonEncoder.withIndent('  ');
  final text = json == null ? 'null' : encoder.convert(json);

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 12)),
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

void _showLogDialog(BuildContext context, Map<String, dynamic> log) {
  final encoder = const JsonEncoder.withIndent('  ');
  String pretty(dynamic value) =>
      value == null ? 'null' : encoder.convert(value);

  final content = [
    'Transaction: ${_orDash(log['transaction_id'])}',
    'Status: ${_orDash(log['status'])}',
    '',
    'Request payload:',
    pretty(log['request_payload']),
    '',
    'Response payload:',
    pretty(log['response_payload']),
    if (_text(log['error_message']).isNotEmpty) ...[
      '',
      'Error: ${_text(log['error_message'])}',
    ],
  ].join('\n');

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Data Flow Log'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: SingleChildScrollView(
          child: SelectableText(content, style: const TextStyle(fontSize: 12)),
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
