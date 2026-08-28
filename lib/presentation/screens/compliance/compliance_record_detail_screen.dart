import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/providers.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/share_utils.dart';
import '../../../models/compliance_models.dart';
import '../../../services/compliance_service.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/compliance_common.dart';

/// Compliance record detail (`/compliance/record/:id`).
///
/// Shows the full metadata, the versioned document list with view / download /
/// share / print actions, per-record reminder history and audit trail, plus a
/// QR code for quick access and a "new version" upload flow.
class ComplianceRecordDetailScreen extends ConsumerWidget {
  const ComplianceRecordDetailScreen({super.key, required this.recordId});

  final String recordId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Compliance Record')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final recordAsync = ref.watch(complianceRecordDetailProvider(recordId));
    final documentsAsync = ref.watch(complianceDocumentsProvider(recordId));

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Compliance Record'),
        actions: [
          recordAsync.maybeWhen(
            data: (record) => record == null
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'QR Code',
                    icon: const Icon(Icons.qr_code),
                    onPressed: () => _showQrDialog(context, record),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: recordAsync.when(
        data: (record) {
          if (record == null) {
            return const ComplianceEmptyState(
              icon: Icons.folder_off_outlined,
              message: 'Record not found.',
            );
          }
          return _buildBody(context, ref, record, documentsAsync, hospitalId);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ComplianceEmptyState(
          icon: Icons.error_outline,
          message: 'Failed to load record: $error',
          actionLabel: 'Retry',
          onAction: () => ref.invalidate(complianceRecordDetailProvider(recordId)),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    AsyncValue<List<ComplianceDocumentFile>> documentsAsync,
    String hospitalId,
  ) {
    final status = record.derivedStatus;
    final canManage = canManageCompliance(ref.watch(authStateProvider).userRole);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildHeader(context, ref, record, status, canManage),
        const SizedBox(height: 12),
        _buildInfoCard(context, record),
        const SizedBox(height: 12),
        _buildDocumentsSection(context, ref, record, documentsAsync, hospitalId, canManage),
        const SizedBox(height: 12),
        _buildReminderSection(context, ref, hospitalId),
        const SizedBox(height: 12),
        _buildAuditSection(context, ref, hospitalId),
        if (canManage) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _confirmDeleteRecord(context, ref, record),
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: const Text('Delete Record', style: TextStyle(color: Colors.red)),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    ComplianceStatus status,
    bool canManage,
  ) {
    return Card(
      color: complianceStatusColor(status).withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: complianceCategoryColor(
                      record.category,
                    ).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    complianceCategoryIcon(record.category),
                    color: complianceCategoryColor(record.category),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.documentName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(record.documentType),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: record.isFavorite
                      ? 'Remove from favorites'
                      : 'Add to favorites',
                  icon: Icon(
                    record.isFavorite ? Icons.star : Icons.star_border,
                    color: record.isFavorite ? Colors.amber : null,
                  ),
                  onPressed: () async {
                    await ref
                        .read(complianceServiceProvider)
                        .setFavorite(record.id, !record.isFavorite);
                    await ref.read(complianceServiceProvider).logAudit(
                          hospitalId: record.hospitalId,
                          recordId: record.id,
                          userId: await ref
                              .read(databaseServiceProvider)
                              .getCurrentUsersTableId(),
                          action: record.isFavorite ? 'unfavorite' : 'favorite',
                          detail: record.documentName,
                        );
                    ref.invalidate(complianceRefreshProvider);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ComplianceStatusBadge(status: status),
                ComplianceCategoryChip(category: record.category),
                Chip(
                  label: Text(
                    record.reminderEnabled ? 'Reminders ON' : 'Reminders OFF',
                    style: const TextStyle(fontSize: 11),
                  ),
                  avatar: Icon(
                    record.reminderEnabled
                        ? Icons.notifications_active
                        : Icons.notifications_off,
                    size: 14,
                  ),
                ),
              ],
            ),
            if (status != ComplianceStatus.active) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: complianceStatusColor(status).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status == ComplianceStatus.expired
                      ? '🚨 This document has EXPIRED. Renew it immediately and upload the new version.'
                      : '⏰ ${daysLeftLabel(record.daysToExpiry)} — plan the renewal and keep the new document ready.',
                  style: TextStyle(
                    color: complianceStatusColor(status),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (canManage) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        context.push('/compliance/record/${record.id}/edit'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, ComplianceRecord record) {
    final rows = <(IconData, String, String)>[
      (Icons.account_balance_outlined, 'Authority', record.authorityName ?? '—'),
      (Icons.tag_outlined, 'Number', record.documentNumber ?? '—'),
      (Icons.event_available_outlined, 'Issue Date', record.displayIssue),
      (Icons.event_busy_outlined, 'Expiry Date', record.displayExpiry),
      (
        Icons.hourglass_bottom,
        'Days Left',
        record.daysToExpiry == null
            ? 'No expiry'
            : '${record.daysToExpiry} day(s)',
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Details',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(row.$1, size: 18, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: Text(
                        row.$2,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(child: Text(row.$3)),
                  ],
                ),
              ),
            if ((record.notes ?? '').isNotEmpty) ...[
              const Divider(),
              Text(
                record.notes!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentsSection(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    AsyncValue<List<ComplianceDocumentFile>> documentsAsync,
    String hospitalId,
    bool canManage,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Documents & Versions',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _showUploadSheet(context, ref, record, hospitalId),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('New Version'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            documentsAsync.when(
              data: (documents) {
                if (documents.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text('No documents uploaded yet.')),
                  );
                }
                return Column(
                  children: documents.map((doc) => _buildDocumentTile(
                    context,
                    ref,
                    record,
                    doc,
                    canManage,
                  )).toList(),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Text('Failed to load documents: $error'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentTile(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    ComplianceDocumentFile doc,
    bool canManage,
  ) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: ListTile(
        leading: Icon(documentTypeIcon(doc.fileName), size: 32),
        title: Text(doc.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${doc.versionLabel} • ${doc.displaySize} • '
          '${doc.createdAt == null ? '' : DateFormat('dd MMM yyyy').format(doc.createdAt!.toLocal())}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) => _handleDocumentAction(
            context,
            ref,
            record,
            doc,
            action,
          ),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'view', child: Text('View')),
            const PopupMenuItem(value: 'download', child: Text('Download')),
            const PopupMenuItem(value: 'share', child: Text('Share')),
            const PopupMenuItem(value: 'print', child: Text('Print')),
            if (canManage)
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: () =>
            context.push('/compliance/document/${doc.id}/view?recordId=${record.id}'),
      ),
    );
  }

  Future<void> _handleDocumentAction(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    ComplianceDocumentFile doc,
    String action,
  ) async {
    switch (action) {
      case 'view':
        context.push('/compliance/document/${doc.id}/view?recordId=${record.id}');
        break;
      case 'download':
        await _downloadDocument(context, ref, doc);
        break;
      case 'share':
        await _shareDocument(context, ref, doc);
        break;
      case 'print':
        await _printDocument(context, ref, doc);
        break;
      case 'delete':
        await _confirmDeleteDocument(context, ref, record, doc);
        break;
    }
  }

  Future<void> _downloadDocument(
    BuildContext context,
    WidgetRef ref,
    ComplianceDocumentFile doc,
  ) async {
    try {
      final bytes = await ref
          .read(storageServiceProvider)
          .downloadBytes(doc.filePath);
      final directory = await _saveDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}${_safeName(doc.fileName)}',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${file.path}')),
      );
      await ref.read(complianceServiceProvider).logAudit(
            hospitalId: doc.hospitalId,
            recordId: doc.recordId,
            documentId: doc.id,
            userId: await ref.read(databaseServiceProvider).getCurrentUsersTableId(),
            action: 'download',
            detail: doc.fileName,
          );
    } catch (e) {
      AppLogger.e('Download failed', e);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  Future<void> _shareDocument(
    BuildContext context,
    WidgetRef ref,
    ComplianceDocumentFile doc,
  ) async {
    try {
      final bytes = await ref
          .read(storageServiceProvider)
          .downloadBytes(doc.filePath);
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_safeName(doc.fileName)}',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.chat, color: Colors.green),
                title: const Text('WhatsApp'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await ShareUtils.shareViaWhatsApp(
                    filePath: file.path,
                    fileName: doc.fileName,
                    message:
                        'Compliance document: ${doc.fileName} (${doc.versionLabel})',
                    mimeType: doc.mimeType,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.email_outlined, color: Colors.blue),
                title: const Text('Email'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await ShareUtils.shareViaEmail(
                    filePath: file.path,
                    fileName: doc.fileName,
                    subject: 'Compliance document: ${doc.fileName}',
                    body: 'Please find attached: ${doc.fileName}',
                    mimeType: doc.mimeType,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share via other apps (Bluetooth, Drive...)'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await ShareUtils.shareFile(
                    filePath: file.path,
                    fileName: doc.fileName,
                    mimeType: doc.mimeType,
                    text: doc.fileName,
                  );
                },
              ),
            ],
          ),
        ),
      );
      await ref.read(complianceServiceProvider).logAudit(
            hospitalId: doc.hospitalId,
            recordId: doc.recordId,
            documentId: doc.id,
            userId: await ref.read(databaseServiceProvider).getCurrentUsersTableId(),
            action: 'share',
            detail: doc.fileName,
          );
    } catch (e) {
      AppLogger.e('Share failed', e);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  Future<void> _printDocument(
    BuildContext context,
    WidgetRef ref,
    ComplianceDocumentFile doc,
  ) async {
    if (!doc.isPdf) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Printing is available for PDF documents.')));
      return;
    }
    try {
      final bytes = await ref
          .read(storageServiceProvider)
          .downloadBytes(doc.filePath);
      if (!context.mounted) return;
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: doc.fileName,
      );
      await ref.read(complianceServiceProvider).logAudit(
            hospitalId: doc.hospitalId,
            recordId: doc.recordId,
            documentId: doc.id,
            userId: await ref.read(databaseServiceProvider).getCurrentUsersTableId(),
            action: 'print',
            detail: doc.fileName,
          );
    } catch (e) {
      AppLogger.e('Print failed', e);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Print failed: $e')));
      }
    }
  }

  Future<void> _showUploadSheet(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    String hospitalId,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Upload new version',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('File Picker (PDF/DOC/Image)'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndUploadVersion(context, ref, record, hospitalId);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadVersion(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    String hospitalId,
  ) async {
    try {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Documents',
            extensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
          ),
        ],
      );
      if (files.isEmpty || !context.mounted) return;
      final file = files.first;
      final bytes = await file.readAsBytes();
      if (!context.mounted) return;
      if (!ComplianceService.isAllowedExtension(file.name)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Allowed: PDF, JPG, PNG, JPEG, DOC, DOCX')));
        return;
      }
      if (bytes.length > ComplianceService.maxFileSizeBytes) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('File exceeds 25 MB limit')));
        return;
      }
      await ref.read(complianceServiceProvider).uploadDocument(
            recordId: record.id,
            hospitalId: hospitalId,
            fileName: file.name,
            bytes: bytes,
            uploadedBy: (await ref
                    .read(databaseServiceProvider)
                    .getCurrentUsersTableId()) ??
                '',
          );
      await ref.read(complianceServiceProvider).logAudit(
            hospitalId: hospitalId,
            recordId: record.id,
            userId: await ref.read(databaseServiceProvider).getCurrentUsersTableId(),
            action: 'upload',
            detail: '${file.name} (new version)',
          );
      if (!context.mounted) return;
      ref.invalidate(complianceRefreshProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Uploaded ${file.name} as a new version')));
    } catch (e) {
      AppLogger.e('Version upload failed', e);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Widget _buildReminderSection(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
  ) {
    final remindersAsync = ref.watch(complianceRemindersProvider(hospitalId));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Reminder History',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () => context.push('/compliance/reminders'),
                  child: const Text('View all'),
                ),
              ],
            ),
            remindersAsync.when(
              data: (reminders) {
                final mine = reminders.where((r) => r.recordId == recordId).toList();
                if (mine.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No reminders sent yet for this record.'),
                  );
                }
                return Column(
                  children: mine.take(5).map((reminder) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      reminder.reminderType == ReminderType.expired
                          ? Icons.error_outline
                          : reminder.reminderType == ReminderType.sevenDay
                          ? Icons.warning_amber_outlined
                          : Icons.notifications_outlined,
                      color: reminder.reminderType == ReminderType.expired
                          ? Colors.red
                          : reminder.reminderType == ReminderType.sevenDay
                          ? Colors.orange
                          : Colors.blue,
                    ),
                    title: Text(
                      '${reminder.reminderType.label} • ${reminder.channel.label}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      reminder.message ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      reminder.createdAt == null
                          ? ''
                          : DateFormat('dd MMM').format(reminder.createdAt!.toLocal()),
                      style: const TextStyle(fontSize: 11),
                    ),
                  )).toList(),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuditSection(
    BuildContext context,
    WidgetRef ref,
    String hospitalId,
  ) {
    final auditAsync = ref.watch(complianceAuditLogsProvider(hospitalId));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Audit Trail',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () => context.push('/compliance/audit-logs'),
                  child: const Text('View all'),
                ),
              ],
            ),
            auditAsync.when(
              data: (logs) {
                final mine = logs.where((l) => l.recordId == recordId).toList();
                if (mine.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No activity recorded for this record yet.'),
                  );
                }
                return Column(
                  children: mine.take(5).map((log) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_auditIcon(log.action), size: 20),
                    title: Text(
                      '${log.action.toUpperCase()} — ${log.userName ?? 'System'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      log.detail ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      log.createdAt == null
                          ? ''
                          : DateFormat('dd MMM, hh:mm a').format(log.createdAt!.toLocal()),
                      style: const TextStyle(fontSize: 11),
                    ),
                  )).toList(),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  IconData _auditIcon(String action) {
    switch (action) {
      case 'upload':
        return Icons.upload_file;
      case 'view':
        return Icons.visibility_outlined;
      case 'download':
        return Icons.download_outlined;
      case 'share':
        return Icons.share_outlined;
      case 'print':
        return Icons.print_outlined;
      case 'delete':
        return Icons.delete_outline;
      default:
        return Icons.history;
    }
  }

  Future<void> _confirmDeleteRecord(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete record?'),
        content: Text(
          'This will permanently delete "${record.documentName}" and all its document versions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(complianceServiceProvider).deleteRecord(record.id);
      if (!context.mounted) return;
      ref.invalidate(complianceRefreshProvider);
      context.go('/compliance');
    } catch (e) {
      AppLogger.e('Delete record failed', e);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _confirmDeleteDocument(
    BuildContext context,
    WidgetRef ref,
    ComplianceRecord record,
    ComplianceDocumentFile doc,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('Delete "${doc.fileName}" (${doc.versionLabel})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(complianceServiceProvider).deleteDocument(doc.id);
      await ref.read(complianceServiceProvider).logAudit(
            hospitalId: record.hospitalId,
            recordId: record.id,
            documentId: doc.id,
            userId: await ref.read(databaseServiceProvider).getCurrentUsersTableId(),
            action: 'delete',
            detail: doc.fileName,
          );
      if (!context.mounted) return;
      ref.invalidate(complianceRefreshProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _showQrDialog(BuildContext context, ComplianceRecord record) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Quick Access QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: '/compliance/record/${record.id}',
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              'Scan to open: ${record.documentName}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Best-effort save directory: platform Downloads when available, otherwise
/// the application documents directory.
Future<Directory> _saveDirectory() async {
  if (!kIsWeb) {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {
      // Not supported on this platform.
    }
    return getApplicationDocumentsDirectory();
  }
  return getApplicationDocumentsDirectory();
}

String _safeName(String fileName) {
  return fileName.replaceAll(RegExp(r'[^\w.\-]+'), '_');
}
