import 'package:flutter/material.dart';

/// Share options bottom sheet for a report.
///
/// Har option ka apna callback hota hai — WhatsApp (green), Gmail (red),
/// Copy Text (blue), More Apps (grey), Download PDF (indigo) aur Print
/// (orange). Callers detail screen se actions wire karte hain.
class ShareOptionsSheet extends StatelessWidget {
  const ShareOptionsSheet({
    super.key,
    required this.report,
    required this.onWhatsApp,
    required this.onEmail,
    required this.onCopyText,
    required this.onMoreApps,
    required this.onDownload,
    required this.onPrint,
  });

  final Map<String, dynamic> report;
  final VoidCallback onWhatsApp;
  final VoidCallback onEmail;
  final VoidCallback onCopyText;
  final VoidCallback onMoreApps;
  final VoidCallback onDownload;
  final VoidCallback onPrint;

  /// Modal bottom sheet ke roop mein options dikhata hai.
  static Future<void> show(
    BuildContext context, {
    required Map<String, dynamic> report,
    required VoidCallback onWhatsApp,
    required VoidCallback onEmail,
    required VoidCallback onCopyText,
    required VoidCallback onMoreApps,
    required VoidCallback onDownload,
    required VoidCallback onPrint,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ShareOptionsSheet(
        report: report,
        onWhatsApp: onWhatsApp,
        onEmail: onEmail,
        onCopyText: onCopyText,
        onMoreApps: onMoreApps,
        onDownload: onDownload,
        onPrint: onPrint,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = report['title']?.toString() ?? 'Report';
    final status = report['status']?.toString() ?? '';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Share Report',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$title  •  $status',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _ShareOption(
              icon: Icons.chat,
              color: const Color(0xFF25D366),
              title: 'WhatsApp',
              subtitle: 'Send via WhatsApp chat',
              onTap: () {
                Navigator.pop(context);
                onWhatsApp();
              },
            ),
            _ShareOption(
              icon: Icons.mail,
              color: const Color(0xFFD32F2F),
              title: 'Gmail / Email',
              subtitle: 'Send via email app',
              onTap: () {
                Navigator.pop(context);
                onEmail();
              },
            ),
            _ShareOption(
              icon: Icons.copy,
              color: const Color(0xFF1976D2),
              title: 'Copy Text',
              subtitle: 'Copy formatted summary to clipboard',
              onTap: () {
                Navigator.pop(context);
                onCopyText();
              },
            ),
            _ShareOption(
              icon: Icons.apps,
              color: const Color(0xFF607D8B),
              title: 'More Apps',
              subtitle: 'Share via any installed app',
              onTap: () {
                Navigator.pop(context);
                onMoreApps();
              },
            ),
            _ShareOption(
              icon: Icons.download,
              color: const Color(0xFF3F51B5),
              title: 'Download PDF',
              subtitle: 'Download and open the report file',
              onTap: () {
                Navigator.pop(context);
                onDownload();
              },
            ),
            _ShareOption(
              icon: Icons.print,
              color: const Color(0xFFF4511E),
              title: 'Print Report',
              subtitle: 'Print the report directly',
              onTap: () {
                Navigator.pop(context);
                onPrint();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: color.withValues(alpha: 0.14),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right, size: 20),
    );
  }
}
