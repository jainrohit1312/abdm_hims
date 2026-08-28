import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../models/compliance_models.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/compliance_common.dart';

/// Compliance audit log (`/compliance/audit-logs`).
///
/// Who uploaded, viewed, downloaded, shared, printed, deleted or starred which
/// document — the module's security audit trail.
class ComplianceAuditLogScreen extends ConsumerStatefulWidget {
  const ComplianceAuditLogScreen({super.key});

  @override
  ConsumerState<ComplianceAuditLogScreen> createState() =>
      _ComplianceAuditLogScreenState();
}

class _ComplianceAuditLogScreenState
    extends ConsumerState<ComplianceAuditLogScreen> {
  String? _actionFilter;

  static const List<String> _actions = [
    'upload',
    'view',
    'download',
    'share',
    'print',
    'delete',
    'favorite',
    'unfavorite',
    'update',
  ];

  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('Audit Logs')),
        body: const Center(child: Text('Hospital not assigned to this user.')),
      );
    }

    final logsAsync = ref.watch(complianceAuditLogsProvider(hospitalId));

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Audit Logs')),
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: logsAsync.when(
              data: (logs) {
                final filtered = _actionFilter == null
                    ? logs
                    : logs.where((l) => l.action == _actionFilter).toList();
                if (filtered.isEmpty) {
                  return const ComplianceEmptyState(
                    icon: Icons.history,
                    message: 'No audit activity recorded yet.',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(complianceRefreshProvider),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) =>
                        _buildLogTile(filtered[index]),
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ComplianceEmptyState(
                icon: Icons.error_outline,
                message: 'Failed to load audit logs: $error',
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(complianceRefreshProvider),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _chip('All', _actionFilter == null, () => setState(() => _actionFilter = null)),
            for (final action in _actions)
              _chip(
                action.toUpperCase(),
                _actionFilter == action,
                () => setState(() {
                  _actionFilter = _actionFilter == action ? null : action;
                }),
                color: _actionColor(action),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, {Color? color}) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        selectedColor: effectiveColor.withValues(alpha: 0.18),
        checkmarkColor: effectiveColor,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _buildLogTile(ComplianceAuditEntry log) {
    final color = _actionColor(log.action);
    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(_actionIcon(log.action), color: color, size: 20),
        ),
        title: Text(
          '${log.action.toUpperCase()} • ${log.userName ?? 'System'}',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          log.detail ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Text(
          log.createdAt == null
              ? ''
              : DateFormat('dd MMM, hh:mm a').format(log.createdAt!.toLocal()),
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  IconData _actionIcon(String action) {
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
      case 'favorite':
        return Icons.star;
      case 'unfavorite':
        return Icons.star_border;
      default:
        return Icons.edit_outlined;
    }
  }

  Color _actionColor(String action) {
    switch (action) {
      case 'upload':
        return Colors.green;
      case 'view':
        return Colors.blue;
      case 'download':
        return Colors.indigo;
      case 'share':
        return Colors.teal;
      case 'print':
        return Colors.brown;
      case 'delete':
        return Colors.red;
      case 'favorite':
        return Colors.amber;
      default:
        return Colors.blueGrey;
    }
  }
}
