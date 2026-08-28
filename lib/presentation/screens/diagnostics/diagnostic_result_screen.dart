import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/providers.dart';
import '../../../core/extensions/datetime_extensions.dart';
import '../../../services/diagnostic_report_pdf.dart';
import '../../widgets/smart_navigation.dart';

/// Diagnostic result entry screen — technician picks a pending order and
/// enters results per test (pathology values / radiology findings / cardiology
/// interpretation + images). Results can be Draft, Final or Amended.
class DiagnosticResultScreen extends ConsumerStatefulWidget {
  const DiagnosticResultScreen({super.key});

  @override
  ConsumerState<DiagnosticResultScreen> createState() =>
      _DiagnosticResultScreenState();
}

class _DiagnosticResultScreenState extends ConsumerState<DiagnosticResultScreen> {
  Future<void> _reload() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId != null) {
      ref.invalidate(diagnosticOrdersProvider(DiagnosticOrdersParams(hospitalId: hospitalId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Diagnostic Results')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final ordersAsync = ref.watch(
      diagnosticOrdersProvider(DiagnosticOrdersParams(hospitalId: hospitalId)),
    );

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: SmartAppBar(
          title: const Text('Diagnostic Results'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Pending Orders'),
              Tab(text: 'Completed'),
            ],
          ),
        ),
        body: ordersAsync.when(
          data: (orders) {
            final pending = orders
                .where(
                  (o) =>
                      o['status'] == 'pending' || o['status'] == 'in_progress',
                )
                .toList();
            final completed = orders
                .where((o) => o['status'] == 'completed')
                .toList();

            return TabBarView(
              children: [
                _buildOrderList(pending, isCompleted: false),
                _buildOrderList(completed, isCompleted: true),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Failed to load orders: $error'),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reload, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOrderList(List<Map<String, dynamic>> orders, {required bool isCompleted}) {
    if (orders.isEmpty) {
      return Center(
        child: Text(isCompleted ? 'No completed orders.' : 'No pending orders.'),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: orders.length,
        itemBuilder: (context, index) => _OrderTile(
          order: orders[index],
          isCompleted: isCompleted,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Single order tile (expansion with items)
// -----------------------------------------------------------------------------
class _OrderTile extends ConsumerWidget {
  final Map<String, dynamic> order;
  final bool isCompleted;

  const _OrderTile({required this.order, required this.isCompleted});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = (order['patients'] as Map?)?.cast<String, dynamic>() ?? const {};
    final patientName =
        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
    final uhid = patient['uhid']?.toString() ?? '-';
    final urgency = order['urgency']?.toString() ?? 'routine';
    final total = double.tryParse(order['total_amount']?.toString() ?? '') ?? 0;
    final orderDate = _formatDate(order['order_date']);

    final itemsAsync = ref.watch(
      diagnosticOrderItemsProvider(order['id'].toString()),
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: CircleAvatar(
          child: Icon(isCompleted ? Icons.check : Icons.pending_outlined),
        ),
        title: Text(
          patientName.isEmpty ? 'Unknown Patient' : patientName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          'UHID: $uhid • $orderDate • ₹ ${total.toStringAsFixed(2)}',
        ),
        trailing: _urgencyChip(urgency),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          itemsAsync.when(
            data: (items) => _buildItems(context, ref, items),
            loading: () => const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Failed to load items: $error'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItems(
    BuildContext context,
    WidgetRef ref,
    List<Map<String, dynamic>> items,
  ) {
    final allFinal = items.isNotEmpty && items.every((item) {
      final results = ((item['diagnostic_results'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      return results.any((r) => r['status'] == 'final' || r['status'] == 'amended');
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items) _buildItemTile(context, ref, item),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (isCompleted)
              FilledButton.icon(
                onPressed: () => _printReport(context, ref),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Print Report'),
              )
            else ...[
              Text(
                allFinal
                    ? 'All results finalised'
                    : 'Finalise all results to complete the order',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: allFinal
                    ? () => _markCompleted(context, ref)
                    : null,
                child: const Text('Mark Completed'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildItemTile(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> item,
  ) {
    final results = ((item['diagnostic_results'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final existing = results.isEmpty ? null : results.last;
    final status = existing?['status']?.toString();

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        _categoryIcon(item['category']?.toString()),
        color: _categoryColor(item['category']?.toString()),
      ),
      title: Text(item['test_name']?.toString() ?? '-'),
      subtitle: Text(
        status == null ? 'No result yet' : 'Status: ${status.toUpperCase()}',
        style: TextStyle(
          color: status == null ? Colors.grey : _statusColor(status),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == 'final' || status == 'amended')
            IconButton(
              tooltip: 'Print Report',
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => _printReport(context, ref),
            ),
          FilledButton.tonal(
            onPressed: () => _openResultEntry(context, ref, item, existing),
            child: Text(status == null ? 'Enter Result' : 'Edit Result'),
          ),
        ],
      ),
    );
  }

  Future<void> _openResultEntry(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> item,
    Map<String, dynamic>? existing,
  ) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _ResultEntryDialog(item: item, existing: existing),
    );
    if (data == null) return;

    final db = ref.read(databaseServiceProvider);
    try {
      await db.saveDiagnosticResult(data, id: existing?['id']?.toString());
      ref.invalidate(diagnosticOrderItemsProvider(order['id'].toString()));
      ref.invalidate(
        diagnosticOrdersProvider(
          DiagnosticOrdersParams(
            hospitalId: ref.read(authStateProvider).hospitalId,
          ),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Result saved')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save result: $e')),
        );
      }
    }
  }

  Future<void> _markCompleted(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseServiceProvider);
    try {
      await db.updateDiagnosticOrderStatus(order['id'].toString(), 'completed');
      ref.invalidate(
        diagnosticOrdersProvider(
          DiagnosticOrdersParams(hospitalId: ref.read(authStateProvider).hospitalId),
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Order marked completed')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update order: $e')));
      }
    }
  }

  Future<void> _printReport(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseServiceProvider);
    final hospitalId = ref.read(authStateProvider).hospitalId;

    try {
      final items = await db.getDiagnosticOrderItems(order['id'].toString());
      final results = <Map<String, dynamic>>[];

      for (final item in items) {
        final itemResults = ((item['diagnostic_results'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        final result = itemResults.isEmpty ? const <String, dynamic>{} : itemResults.last;
        results.add({
          'test_name': item['test_name']?.toString() ?? '-',
          'category': item['category']?.toString() ?? 'other',
          'result_value': result['result_value'],
          'reference_range': result['reference_range'],
          'unit': result['unit'],
          'findings': result['findings'],
          'impression': result['impression'],
          'recommendations': result['recommendations'],
          'image_url': result['image_url'],
        });
      }

      final patient = (order['patients'] as Map?)?.cast<String, dynamic>() ?? const {};
      final patientName =
          '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
      final uhid = patient['uhid']?.toString() ?? '-';

      var doctorName = 'Dr. -';
      final doctorId = order['doctor_id']?.toString();
      if (doctorId != null && doctorId.isNotEmpty) {
        final doctor = await db.getDoctorById(doctorId);
        final doctorFullName =
            '${doctor?['first_name'] ?? ''} ${doctor?['last_name'] ?? ''}'.trim();
        if (doctorFullName.isNotEmpty) doctorName = doctorFullName;
      }

      var hospitalName = 'Hospital';
      var hospitalAddress = '';
      if (hospitalId != null) {
        final hospital = await db.getById('hospitals', hospitalId);
        hospitalName = hospital?['name']?.toString() ?? hospitalName;
        final city = hospital?['city']?.toString() ?? '';
        final address = hospital?['address']?.toString() ?? '';
        hospitalAddress = [address, city].where((s) => s.isNotEmpty).join(', ');
      }

      await DiagnosticReportService.printDiagnosticReport(
        hospitalName: hospitalName,
        hospitalAddress: hospitalAddress,
        patientName: patientName,
        uhid: uhid,
        doctorName: doctorName,
        orderDate: _formatDate(order['order_date']),
        reportDate: DateTime.now().toDisplayDate,
        results: results,
        technicianName: 'Lab Technician',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to generate PDF: $e')));
      }
    }
  }

  Widget _urgencyChip(String urgency) {
    final (label, color) = switch (urgency) {
      'stat' => ('STAT', Colors.red),
      'urgent' => ('URGENT', Colors.orange),
      _ => ('ROUTINE', Colors.green),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  String _formatDate(dynamic value) {
    if (value == null) return '-';
    final date = DateTime.tryParse(value.toString());
    return date?.toDisplayDate ?? value.toString();
  }

  Color _categoryColor(String? category) {
    switch (category) {
      case 'pathology':
        return Colors.purple;
      case 'radiology':
        return Colors.blue;
      case 'cardiology':
        return Colors.red;
      default:
        return Colors.teal;
    }
  }

  IconData _categoryIcon(String? category) {
    switch (category) {
      case 'pathology':
        return Icons.biotech_outlined;
      case 'radiology':
        return Icons.image_search_outlined;
      case 'cardiology':
        return Icons.monitor_heart_outlined;
      default:
        return Icons.science_outlined;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'final':
        return Colors.green;
      case 'amended':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }
}

// -----------------------------------------------------------------------------
// Result entry dialog (category aware)
// -----------------------------------------------------------------------------
class _ResultEntryDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> item;
  final Map<String, dynamic>? existing;

  const _ResultEntryDialog({required this.item, this.existing});

  @override
  ConsumerState<_ResultEntryDialog> createState() => _ResultEntryDialogState();
}

class _ResultEntryDialogState extends ConsumerState<_ResultEntryDialog> {
  late final TextEditingController _valueController;
  late final TextEditingController _referenceController;
  late final TextEditingController _unitController;
  late final TextEditingController _findingsController;
  late final TextEditingController _impressionController;
  late final TextEditingController _recommendationsController;

  String _status = 'final';
  bool _saving = false;
  XFile? _pickedImage;
  String? _existingImageUrl;

  String get _category => widget.item['category']?.toString() ?? 'other';

  bool get _showImageUpload =>
      _category == 'radiology' || _category == 'cardiology';

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _valueController = TextEditingController(
      text: existing?['result_value']?.toString() ?? '',
    );
    _referenceController = TextEditingController(
      text: existing?['reference_range']?.toString() ?? '',
    );
    _unitController = TextEditingController(
      text: existing?['unit']?.toString() ?? '',
    );
    _findingsController = TextEditingController(
      text: existing?['findings']?.toString() ?? '',
    );
    _impressionController = TextEditingController(
      text: existing?['impression']?.toString() ?? '',
    );
    _recommendationsController = TextEditingController(
      text: existing?['recommendations']?.toString() ?? '',
    );
    _status = existing?['status']?.toString() ?? 'final';
    _existingImageUrl = existing?['image_url']?.toString();
  }

  @override
  void dispose() {
    _valueController.dispose();
    _referenceController.dispose();
    _unitController.dispose();
    _findingsController.dispose();
    _impressionController.dispose();
    _recommendationsController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );
    if (picked != null) {
      setState(() {
        _pickedImage = picked;
        _existingImageUrl = null;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    try {
      String? imageUrl = _existingImageUrl;

      if (_pickedImage != null) {
        final storage = ref.read(storageServiceProvider);
        imageUrl = await storage.uploadDocument(
          'diagnostics',
          widget.item['id'].toString(),
          File(_pickedImage!.path),
        );
      }

      final technicianId =
          await ref.read(databaseServiceProvider).getCurrentUsersTableId() ?? '';

      if (!mounted) return;
      Navigator.pop(
        context,
        {
          'order_item_id': widget.item['id'],
          'result_value': _valueController.text.trim().isEmpty
              ? null
              : _valueController.text.trim(),
          'reference_range': _referenceController.text.trim().isEmpty
              ? null
              : _referenceController.text.trim(),
          'unit': _unitController.text.trim().isEmpty
              ? null
              : _unitController.text.trim(),
          'findings': _findingsController.text.trim().isEmpty
              ? null
              : _findingsController.text.trim(),
          'impression': _impressionController.text.trim().isEmpty
              ? null
              : _impressionController.text.trim(),
          'recommendations': _recommendationsController.text.trim().isEmpty
              ? null
              : _recommendationsController.text.trim(),
          'image_url': imageUrl,
          'status': _status,
          'technician_id': technicianId.isEmpty ? null : technicianId,
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to upload image: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPathology = _category == 'pathology';
    final isRadiology = _category == 'radiology';
    final isCardiology = _category == 'cardiology';

    return AlertDialog(
      title: Text(widget.item['test_name']?.toString() ?? 'Result Entry'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isPathology) ...[
                TextField(
                  controller: _valueController,
                  decoration: const InputDecoration(
                    labelText: 'Result Value',
                    hintText: 'e.g. 14.5',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Reference Range',
                    hintText: 'e.g. 13.0 - 17.0',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _unitController,
                  decoration: const InputDecoration(
                    labelText: 'Unit',
                    hintText: 'e.g. g/dL',
                  ),
                ),
              ] else if (isRadiology) ...[
                TextField(
                  controller: _findingsController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Findings',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _impressionController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Impression',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _recommendationsController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Recommendations',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else if (isCardiology) ...[
                TextField(
                  controller: _valueController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Interpretation',
                    hintText: 'e.g. Normal sinus rhythm',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _valueController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Result Value',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _findingsController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Findings / Notes',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_showImageUpload) ...[
                const SizedBox(height: 12),
                _buildImagePicker(),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'draft', child: Text('Draft')),
                  DropdownMenuItem(value: 'final', child: Text('Final')),
                  DropdownMenuItem(value: 'amended', child: Text('Amended')),
                ],
                onChanged: (value) => setState(() => _status = value ?? 'final'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                readOnly: true,
                initialValue: DateTime.now().toDisplayDate,
                decoration: const InputDecoration(
                  labelText: 'Result Date (auto)',
                  prefixIcon: Icon(Icons.event_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save Result'),
        ),
      ],
    );
  }

  Widget _buildImagePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Image / Graph', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        if (_pickedImage != null)
          Column(
            children: [
              Image.file(
                File(_pickedImage!.path),
                height: 160,
                fit: BoxFit.cover,
              ),
              TextButton(
                onPressed: () => setState(() => _pickedImage = null),
                child: const Text('Remove Image'),
              ),
            ],
          )
        else if (_existingImageUrl != null && _existingImageUrl!.isNotEmpty)
          Column(
            children: [
              Image.network(
                _existingImageUrl!,
                height: 160,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
              ),
              TextButton(
                onPressed: () => setState(() => _existingImageUrl = null),
                child: const Text('Remove Image'),
              ),
            ],
          )
        else
          OutlinedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('Upload Image'),
          ),
      ],
    );
  }
}
