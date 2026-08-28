import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';

/// Playback screen for one counseling session.
///
/// Shows the recorded video/audio, GPS stamp, transcript, AI summary and
/// consent status with download + share actions.
class CounselingPlaybackScreen extends ConsumerStatefulWidget {
  const CounselingPlaybackScreen({
    super.key,
    required this.recordId,
    this.patientName = '',
  });

  final String recordId;
  final String patientName;

  @override
  ConsumerState<CounselingPlaybackScreen> createState() =>
      _CounselingPlaybackScreenState();
}

class _CounselingPlaybackScreenState
    extends ConsumerState<CounselingPlaybackScreen> {
  VideoPlayerController? _videoController;
  String? _initializedVideoSource;
  bool _videoInitFailed = false;

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recordAsync = ref.watch(
      counselingRecordByIdProvider(widget.recordId),
    );
    final mediaAsync = ref.watch(
      counselingMediaForRecordProvider(widget.recordId),
    );
    final consentAsync = ref.watch(
      counselingConsentForRecordProvider(widget.recordId),
    );

    return Scaffold(
      appBar: SmartAppBar(title: const Text('Session Playback')),
      body: recordAsync.when(
        data: (record) => mediaAsync.when(
          data: (media) =>
              _buildBody(record, media, consentAsync.valueOrNull, theme),
          error: (error, _) => _ErrorRetry(
            message: 'Failed to load media: $error',
            onRetry: () => ref.invalidate(
              counselingMediaForRecordProvider(widget.recordId),
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => _ErrorRetry(
          message: 'Failed to load record: $error',
          onRetry: () =>
              ref.invalidate(counselingRecordByIdProvider(widget.recordId)),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildBody(
    Map<String, dynamic>? record,
    List<Map<String, dynamic>> media,
    Map<String, dynamic>? consent,
    ThemeData theme,
  ) {
    final videos = media.where((m) => m['media_type'] == 'video').toList();
    final audios = media.where((m) => m['media_type'] == 'audio').toList();
    final transcript = record?['transcript_text']?.toString() ?? '';
    final summary = record?['summary_text']?.toString() ?? '';
    final gps = _firstGps(media);

    _ensureVideoController(videos.isEmpty ? null : videos.first);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // -- patient / session header -----------------------------------------
        Card(
          child: ListTile(
            leading: const Icon(Icons.record_voice_over),
            title: Text(
              widget.patientName.isEmpty
                  ? 'Counseling Session'
                  : widget.patientName,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              [
                if (record?['counseling_date'] != null)
                  'Date: ${record!['counseling_date']}',
                if (record?['visit_type'] != null)
                  'Visit: ${record!['visit_type'].toString().toUpperCase()}',
                if ((record?['duration_seconds'] as num?)?.toInt() != null)
                  'Duration: ${_formatDuration((record!['duration_seconds'] as num).toInt())}',
                if (consent != null)
                  'Consent: ${consent['status'] ?? 'pending'}',
              ].where((s) => s.isNotEmpty).join('  •  '),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // -- video player ------------------------------------------------------
        if (videos.isNotEmpty) ...[
          _buildVideoCard(videos.first, theme),
          const SizedBox(height: 12),
        ],

        // -- audio player(s) ---------------------------------------------------
        for (final audio in audios) ...[
          _AudioPlayerTile(media: audio),
          const SizedBox(height: 12),
        ],

        // -- GPS stamp ----------------------------------------------------------
        _buildGpsCard(gps, theme),
        const SizedBox(height: 12),

        // -- consent ------------------------------------------------------------
        if (consent != null) ...[
          _buildConsentCard(consent, theme),
          const SizedBox(height: 12),
        ],

        // -- transcript ---------------------------------------------------------
        if (transcript.isNotEmpty) ...[
          _SectionCard(
            icon: Icons.article_outlined,
            title: 'Transcript',
            child: Text(transcript, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(height: 12),
        ],

        // -- AI summary ---------------------------------------------------------
        if (summary.isNotEmpty) ...[
          _SectionCard(
            icon: Icons.auto_awesome,
            title: 'AI Summary',
            child: Text(summary, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(height: 12),
        ],

        // -- download / share ----------------------------------------------------
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in media)
              OutlinedButton.icon(
                onPressed: () => _downloadOrOpen(item),
                icon: const Icon(Icons.download, size: 18),
                label: Text('Download ${item['media_type']}'),
              ),
            for (final item in media)
              OutlinedButton.icon(
                onPressed: () => _share(item),
                icon: const Icon(Icons.share, size: 18),
                label: Text('Share ${item['media_type']}'),
              ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Video controller lifecycle
  // ---------------------------------------------------------------------------

  void _ensureVideoController(Map<String, dynamic>? video) {
    if (video == null) return;
    final url = video['file_url']?.toString();
    final localPath = video['local_file_path']?.toString();
    final source = (url != null && url.isNotEmpty) ? url : localPath;

    if (source == null || source.isEmpty || source == _initializedVideoSource) {
      return;
    }

    _initializedVideoSource = source;
    _videoInitFailed = false;
    final old = _videoController;
    _videoController = null;
    old?.dispose();

    final controller = url != null && url.isNotEmpty
        ? VideoPlayerController.networkUrl(Uri.parse(url))
        : VideoPlayerController.file(File(localPath!));
    _videoController = controller;
    controller
        .initialize()
        .then((_) {
          if (!mounted || _videoController != controller) return;
          setState(() {});
        })
        .catchError((Object e) {
          if (!mounted || _videoController != controller) return;
          setState(() => _videoInitFailed = true);
        });
  }

  Widget _buildVideoCard(Map<String, dynamic> video, ThemeData theme) {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              if (_videoInitFailed)
                const Icon(Icons.error_outline, color: Colors.red)
              else
                const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                _videoInitFailed
                    ? 'Video could not be played on this device.'
                    : 'Loading video...',
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  onPressed: () {
                    setState(() {
                      controller.value.isPlaying
                          ? controller.pause()
                          : controller.play();
                    });
                  },
                  icon: Icon(
                    controller.value.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    size: 36,
                  ),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    colors: VideoProgressColors(
                      playedColor: theme.colorScheme.primary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      controller.setVolume(controller.value.volume > 0 ? 0 : 1);
                    });
                  },
                  icon: Icon(
                    controller.value.volume > 0
                        ? Icons.volume_up
                        : Icons.volume_off,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGpsCard(Map<String, dynamic>? gps, ThemeData theme) {
    final hasFix =
        gps != null &&
        gps['gps_latitude'] != null &&
        gps['gps_longitude'] != null;
    final lat = (gps?['gps_latitude'] as num?)?.toDouble();
    final lng = (gps?['gps_longitude'] as num?)?.toDouble();
    final accuracy = (gps?['gps_accuracy'] as num?)?.toDouble();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.location_on_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'GPS Location Stamp',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!hasFix)
              Text(
                'No GPS fix recorded for this session.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                'Latitude: ${lat!.toStringAsFixed(6)}',
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                'Longitude: ${lng!.toStringAsFixed(6)}',
                style: theme.textTheme.bodyMedium,
              ),
              if (accuracy != null)
                Text(
                  'Accuracy: ±${accuracy.toStringAsFixed(1)} m',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://www.google.com/maps?q=$lat,$lng'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Open in Maps'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConsentCard(Map<String, dynamic> consent, ThemeData theme) {
    final status = consent['status']?.toString() ?? 'pending';
    final version = (consent['consent_version'] as num?)?.toInt() ?? 1;
    return Card(
      child: ListTile(
        leading: Icon(
          status == 'signed' ? Icons.fact_check : Icons.fact_check_outlined,
          color: status == 'signed' ? Colors.green : Colors.orange,
        ),
        title: const Text('Consent Form'),
        subtitle: Text(
          'Status: ${status.toUpperCase()}  •  Version: $version'
          '${consent['signed_at'] != null ? '\nSigned: ${consent['signed_at']}' : ''}',
        ),
        trailing: (consent['signed_consent_url']?.toString() ?? '').isNotEmpty
            ? IconButton(
                tooltip: 'Open signed consent',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => launchUrl(
                  Uri.parse(consent['signed_consent_url']!.toString()),
                  mode: LaunchMode.externalApplication,
                ),
              )
            : null,
      ),
    );
  }

  Map<String, dynamic>? _firstGps(List<Map<String, dynamic>> media) {
    for (final m in media) {
      if (m['gps_latitude'] != null && m['gps_longitude'] != null) return m;
    }
    return null;
  }

  Future<void> _downloadOrOpen(Map<String, dynamic> media) async {
    final url = media['file_url']?.toString();
    final localPath = media['local_file_path']?.toString();
    if (url != null && url.isNotEmpty) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else if (localPath != null && localPath.isNotEmpty) {
      await launchUrl(
        Uri.file(localPath),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  Future<void> _share(Map<String, dynamic> media) async {
    final url = media['file_url']?.toString();
    final localPath = media['local_file_path']?.toString();
    try {
      if (localPath != null &&
          localPath.isNotEmpty &&
          File(localPath).existsSync()) {
        await Share.shareXFiles([
          XFile(localPath),
        ], subject: 'Counseling ${media['media_type']} recording');
      } else if (url != null && url.isNotEmpty) {
        await Share.share(url);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  static String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _AudioPlayerTile extends StatefulWidget {
  const _AudioPlayerTile({required this.media});

  final Map<String, dynamic> media;

  @override
  State<_AudioPlayerTile> createState() => _AudioPlayerTileState();
}

class _AudioPlayerTileState extends State<_AudioPlayerTile> {
  AudioPlayer? _player;
  bool _isPlaying = false;
  bool _initFailed = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            _isPlaying ? Icons.graphic_eq : Icons.mic_none,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: const Text('Audio Recording'),
        subtitle: Text(
          _initFailed
              ? 'Audio could not be played on this device.'
              : 'Tap play to listen',
        ),
        trailing: IconButton(
          onPressed: _toggle,
          icon: Icon(
            _isPlaying ? Icons.stop_circle : Icons.play_circle_fill,
            size: 36,
          ),
        ),
      ),
    );
  }

  Future<void> _toggle() async {
    final url = widget.media['file_url']?.toString();
    final localPath = widget.media['local_file_path']?.toString();

    if (_isPlaying) {
      await _player?.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }

    _player ??= AudioPlayer();
    try {
      if (url != null && url.isNotEmpty) {
        await _player!.play(UrlSource(url));
      } else if (localPath != null && localPath.isNotEmpty) {
        await _player!.play(DeviceFileSource(localPath));
      } else {
        return;
      }
      if (mounted) setState(() => _isPlaying = true);
      _player!.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _isPlaying = false);
      });
    } catch (_) {
      if (mounted) setState(() => _initFailed = true);
    }
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
