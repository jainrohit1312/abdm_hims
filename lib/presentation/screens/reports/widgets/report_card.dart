import 'package:flutter/material.dart';

import '../../../../core/extensions/datetime_extensions.dart';

/// Reports module ke liye shared visual helpers — report type aur status ke
/// icon, color aur label. `ReportCard`, `ReportStatusBadge` aur detail screen
/// sab isi file se reuse karte hain.
class ReportVisuals {
  ReportVisuals._();

  static const Map<String, IconData> _typeIcons = {
    'consultation': Icons.medical_services_outlined,
    'patient': Icons.person_outline,
    'counseling': Icons.psychology_outlined,
    'doctor_performance': Icons.insights_outlined,
    'revenue': Icons.payments_outlined,
    'followup': Icons.event_repeat_outlined,
  };

  static const Map<String, Color> _typeColors = {
    'consultation': Color(0xFF1976D2),
    'patient': Color(0xFF00897B),
    'counseling': Color(0xFF8E24AA),
    'doctor_performance': Color(0xFFF4511E),
    'revenue': Color(0xFF43A047),
    'followup': Color(0xFF6D4C41),
  };

  static IconData iconForType(String? type) {
    final key = (type ?? '').toLowerCase().trim();
    return _typeIcons[key] ?? Icons.analytics_outlined;
  }

  static Color colorForType(String? type) {
    final key = (type ?? '').toLowerCase().trim();
    return _typeColors[key] ?? const Color(0xFF607D8B);
  }

  static String labelForType(String? type) {
    switch ((type ?? '').toLowerCase().trim()) {
      case 'consultation':
        return 'Consultation';
      case 'patient':
        return 'Patient';
      case 'counseling':
        return 'Counseling';
      case 'doctor_performance':
      case 'doctor-performance':
        return 'Doctor Performance';
      case 'revenue':
        return 'Revenue';
      case 'followup':
      case 'follow_up':
        return 'Follow-up';
      default:
        return type == null || type.isEmpty ? 'General' : type;
    }
  }

  static Color colorForStatus(String? status) {
    switch ((status ?? '').toLowerCase().trim()) {
      case 'ready':
        return const Color(0xFF66BB6A); // green
      case 'generating':
        return const Color(0xFFFFA726); // orange
      case 'failed':
        return const Color(0xFFD32F2F); // red
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  static String labelForStatus(String? status) {
    switch ((status ?? '').toLowerCase().trim()) {
      case 'ready':
        return 'Ready';
      case 'generating':
        return 'Generating';
      case 'failed':
        return 'Failed';
      default:
        return status == null || status.isEmpty ? 'Unknown' : status;
    }
  }

  /// Report ke `summary` JSONB se pehle [limit] "label: value" chips banata
  /// hai. `data` JSONB se pehli kuch rows ki `key: value` fallback bhi
  /// available hai jab summary khali ho.
  static List<MapEntry<String, String>> summaryEntries(
    Map<String, dynamic> report, {
    int limit = 4,
  }) {
    final entries = <MapEntry<String, String>>[];

    void collect(dynamic source) {
      if (source is Map) {
        for (final entry in source.entries) {
          if (entries.length >= limit) return;
          final value = entry.value;
          entries.add(
            MapEntry(
              entry.key.toString(),
              value == null ? '-' : value.toString(),
            ),
          );
        }
      } else if (source is List) {
        for (var i = 0; i < source.length && entries.length < limit; i++) {
          final item = source[i];
          if (item is Map) {
            final label =
                item['label'] ?? item['key'] ?? item['name'] ?? 'Item ${i + 1}';
            final value =
                item['value'] ?? item['count'] ?? item['total'] ?? '-';
            entries.add(MapEntry(label.toString(), value.toString()));
          } else {
            entries.add(MapEntry('Item ${i + 1}', item?.toString() ?? '-'));
          }
        }
      }
    }

    collect(report['summary']);
    if (entries.isEmpty) collect(report['data']);

    return entries;
  }
}

/// Colored status badge — green=ready, orange=generating, red=failed.
class ReportStatusBadge extends StatelessWidget {
  const ReportStatusBadge({super.key, required this.status});

  final String? status;

  @override
  Widget build(BuildContext context) {
    final color = ReportVisuals.colorForStatus(status);
    final icon = switch (status?.toLowerCase().trim()) {
      'ready' => Icons.check_circle_outline,
      'generating' => Icons.hourglass_top,
      'failed' => Icons.error_outline,
      _ => Icons.help_outline,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            ReportVisuals.labelForStatus(status),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reports list ke liye ek report card.
///
/// Icon + type color, title, date, status badge, summary chips (pehle 4) aur
/// generated-by user dikhata hai. Tap par [onTap] call hota hai.
class ReportCard extends StatelessWidget {
  const ReportCard({super.key, required this.report, this.onTap});

  final Map<String, dynamic> report;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = report['report_type']?.toString();
    final typeColor = ReportVisuals.colorForType(type);
    final title = report['title']?.toString() ?? 'Untitled Report';
    final createdAt = DateTime.tryParse(report['created_at']?.toString() ?? '');
    final dateFrom = DateTime.tryParse(report['date_from']?.toString() ?? '');
    final dateTo = DateTime.tryParse(report['date_to']?.toString() ?? '');
    final generatedBy =
        report['generated_by_name']?.toString() ??
        report['generated_by']?.toString();
    final chips = ReportVisuals.summaryEntries(report);
    final format = report['file_format']?.toString();

    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: typeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      ReportVisuals.iconForType(type),
                      color: typeColor,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              ReportVisuals.labelForType(type),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: typeColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (dateFrom != null && dateTo != null)
                              Text(
                                '${dateFrom.toDisplayDate} → '
                                '${dateTo.toDisplayDate}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            if (createdAt != null)
                              Text(
                                createdAt.toDisplayDateTime,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            if (format != null && format.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  format.toUpperCase(),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ReportStatusBadge(status: report['status']?.toString()),
                ],
              ),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final chip in chips)
                      _SummaryChip(label: chip.key, value: chip.value),
                  ],
                ),
              ],
              if (generatedBy != null && generatedBy.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.person_outline,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Generated by $generatedBy',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        '$label: $value',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
