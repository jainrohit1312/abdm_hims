import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';

/// Inline counseling history for ONE OPD visit / IPD admission.
///
/// Shows every counseling session stacked under the same visit
/// (newest first) plus a "New Session" button. Used inside the OPD
/// consultation and IPD patient dashboard screens so counseling stays
/// visit-specific and never needs a patient-profile entry point.
class CounselingVisitHistoryList extends ConsumerWidget {
  const CounselingVisitHistoryList({
    super.key,
    required this.visitType,
    required this.visitId,
    this.patientId = '',
    this.patientName = '',
    this.uhid = '',
    this.onNewSession,
  });

  /// `opd` or `ipd`.
  final String visitType;

  /// `opd_registrations.id` / `ipd_admissions.id`.
  final String visitId;

  final String patientId;
  final String patientName;
  final String uhid;

  /// Optional custom action for "New Session" (e.g. OPD screen passes its own
  /// callback so it can include the UHID). When null, a default route push is
  /// built from [visitType] / [visitId] / [patientId] / [patientName].
  final VoidCallback? onNewSession;

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: onNewSession ?? _defaultNewSession(context),
            icon: const Icon(Icons.add),
            label: const Text('New Session'),
          ),
        ),
        const SizedBox(height: 8),
        historyAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Failed to load counseling sessions: $error',
              textAlign: TextAlign.center,
            ),
          ),
          data: (sessions) {
            if (sessions.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(
                      Icons.record_voice_over_outlined,
                      size: 44,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No counseling sessions for this '
                      '${visitType == 'ipd' ? 'admission' : 'visit'} yet.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                for (var i = 0; i < sessions.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _SessionCard(
                    session: sessions[i],
                    patientName: patientName,
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  VoidCallback _defaultNewSession(BuildContext context) {
    return () {
      final nameParam = Uri.encodeComponent(patientName);
      final uhidParam = Uri.encodeComponent(uhid);
      final visitKey = visitType == 'ipd'
          ? 'ipdAdmissionId'
          : 'opdRegistrationId';
      context.push(
        '/counseling?patientId=$patientId'
        '&patientName=$nameParam&uhid=$uhidParam&visitType=$visitType'
        '&$visitKey=$visitId',
      );
    };
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.patientName});

  final Map<String, dynamic> session;
  final String patientName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recordId = session['id']?.toString() ?? '';
    final media = (session['media'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final consent = session['consent'] as Map<String, dynamic>?;
    final durationSeconds = (session['duration_seconds'] as num?)?.toInt() ?? 0;
    final hasVideo = media.any((m) => m['media_type'] == 'video');
    final hasAudio = media.any((m) => m['media_type'] == 'audio');
    final hasSummary = (session['summary_text']?.toString() ?? '').isNotEmpty;
    final dateLabel = _formatDate(session['counseling_date']);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.record_voice_over,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dateLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _StatusChip(
                  label: consent?['status']?.toString() ?? 'no_consent',
                ),
              ],
            ),
            const SizedBox(height: 6),
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
                  const _InfoChip(icon: Icons.videocam_outlined, label: 'Video'),
                if (hasAudio)
                  const _InfoChip(icon: Icons.mic_none, label: 'Audio'),
                if (hasSummary)
                  const _InfoChip(icon: Icons.auto_awesome, label: 'Summary'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: (hasVideo || hasAudio) && recordId.isNotEmpty
                      ? () => _openPlayback(context, recordId)
                      : null,
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: const Text('Playback'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: recordId.isNotEmpty
                      ? () => _openPlayback(context, recordId)
                      : null,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('Details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openPlayback(BuildContext context, String recordId) {
    context.push(
      '/counseling/playback/$recordId'
      '?patientName=${Uri.encodeComponent(patientName)}',
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
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (label) {
      'signed' => Colors.green,
      'expired' => theme.colorScheme.error,
      'pending' => Colors.orange,
      _ => theme.colorScheme.outline,
    };
    final display = label == 'no_consent' ? 'NO CONSENT' : label.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        display,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
