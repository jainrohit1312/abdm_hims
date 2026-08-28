import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/app_refresh_button.dart';
import '../../../services/push_notification_service.dart';
import '../../widgets/smart_navigation.dart';

/// `/notifications` — saare in-app notifications (OPD Visit, IPD Admission,
/// Voucher, Lab Report, Billing) yahan dikhte hain. Type-filter chips aur
/// read/unread state ke saath.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final publicUserIdAsync = ref.watch(currentPublicUserIdProvider);

    return publicUserIdAsync.when(
      data: (userId) {
        if (userId == null || userId.isEmpty) {
          return Scaffold(
            appBar: SmartAppBar(title: const Text('Notifications')),
            body: const Center(
              child: Text('Login required to view notifications.'),
            ),
          );
        }

        final notificationsAsync = ref.watch(notificationsProvider(userId));
        final selectedType = ref.watch(notificationTypeFilterProvider);

        return Scaffold(
          appBar: SmartAppBar(
            title: const Text('Notifications'),
            actions: [
              AppRefreshButton(
                onRefresh: () {
                  ref.invalidate(notificationsProvider(userId));
                  ref.invalidate(unreadNotificationCountProvider(userId));
                  ref.invalidate(recentNotificationsProvider(userId));
                },
              ),
              IconButton(
                tooltip: 'Mark all as read',
                onPressed: () => _markAllRead(context, ref, userId),
                icon: const Icon(Icons.done_all),
              ),
            ],
          ),
          body: Column(
            children: [
              // Type filter — All / OPD / IPD / Voucher / Lab / Billing.
              _NotificationFilterBar(
                selectedType: selectedType,
                onSelected: (value) {
                  ref.read(notificationTypeFilterProvider.notifier).state =
                      value;
                },
              ),
              const Divider(height: 1),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(notificationsProvider(userId));
                    ref.invalidate(unreadNotificationCountProvider(userId));
                    await Future<void>.delayed(
                      const Duration(milliseconds: 400),
                    );
                  },
                  child: notificationsAsync.when(
                    data: (notifications) {
                      final visible = selectedType == null
                          ? notifications
                          : notifications
                                .where(
                                  (n) =>
                                      n['notification_type']?.toString() ==
                                      selectedType,
                                )
                                .toList();

                      if (visible.isEmpty) {
                        return _EmptyState(
                          hasFilter: selectedType != null,
                          hasAnyNotifications: notifications.isNotEmpty,
                        );
                      }

                      return ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final notification = visible[index];
                          return _NotificationTile(
                            notification: notification,
                            onTap: () =>
                                _markRead(context, ref, userId, notification),
                          );
                        },
                      );
                    },
                    error: (error, _) => ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 160),
                        Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.red.shade300,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text('Failed to load notifications\n$error'),
                        ),
                      ],
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => Scaffold(
        appBar: SmartAppBar(title: const Text('Notifications')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: SmartAppBar(title: const Text('Notifications')),
        body: Center(child: Text('Failed to load user context\n$error')),
      ),
    );
  }

  Future<void> _markRead(
    BuildContext context,
    WidgetRef ref,
    String userId,
    Map<String, dynamic> notification,
  ) async {
    final isRead = notification['is_read'] == true;
    if (isRead) return;

    final notificationId = notification['id']?.toString();
    if (notificationId == null) return;

    await ref
        .read(databaseServiceProvider)
        .markNotificationAsRead(notificationId);

    ref.invalidate(notificationsProvider(userId));
    ref.invalidate(unreadNotificationCountProvider(userId));
    ref.invalidate(recentNotificationsProvider(userId));
  }

  Future<void> _markAllRead(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) async {
    await ref.read(databaseServiceProvider).markAllNotificationsAsRead(userId);

    ref.invalidate(notificationsProvider(userId));
    ref.invalidate(unreadNotificationCountProvider(userId));
    ref.invalidate(recentNotificationsProvider(userId));

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All notifications marked as read')),
      );
    }
  }
}

/// Horizontal filter chips: All / OPD / IPD / Voucher / Lab / Billing.
class _NotificationFilterBar extends StatelessWidget {
  const _NotificationFilterBar({
    required this.selectedType,
    required this.onSelected,
  });

  final String? selectedType;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _filterChip(label: 'All', value: null),
          for (final type in NotificationType.values) ...[
            const SizedBox(width: 8),
            _filterChip(label: type.label, value: type.value),
          ],
        ],
      ),
    );
  }

  Widget _filterChip({required String label, required String? value}) {
    return ChoiceChip(
      label: Text(label),
      selected: selectedType == value,
      onSelected: (_) => onSelected(value),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.hasFilter,
    required this.hasAnyNotifications,
  });

  final bool hasFilter;
  final bool hasAnyNotifications;

  @override
  Widget build(BuildContext context) {
    // RefreshIndicator ko scrollable chahiye; empty state bhi scrollable list
    // ke andar rakhte hain.
    final message = hasFilter
        ? (hasAnyNotifications
              ? 'No notifications for this filter'
              : 'No notifications yet')
        : 'No notifications yet';

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 160),
        const Icon(Icons.notifications_none, size: 64, color: Colors.grey),
        const SizedBox(height: 12),
        Center(
          child: Text(message, style: const TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final Map<String, dynamic> notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRead = notification['is_read'] == true;
    final type = NotificationType.fromValue(
      notification['notification_type']?.toString(),
    );
    final title = notification['title']?.toString() ?? 'Notification';
    final message = notification['message']?.toString() ?? '';
    final createdAt = DateTime.tryParse(
      notification['created_at']?.toString() ?? '',
    );

    return ListTile(
      onTap: onTap,
      tileColor: isRead
          ? null
          : theme.colorScheme.primary.withValues(alpha: 0.06),
      leading: CircleAvatar(
        backgroundColor: _typeColor(type).withValues(alpha: 0.15),
        child: Icon(_typeIcon(type), color: _typeColor(type), size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: isRead ? FontWeight.w400 : FontWeight.w700,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.isNotEmpty) ...[const SizedBox(height: 2), Text(message)],
          const SizedBox(height: 4),
          Row(
            children: [
              if (type != null) ...[
                _typeChip(theme, type),
                const SizedBox(width: 6),
              ],
              Text(
                createdAt == null ? '' : _timeAgo(createdAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: isRead
          ? null
          : Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
    );
  }

  Widget _typeChip(ThemeData theme, NotificationType type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _typeColor(type).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        type.label,
        style: TextStyle(fontSize: 11, color: _typeColor(type)),
      ),
    );
  }

  IconData _typeIcon(NotificationType? type) {
    switch (type) {
      case NotificationType.opdVisit:
        return Icons.medical_services_outlined;
      case NotificationType.ipdAdmission:
        return Icons.local_hotel_outlined;
      case NotificationType.voucher:
        return Icons.confirmation_number_outlined;
      case NotificationType.labReport:
        return Icons.biotech_outlined;
      case NotificationType.billing:
        return Icons.receipt_long_outlined;
      case NotificationType.complianceReminder:
        return Icons.verified_user_outlined;
      case null:
        return Icons.notifications_outlined;
    }
  }

  Color _typeColor(NotificationType? type) {
    switch (type) {
      case NotificationType.opdVisit:
        return Colors.blue;
      case NotificationType.ipdAdmission:
        return Colors.orange;
      case NotificationType.voucher:
        return Colors.teal;
      case NotificationType.labReport:
        return Colors.purple;
      case NotificationType.billing:
        return Colors.indigo;
      case NotificationType.complianceReminder:
        return Colors.teal;
      case null:
        return Colors.grey;
    }
  }

  String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime.toLocal());

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return DateFormat('dd MMM yyyy, hh:mm a').format(dateTime.toLocal());
  }
}
