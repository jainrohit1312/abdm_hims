import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// Session history for one specific OPD visit / IPD admission — every
/// counseling session attached to that visit with its recordings, consent
/// status, GPS stamp and AI summary. Multiple sessions stack chronologically
/// (newest first) under the same visit.
class CounselingSessionHistoryScreen extends ConsumerWidget {
  const CounselingSessionHistoryScreen({
    super.key,
    required this.patientId,
    required this.visitType,
    required this.visitId,
    this.patientName = '',
  });

  final String patientId;
  final String patientName;

  /// `opd` or `ipd` — auto-detected from the module that opened this screen.
  final String visitType;

  /// The `opd_registrations.id` / `ipd_admissions.id` whose sessions are
  /// stacked here.
  final String visitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final params = CounselingVisitParams(
      visitType: visitType,
      visitId: visitId,
    );
    final historyAsync = ref.watch(
      counselingSessionHistoryByVisitProvider(params),
    );

    return Scaffold(
      appBar: SmartAppBar(
        title: Text(
          visitType == 'ipd'
              ? 'IPD Counseling History'
              : 'OPD Counseling History',
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          final nameParam = Uri.encodeComponent(patientName);
          final visitKey = visitType == 'ipd'
              ? 'ipdAdmissionId'
              : 'opdRegistrationId';
          context.push(
            '/counseling?patientId=$patientId'
            '&patientName=$nameParam&visitType=$visitType'
            '&$visitKey=$visitId',
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('New Session'),
      ),
      body: historyAsync.when(
        data: (sessions) => sessions.isEmpty
            ? _EmptyHistory(patientName: patientName)
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: sessions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  return _SessionCard(
                    session: session,
                    patientName: patientName,
                    theme: theme,
                  );
                },
              ),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Failed to load history: $error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.patientName});

  final String patientName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history_toggle_off,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            patientName.isEmpty
                ? 'No counseling sessions for this visit yet.'
                : 'No counseling sessions for $patientName in this visit yet.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.patientName,
    required this.theme,
  });

  final Map<String, dynamic> session;
  final String patientName;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final recordId = session['id']?.toString() ?? '';
    final media = (session['media'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final consent = session['consent'] as Map<String, dynamic>?;
    final durationSeconds = (session['duration_seconds'] as num?)?.toInt() ?? 0;
    final visitType = (session['visit_type']?.toString() ?? 'opd')
        .toUpperCase();
    final dateLabel = _formatDate(session['counseling_date']);
    final hasVideo = media.any((m) => m['media_type'] == 'video');
    final hasAudio = media.any((m) => m['media_type'] == 'audio');
    final hasSummary = (session['summary_text']?.toString() ?? '').isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  visitType == 'IPD' ? Icons.bed : Icons.record_voice_over,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$dateLabel • $visitType',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _StatusChip(
                  label: consent?['status']?.toString() ?? 'No Consent',
                  tone: consent?['status']?.toString(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (durationSeconds > 0)
                  _InfoChip(
                    icon: Icons.timer_outlined,
                    label: _formatDuration(durationSeconds),
                  ),
                if (hasVideo)
                  const _InfoChip(
                    icon: Icons.videocam_outlined,
                    label: 'Video',
                  ),
                if (hasAudio)
                  const _InfoChip(icon: Icons.mic_none, label: 'Audio'),
                if (hasSummary)
                  const _InfoChip(
                    icon: Icons.auto_awesome,
                    label: 'AI Summary',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: (hasVideo || hasAudio) && recordId.isNotEmpty
                      ? () => context.push(
                          '/counseling/playback/$recordId'
                          '?patientName=${Uri.encodeComponent(patientName)}',
                        )
                      : null,
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: const Text('Playback'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: recordId.isNotEmpty
                      ? () => context.push(
                          '/counseling/playback/$recordId'
                          '?patientName=${Uri.encodeComponent(patientName)}',
                        )
                      : null,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View Details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(Object? value) {
    if (value == null) return 'N/A';
    final date = DateTime.tryParse(value.toString());
    if (date == null) return value.toString();
    return DateFormat('dd MMM yyyy').format(date);
  }

  static String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, this.tone});

  final String label;
  final String? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (tone) {
      'signed' => Colors.green,
      'expired' => theme.colorScheme.error,
      'pending' => Colors.orange,
      _ => theme.colorScheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
