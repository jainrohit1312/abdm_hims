import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../../services/print_prescription.dart';
import '../../../services/receipt_service.dart';
import '../../widgets/counseling_visit_history_list.dart';
import '../../widgets/prescription_clinical_fields.dart';
import '../../widgets/prescription_form.dart';
import '../../widgets/smart_navigation.dart';

/// OPD consultation screen.
///
/// 4 tabs rakhta hai (History / Prescription / Investigations / Counseling)
/// kyunki Medicine tab khud bahut bulky hai (1000+ medicines ki live list).
/// Tabs sirf ye control karte hain ki doctor abhi kya bhar raha hai — chaaron
/// tabs ka data ek hi prescription mein save hota hai jab doctor
/// "Save & Complete" dabata hai.
///
/// Neeche ka "Saved Prescription" section hamesha poora prescription dikhata
/// hai (History + Medicines + Investigations + Counseling) aur tabs ke bahar
/// hai, isliye tab switch karne par saved view kabhi nahi badalta. Print ka
/// option yahan aur OPD Queue / Saved Prescriptions mein milta hai.
class OPDConsultationScreen extends ConsumerStatefulWidget {
  final String registrationId;
  final String? patientName;
  final String? uhid;
  final String? doctorName;
  final String? department;
  final double? fee;

  const OPDConsultationScreen({
    super.key,
    required this.registrationId,
    this.patientName,
    this.uhid,
    this.doctorName,
    this.department,
    this.fee,
  });

  @override
  ConsumerState<OPDConsultationScreen> createState() =>
      _OPDConsultationScreenState();
}

class _OPDConsultationScreenState extends ConsumerState<OPDConsultationScreen> {
  final _prescriptionFormKey = GlobalKey<DoctorPrescriptionFormState>();
  final _clinicalController = PrescriptionClinicalController();
  bool _isSaving = false;

  /// Whether the pinned saved-prescription panel is expanded. Collapsed by
  /// default so the working area stays visible on every screen size.
  bool _savedRxExpanded = false;

  // Registration / patient info (initState mein load hota hai).
  String? _patientName;
  String? _uhid;
  String? _age;
  String? _gender;
  String? _doctorName;
  String? _department;
  double? _fee;
  String? _patientId;

  @override
  void initState() {
    super.initState();
    _patientName = widget.patientName;
    _uhid = widget.uhid;
    _doctorName = widget.doctorName;
    _department = widget.department;
    _fee = widget.fee;
    Future.delayed(Duration.zero, _loadRegistration);
  }

  @override
  void dispose() {
    _clinicalController.dispose();
    super.dispose();
  }

  Future<void> _loadRegistration() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final registration = await db.getById(
        ApiConstants.opdRegistrationsTable,
        widget.registrationId,
      );
      if (registration == null || !mounted) return;

      var name = _patientName;
      var uhid = _uhid;
      var age = _age;
      var gender = _gender;

      final patientId = registration['patient_id']?.toString();
      if (patientId != null && patientId.isNotEmpty) {
        final patient = await db.getById(ApiConstants.patientsTable, patientId);
        if (patient != null) {
          final first = patient['first_name']?.toString() ?? '';
          final last = patient['last_name']?.toString() ?? '';
          final fullName = '$first $last'.trim();
          if (fullName.isNotEmpty) name = fullName;
          uhid = patient['uhid']?.toString() ?? uhid;
          age = patient['age']?.toString() ?? age;
          gender = patient['gender']?.toString() ?? gender;
        }
      }

      final doctorName = registration['doctor_name']?.toString();
      final departmentName = registration['department_name']?.toString();
      final feeRaw =
          registration['consultation_fee'] ?? registration['payment_amount'];

      if (!mounted) return;
      setState(() {
        _patientId = patientId;
        _patientName = name;
        _uhid = uhid;
        _age = age;
        _gender = gender;
        if (doctorName != null && doctorName.isNotEmpty) {
          _doctorName = doctorName;
        }
        if (departmentName != null && departmentName.isNotEmpty) {
          _department = departmentName;
        }
        final parsedFee = double.tryParse(feeRaw?.toString() ?? '');
        if (parsedFee != null) _fee = parsedFee;
      });
    } catch (_) {
      // Patient details optional hain — consultation baaki data ke saath chalti
      // rahegi. (Network fail par bhi doctor form bhar sakta hai.)
    }
  }

  // ---------------------------------------------------------------------------
  // Counseling (visit-specific — this OPD registration)
  // ---------------------------------------------------------------------------

  /// Opens the counseling recorder linked to THIS OPD registration. The visit
  /// type is fixed to `opd` — the counseling screen cannot toggle it.
  void _openCounseling() {
    final patientId = _patientId ?? '';
    if (patientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Patient details are still loading. Please try again.'),
        ),
      );
      return;
    }

    final nameParam = Uri.encodeComponent(_patientName ?? '');
    final uhidParam = Uri.encodeComponent(_uhid ?? '');
    context.push(
      '/counseling?patientId=$patientId'
      '&patientName=$nameParam&uhid=$uhidParam'
      '&visitType=opd&opdRegistrationId=${widget.registrationId}',
    );
  }

  // ---------------------------------------------------------------------------
  // Save & Complete
  // ---------------------------------------------------------------------------

  Future<void> _saveAndComplete() async {
    final form = _prescriptionFormKey.currentState;
    final medicinesError = form?.validateMedicines();
    if (medicinesError != null) {
      _showSnack(medicinesError);
      return;
    }

    final medicines =
        form?.collectMedicines() ?? const <Map<String, dynamic>>[];
    final unifiedSections = _clinicalController.toUnifiedJson();
    final history =
        (unifiedSections['history'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final investigations =
        (unifiedSections['investigations'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final advice =
        (unifiedSections['advice'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final hasClinicalData =
        history.isNotEmpty || investigations.isNotEmpty || advice.isNotEmpty;

    if (medicines.isEmpty && !hasClinicalData) {
      _showSnack(
        'Add at least one medicine or fill any history / investigation '
        'detail before saving.',
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final authState = ref.read(authStateProvider);

      final registration = await db.getById(
        ApiConstants.opdRegistrationsTable,
        widget.registrationId,
      );
      final patientId = registration?['patient_id']?.toString();
      if (patientId == null || patientId.isEmpty) {
        throw Exception('Patient not found for this OPD visit.');
      }

      final doctor = await db.getCurrentUserRecord();
      final doctorId = doctor?['id']?.toString();
      if (doctorId == null || doctorId.isEmpty) {
        throw Exception(
          'Doctor record not found. Please re-login and try again.',
        );
      }

      await db.savePrescription(
        patientId: patientId,
        doctorId: doctorId,
        hospitalId: authState.hospitalId,
        opdRegistrationId: widget.registrationId,
        visitType: 'opd',
        medicines: medicines,
        history: history,
        investigations: investigations,
        advice: advice,
      );

      if (!mounted) return;

      form?.resetAfterSave();
      ref.invalidate(opdQueueProvider);
      ref.invalidate(opdPrescriptionsProvider(widget.registrationId));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Consultation saved. Prescription print option is now available '
            'in OPD Queue.',
          ),
        ),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      _showSnack('Failed to save consultation: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Print helpers
  // ---------------------------------------------------------------------------

  Future<void> _printReceipt() async {
    final receiptData = {
      'hospitalName': 'MediFlow HIMS',
      'hospitalAddress': '123, Healthcare Avenue, New Delhi',
      'patientName': _patientName ?? 'Patient',
      'uhid': _uhid ?? 'N/A',
      'doctorName': _doctorName ?? 'N/A',
      'department': _department ?? 'N/A',
      'fee': _fee ?? 0,
      'date': DateTime.now(),
      'receiptNumber':
          'OPD-${widget.registrationId.length >= 8 ? widget.registrationId.substring(0, 8) : widget.registrationId}',
    };
    try {
      await ReceiptService.printReceipt(receiptData);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Print failed. Please try again.')),
      );
    }
  }

  Future<void> _printPrescription(String? prescriptionId) async {
    final db = ref.read(databaseServiceProvider);
    final hospitalId = ref.read(authStateProvider).hospitalId;
    final error = await PrescriptionPrintService.printForOPD(
      db: db,
      opdRegistrationId: widget.registrationId,
      hospitalId: hospitalId,
      prescriptionId: prescriptionId,
      fallbackPatientName: _patientName ?? 'Patient',
      fallbackUhid: _uhid ?? 'N/A',
    );
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('OPD Consultation'),
        actions: [
          IconButton(
            icon: const Icon(Icons.medication),
            tooltip: 'Open full prescription screen',
            onPressed: () async {
              final patientNameParam = Uri.encodeComponent(_patientName ?? '');
              final uhidParam = Uri.encodeComponent(_uhid ?? '');
              await context.push(
                '/doctor/prescription?opdRegistrationId=${widget.registrationId}'
                '&patientName=$patientNameParam&uhid=$uhidParam',
              );
              if (context.mounted) {
                ref.invalidate(opdPrescriptionsProvider(widget.registrationId));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            tooltip: 'Record counseling for this OPD visit',
            onPressed: _openCounseling,
          ),
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Print OPD Receipt',
            onPressed: _printReceipt,
          ),
          IconButton(icon: const Icon(Icons.help_outline), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _buildPatientCard(theme),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: DefaultTabController(
              length: 4,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final isDesktop = width > _savedRxDesktopBreakpoint;
                  final isTablet =
                      width >= _savedRxTabletBreakpoint &&
                      width <= _savedRxDesktopBreakpoint;

                  // TabBar + TabBarView — working area. Desktop par iske
                  // right side mein saved-prescription preview side-by-side
                  // dikhta hai; mobile/tablet par neeche compact panel.
                  final workingArea = Column(
                    children: [
                      TabBar(
                        labelColor: theme.colorScheme.primary,
                        tabs: const [
                          Tab(text: 'History'),
                          Tab(text: 'Prescription'),
                          Tab(text: 'Investigations'),
                          Tab(text: 'Counseling'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _KeepAliveTab(child: _buildHistoryTab(theme)),
                            _KeepAliveTab(child: _buildPrescriptionTab(theme)),
                            _KeepAliveTab(
                              child: _buildInvestigationsTab(theme),
                            ),
                            _KeepAliveTab(child: _buildCounselingTab(theme)),
                          ],
                        ),
                      ),
                    ],
                  );

                  if (isDesktop) {
                    // Laptop/Desktop: side-by-side — working area ko poori
                    // width nahi chheenna, bas ek compact side panel.
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: workingArea),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: _savedPanelWidth(width),
                          child: _buildSavedPrescriptionsSection(
                            theme,
                            isDesktop: true,
                            isTablet: false,
                          ),
                        ),
                      ],
                    );
                  }

                  // Mobile/Tablet: stacked. Saved panel collapsed-by-default
                  // single-line (mobile) ya compact preview (tablet) hota hai.
                  return Column(
                    children: [
                      Expanded(child: workingArea),
                      _buildSavedPrescriptionsSection(
                        theme,
                        isDesktop: false,
                        isTablet: isTablet,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
                ElevatedButton.icon(
                  onPressed: _isSaving ? null : _saveAndComplete,
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: const Text('Save & Complete'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatientCard(ThemeData theme) {
    final name = _patientName ?? 'Patient Name';
    final uhid = _uhid ?? 'XXXXX';
    final ageSex = [
      if (_age != null && _age!.isNotEmpty) _age!,
      if (_gender != null && _gender!.isNotEmpty) _gender!,
    ].join(' / ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.person,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'UHID: $uhid${ageSex.isNotEmpty ? ' | $ageSex' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_doctorName != null && _doctorName!.isNotEmpty)
                    Text(
                      'Dr. $_doctorName',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tabs
  // ---------------------------------------------------------------------------

  Widget _buildHistoryTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [PrescriptionHistoryFields(controller: _clinicalController)],
    );
  }

  Widget _buildPrescriptionTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Medicine-only bulky form. History / Investigations / Counseling apne
        // apne tabs mein hain — bottom ka "Save & Complete" chaaron tabs ka
        // data ek hi complete prescription mein save karta hai.
        DoctorPrescriptionForm(
          key: _prescriptionFormKey,
          embedded: true,
          opdRegistrationId: widget.registrationId,
          patientName: _patientName,
          uhid: _uhid,
        ),
      ],
    );
  }

  Widget _buildInvestigationsTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        PrescriptionInvestigationsFields(controller: _clinicalController),
      ],
    );
  }

  Widget _buildCounselingTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Counseling advice + follow-up — prescription ke `advice` JSONB mein
        // save hota hai aur saved prescription view mein Counseling section ke
        // roop mein dikhta hai.
        PrescriptionAdviceFollowUpFields(controller: _clinicalController),
        const SizedBox(height: 12),
        Text(
          'Counseling Sessions',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Recordings linked to this OPD visit are stacked here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        CounselingVisitHistoryList(
          visitType: 'opd',
          visitId: widget.registrationId,
          patientId: _patientId ?? '',
          patientName: _patientName ?? '',
          uhid: _uhid ?? '',
          onNewSession: _openCounseling,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Saved prescription panel (responsive)
  // ---------------------------------------------------------------------------

  /// Saved-prescription panel breakpoints:
  ///  * < 768            -> mobile: single-line collapsible card
  ///  * 768 - 1024       -> tablet: compact preview + expand
  ///  * > 1024           -> laptop/desktop: side-by-side panel
  static const double _savedRxTabletBreakpoint = 768;
  static const double _savedRxDesktopBreakpoint = 1024;

  /// Desktop side panel width — ~32% of available width, clamped taaki panel
  /// readable rahe aur working area se aadhi screen na chheen le.
  double _savedPanelWidth(double availableWidth) {
    return (availableWidth * 0.32).clamp(300.0, 460.0).toDouble();
  }

  /// Pinned saved-prescription panel — TabBarView ke BAHAR hai, isliye tab
  /// switch karne par saved view kabhi nahi badalta.
  ///
  /// * Mobile: single-line collapsible card (collapsed by default)
  /// * Tablet: compact preview + expand option
  /// * Desktop: side-by-side compact panel with preview/expand
  Widget _buildSavedPrescriptionsSection(
    ThemeData theme, {
    required bool isDesktop,
    required bool isTablet,
  }) {
    final prescriptionsAsync = ref.watch(
      opdPrescriptionsProvider(widget.registrationId),
    );

    return Padding(
      padding: isDesktop
          ? const EdgeInsets.only(right: 12)
          : const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: isDesktop ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSavedPanelHeader(
              theme,
              prescriptionsAsync,
              isDesktop: isDesktop,
              isTablet: isTablet,
            ),
            if (isDesktop || _savedRxExpanded || isTablet)
              const Divider(height: 1),
            if (isDesktop)
              Expanded(
                child: _buildSavedPanelBody(
                  theme,
                  prescriptionsAsync,
                  expanded: _savedRxExpanded,
                ),
              )
            else if (_savedRxExpanded)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: isTablet
                      ? 300
                      : MediaQuery.sizeOf(context).height * 0.45,
                ),
                child: _buildSavedPanelBody(
                  theme,
                  prescriptionsAsync,
                  expanded: true,
                ),
              )
            else if (isTablet)
              _buildTabletCollapsedPreview(theme, prescriptionsAsync),
          ],
        ),
      ),
    );
  }

  /// Panel header — poora header tappable hai aur expand/collapse toggle karta
  /// hai. Mobile collapsed par ek hi line dikhti hai; baaki states mein title +
  /// subtitle ka compact two-line header.
  Widget _buildSavedPanelHeader(
    ThemeData theme,
    AsyncValue<List<Map<String, dynamic>>> prescriptionsAsync, {
    required bool isDesktop,
    required bool isTablet,
  }) {
    final texts = _savedPanelTexts(prescriptionsAsync);
    final showTwoLines = isDesktop || isTablet || _savedRxExpanded;

    return InkWell(
      onTap: () => setState(() => _savedRxExpanded = !_savedRxExpanded),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          isDesktop ? 10 : 8,
          8,
          isDesktop ? 10 : 8,
        ),
        child: Row(
          children: [
            Icon(
              Icons.description_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: showTwoLines
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          texts.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          texts.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      texts.singleLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            Icon(
              isDesktop
                  ? (_savedRxExpanded
                        ? Icons.close_fullscreen
                        : Icons.open_in_full)
                  : (_savedRxExpanded ? Icons.expand_less : Icons.expand_more),
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// Title / subtitle / single-line labels for the panel header.
  ({String title, String subtitle, String singleLine}) _savedPanelTexts(
    AsyncValue<List<Map<String, dynamic>>> prescriptionsAsync,
  ) {
    return prescriptionsAsync.maybeWhen(
      data: (prescriptions) {
        if (prescriptions.isEmpty) {
          return (
            title: 'Saved Prescription',
            subtitle: 'No prescriptions saved yet',
            singleLine: 'No saved prescription yet',
          );
        }

        final count = prescriptions.length;
        final medicineCount = prescriptions.fold<int>(
          0,
          (sum, prescription) =>
              sum + _prescriptionMedicines(prescription).length,
        );
        final medicineLabel = medicineCount == 1
            ? '1 medicine'
            : '$medicineCount medicines';
        final latestDate = _asText(prescriptions.first['prescription_date']);
        final dateLabel = latestDate.isEmpty ? '' : ' · $latestDate';

        return (
          title: 'Saved Prescription ($count)',
          subtitle: 'History • Medicines • Investigations • Counseling',
          singleLine: 'Saved Rx ($count) · $medicineLabel$dateLabel',
        );
      },
      orElse: () => (
        title: 'Saved Prescription',
        subtitle: 'Loading saved prescription…',
        singleLine: 'Saved Prescription',
      ),
    );
  }

  /// Panel body — expanded par COMPLETE prescription cards, collapsed (desktop
  /// preview) par compact preview cards.
  Widget _buildSavedPanelBody(
    ThemeData theme,
    AsyncValue<List<Map<String, dynamic>>> prescriptionsAsync, {
    required bool expanded,
  }) {
    return prescriptionsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Failed to load prescriptions: $error',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      data: (prescriptions) {
        if (prescriptions.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ListTile(
                leading: const Icon(Icons.medication_outlined),
                title: const Text('No prescriptions saved yet.'),
                subtitle: const Text(
                  'Save & Complete dabate hi poora prescription '
                  '(History + Medicines + Investigations + Counseling) '
                  'yahan ek saath dikhega.',
                ),
              ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          children: [
            for (final prescription in prescriptions)
              if (expanded)
                _completePrescriptionCard(theme, prescription)
              else
                _compactPrescriptionCard(
                  theme,
                  prescription,
                  onTap: () => setState(() => _savedRxExpanded = true),
                ),
          ],
        );
      },
    );
  }

  /// Tablet collapsed state — latest prescription ka compact preview.
  Widget _buildTabletCollapsedPreview(
    ThemeData theme,
    AsyncValue<List<Map<String, dynamic>>> prescriptionsAsync,
  ) {
    return SizedBox(
      height: 104,
      child: prescriptionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Failed to load prescriptions: $error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (prescriptions) {
          if (prescriptions.isEmpty) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('No prescriptions saved yet.'),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _compactPrescriptionCard(
              theme,
              prescriptions.first,
              onTap: () => setState(() => _savedRxExpanded = true),
            ),
          );
        },
      ),
    );
  }

  /// Compact one-card preview: date + medicines + diagnosis + print action.
  /// Tapping the card expands the panel to the complete prescription view.
  Widget _compactPrescriptionCard(
    ThemeData theme,
    Map<String, dynamic> prescription, {
    VoidCallback? onTap,
  }) {
    final items = _prescriptionMedicines(prescription);
    final date = _asText(prescription['prescription_date']);
    final prescriptionId = prescription['id']?.toString();
    final visitType = prescription['visit_type']?.toString() ?? 'opd';

    final names = items
        .map((item) => item['medicine_name']?.toString() ?? 'Medicine')
        .take(3)
        .join(' • ');
    final more = items.length > 3 ? '  +${items.length - 3} more' : '';

    final history = _asMap(prescription['history']);
    final notes = _asMap(prescription['clinical_notes']);
    final diagnosis = _firstNonEmpty(history['diagnosis'], notes['diagnosis']);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.medication,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${date.isEmpty ? 'N/A' : date}'
                      '${visitType == 'ipd' ? ' (IPD)' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      names.isEmpty ? 'No medicines' : '$names$more',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (diagnosis.isNotEmpty)
                      Text(
                        'Dx: $diagnosis',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.print, color: Colors.blue, size: 20),
                tooltip: 'Print Complete Prescription',
                onPressed: () => _printPrescription(prescriptionId),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One saved prescription rendered as a COMPLETE unified document.
  Widget _completePrescriptionCard(
    ThemeData theme,
    Map<String, dynamic> prescription,
  ) {
    final items = _prescriptionMedicines(prescription);
    final date = _asText(prescription['prescription_date']);
    final prescriptionId = prescription['id']?.toString();
    final visitType = prescription['visit_type']?.toString() ?? 'opd';

    // Unified JSONB columns pehle; legacy `clinical_notes` fallback ke liye.
    final history = _asMap(prescription['history']);
    final investigations = _asMap(prescription['investigations']);
    final advice = _asMap(prescription['advice']);
    final notes = _asMap(prescription['clinical_notes']);

    final historyEntries = _historyEntries(history, notes);
    final investigationEntries = _investigationEntries(investigations, notes);
    final counselingEntries = _counselingEntries(advice, notes);

    final hasClinicalData =
        historyEntries.isNotEmpty ||
        investigationEntries.isNotEmpty ||
        counselingEntries.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Prescription: ${date.isEmpty ? 'N/A' : date}'
                    '${visitType == 'ipd' ? ' (IPD)' : ''}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.print, color: Colors.blue),
                  tooltip: 'Print Complete Prescription',
                  onPressed: () => _printPrescription(prescriptionId),
                ),
              ],
            ),
            if (historyEntries.isNotEmpty) ...[
              _sectionTitle(theme, 'History', Icons.history),
              for (final entry in historyEntries)
                _detailLine(theme, entry.key, entry.value),
            ],
            if (items.isNotEmpty) ...[
              _sectionTitle(theme, 'Medicines (Rx)', Icons.medication),
              for (final item in items) _medicineLine(theme, item),
            ],
            if (investigationEntries.isNotEmpty) ...[
              _sectionTitle(theme, 'Investigations', Icons.biotech),
              for (final entry in investigationEntries)
                _detailLine(theme, entry.key, entry.value),
            ],
            if (counselingEntries.isNotEmpty) ...[
              _sectionTitle(
                theme,
                'Counseling & Advice',
                Icons.record_voice_over,
              ),
              for (final entry in counselingEntries)
                _detailLine(theme, entry.key, entry.value),
            ],
            if (items.isEmpty && !hasClinicalData)
              Text(
                'No medicines or clinical details in this prescription.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Complete-prescription helpers
  // ---------------------------------------------------------------------------

  Widget _sectionTitle(ThemeData theme, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailLine(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _medicineLine(ThemeData theme, Map<String, dynamic> item) {
    final name = item['medicine_name']?.toString() ?? 'Medicine';
    final strength = _asText(item['strength']);
    final title = strength.isEmpty ? name : '$name ($strength)';
    final details = [
      if (_asText(item['dosage']).isNotEmpty) 'Dosage: ${item['dosage']}',
      if (_asText(item['frequency']).isNotEmpty)
        'Frequency: ${item['frequency']}',
      if (_asText(item['route']).isNotEmpty) 'Route: ${item['route']}',
      if (_asText(item['duration']).isNotEmpty) 'Duration: ${item['duration']}',
      if (item['custom_times'] is List &&
          (item['custom_times'] as List).isNotEmpty)
        'Timing: ${(item['custom_times'] as List).join(', ')}',
      if (_asText(item['instructions']).isNotEmpty)
        'Note: ${item['instructions']}',
    ].join('\n');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.medication, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _prescriptionMedicines(
    Map<String, dynamic> prescription,
  ) {
    final rawMedicines = prescription['medicines'];
    if (rawMedicines is List && rawMedicines.isNotEmpty) {
      return rawMedicines
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    final rawItems = prescription['items'];
    if (rawItems is List) {
      return rawItems
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  List<MapEntry<String, String>> _historyEntries(
    Map<String, dynamic> history,
    Map<String, dynamic> notes,
  ) {
    String pick(dynamic primary, dynamic fallback) =>
        _firstNonEmpty(primary, fallback);

    final entries = <MapEntry<String, String>>[
      MapEntry(
        'Chief Complaints',
        pick(history['chief_complaints'], notes['chief_complaints']),
      ),
      MapEntry(
        'HOPI',
        pick(history['history_presenting_illness'], notes['hopi']),
      ),
      MapEntry(
        'Past History',
        pick(history['past_history'], notes['past_history']),
      ),
      MapEntry(
        'Personal / Family',
        pick(
          _joinNonEmpty([
            history['personal_history'],
            history['family_history'],
          ]),
          notes['personal_family_history'],
        ),
      ),
      MapEntry('Allergies', pick(history['allergies'], notes['drug_allergy'])),
      MapEntry(
        'Examination',
        pick(history['examination_findings'], notes['examination']),
      ),
      MapEntry('Diagnosis', pick(history['diagnosis'], notes['diagnosis'])),
      MapEntry(
        'Vitals',
        pick(_vitalsLine(history['vitals']), _vitalsLine(notes['vitals'])),
      ),
    ];

    return entries.where((e) => e.value.isNotEmpty).toList();
  }

  List<MapEntry<String, String>> _investigationEntries(
    Map<String, dynamic> investigations,
    Map<String, dynamic> notes,
  ) {
    final legacy = _asMap(notes['investigations']);

    String pick(
      String unifiedKey,
      String legacyKey, {
      bool legacyList = false,
    }) {
      final unifiedList = _asStringList(investigations[unifiedKey]);
      if (unifiedList.isNotEmpty) return unifiedList.join(', ');
      final legacyValue = legacy[legacyKey];
      if (legacyList) return _asStringList(legacyValue).join(', ');
      return _asText(legacyValue);
    }

    final entries = <MapEntry<String, String>>[
      MapEntry('Lab Tests', pick('lab_tests', 'blood', legacyList: true)),
      MapEntry(
        'Radiology / Imaging',
        pick('radiology', 'radiology', legacyList: true),
      ),
      MapEntry(
        'Other Investigations',
        pick('other_investigations', 'previous_findings'),
      ),
    ];

    return entries.where((e) => e.value.isNotEmpty).toList();
  }

  List<MapEntry<String, String>> _counselingEntries(
    Map<String, dynamic> advice,
    Map<String, dynamic> notes,
  ) {
    final entries = <MapEntry<String, String>>[];

    final followUp = _firstNonEmpty(
      advice['follow_up_date'],
      notes['follow_up'],
    );
    if (followUp.isNotEmpty) entries.add(MapEntry('Follow-up', followUp));

    final dietary = _asText(advice['dietary_advice']);
    if (dietary.isNotEmpty) entries.add(MapEntry('Dietary Advice', dietary));

    final activity = _asText(advice['activity_advice']);
    if (activity.isNotEmpty) entries.add(MapEntry('Activity Advice', activity));

    final other = _asText(advice['other_advice']);
    if (other.isNotEmpty) entries.add(MapEntry('Other Advice', other));

    // Legacy `clinical_notes.advice` sirf tab dikhao jab unified advice keys
    // khali hon (old saved rows ke liye).
    final legacyAdvice = _asText(notes['advice']);
    if (dietary.isEmpty &&
        activity.isEmpty &&
        other.isEmpty &&
        legacyAdvice.isNotEmpty) {
      entries.add(MapEntry('Advice', legacyAdvice));
    }

    return entries;
  }

  Map<String, dynamic> _asMap(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};

  String _asText(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  String _firstNonEmpty(dynamic primary, dynamic fallback) {
    final value = _asText(primary);
    if (value.isNotEmpty) return value;
    return _asText(fallback);
  }

  String _joinNonEmpty(List<dynamic> values, [String separator = ' • ']) {
    return values
        .map(_asText)
        .where((value) => value.isNotEmpty)
        .join(separator);
  }

  List<String> _asStringList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final text = _asText(value);
    return text.isEmpty ? const <String>[] : [text];
  }

  String _vitalsLine(dynamic rawVitals) {
    if (rawVitals is! Map) return '';
    final vitals = Map<String, dynamic>.from(rawVitals);
    final parts = <String>[
      if (_asText(vitals['bp']).isNotEmpty) 'BP: ${vitals['bp']}',
      if (_asText(vitals['pulse']).isNotEmpty) 'Pulse: ${vitals['pulse']}',
      if (_asText(vitals['temp']).isNotEmpty) 'Temp: ${vitals['temp']}',
      if (_asText(vitals['spo2']).isNotEmpty) 'SpO₂: ${vitals['spo2']}',
      if (_asText(vitals['weight']).isNotEmpty) 'Weight: ${vitals['weight']}',
    ];
    return parts.join(' • ');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Tab ke off-screen hone par bhi uski state alive rakhta hai taaki
/// Prescription tab mein bhara hua data (medicines draft) kabhi lost na ho.
class _KeepAliveTab extends StatefulWidget {
  final Widget child;

  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
