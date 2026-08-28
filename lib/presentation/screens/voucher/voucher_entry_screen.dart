import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/utils/logger.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';

/// Voucher Entry screen (`/vouchers/new`).
///
/// Creates one hospital expense/payment/adjustment voucher. The voucher number
/// is auto-generated and the entry is saved to the `vouchers` table.
class VoucherEntryScreen extends ConsumerStatefulWidget {
  const VoucherEntryScreen({super.key});

  @override
  ConsumerState<VoucherEntryScreen> createState() => _VoucherEntryScreenState();
}

class _VoucherEntryScreenState extends ConsumerState<VoucherEntryScreen> {
  static const List<String> _paymentModes = [
    'Cash',
    'Card',
    'UPI',
    'Bank Transfer',
  ];

  static const List<String> _voucherTypes = [
    'Expense',
    'Payment',
    'Adjustment',
  ];

  /// Built-in expense categories. Custom categories are appended at runtime
  /// from `voucher_categories`.
  static const List<String> _builtInCategories = [
    'Laundry & Housekeeping',
    'Anesthesia / OT Charges',
    'Surgeon / Doctor On-Call Payment',
    'Medicine / Package Bills',
    'Staff Salary',
    'Utility Bills',
    'Maintenance & Repairs',
    'Equipment Purchase',
    'Travel & Conveyance',
    'Food & Dietary',
    'Blood Bank / Transfusion Payment',
    'Pathology / Lab Outsourcing Payment',
    'Radiology Payment (Outsourced X-Ray/CT)',
    'Medical Gas (Oxygen) Refill',
    'Ambulance Charges',
    'CSSD / Sterilization Charges',
    'Contract Staff Payment (Nurses/Technicians)',
    'Mediclaim / Insurance Premium',
  ];

  static const String _customCategoryValue = '__custom__';

  /// Only PDF and image files are allowed as voucher attachments.
  static const Set<String> _allowedAttachmentExtensions = {
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
  };

  /// Maximum allowed size per attachment (2 MB).
  static const int _maxAttachmentSizeBytes = 2 * 1024 * 1024;

  final _formKey = GlobalKey<FormState>();

  final _payeeController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController();
  final _customCategoryController = TextEditingController();
  final _voucherNumberController = TextEditingController();
  late final TextEditingController _dateController;

  DateTime _voucherDate = DateTime.now();
  String? _voucherNumber;
  String _paymentMode = 'Cash';
  String _voucherType = 'Expense';
  String? _category;
  bool _saving = false;
  bool _uploading = false;
  final List<_VoucherAttachmentDraft> _attachments = [];

  @override
  void initState() {
    super.initState();
    _dateController = TextEditingController(
      text: DateFormat('dd/MM/yyyy').format(_voucherDate),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadVoucherNumber());
  }

  @override
  void dispose() {
    _payeeController.dispose();
    _descriptionController.dispose();
    _amountController.dispose();
    _customCategoryController.dispose();
    _voucherNumberController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _loadVoucherNumber() async {
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null) return;

    final number = await ref.read(databaseServiceProvider).generateVoucherNumber(
      hospitalId,
      voucherDate: DateFormat('yyyy-MM-dd').format(_voucherDate),
    );
    if (!mounted) return;
    setState(() {
      _voucherNumber = number;
      _voucherNumberController.text = number;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _voucherDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;

    setState(() {
      _voucherDate = picked;
      _dateController.text = DateFormat('dd/MM/yyyy').format(picked);
    });
    await _loadVoucherNumber();
  }

  Future<void> _pickAttachments() async {
    try {
      // Official Flutter file_selector: reliable on web + desktop + mobile.
      // The OS dialog only shows PDF/image files; we still re-validate below.
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'PDF / Images',
            extensions: ['pdf', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'],
          ),
        ],
      );
      if (files.isEmpty || !mounted) return;

      final loaded = <_VoucherAttachmentDraft>[];
      final skipped = <String>[];

      for (final file in files) {
        final name = file.name;
        final extension = (name.contains('.') ? name.split('.').last : '')
            .toLowerCase();

        if (!_allowedAttachmentExtensions.contains(extension)) {
          skipped.add('$name (only PDF/image allowed)');
          continue;
        }

        final size = await file.length();
        if (size > _maxAttachmentSizeBytes) {
          skipped.add('$name (larger than 2 MB)');
          continue;
        }

        final bytes = await file.readAsBytes();
        loaded.add(
          _VoucherAttachmentDraft(name: name, bytes: bytes, size: size),
        );
      }

      if (!mounted) return;

      if (loaded.isNotEmpty) {
        setState(() => _attachments.addAll(loaded));
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '✓ Attached: ${loaded.map((f) => f.name).join(', ')}',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
      }

      if (skipped.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Skipped: ${skipped.join(', ')}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not pick files: $e')));
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _attachmentIcon(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    if (extension == 'pdf') return Icons.picture_as_pdf_outlined;
    if (const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension)) {
      return Icons.image_outlined;
    }
    if (const ['xls', 'xlsx', 'csv'].contains(extension)) {
      return Icons.table_chart_outlined;
    }
    if (const ['doc', 'docx'].contains(extension)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hospital not assigned to this user.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final db = ref.read(databaseServiceProvider);

      var category = _category;
      if (category == _customCategoryValue) {
        category = _customCategoryController.text.trim();
        // Save the new category so it is available for future vouchers. If it
        // already exists (unique constraint) the entered name is still used.
        try {
          await db.createVoucherCategory(
            hospitalId: hospitalId,
            categoryName: category,
          );
          ref.invalidate(voucherCategoriesProvider(hospitalId));
        } catch (_) {
          // Duplicate/network errors are non-fatal for the voucher itself.
        }
      }

      // Upload supporting documents (bill, AMC document, etc.) first so the
      // voucher row can store their public URLs in one shot.
      final uploadedAttachments = <Map<String, dynamic>>[];
      if (_attachments.isNotEmpty) {
        setState(() => _uploading = true);
        final storage = ref.read(storageServiceProvider);
        for (final attachment in _attachments) {
          final url = await storage.uploadBytes(
            path: 'vouchers/$hospitalId',
            bytes: attachment.bytes,
            fileName: attachment.name,
          );
          uploadedAttachments.add({
            'name': attachment.name,
            'url': url,
            'size': attachment.size,
          });
        }
        if (mounted) setState(() => _uploading = false);
      }

      final createdBy = await db.getCurrentUsersTableId();

      final voucherData = <String, dynamic>{
        'hospital_id': hospitalId,
        'voucher_date': DateFormat('yyyy-MM-dd').format(_voucherDate),
        'payee_name': _payeeController.text.trim(),
        'payment_mode': _paymentMode,
        'description': _descriptionController.text.trim(),
        'amount': double.tryParse(_amountController.text.trim()) ?? 0,
        'voucher_type': _voucherType,
        'expense_category': category,
        'created_by': createdBy,
      };
      if (uploadedAttachments.isNotEmpty) {
        voucherData['attachments'] = uploadedAttachments;
      }

      final createdVoucher = await db.createVoucher(voucherData);

      // Super Admin/Admin ko notify karo ki voucher punch hua hai.
      final createdVoucherNumber =
          createdVoucher['voucher_number']?.toString() ?? _voucherNumber;
      if (createdVoucherNumber != null && createdVoucherNumber.isNotEmpty) {
        try {
          await ref.read(pushNotificationServiceProvider).notifyVoucher(
                hospitalId: hospitalId,
                voucherNumber: createdVoucherNumber,
                linkUrl: '/vouchers',
              );
        } catch (e) {
          AppLogger.e('Could not notify admins about voucher creation', e);
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            uploadedAttachments.isEmpty
                ? 'Voucher $_voucherNumber saved successfully'
                : 'Voucher $_voucherNumber saved with '
                      '${uploadedAttachments.length} attachment'
                      '${uploadedAttachments.length == 1 ? '' : 's'}',
          ),
        ),
      );
      context.go('/vouchers');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save voucher: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _uploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    final customCategories = ref
            .watch(voucherCategoriesProvider(hospitalId))
            .maybeWhen(data: (list) => list, orElse: () => const <Map<String, dynamic>>[])
        .where((c) => (c['category_name']?.toString() ?? '').isNotEmpty)
        .map((c) => c['category_name'].toString())
        .toSet()
        .toList()
      ..sort();

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('New Voucher'),
        actions: [
          AppRefreshButton(
            onRefresh: () {
              final hospitalId = ref.read(authStateProvider).hospitalId;
              ref.invalidate(voucherCategoriesProvider(hospitalId));
              setState(() {});
            },
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionCard('Voucher Details', [
              TextFormField(
                controller: _voucherNumberController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Voucher Number',
                  hintText: _voucherNumber == null
                      ? 'Generating...'
                      : 'Auto-generated',
                  suffixIcon: IconButton(
                    tooltip: 'Regenerate',
                    icon: const Icon(Icons.refresh),
                    onPressed: _loadVoucherNumber,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dateController,
                readOnly: true,
                onTap: _pickDate,
                decoration: const InputDecoration(
                  labelText: 'Date',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _payeeController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Payee Name *',
                  hintText: 'e.g. Dr. Anesthesia, Laundry Vendor',
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Payee name is required'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _paymentMode,
                decoration: const InputDecoration(labelText: 'Payment Mode'),
                items: _paymentModes
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(mode),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _paymentMode = value ?? 'Cash'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'e.g. Anesthesia payment for Surgery 123',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              _buildAttachmentField(),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Amount (₹) *',
                  prefixText: '₹ ',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Amount is required';
                  }
                  final amount = double.tryParse(value.trim());
                  if (amount == null || amount <= 0) {
                    return 'Enter a valid amount';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _voucherType,
                decoration: const InputDecoration(labelText: 'Voucher Type'),
                items: _voucherTypes
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(type),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _voucherType = value ?? 'Expense'),
              ),
            ]),
            const SizedBox(height: 16),
            _sectionCard('Expense Category', [
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'Expense Category *',
                ),
                items: [
                  ..._builtInCategories.map(
                    (category) => DropdownMenuItem(
                      value: category,
                      child: Text(category),
                    ),
                  ),
                  ...customCategories.map(
                    (category) => DropdownMenuItem(
                      value: category,
                      child: Text('$category (custom)'),
                    ),
                  ),
                  const DropdownMenuItem(
                    value: _customCategoryValue,
                    child: Text('➕ Custom Category...'),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _category = value;
                  if (value != _customCategoryValue) {
                    _customCategoryController.clear();
                  }
                }),
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Select an expense category'
                    : null,
              ),
              if (_category == _customCategoryValue) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _customCategoryController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'New Category Name *',
                    hintText: 'e.g. Generator Diesel',
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'Enter the custom category name'
                      : null,
                ),
              ],
            ]),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: (_saving || _uploading) ? null : _save,
              icon: (_saving || _uploading)
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                _uploading
                    ? 'Uploading attachments...'
                    : _saving
                    ? 'Saving...'
                    : 'Save Voucher',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Attachments',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        Material(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: (_saving || _uploading) ? null : _pickAttachments,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _uploading ? Icons.cloud_upload_outlined : Icons.attach_file,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _uploading
                          ? 'Uploading attachments...'
                          : _attachments.isEmpty
                          ? 'Add Bill / AMC Document (PDF or Image)'
                          : '✓ ${_attachments.length} file'
                                '${_attachments.length == 1 ? '' : 's'} attached'
                                ' — Add more',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Allowed: PDF / image files only • Max 2 MB per file',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
        ),
        if (_attachments.isNotEmpty) ...[
          const SizedBox(height: 8),
          ..._attachments.asMap().entries.map((entry) {
            final index = entry.key;
            final attachment = entry.value;
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 6),
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: ListTile(
                dense: true,
                leading: Icon(_attachmentIcon(attachment.name)),
                title: Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(_formatFileSize(attachment.size)),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: (_saving || _uploading)
                      ? null
                      : () => setState(() => _attachments.removeAt(index)),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _sectionCard(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _VoucherAttachmentDraft {
  final String name;
  final Uint8List bytes;
  final int size;

  _VoucherAttachmentDraft({
    required this.name,
    required this.bytes,
    required this.size,
  });
}
