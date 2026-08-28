import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../core/utils/logger.dart';
import '../../../models/compliance_models.dart';
import '../../../services/compliance_service.dart';
import '../../widgets/app_refresh_button.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/compliance_common.dart';

/// Create / edit a compliance record (`/compliance/new` and
/// `/compliance/:id/edit`).
///
/// Supports camera, gallery and file-picker uploads (PDF/JPG/PNG/JPEG/DOC/DOCX,
/// max 25 MB each), thumbnail previews, upload progress and the full
/// regulatory/AMC/CMC/insurance/contract document-type catalogue.
class ComplianceRecordFormScreen extends ConsumerStatefulWidget {
  const ComplianceRecordFormScreen({super.key, this.recordId});

  /// When non-null the form edits an existing record (metadata only).
  final String? recordId;

  @override
  ConsumerState<ComplianceRecordFormScreen> createState() =>
      _ComplianceRecordFormScreenState();
}

class _ComplianceRecordFormScreenState
    extends ConsumerState<ComplianceRecordFormScreen> {
  final _formKey = GlobalKey<FormState>();

  final _documentNameController = TextEditingController();
  final _authorityController = TextEditingController();
  final _documentNumberController = TextEditingController();
  final _issueDateController = TextEditingController();
  final _expiryDateController = TextEditingController();
  final _notesController = TextEditingController();

  final ImagePicker _imagePicker = ImagePicker();

  String? _documentType;
  ComplianceCategory _category = ComplianceCategory.regulatory;
  DateTime? _issueDate;
  DateTime? _expiryDate;
  bool _reminderEnabled = true;
  bool _isFavorite = false;
  bool _saving = false;
  bool _uploading = false;
  final List<_ComplianceDraftFile> _drafts = [];

  bool get _isEdit => widget.recordId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadRecord());
    }
  }

  @override
  void dispose() {
    _documentNameController.dispose();
    _authorityController.dispose();
    _documentNumberController.dispose();
    _issueDateController.dispose();
    _expiryDateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadRecord() async {
    final record = await ref
        .read(complianceServiceProvider)
        .getRecordById(widget.recordId!, hospitalId: ref.read(authStateProvider).hospitalId);
    if (!mounted || record == null) return;
    setState(() {
      _documentNameController.text = record.documentName;
      _documentType = record.documentType;
      _category = record.category;
      _authorityController.text = record.authorityName ?? '';
      _documentNumberController.text = record.documentNumber ?? '';
      _issueDate = record.issueDate;
      _expiryDate = record.expiryDate;
      _issueDateController.text = record.issueDate == null
          ? ''
          : DateFormat('dd/MM/yyyy').format(record.issueDate!);
      _expiryDateController.text = record.expiryDate == null
          ? ''
          : DateFormat('dd/MM/yyyy').format(record.expiryDate!);
      _notesController.text = record.notes ?? '';
      _reminderEnabled = record.reminderEnabled;
      _isFavorite = record.isFavorite;
    });
  }

  Future<void> _pickDate({required bool isIssue}) async {
    final initial = isIssue ? (_issueDate ?? DateTime.now()) : (_expiryDate ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
      helpText: isIssue ? 'Select issue date' : 'Select expiry date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isIssue) {
        _issueDate = picked;
        _issueDateController.text = DateFormat('dd/MM/yyyy').format(picked);
      } else {
        _expiryDate = picked;
        _expiryDateController.text = DateFormat('dd/MM/yyyy').format(picked);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Uploads: camera / gallery / file picker
  // ---------------------------------------------------------------------------

  Future<void> _pickFromCamera() async {
    try {
      final shot = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 2400,
      );
      if (shot == null || !mounted) return;
      final bytes = await shot.readAsBytes();
      _addDraft(shot.name, bytes);
    } catch (e) {
      _showSnack('Could not open camera: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final shots = await _imagePicker.pickMultiImage(imageQuality: 85, maxWidth: 2400);
      if (shots.isEmpty || !mounted) return;
      for (final shot in shots) {
        final bytes = await shot.readAsBytes();
        _addDraft(shot.name, bytes);
      }
    } catch (e) {
      _showSnack('Could not open gallery: $e');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Documents',
            extensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
          ),
        ],
      );
      if (files.isEmpty || !mounted) return;
      for (final file in files) {
        final bytes = await file.readAsBytes();
        _addDraft(file.name, bytes);
      }
    } catch (e) {
      _showSnack('Could not pick files: $e');
    }
  }

  void _addDraft(String name, Uint8List bytes) {
    if (!ComplianceService.isAllowedExtension(name)) {
      _showSnack('$name skipped — allowed: PDF, JPG, PNG, JPEG, DOC, DOCX');
      return;
    }
    if (bytes.length > ComplianceService.maxFileSizeBytes) {
      _showSnack('$name skipped — larger than 25 MB');
      return;
    }
    setState(() {
      _drafts.add(
        _ComplianceDraftFile(
          name: name,
          bytes: bytes,
          size: bytes.length,
          isImage: const ['jpg', 'jpeg', 'png'].contains(
            name.contains('.') ? name.split('.').last.toLowerCase() : '',
          ),
        ),
      );
    });
  }

  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final hospitalId = ref.read(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      _showSnack('Hospital not assigned to this user.');
      return;
    }

    setState(() => _saving = true);
    try {
      final service = ref.read(complianceServiceProvider);
      final status = ComplianceStatus.fromExpiry(_expiryDate);
      final payload = <String, dynamic>{
        'document_name': _documentNameController.text.trim(),
        'document_type': _documentType,
        'category': _category.value,
        'authority_name': _authorityController.text.trim(),
        'document_number': _documentNumberController.text.trim(),
        'issue_date': _issueDate == null
            ? null
            : DateFormat('yyyy-MM-dd').format(_issueDate!),
        'expiry_date': _expiryDate == null
            ? null
            : DateFormat('yyyy-MM-dd').format(_expiryDate!),
        'reminder_enabled': _reminderEnabled,
        'status': status.value,
        'is_favorite': _isFavorite,
        'notes': _notesController.text.trim(),
      };

      late ComplianceRecord saved;
      if (_isEdit) {
        saved = await service.updateRecord(widget.recordId!, payload);
      } else {
        final userId = await ref
            .read(databaseServiceProvider)
            .getCurrentUsersTableId();
        payload['created_by'] = userId;
        saved = await service.createRecord(payload, hospitalId: hospitalId);
      }

      // Upload selected files as versioned documents.
      if (_drafts.isNotEmpty && !_isEdit) {
        setState(() => _uploading = true);
        final uploadedBy = await ref
            .read(databaseServiceProvider)
            .getCurrentUsersTableId();
        for (final draft in _drafts) {
          if (mounted) {
            setState(() {});
          }
          await service.uploadDocument(
            recordId: saved.id,
            hospitalId: hospitalId,
            fileName: draft.name,
            bytes: draft.bytes,
            uploadedBy: uploadedBy ?? '',
          );
        }
        if (mounted) setState(() => _uploading = false);
      }

      await service.logAudit(
        hospitalId: hospitalId,
        recordId: saved.id,
        userId: await ref.read(databaseServiceProvider).getCurrentUsersTableId(),
        action: _isEdit ? 'update' : 'upload',
        detail: '${saved.documentName} (${saved.documentType})',
      );

      if (!mounted) return;
      ref.invalidate(complianceRefreshProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEdit
                ? 'Compliance record updated'
                : 'Compliance record saved with ${_drafts.length} file${_drafts.length == 1 ? '' : 's'}',
          ),
        ),
      );
      context.go('/compliance/record/${saved.id}');
    } catch (e) {
      AppLogger.e('Failed to save compliance record', e);
      if (mounted) _showSnack('Failed to save: $e');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _uploading = false;
        });
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(
        title: Text(_isEdit ? 'Edit Compliance Record' : 'New Compliance Document'),
        actions: [
          AppRefreshButton(
            onRefresh: () {
              if (_isEdit) _loadRecord();
              ref.invalidate(complianceRefreshProvider);
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
            _sectionCard('Document Details', [
              TextFormField(
                controller: _documentNameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Document Name *',
                  hintText: 'e.g. Fire NOC — Main Building',
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Document name is required'
                    : null,
              ),
              const SizedBox(height: 12),
              _buildTypeDropdown(),
              const SizedBox(height: 12),
              TextFormField(
                controller: _authorityController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Issuing Authority',
                  hintText: 'e.g. Municipal Corporation, Fire Dept.',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _documentNumberController,
                decoration: const InputDecoration(
                  labelText: 'Document / License Number',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _issueDateController,
                      readOnly: true,
                      onTap: () => _pickDate(isIssue: true),
                      decoration: const InputDecoration(
                        labelText: 'Issue Date',
                        suffixIcon: Icon(Icons.calendar_today_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _expiryDateController,
                      readOnly: true,
                      onTap: () => _pickDate(isIssue: false),
                      decoration: const InputDecoration(
                        labelText: 'Expiry Date *',
                        suffixIcon: Icon(Icons.calendar_today_outlined),
                      ),
                      validator: (value) => (value == null || value.isEmpty)
                          ? 'Expiry date is required for reminders'
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _sectionCard('Preferences', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Reminder before expiry'),
                subtitle: const Text('30-day, 7-day and expired alerts'),
                value: _reminderEnabled,
                onChanged: (value) => setState(() => _reminderEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mark as favorite'),
                subtitle: const Text('Show in quick access'),
                value: _isFavorite,
                onChanged: (value) => setState(() => _isFavorite = value),
              ),
            ]),
            if (!_isEdit) ...[
              const SizedBox(height: 12),
              _buildUploadSection(),
            ],
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
                    ? 'Uploading files...'
                    : _saving
                    ? 'Saving...'
                    : _isEdit
                    ? 'Update Record'
                    : 'Save & Upload',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeDropdown() {
    final items = <DropdownMenuItem<String>>[
      for (final entry in ComplianceDocumentTypeCatalog.flat)
        DropdownMenuItem(
          value: entry.value,
          child: Text(
            '${entry.key.label}: ${entry.value}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];

    return DropdownButtonFormField<String>(
      key: ValueKey('compliance_type_$_documentType'),
      initialValue: _documentType,
      decoration: const InputDecoration(labelText: 'Document Type *'),
      items: items,
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _documentType = value;
          _category = ComplianceDocumentTypeCatalog.categoryForType(value);
        });
      },
      validator: (value) =>
          (value == null || value.isEmpty) ? 'Select a document type' : null,
      menuMaxHeight: 420,
    );
  }

  Widget _buildUploadSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Documents',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'PDF, JPG, PNG, JPEG, DOC, DOCX • Max 25 MB per file',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _uploadTile(
                icon: Icons.photo_camera_outlined,
                label: 'Camera',
                onTap: (_saving || _uploading) ? null : _pickFromCamera,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _uploadTile(
                icon: Icons.photo_library_outlined,
                label: 'Gallery',
                onTap: (_saving || _uploading) ? null : _pickFromGallery,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _uploadTile(
                icon: Icons.folder_open_outlined,
                label: 'File Picker',
                onTap: (_saving || _uploading) ? null : _pickFiles,
              ),
            ),
          ],
        ),
        if (_uploading) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (_drafts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '${_drafts.length} file${_drafts.length == 1 ? '' : 's'} ready to upload',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          ..._drafts.asMap().entries.map((entry) {
            final index = entry.key;
            final draft = entry.value;
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 6),
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: ListTile(
                dense: true,
                leading: draft.isImage
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(
                          draft.bytes,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(
                            documentTypeIcon(draft.name),
                          ),
                        ),
                      )
                    : Icon(documentTypeIcon(draft.name)),
                title: Text(
                  draft.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(formatFileSize(draft.size)),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: (_saving || _uploading)
                      ? null
                      : () => setState(() => _drafts.removeAt(index)),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _uploadTile({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            children: [
              Icon(icon),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ComplianceDraftFile {
  final String name;
  final Uint8List bytes;
  final int size;
  final bool isImage;

  _ComplianceDraftFile({
    required this.name,
    required this.bytes,
    required this.size,
    required this.isImage,
  });
}
