import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/report_generation_service.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/report_card.dart';
import 'widgets/report_filter.dart';

/// `/reports/generate` — form that creates a new analytics report.
///
/// Report type, From/To date range and quick range chips. On generate the
/// [ReportGenerationService] calculates real tenant-scoped data and saves it
/// into the existing `reports` table, then this screen navigates to the
/// generated report detail.
class ReportGenerateScreen extends ConsumerStatefulWidget {
  const ReportGenerateScreen({super.key});

  @override
  ConsumerState<ReportGenerateScreen> createState() =>
      _ReportGenerateScreenState();
}

class _ReportGenerateScreenState extends ConsumerState<ReportGenerateScreen> {
  final TextEditingController _fromController = TextEditingController();
  final TextEditingController _toController = TextEditingController();

  DateTime _from = DateTime.now();
  DateTime _to = DateTime.now();
  String _reportType = ReportFilterBar.reportTypes.first;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _syncControllers() {
    _fromController.text = _from.toDisplayDate;
    _toController.text = _to.toDisplayDate;
  }

  Future<void> _pickFromDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 5),
      helpText: 'Select From Date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _from = picked;
      _syncControllers();
    });
  }

  Future<void> _pickToDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 5),
      helpText: 'Select To Date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _to = picked;
      _syncControllers();
    });
  }

  void _applyQuickRange(String range) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    setState(() {
      switch (range) {
        case 'today':
          _from = today;
          _to = today;
        case 'last7':
          _to = today;
          _from = today.subtract(const Duration(days: 6));
        case 'thisMonth':
          _from = DateTime(now.year, now.month, 1);
          _to = today;
        case 'lastMonth':
          _from = DateTime(now.year, now.month - 1, 1);
          _to = DateTime(now.year, now.month, 0);
      }
      _syncControllers();
    });
  }

  Future<void> _generate() async {
    if (_from.isAfter(_to)) {
      _showSnack('From date must be on or before To date.');
      return;
    }

    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      _showSnack('Hospital not assigned to this user.');
      return;
    }

    setState(() => _generating = true);
    try {
      final report = await ref
          .read(reportGenerationServiceProvider)
          .generateReport(
            hospitalId: hospitalId,
            reportType: _reportType,
            from: _from,
            to: _to,
          );

      ref.invalidate(reportsProvider(hospitalId));

      final reportId = report['id']?.toString();
      if (!mounted) return;
      if (reportId != null && reportId.isNotEmpty) {
        context.push('/reports/$reportId');
      }
    } on ReportGenerationException catch (e) {
      if (!mounted) return;
      ref.invalidate(reportsProvider(hospitalId));
      _showSnack(e.message);
    } catch (e) {
      if (!mounted) return;
      ref.invalidate(reportsProvider(hospitalId));
      _showSnack('Could not generate report: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Generate Report')),
        body: const Center(
          child: Text('Hospital not assigned to this user.'),
        ),
      );
    }

    return AppPage(
      title: 'Generate Report',
      children: [
        AppSectionCard(
          title: 'Report Type',
          child: DropdownButtonFormField<String>(
            initialValue: _reportType,
            decoration: InputDecoration(
              labelText: 'Report Type',
              prefixIcon: Icon(
                ReportVisuals.iconForType(_reportType),
                color: ReportVisuals.colorForType(_reportType),
              ),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final type in ReportFilterBar.reportTypes)
                DropdownMenuItem(
                  value: type,
                  child: Text(ReportVisuals.labelForType(type)),
                ),
            ],
            onChanged: _generating
                ? null
                : (value) {
                    if (value != null) setState(() => _reportType = value);
                  },
          ),
        ),
        const SizedBox(height: 12),
        AppSectionCard(
          title: 'Date Range',
          subtitle: 'Reports are generated from real records in this period.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppFieldRow(
                children: [
                  _DateField(
                    label: 'From Date',
                    controller: _fromController,
                    icon: Icons.event_outlined,
                    enabled: !_generating,
                    onTap: _pickFromDate,
                  ),
                  _DateField(
                    label: 'To Date',
                    controller: _toController,
                    icon: Icons.event_available_outlined,
                    enabled: !_generating,
                    onTap: _pickToDate,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final range in _quickRanges)
                    ActionChip(
                      avatar: Icon(range.icon, size: 16),
                      label: Text(range.label),
                      onPressed: _generating
                          ? null
                          : () => _applyQuickRange(range.value),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppSubmitButton(
          label: 'Generate Report',
          icon: Icons.add_chart,
          loading: _generating,
          onPressed: _generate,
        ),
        const SizedBox(height: 12),
        Text(
          'The report is calculated from your hospital records and saved in '
          'Reports history.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.controller,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final TextEditingController controller;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      enabled: enabled,
      onTap: onTap,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _QuickRange {
  const _QuickRange(this.label, this.value, this.icon);

  final String label;
  final String value;
  final IconData icon;
}

const List<_QuickRange> _quickRanges = [
  _QuickRange('Today', 'today', Icons.today_outlined),
  _QuickRange('Last 7 Days', 'last7', Icons.date_range_outlined),
  _QuickRange('This Month', 'thisMonth', Icons.calendar_view_month_outlined),
  _QuickRange('Last Month', 'lastMonth', Icons.history_outlined),
];
