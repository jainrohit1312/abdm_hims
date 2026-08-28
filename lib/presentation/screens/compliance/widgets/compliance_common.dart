import 'package:flutter/material.dart';

import '../../../../models/compliance_models.dart';

/// Shared visual helpers for the Compliance & Renewal Reminder module.

/// Role-based access control: only Admin may delete records/files or change
/// security-critical settings. Staff/Manager roles (doctor, nurse,
/// receptionist, pharmacist, lab technician, accountant) can upload & view.
bool canManageCompliance(String? userRole) {
  final role = (userRole ?? '').toLowerCase();
  return role == 'admin' || role == 'super_admin';
}

Color complianceStatusColor(ComplianceStatus status) {
  switch (status) {
    case ComplianceStatus.active:
      return Colors.green;
    case ComplianceStatus.expiring:
      return Colors.orange;
    case ComplianceStatus.expired:
      return Colors.red;
    case ComplianceStatus.archived:
      return Colors.blueGrey;
  }
}

IconData complianceStatusIcon(ComplianceStatus status) {
  switch (status) {
    case ComplianceStatus.active:
      return Icons.check_circle_outline;
    case ComplianceStatus.expiring:
      return Icons.timer_outlined;
    case ComplianceStatus.expired:
      return Icons.error_outline;
    case ComplianceStatus.archived:
      return Icons.archive_outlined;
  }
}

IconData complianceCategoryIcon(ComplianceCategory category) {
  switch (category) {
    case ComplianceCategory.regulatory:
      return Icons.gavel_outlined;
    case ComplianceCategory.amc:
      return Icons.settings_suggest_outlined;
    case ComplianceCategory.cmc:
      return Icons.build_circle_outlined;
    case ComplianceCategory.insurance:
      return Icons.shield_outlined;
    case ComplianceCategory.contracts:
      return Icons.handshake_outlined;
  }
}

Color complianceCategoryColor(ComplianceCategory category) {
  switch (category) {
    case ComplianceCategory.regulatory:
      return Colors.indigo;
    case ComplianceCategory.amc:
      return Colors.teal;
    case ComplianceCategory.cmc:
      return Colors.brown;
    case ComplianceCategory.insurance:
      return Colors.blue;
    case ComplianceCategory.contracts:
      return Colors.purple;
  }
}

IconData documentTypeIcon(String fileName) {
  final ext = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  if (const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
    return Icons.image_outlined;
  }
  if (const ['doc', 'docx'].contains(ext)) {
    return Icons.description_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Human label for days-left before expiry.
String daysLeftLabel(int? days) {
  if (days == null) return 'No expiry';
  if (days < 0) return 'Expired ${-days} day(s) ago';
  if (days == 0) return 'Expires today';
  if (days == 1) return 'Expires tomorrow';
  return 'Expires in $days days';
}

/// Small status pill used on cards and detail headers.
class ComplianceStatusBadge extends StatelessWidget {
  const ComplianceStatusBadge({super.key, required this.status, this.size});

  final ComplianceStatus status;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final color = complianceStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(complianceStatusIcon(status), size: (size ?? 12), color: color),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: TextStyle(
              fontSize: size == null ? 11 : (size! - 1),
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small category pill with icon.
class ComplianceCategoryChip extends StatelessWidget {
  const ComplianceCategoryChip({super.key, required this.category});

  final ComplianceCategory category;

  @override
  Widget build(BuildContext context) {
    final color = complianceCategoryColor(category);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(complianceCategoryIcon(category), size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            category.label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

/// Consistent empty state.
class ComplianceEmptyState extends StatelessWidget {
  const ComplianceEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
