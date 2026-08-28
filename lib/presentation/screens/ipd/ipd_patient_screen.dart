import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../core/utils/pdf_font_helper.dart';
import '../../../core/utils/share_utils.dart';
import '../../../services/print_prescription.dart';
import '../../widgets/counseling_visit_history_list.dart';
import '../../widgets/smart_navigation.dart';

class IPDPatientScreen extends ConsumerStatefulWidget {
  final String admissionId;
  const IPDPatientScreen({super.key, required this.admissionId});

  @override
  ConsumerState<IPDPatientScreen> createState() => _IPDPatientScreenState();
}

class _IPDPatientScreenState extends ConsumerState<IPDPatientScreen> {
  bool _tprViewChart = true;

  @override
  Widget build(BuildContext context) {
    final patientAsync = ref.watch(ipdPatientProvider(widget.admissionId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('IPD Patient Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh dashboard',
            onPressed: () =>
                ref.invalidate(ipdPatientProvider(widget.admissionId)),
          ),
        ],
      ),
      body: patientAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorView(
          message: 'Failed to load IPD patient data.\n$error',
          onRetry: () => ref.invalidate(ipdPatientProvider(widget.admissionId)),
        ),
        data: (data) => _buildDashboard(context, data),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Main dashboard layout
  // ---------------------------------------------------------------------------

  Widget _buildDashboard(BuildContext context, Map<String, dynamic> data) {
    final theme = Theme.of(context);

    final admission =
        (data['admission'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final patient = (data['patient'] as Map?)?.cast<String, dynamic>();
    final bed = (data['bed'] as Map?)?.cast<String, dynamic>();
    final vitals =
        (data['vitals'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final progressNotes =
        (data['progress_notes'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final medications =
        (data['medications'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final reports =
        (data['reports'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    final patientName = _patientName(patient);
    final uhid = patient?['uhid']?.toString() ?? 'N/A';
    final bedNumber = bed?['bed_number']?.toString() ?? 'N/A';
    final ward = _formatWardType(
      admission['ward_type']?.toString() ??
          bed?['ward_type']?.toString() ??
          'general',
    );
    final diagnosis = admission['diagnosis']?.toString() ?? 'N/A';
    final admissionDate = _parseDate(admission['admission_date']);
    final patientId = admission['patient_id']?.toString() ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPatientHeaderCard(
            theme,
            patientName: patientName,
            uhid: uhid,
            admissionId: widget.admissionId,
            admissionDate: admissionDate,
            bedNumber: bedNumber,
            ward: ward,
            diagnosis: diagnosis,
          ),
          const SizedBox(height: 16),
          _buildGroupedSections(
            theme,
            patientId: patientId,
            patientName: patientName,
            uhid: uhid,
            vitals: vitals,
            progressNotes: progressNotes,
            medications: medications,
            reports: reports,
          ),
          const SizedBox(height: 24),
          _buildActionButtons(
            patientId: patientId,
            patientName: patientName,
            uhid: uhid,
          ),
        ],
      ),
    );
  }

  Widget _buildPatientHeaderCard(
    ThemeData theme, {
    required String patientName,
    required String uhid,
    required String admissionId,
    required DateTime? admissionDate,
    required String bedNumber,
    required String ward,
    required String diagnosis,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                        patientName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('UHID: $uhid', style: theme.textTheme.bodySmall),
                      Text(
                        'Admission ID: ${admissionId.substring(0, admissionId.length < 8 ? admissionId.length : 8)}...',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Wrap(
              alignment: WrapAlignment.start,
              spacing: 24,
              runSpacing: 16,
              children: [
                _infoChip('Bed', bedNumber, Icons.bed),
                _infoChip('Ward', ward, Icons.meeting_room),
                _infoChip('Diagnosis', diagnosis, Icons.medical_services),
                _infoChip(
                  'Admission Date',
                  admissionDate?.toDisplayDate ?? 'N/A',
                  Icons.calendar_today,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Grouped record sections (TPR / Drug chart / Progress notes / Reports)
  // ---------------------------------------------------------------------------

  Widget _buildGroupedSections(
    ThemeData theme, {
    required String patientId,
    required String patientName,
    required String uhid,
    required List<Map<String, dynamic>> vitals,
    required List<Map<String, dynamic>> progressNotes,
    required List<Map<String, dynamic>> medications,
    required List<Map<String, dynamic>> reports,
  }) {
    return Column(
      children: [
        _buildTprGroup(vitals, patientName: patientName, uhid: uhid),
        _buildMedsGroup(medications, patientName: patientName, uhid: uhid),
        _buildIpdPrescriptionsGroup(
          patientName: patientName,
          uhid: uhid,
        ),
        _buildNotesGroup(progressNotes, patientName: patientName, uhid: uhid),
        _buildReportsGroup(reports, patientName: patientName, uhid: uhid),
        _buildCounselingGroup(patientId, patientName, uhid),
      ],
    );
  }

  /// Shared visual wrapper for every record group.
  Widget _recordGroupCard({
    required String title,
    required IconData icon,
    required Color color,
    required String subtitle,
    required int count,
    required List<Widget> headerActions,
    required Widget child,
    bool showCount = true,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        showCount
                            ? '$count record${count == 1 ? '' : 's'} • $subtitle'
                            : subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                ...headerActions,
              ],
            ),
            const Divider(height: 20),
            child,
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. TPR Chart (Vitals)
  // ---------------------------------------------------------------------------

  Widget _buildTprGroup(
    List<Map<String, dynamic>> vitals, {
    required String patientName,
    required String uhid,
  }) {
    return _recordGroupCard(
      title: 'TPR Chart (Vitals)',
      icon: Icons.monitor_heart_outlined,
      color: Colors.redAccent,
      subtitle: 'Temperature • Pulse • Respiration • BP • SpO₂',
      count: vitals.length,
      headerActions: [
        IconButton(
          tooltip: 'Download TPR chart (PDF)',
          icon: const Icon(Icons.download),
          onPressed: () => _downloadTprPdf(vitals, patientName, uhid),
        ),
        IconButton(
          tooltip: 'Record vitals',
          icon: const Icon(Icons.add),
          onPressed: () => _showVitalsForm(),
        ),
      ],
      child: vitals.isEmpty
          ? _emptyState(Icons.monitor_heart_outlined, 'No vitals recorded yet.')
          : _buildTprSection(vitals),
    );
  }

  Widget _buildTprSection(List<Map<String, dynamic>> vitals) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('Chart'),
                icon: Icon(Icons.show_chart),
              ),
              ButtonSegment(
                value: false,
                label: Text('Table'),
                icon: Icon(Icons.table_chart_outlined),
              ),
            ],
            selected: {_tprViewChart},
            onSelectionChanged: (selection) =>
                setState(() => _tprViewChart = selection.first),
          ),
        ),
        const SizedBox(height: 12),
        if (_tprViewChart) _buildTprChart(vitals) else _buildTprTable(vitals),
      ],
    );
  }

  Widget _buildTprChart(List<Map<String, dynamic>> vitals) {
    final theme = Theme.of(context);

    final tempSpots = <FlSpot>[];
    final pulseSpots = <FlSpot>[];
    final respSpots = <FlSpot>[];
    final values = <double>[];

    for (var i = 0; i < vitals.length; i++) {
      final vital = vitals[i];
      final temp = _toDouble(vital['temperature']);
      final pulse = _toDouble(vital['pulse_rate']);
      final resp = _toDouble(vital['respiration_rate']);

      if (temp != null) values.add(temp);
      if (pulse != null) values.add(pulse);
      if (resp != null) values.add(resp);

      tempSpots.add(
        temp == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), temp),
      );
      pulseSpots.add(
        pulse == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), pulse),
      );
      respSpots.add(
        resp == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), resp),
      );
    }

    var minY = values.isEmpty ? 0.0 : values.first;
    var maxY = values.isEmpty ? 100.0 : values.first;
    for (final value in values) {
      if (value < minY) minY = value;
      if (value > maxY) maxY = value;
    }
    final paddedMin = minY - 5;
    minY = paddedMin < 0 ? 0.0 : paddedMin;
    maxY = maxY + 5;
    if (maxY <= minY) maxY = minY + 10;

    final maxX = vitals.length > 1 ? (vitals.length - 1).toDouble() : 1.0;
    final labelStep = (vitals.length / 6)
        .ceil()
        .clamp(1, vitals.length)
        .toInt();
    final yInterval = _yInterval(maxY - minY);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _latestVitalSummary(vitals),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _legendItem(Colors.red, 'Temperature (°F)'),
            _legendItem(Colors.blue, 'Pulse (bpm)'),
            _legendItem(Colors.green, 'Respiration (/min)'),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 240,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: maxX,
              minY: minY,
              maxY: maxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: yInterval,
              ),
              borderData: FlBorderData(show: true),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: yInterval,
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: 1,
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 ||
                          index >= vitals.length ||
                          index % labelStep != 0) {
                        return const SizedBox.shrink();
                      }
                      final recordedAt = _parseDate(
                        vitals[index]['recorded_at'],
                      );
                      return SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text(
                          recordedAt?.toTimeString ?? '$index',
                          style: const TextStyle(fontSize: 9),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: const LineTouchData(),
              lineBarsData: [
                LineChartBarData(
                  spots: tempSpots,
                  color: Colors.red,
                  barWidth: 2.5,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  dotData: const FlDotData(show: true),
                ),
                LineChartBarData(
                  spots: pulseSpots,
                  color: Colors.blue,
                  barWidth: 2.5,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  dotData: const FlDotData(show: true),
                ),
                LineChartBarData(
                  spots: respSpots,
                  color: Colors.green,
                  barWidth: 2.5,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  dotData: const FlDotData(show: true),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'X-axis: recording time (oldest → newest)',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _latestVitalSummary(List<Map<String, dynamic>> vitals) {
    final latest = vitals.isNotEmpty ? vitals.last : null;
    if (latest == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        _metricChip('Latest BP', _bpText(latest)),
        _metricChip('Latest SpO₂', '${_orDash(latest['spo2'])}%'),
        _metricChip('Recorded', _orDash(_whoString(latest, isVitals: true))),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildTprTable(List<Map<String, dynamic>> vitals) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 20,
        columns: const [
          DataColumn(label: Text('Date & Time')),
          DataColumn(label: Text('T (°F)')),
          DataColumn(label: Text('P (bpm)')),
          DataColumn(label: Text('R (/min)')),
          DataColumn(label: Text('BP (mmHg)')),
          DataColumn(label: Text('SpO₂ (%)')),
          DataColumn(label: Text('Recorded By')),
          DataColumn(label: Text('')),
        ],
        rows: [
          for (final vital in vitals)
            DataRow(
              cells: [
                DataCell(Text(_dateTimeOrDash(vital['recorded_at']))),
                DataCell(Text(_orDash(vital['temperature']))),
                DataCell(Text(_orDash(vital['pulse_rate']))),
                DataCell(Text(_orDash(vital['respiration_rate']))),
                DataCell(Text(_bpText(vital))),
                DataCell(Text(_orDash(vital['spo2']))),
                DataCell(Text(_orDash(_whoString(vital, isVitals: true)))),
                DataCell(
                  _recordMenu(vital, onEdit: () => _showVitalsForm(vital)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. Drug Chart (Medications)
  // ---------------------------------------------------------------------------

  Widget _buildMedsGroup(
    List<Map<String, dynamic>> medications, {
    required String patientName,
    required String uhid,
  }) {
    return _recordGroupCard(
      title: 'Drug Chart',
      icon: Icons.medication_outlined,
      color: Colors.teal,
      subtitle: 'Medications • dosage • frequency • duration',
      count: medications.length,
      headerActions: [
        IconButton(
          tooltip: 'Download drug chart (PDF)',
          icon: const Icon(Icons.download),
          onPressed: () => _downloadMedsPdf(medications, patientName, uhid),
        ),
        IconButton(
          tooltip: 'Add medication',
          icon: const Icon(Icons.add),
          onPressed: () => _showMedicationForm(),
        ),
      ],
      child: medications.isEmpty
          ? _emptyState(
              Icons.medication_outlined,
              'No medications charted yet.',
            )
          : Column(
              children: [for (final med in medications) _medicationCard(med)],
            ),
    );
  }

  Widget _medicationCard(Map<String, dynamic> med) {
    final theme = Theme.of(context);
    final startDate = _parseDate(med['start_date']);
    final endDate = _parseDate(med['end_date']);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isActive = endDate == null || !endDate.isBefore(today);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Icon(
                    Icons.medication,
                    size: 16,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    med['medicine_name']?.toString() ?? 'Unknown medicine',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Chip(
                  label: Text(isActive ? 'Active' : 'Stopped'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: isActive
                      ? Colors.green.withValues(alpha: 0.15)
                      : theme.colorScheme.surfaceContainerHighest,
                ),
                _recordMenu(med, onEdit: () => _showMedicationForm(med)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${med['dosage']?.toString() ?? '--'} • ${med['frequency']?.toString() ?? '--'}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 2),
            Text(
              '${startDate?.toDisplayDate ?? 'N/A'} → ${endDate?.toDisplayDate ?? 'Ongoing'}',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 16),
            _auditTrail(med),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2b. Unified IPD Prescriptions (medicines-only prescriptions)
  // ---------------------------------------------------------------------------

  Widget _buildIpdPrescriptionsGroup({
    required String patientName,
    required String uhid,
  }) {
    final theme = Theme.of(context);
    final prescriptionsAsync = ref.watch(
      ipdPrescriptionsProvider(widget.admissionId),
    );

    return _recordGroupCard(
      title: 'IPD Prescriptions',
      icon: Icons.medication_liquid_outlined,
      color: Colors.teal,
      subtitle: 'Unified prescriptions (medicines only)',
      count: prescriptionsAsync.valueOrNull?.length ?? 0,
      headerActions: [
        IconButton(
          tooltip: 'New IPD prescription',
          icon: const Icon(Icons.add),
          onPressed: () {
            final patientNameParam = Uri.encodeComponent(patientName);
            context.push(
              '/doctor/prescription?patientName=$patientNameParam'
              '&ipdAdmissionId=${widget.admissionId}',
            );
          },
        ),
      ],
      child: prescriptionsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => Padding(
          padding: const EdgeInsets.all(8),
          child: Text('Failed to load IPD prescriptions: $error'),
        ),
        data: (prescriptions) {
          if (prescriptions.isEmpty) {
            return _emptyState(
              Icons.medication_liquid_outlined,
              'No IPD prescriptions saved yet.',
            );
          }
          return Column(
            children: [
              for (final prescription in prescriptions)
                _ipdPrescriptionCard(theme, prescription, patientName, uhid),
            ],
          );
        },
      ),
    );
  }

  Widget _ipdPrescriptionCard(
    ThemeData theme,
    Map<String, dynamic> prescription,
    String patientName,
    String uhid,
  ) {
    final medicines =
        (prescription['medicines'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final date = prescription['prescription_date']?.toString() ?? 'N/A';
    final prescriptionId = prescription['id']?.toString();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Prescription Date: $date',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.print, color: Colors.blue),
                  tooltip: 'Print IPD prescription',
                  onPressed: () => _printIpdPrescription(
                    prescriptionId,
                    patientName,
                    uhid,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (medicines.isEmpty)
              const Text('No medicines in this prescription.')
            else
              for (final medicine in medicines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.medication, size: 20),
                  title: Text(
                    medicine['medicine_name']?.toString() ?? 'Medicine',
                  ),
                  subtitle: Text(
                    [
                      if (medicine['dosage']?.toString().isNotEmpty == true)
                        'Dosage: ${medicine['dosage']}',
                      if (medicine['frequency']?.toString().isNotEmpty == true)
                        'Frequency: ${medicine['frequency']}',
                      if (medicine['route']?.toString().isNotEmpty == true)
                        'Route: ${medicine['route']}',
                      if (medicine['duration']?.toString().isNotEmpty == true)
                        'Duration: ${medicine['duration']}',
                      if (medicine['instructions']?.toString().isNotEmpty ==
                          true)
                        'Note: ${medicine['instructions']}',
                    ].join('\n'),
                  ),
                  isThreeLine: true,
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _printIpdPrescription(
    String? prescriptionId,
    String patientName,
    String uhid,
  ) async {
    final db = ref.read(databaseServiceProvider);
    final hospitalId = ref.read(authStateProvider).hospitalId;
    final error = await PrescriptionPrintService.printForIPD(
      db: db,
      ipdAdmissionId: widget.admissionId,
      hospitalId: hospitalId,
      prescriptionId: prescriptionId,
      fallbackPatientName: patientName,
      fallbackUhid: uhid,
    );
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 3. Daily Progress Notes
  // ---------------------------------------------------------------------------

  Widget _buildNotesGroup(
    List<Map<String, dynamic>> notes, {
    required String patientName,
    required String uhid,
  }) {
    return _recordGroupCard(
      title: 'Daily Progress Notes',
      icon: Icons.event_note_outlined,
      color: Colors.indigo,
      subtitle: 'Chronological clinical notes',
      count: notes.length,
      headerActions: [
        IconButton(
          tooltip: 'Download progress notes (PDF)',
          icon: const Icon(Icons.download),
          onPressed: () => _downloadNotesPdf(notes, patientName, uhid),
        ),
        IconButton(
          tooltip: 'Add progress note',
          icon: const Icon(Icons.note_add_outlined),
          onPressed: () => _showProgressNoteForm(),
        ),
      ],
      child: notes.isEmpty
          ? _emptyState(Icons.note_alt_outlined, 'No progress notes yet.')
          : Column(
              children: [
                for (var i = 0; i < notes.length; i++)
                  _noteCard(notes[i], index: i + 1),
              ],
            ),
    );
  }

  Widget _noteCard(Map<String, dynamic> note, {required int index}) {
    final theme = Theme.of(context);
    final date =
        _parseDate(note['note_date']) ?? _parseDate(note['created_at']);
    final doctor = _userLabel(note, 'doctor');
    final doctorText = doctor.isEmpty ? '' : ' • $doctor';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    '$index',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${date?.toDisplayDateTime ?? 'N/A'}$doctorText',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _recordMenu(note, onEdit: () => _showProgressNoteForm(note)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              note['note_text']?.toString() ?? '',
              style: theme.textTheme.bodyMedium,
            ),
            const Divider(height: 16),
            _auditTrail(note),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. Reports
  // ---------------------------------------------------------------------------

  Widget _buildReportsGroup(
    List<Map<String, dynamic>> reports, {
    required String patientName,
    required String uhid,
  }) {
    return _recordGroupCard(
      title: 'Reports',
      icon: Icons.folder_open,
      color: Colors.deepOrange,
      subtitle: 'Investigation & lab reports',
      count: reports.length,
      headerActions: [
        IconButton(
          tooltip: 'Download reports summary (PDF)',
          icon: const Icon(Icons.download),
          onPressed: () => _downloadReportsPdf(reports, patientName, uhid),
        ),
        IconButton(
          tooltip: 'Add report',
          icon: const Icon(Icons.add),
          onPressed: () => _showReportForm(),
        ),
      ],
      child: reports.isEmpty
          ? _emptyState(Icons.folder_open, 'No reports available yet.')
          : Column(
              children: [for (final report in reports) _reportCard(report)],
            ),
    );
  }

  Widget _reportCard(Map<String, dynamic> report) {
    final theme = Theme.of(context);
    final date = _parseDate(report['report_date']);
    final url = report['report_url']?.toString() ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  child: Icon(Icons.description_outlined, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    report['report_type']?.toString() ?? 'Report',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _reportMenu(report),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              date?.toDisplayDate ?? 'N/A',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 16),
            _auditTrail(report),
            if (url.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => _openReport(url),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('View'),
                  ),
                  TextButton.icon(
                    onPressed: () => _downloadReportFile(report),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download'),
                  ),
                  TextButton.icon(
                    onPressed: () => _shareReportFile(report),
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('Share'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 5. Counseling sessions (kept from the earlier tabbed dashboard)
  // ---------------------------------------------------------------------------

  Widget _buildCounselingGroup(
    String patientId,
    String patientName,
    String uhid,
  ) {
    return _recordGroupCard(
      title: 'Counseling Sessions',
      icon: Icons.record_voice_over_outlined,
      color: Colors.purple,
      subtitle: 'Recordings linked to this IPD admission are stacked here.',
      count: 0,
      headerActions: const [],
      showCount: false,
      child: CounselingVisitHistoryList(
        visitType: 'ipd',
        visitId: widget.admissionId,
        patientId: patientId,
        patientName: patientName,
        uhid: uhid,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Per-record popup menus
  // ---------------------------------------------------------------------------

  Widget _recordMenu(Map<String, dynamic> record, {VoidCallback? onEdit}) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: 'Record actions',
      onSelected: (value) {
        switch (value) {
          case 'download':
            _downloadRecordPdf(record);
            break;
          case 'share':
            _shareRecordText(record);
            break;
          case 'edit':
            onEdit?.call();
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'download',
          child: _MenuRow(icon: Icons.download, label: 'Download PDF'),
        ),
        const PopupMenuItem(
          value: 'share',
          child: _MenuRow(icon: Icons.share, label: 'Share'),
        ),
        if (onEdit != null)
          const PopupMenuItem(
            value: 'edit',
            child: _MenuRow(icon: Icons.edit_outlined, label: 'Edit'),
          ),
      ],
    );
  }

  Widget _reportMenu(Map<String, dynamic> report) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: 'Report actions',
      onSelected: (value) {
        switch (value) {
          case 'view':
            _openReport(report['report_url']?.toString() ?? '');
            break;
          case 'download':
            _downloadReportFile(report);
            break;
          case 'share':
            _shareReportFile(report);
            break;
          case 'edit':
            _showReportForm(report);
            break;
          case 'pdf':
            _downloadRecordPdf(report);
            break;
        }
      },
      itemBuilder: (context) => [
        if ((report['report_url']?.toString() ?? '').isNotEmpty)
          const PopupMenuItem(
            value: 'view',
            child: _MenuRow(icon: Icons.open_in_new, label: 'View file'),
          ),
        if ((report['report_url']?.toString() ?? '').isNotEmpty)
          const PopupMenuItem(
            value: 'download',
            child: _MenuRow(icon: Icons.download, label: 'Download file'),
          ),
        if ((report['report_url']?.toString() ?? '').isNotEmpty)
          const PopupMenuItem(
            value: 'share',
            child: _MenuRow(icon: Icons.share, label: 'Share file'),
          ),
        const PopupMenuItem(
          value: 'pdf',
          child: _MenuRow(icon: Icons.picture_as_pdf, label: 'Download PDF'),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: _MenuRow(icon: Icons.edit_outlined, label: 'Edit'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Download / share helpers
  // ---------------------------------------------------------------------------

  Future<void> _downloadTprPdf(
    List<Map<String, dynamic>> vitals,
    String patientName,
    String uhid,
  ) async {
    await _printPdf(
      title: 'TPR Chart — $patientName ($uhid)',
      headers: const [
        'Date & Time',
        'T (°F)',
        'P (bpm)',
        'R (/min)',
        'BP (mmHg)',
        'SpO₂ (%)',
        'Recorded By',
      ],
      rows: [
        for (final vital in vitals)
          [
            _dateTimeOrDash(vital['recorded_at']),
            _orDash(vital['temperature']),
            _orDash(vital['pulse_rate']),
            _orDash(vital['respiration_rate']),
            _bpText(vital),
            _orDash(vital['spo2']),
            _whoString(vital, isVitals: true),
          ],
      ],
      fileName: 'TPR_Chart_${_shortId(widget.admissionId)}.pdf',
    );
  }

  Future<void> _downloadMedsPdf(
    List<Map<String, dynamic>> medications,
    String patientName,
    String uhid,
  ) async {
    await _printPdf(
      title: 'Drug Chart — $patientName ($uhid)',
      headers: const [
        '#',
        'Medicine',
        'Dosage',
        'Frequency',
        'Start',
        'End',
        'Status',
        'Added By',
        'Modified By',
      ],
      rows: [
        for (var i = 0; i < medications.length; i++)
          [
            '${i + 1}',
            medications[i]['medicine_name']?.toString() ?? '-',
            _orDash(medications[i]['dosage']),
            _orDash(medications[i]['frequency']),
            _dateOrDash(medications[i]['start_date']),
            _dateOrDash(medications[i]['end_date'], ongoing: true),
            _medicationStatus(medications[i]),
            _userLabel(medications[i], 'created_by'),
            _userLabel(medications[i], 'updated_by'),
          ],
      ],
      fileName: 'Drug_Chart_${_shortId(widget.admissionId)}.pdf',
    );
  }

  Future<void> _downloadNotesPdf(
    List<Map<String, dynamic>> notes,
    String patientName,
    String uhid,
  ) async {
    await _printPdf(
      title: 'Daily Progress Notes — $patientName ($uhid)',
      headers: const [
        '#',
        'Date & Time',
        'Doctor',
        'Note',
        'Added By',
        'Modified By',
      ],
      rows: [
        for (var i = 0; i < notes.length; i++)
          [
            '${i + 1}',
            _dateTimeOrDash(notes[i]['note_date']) == '—'
                ? _dateTimeOrDash(notes[i]['created_at'])
                : _dateTimeOrDash(notes[i]['note_date']),
            _userLabel(notes[i], 'doctor'),
            notes[i]['note_text']?.toString() ?? '-',
            _userLabel(notes[i], 'created_by'),
            _userLabel(notes[i], 'updated_by'),
          ],
      ],
      fileName: 'Progress_Notes_${_shortId(widget.admissionId)}.pdf',
    );
  }

  Future<void> _downloadReportsPdf(
    List<Map<String, dynamic>> reports,
    String patientName,
    String uhid,
  ) async {
    await _printPdf(
      title: 'Investigation Reports — $patientName ($uhid)',
      headers: const [
        '#',
        'Report Type',
        'Date',
        'File URL',
        'Added By',
        'Modified By',
      ],
      rows: [
        for (var i = 0; i < reports.length; i++)
          [
            '${i + 1}',
            reports[i]['report_type']?.toString() ?? '-',
            _dateOrDash(reports[i]['report_date']),
            _orDash(reports[i]['report_url']),
            _userLabel(reports[i], 'created_by'),
            _userLabel(reports[i], 'updated_by'),
          ],
      ],
      fileName: 'Reports_${_shortId(widget.admissionId)}.pdf',
    );
  }

  Future<void> _downloadRecordPdf(Map<String, dynamic> record) async {
    final id = record['id']?.toString() ?? 'record';
    await _printPdf(
      title: 'IPD Record — ${_shortId(id)}',
      headers: const ['Field', 'Value'],
      rows: [
        for (final entry in record.entries)
          if (entry.value != null &&
              entry.value.toString().isNotEmpty &&
              !entry.key.endsWith('_by') &&
              !entry.key.endsWith('_name') &&
              !entry.key.endsWith('_role') &&
              !entry.key.endsWith('_designation') &&
              !entry.key.endsWith('_id'))
            [entry.key, entry.value.toString()],
      ],
      fileName: 'IPD_Record_${_shortId(id)}.pdf',
    );
  }

  Future<void> _printPdf({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
    required String fileName,
  }) async {
    try {
      await PDFFontHelper.loadFonts();

      final pdf = pw.Document();
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (context) => [
            PDFFontHelper.text(
              'HIMS — IPD Patient Dashboard',
              fontSize: 9,
              color: PdfColors.grey700,
            ),
            pw.SizedBox(height: 4),
            PDFFontHelper.text(
              title,
              fontSize: 14,
              fontWeight: pw.FontWeight.bold,
            ),
            pw.SizedBox(height: 10),
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: rows,
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              headerStyle: PDFFontHelper.textStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 8,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blue800,
              ),
              cellStyle: PDFFontHelper.bodyStyle(fontSize: 8),
              cellAlignment: pw.Alignment.topLeft,
              headerAlignment: pw.Alignment.centerLeft,
            ),
          ],
        ),
      );
      final bytes = await pdf.save();
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: fileName);
    } catch (e) {
      _showMessage('Could not generate PDF: $e');
    }
  }

  Future<void> _shareRecordText(Map<String, dynamic> record) async {
    final buffer = StringBuffer();
    for (final entry in record.entries) {
      if (entry.value == null || entry.value.toString().isEmpty) continue;
      if (entry.key.endsWith('_name') ||
          entry.key.endsWith('_role') ||
          entry.key.endsWith('_designation') ||
          entry.key.endsWith('_id')) {
        continue;
      }
      buffer.writeln('${entry.key}: ${entry.value}');
    }
    try {
      await ShareUtils.shareText(
        buffer.toString().trim(),
        subject: 'IPD Record',
      );
    } catch (e) {
      _showMessage('Could not share record: $e');
    }
  }

  Future<void> _downloadReportFile(Map<String, dynamic> report) async {
    final url = report['report_url']?.toString() ?? '';
    if (url.isEmpty) {
      _showMessage('No file attached to this report.');
      return;
    }
    try {
      final fileName = _reportFileName(report);
      final path = await ShareUtils.downloadFile(url: url, fileName: fileName);
      await ShareUtils.openFile(path);
    } catch (e) {
      _showMessage('Download failed: $e');
    }
  }

  Future<void> _shareReportFile(Map<String, dynamic> report) async {
    final url = report['report_url']?.toString() ?? '';
    if (url.isEmpty) {
      _showMessage('No file attached to this report.');
      return;
    }
    try {
      final fileName = _reportFileName(report);
      final path = await ShareUtils.downloadFile(url: url, fileName: fileName);
      await ShareUtils.shareFile(
        filePath: path,
        fileName: fileName,
        subject: report['report_type']?.toString() ?? 'IPD Report',
      );
    } catch (e) {
      _showMessage('Share failed: $e');
    }
  }

  String _reportFileName(Map<String, dynamic> report) {
    final type = (report['report_type']?.toString() ?? 'report').replaceAll(
      RegExp(r'[^A-Za-z0-9]+'),
      '_',
    );
    final url = report['report_url']?.toString() ?? '';
    var extension = '.pdf';
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? '';
    if (path.contains('.') && path.lastIndexOf('.') < path.length - 1) {
      extension = path.substring(path.lastIndexOf('.'));
    }
    return '${type}_${_shortId(report['id']?.toString() ?? 'report')}$extension';
  }

  Future<void> _openReport(String url) async {
    if (url.isEmpty) {
      _showMessage('No report URL available.');
      return;
    }
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        _showMessage('Invalid report URL.');
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _showMessage('Could not open report: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Form launchers
  // ---------------------------------------------------------------------------

  void _showVitalsForm([Map<String, dynamic>? vital]) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          _VitalsFormSheet(admissionId: widget.admissionId, vital: vital),
    );
  }

  void _showProgressNoteForm([Map<String, dynamic>? note]) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          _ProgressNoteFormSheet(admissionId: widget.admissionId, note: note),
    );
  }

  void _showMedicationForm([Map<String, dynamic>? medication]) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _MedicationFormSheet(
        admissionId: widget.admissionId,
        medication: medication,
      ),
    );
  }

  void _showReportForm([Map<String, dynamic>? report]) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          _ReportFormSheet(admissionId: widget.admissionId, report: report),
    );
  }

  // ---------------------------------------------------------------------------
  // Quick actions
  // ---------------------------------------------------------------------------

  Widget _buildActionButtons({
    required String patientId,
    required String patientName,
    required String uhid,
  }) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        ElevatedButton.icon(
          onPressed: () {
            final patientNameParam = Uri.encodeComponent(patientName);
            final uhidParam = Uri.encodeComponent(uhid);
            context.push(
              '/counseling?patientId=$patientId'
              '&patientName=$patientNameParam&uhid=$uhidParam&visitType=ipd'
              '&ipdAdmissionId=${widget.admissionId}',
            );
          },
          icon: const Icon(Icons.record_voice_over),
          label: const Text('Record Counseling'),
        ),
        ElevatedButton.icon(
          onPressed: () {
            final patientNameParam = Uri.encodeComponent(patientName);
            final uhidParam = Uri.encodeComponent(uhid);
            context.push(
              '/doctor/prescription?patientId=$patientId'
              '&ipdAdmissionId=${widget.admissionId}'
              '&patientName=$patientNameParam&uhid=$uhidParam',
            );
          },
          icon: const Icon(Icons.medication),
          label: const Text('Prescription'),
        ),
        ElevatedButton.icon(
          onPressed: () => _showVitalsForm(),
          icon: const Icon(Icons.favorite),
          label: const Text('Record Vitals'),
        ),
        ElevatedButton.icon(
          onPressed: () => _showProgressNoteForm(),
          icon: const Icon(Icons.note_add),
          label: const Text('Add Progress Note'),
        ),
        ElevatedButton.icon(
          onPressed: () =>
              context.push('/ipd/transfer?admissionId=${widget.admissionId}'),
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Transfer Ward'),
        ),
        ElevatedButton.icon(
          onPressed: () =>
              context.push('/ipd/billing?admissionId=${widget.admissionId}'),
          icon: const Icon(Icons.receipt_long),
          label: const Text('Billing'),
        ),
        ElevatedButton.icon(
          onPressed: () => context.push('/ipd/discharge/${widget.admissionId}'),
          icon: const Icon(Icons.exit_to_app),
          label: const Text('Discharge'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  Widget _infoChip(String label, String value, IconData icon) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _emptyState(IconData icon, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String label, String value) {
    return Chip(
      label: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _auditTrail(Map<String, dynamic> row, {bool isVitals = false}) {
    final recordedBy = isVitals ? _userLabel(row, 'recorded_by') : '';
    final addedBy = _userLabel(row, 'created_by');
    final modifiedBy = _userLabel(row, 'updated_by');

    final children = <Widget>[];
    if (recordedBy.isNotEmpty) {
      children.add(
        _auditLine(Icons.person_outline, 'Recorded by: $recordedBy'),
      );
    } else if (addedBy.isNotEmpty) {
      children.add(
        _auditLine(Icons.person_add_alt_1_outlined, 'Added by: $addedBy'),
      );
    } else {
      children.add(_auditLine(Icons.person_outline, 'Added by: —'));
    }
    if (modifiedBy.isNotEmpty) {
      children.add(_auditLine(Icons.edit_outlined, 'Modified by: $modifiedBy'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _auditLine(IconData icon, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  String _userLabel(Map<String, dynamic> row, String prefix) {
    final name = row['${prefix}_name']?.toString().trim() ?? '';
    final role = row['${prefix}_role']?.toString().trim() ?? '';
    final id = row['${prefix}_id']?.toString().trim() ?? '';
    if (name.isEmpty && id.isEmpty) return '';
    final roleText = role.isEmpty ? '' : ' ($role)';
    final idText = id.isEmpty
        ? ''
        : id.length > 8
        ? ' • ID: ${_shortId(id)}...'
        : ' • ID: $id';
    return '$name$roleText$idText';
  }

  String _whoString(Map<String, dynamic> row, {bool isVitals = false}) {
    if (isVitals) {
      final recorded = _userLabel(row, 'recorded_by');
      if (recorded.isNotEmpty) return recorded;
    }
    return _userLabel(row, 'created_by');
  }

  String _patientName(Map<String, dynamic>? patient) {
    if (patient == null) return 'Unknown Patient';
    final first = patient['first_name']?.toString() ?? '';
    final last = patient['last_name']?.toString() ?? '';
    final name = '$first $last'.trim();
    return name.isEmpty ? 'Unknown Patient' : name;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  String _formatWardType(String wardType) {
    final words = wardType.split('_').where((w) => w.isNotEmpty).toList();
    final formatted = words
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    return formatted.isEmpty ? 'General' : formatted;
  }

  String _orDash(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? '—' : text;
  }

  String _bpText(Map<String, dynamic> vital) {
    final systolic = vital['blood_pressure_systolic'];
    final diastolic = vital['blood_pressure_diastolic'];
    if (systolic == null && diastolic == null) return '—';
    return '${systolic ?? '--'}/${diastolic ?? '--'}';
  }

  String _dateTimeOrDash(dynamic value) {
    final date = _parseDate(value);
    return date?.toDisplayDateTime ?? '—';
  }

  String _dateOrDash(dynamic value, {bool ongoing = false}) {
    final date = _parseDate(value);
    if (date == null) return ongoing ? 'Ongoing' : '—';
    return date.toDisplayDate;
  }

  String _medicationStatus(Map<String, dynamic> med) {
    final endDate = _parseDate(med['end_date']);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return endDate == null || !endDate.isBefore(today) ? 'Active' : 'Stopped';
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    return double.tryParse(value.toString().trim());
  }

  double _yInterval(double range) {
    if (range <= 10) return 1;
    if (range <= 30) return 5;
    if (range <= 60) return 10;
    if (range <= 120) return 20;
    return 25;
  }

  String _shortId(dynamic id) {
    final text = id?.toString() ?? '';
    if (text.length <= 8) return text;
    return text.substring(0, 8);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

// -----------------------------------------------------------------------------
// Menu row helper
// -----------------------------------------------------------------------------

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 8), Text(label)],
    );
  }
}

// -----------------------------------------------------------------------------
// Vitals add/edit form
// -----------------------------------------------------------------------------

class _VitalsFormSheet extends ConsumerStatefulWidget {
  final String admissionId;
  final Map<String, dynamic>? vital;

  const _VitalsFormSheet({required this.admissionId, this.vital});

  @override
  ConsumerState<_VitalsFormSheet> createState() => _VitalsFormSheetState();
}

class _VitalsFormSheetState extends ConsumerState<_VitalsFormSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _temperatureController;
  late final TextEditingController _pulseController;
  late final TextEditingController _respirationController;
  late final TextEditingController _systolicController;
  late final TextEditingController _diastolicController;
  late final TextEditingController _spo2Controller;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final vital = widget.vital;
    _temperatureController = TextEditingController(
      text: _textOf(vital?['temperature']),
    );
    _pulseController = TextEditingController(
      text: _textOf(vital?['pulse_rate']),
    );
    _respirationController = TextEditingController(
      text: _textOf(vital?['respiration_rate']),
    );
    _systolicController = TextEditingController(
      text: _textOf(vital?['blood_pressure_systolic']),
    );
    _diastolicController = TextEditingController(
      text: _textOf(vital?['blood_pressure_diastolic']),
    );
    _spo2Controller = TextEditingController(text: _textOf(vital?['spo2']));
  }

  @override
  void dispose() {
    _temperatureController.dispose();
    _pulseController.dispose();
    _respirationController.dispose();
    _systolicController.dispose();
    _diastolicController.dispose();
    _spo2Controller.dispose();
    super.dispose();
  }

  String _textOf(dynamic value) => value?.toString() ?? '';

  bool get _hasAnyValue =>
      _temperatureController.text.trim().isNotEmpty ||
      _pulseController.text.trim().isNotEmpty ||
      _respirationController.text.trim().isNotEmpty ||
      _systolicController.text.trim().isNotEmpty ||
      _diastolicController.text.trim().isNotEmpty ||
      _spo2Controller.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.vital == null ? 'Record Vitals' : 'Edit Vitals',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _numberField(
                _temperatureController,
                label: 'Temperature (°F)',
                icon: Icons.thermostat,
              ),
              const SizedBox(height: 12),
              _numberField(
                _pulseController,
                label: 'Pulse Rate (bpm)',
                icon: Icons.monitor_heart_outlined,
              ),
              const SizedBox(height: 12),
              _numberField(
                _respirationController,
                label: 'Respiration Rate (/min)',
                icon: Icons.air,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _numberField(
                      _systolicController,
                      label: 'BP Systolic',
                      icon: Icons.speed,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _numberField(
                      _diastolicController,
                      label: 'BP Diastolic',
                      icon: Icons.speed,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _numberField(
                _spo2Controller,
                label: 'SpO₂ (%)',
                icon: Icons.water_drop_outlined,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(
                    widget.vital == null ? 'Save Vitals' : 'Update Vitals',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numberField(
    TextEditingController controller, {
    required String label,
    required IconData icon,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      validator: _validateNumber,
    );
  }

  String? _validateNumber(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    return double.tryParse(text) == null ? 'Enter a valid number' : null;
  }

  Future<void> _save() async {
    if (!_hasAnyValue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter at least one vital value.')),
      );
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final userId = await db.getCurrentUsersTableId();
      final data = <String, dynamic>{
        'admission_id': widget.admissionId,
        'temperature': _toDoubleOrNull(_temperatureController.text),
        'pulse_rate': _toIntOrNull(_pulseController.text),
        'respiration_rate': _toIntOrNull(_respirationController.text),
        'blood_pressure_systolic': _toIntOrNull(_systolicController.text),
        'blood_pressure_diastolic': _toIntOrNull(_diastolicController.text),
        'spo2': _toDoubleOrNull(_spo2Controller.text),
      };

      if (widget.vital == null) {
        data['recorded_at'] = DateTime.now().toUtc().toIso8601String();
        if (userId != null) {
          data['recorded_by'] = userId;
          data['created_by'] = userId;
        }
        await db.create(ApiConstants.ipdVitalsTable, data);
      } else {
        data['updated_at'] = DateTime.now().toUtc().toIso8601String();
        if (userId != null) data['updated_by'] = userId;
        await db.update(
          ApiConstants.ipdVitalsTable,
          widget.vital!['id'] as String,
          data,
        );
      }

      ref.invalidate(ipdPatientProvider(widget.admissionId));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.vital == null ? 'Vitals recorded.' : 'Vitals updated.',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save vitals: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  int? _toIntOrNull(String text) {
    final value = double.tryParse(text.trim());
    if (value == null) return null;
    return value.round();
  }

  double? _toDoubleOrNull(String text) {
    return double.tryParse(text.trim());
  }
}

// -----------------------------------------------------------------------------
// Progress note add/edit form
// -----------------------------------------------------------------------------

class _ProgressNoteFormSheet extends ConsumerStatefulWidget {
  final String admissionId;
  final Map<String, dynamic>? note;

  const _ProgressNoteFormSheet({required this.admissionId, this.note});

  @override
  ConsumerState<_ProgressNoteFormSheet> createState() =>
      _ProgressNoteFormSheetState();
}

class _ProgressNoteFormSheetState
    extends ConsumerState<_ProgressNoteFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _noteController;
  late final TextEditingController _noteDateController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(
      text: widget.note?['note_text']?.toString() ?? '',
    );
    _noteDateController = TextEditingController(
      text:
          widget.note?['note_date']?.toString() ??
          DateTime.now().toIso8601String().split('T')[0],
    );
  }

  @override
  void dispose() {
    _noteController.dispose();
    _noteDateController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final initial =
        DateTime.tryParse(_noteDateController.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(
        () => _noteDateController.text = picked.toIso8601String().split('T')[0],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.note == null
                        ? 'Add Progress Note'
                        : 'Edit Progress Note',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteDateController,
                readOnly: true,
                onTap: _pickDate,
                decoration: InputDecoration(
                  labelText: 'Note Date *',
                  prefixIcon: const Icon(Icons.calendar_today),
                  suffixIcon: const Icon(Icons.arrow_drop_down),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteController,
                maxLines: 5,
                autofocus: widget.note == null,
                decoration: InputDecoration(
                  labelText: 'Progress Note *',
                  hintText: 'e.g. Patient is stable, fever reduced...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (value) =>
                    value?.trim().isEmpty == true ? 'Note is required' : null,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(
                    widget.note == null ? 'Save Note' : 'Update Note',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final doctorId = await db.getCurrentUsersTableId();
      final data = <String, dynamic>{
        'admission_id': widget.admissionId,
        'note_text': _noteController.text.trim(),
        'note_date': _noteDateController.text.trim(),
      };

      if (widget.note == null) {
        if (doctorId != null) {
          data['doctor_id'] = doctorId;
          data['created_by'] = doctorId;
        }
        await db.create(ApiConstants.ipdProgressNotesTable, data);
      } else {
        data['updated_at'] = DateTime.now().toUtc().toIso8601String();
        if (doctorId != null) data['updated_by'] = doctorId;
        await db.update(
          ApiConstants.ipdProgressNotesTable,
          widget.note!['id'] as String,
          data,
        );
      }

      ref.invalidate(ipdPatientProvider(widget.admissionId));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.note == null
                ? 'Progress note saved.'
                : 'Progress note updated.',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save note: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

// -----------------------------------------------------------------------------
// Medication add/edit form
// -----------------------------------------------------------------------------

class _MedicationFormSheet extends ConsumerStatefulWidget {
  final String admissionId;
  final Map<String, dynamic>? medication;

  const _MedicationFormSheet({required this.admissionId, this.medication});

  @override
  ConsumerState<_MedicationFormSheet> createState() =>
      _MedicationFormSheetState();
}

class _MedicationFormSheetState extends ConsumerState<_MedicationFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _dosageController;
  late final TextEditingController _frequencyController;
  late final TextEditingController _startDateController;
  late final TextEditingController _endDateController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.medication?['medicine_name']?.toString() ?? '',
    );
    _dosageController = TextEditingController(
      text: widget.medication?['dosage']?.toString() ?? '',
    );
    _frequencyController = TextEditingController(
      text: widget.medication?['frequency']?.toString() ?? '',
    );
    _startDateController = TextEditingController(
      text:
          widget.medication?['start_date']?.toString() ??
          DateTime.now().toIso8601String().split('T')[0],
    );
    _endDateController = TextEditingController(
      text: widget.medication?['end_date']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _dosageController.dispose();
    _frequencyController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => controller.text = picked.toIso8601String().split('T')[0]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.medication == null
                        ? 'Add Medication'
                        : 'Edit Medication',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                autofocus: widget.medication == null,
                decoration: InputDecoration(
                  labelText: 'Medicine Name *',
                  prefixIcon: const Icon(Icons.medication),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (value) => value?.trim().isEmpty == true
                    ? 'Medicine name is required'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dosageController,
                decoration: InputDecoration(
                  labelText: 'Dosage',
                  hintText: 'e.g. 500 mg',
                  prefixIcon: const Icon(Icons.straighten),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _frequencyController,
                decoration: InputDecoration(
                  labelText: 'Frequency',
                  hintText: 'e.g. TDS / BD / OD',
                  prefixIcon: const Icon(Icons.schedule),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _dateField(
                      _startDateController,
                      label: 'Start Date *',
                      onTap: () => _pickDate(_startDateController),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _dateField(
                      _endDateController,
                      label: 'End Date (optional)',
                      onTap: () => _pickDate(_endDateController),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(
                    widget.medication == null
                        ? 'Save Medication'
                        : 'Update Medication',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateField(
    TextEditingController controller, {
    required String label,
    required VoidCallback onTap,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: true,
      onTap: onTap,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.calendar_today),
        suffixIcon: const Icon(Icons.arrow_drop_down),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final userId = await db.getCurrentUsersTableId();
      final data = <String, dynamic>{
        'admission_id': widget.admissionId,
        'medicine_name': _nameController.text.trim(),
        'dosage': _dosageController.text.trim().isEmpty
            ? null
            : _dosageController.text.trim(),
        'frequency': _frequencyController.text.trim().isEmpty
            ? null
            : _frequencyController.text.trim(),
        'start_date': _startDateController.text.trim(),
        'end_date': _endDateController.text.trim().isEmpty
            ? null
            : _endDateController.text.trim(),
      };

      if (widget.medication == null) {
        if (userId != null) data['created_by'] = userId;
        await db.create(ApiConstants.ipdMedicationsTable, data);
      } else {
        data['updated_at'] = DateTime.now().toUtc().toIso8601String();
        if (userId != null) data['updated_by'] = userId;
        await db.update(
          ApiConstants.ipdMedicationsTable,
          widget.medication!['id'] as String,
          data,
        );
      }

      ref.invalidate(ipdPatientProvider(widget.admissionId));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.medication == null
                ? 'Medication saved.'
                : 'Medication updated.',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save medication: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

// -----------------------------------------------------------------------------
// Report add/edit form
// -----------------------------------------------------------------------------

class _ReportFormSheet extends ConsumerStatefulWidget {
  final String admissionId;
  final Map<String, dynamic>? report;

  const _ReportFormSheet({required this.admissionId, this.report});

  @override
  ConsumerState<_ReportFormSheet> createState() => _ReportFormSheetState();
}

class _ReportFormSheetState extends ConsumerState<_ReportFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _typeController;
  late final TextEditingController _dateController;
  late final TextEditingController _urlController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _typeController = TextEditingController(
      text: widget.report?['report_type']?.toString() ?? '',
    );
    _dateController = TextEditingController(
      text:
          widget.report?['report_date']?.toString() ??
          DateTime.now().toIso8601String().split('T')[0],
    );
    _urlController = TextEditingController(
      text: widget.report?['report_url']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _typeController.dispose();
    _dateController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(
        () => _dateController.text = picked.toIso8601String().split('T')[0],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.report == null ? 'Add Report' : 'Edit Report',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _typeController,
                autofocus: widget.report == null,
                decoration: InputDecoration(
                  labelText: 'Report Type *',
                  hintText: 'e.g. CBC, X-Ray Chest, MRI',
                  prefixIcon: const Icon(Icons.description_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (value) => value?.trim().isEmpty == true
                    ? 'Report type is required'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dateController,
                readOnly: true,
                onTap: _pickDate,
                decoration: InputDecoration(
                  labelText: 'Report Date *',
                  prefixIcon: const Icon(Icons.calendar_today),
                  suffixIcon: const Icon(Icons.arrow_drop_down),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Report File URL (optional)',
                  hintText: 'https://...',
                  prefixIcon: const Icon(Icons.link),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(
                    widget.report == null ? 'Save Report' : 'Update Report',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final userId = await db.getCurrentUsersTableId();
      final data = <String, dynamic>{
        'admission_id': widget.admissionId,
        'report_type': _typeController.text.trim(),
        'report_date': _dateController.text.trim(),
        'report_url': _urlController.text.trim().isEmpty
            ? null
            : _urlController.text.trim(),
      };

      if (widget.report == null) {
        if (userId != null) data['created_by'] = userId;
        await db.create(ApiConstants.ipdReportsTable, data);
      } else {
        data['updated_at'] = DateTime.now().toUtc().toIso8601String();
        if (userId != null) data['updated_by'] = userId;
        await db.update(
          ApiConstants.ipdReportsTable,
          widget.report!['id'] as String,
          data,
        );
      }

      ref.invalidate(ipdPatientProvider(widget.admissionId));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.report == null ? 'Report saved.' : 'Report updated.',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save report: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

// -----------------------------------------------------------------------------
// Error / retry view
// -----------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
