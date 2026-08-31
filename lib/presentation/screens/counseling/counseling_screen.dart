import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/constants/api_constants.dart';
import '../../../services/counseling_recording_service.dart';
import '../../../services/storage_service.dart';
import '../../widgets/smart_navigation.dart';
import 'widgets/consent_management_sheet.dart';

/// Clinical Counseling Recording screen (legal-evidence module).
///
/// Counseling is **visit-specific**: this screen can only be opened from an
/// OPD consultation or an IPD admission. The visit type is auto-detected from
/// [visitType] and every saved session is linked to that exact
/// visit/admission via `opd_registration_id` / `ipd_admission_id`.
///
/// Flow:
///   1. Visit context (OPD/IPD) + patient context (Name / UHID) auto-filled.
///   2. Audio + Video dono ek saath record hote hain (koi alag mode nahi).
///   3. Start dabao: GPS stamp auto-capture hota hai aur consent form
///      auto-generate hota hai.
///   4. Stop ke baad Save dabao — recording + GPS + consent Supabase par
///      secure upload hote hain (`counseling_records`, `counseling_media`,
///      `counseling_consents`) taaki future legal reference ke liye
///      tamper-proof record bana rahe.
class CounselingScreen extends ConsumerStatefulWidget {
  const CounselingScreen({
    super.key,
    required this.patientId,
    required this.visitType,
    this.patientName = '',
    this.uhid = '',
    this.opdRegistrationId,
    this.ipdAdmissionId,
  });

  final String patientId;
  final String patientName;
  final String uhid;

  /// `opd` or `ipd` — auto-detected from the screen that opened counseling.
  final String visitType;

  /// The visit/admission this counseling session belongs to. Exactly one is
  /// expected: [opdRegistrationId] for OPD or [ipdAdmissionId] for IPD.
  final String? opdRegistrationId;
  final String? ipdAdmissionId;

  @override
  ConsumerState<CounselingScreen> createState() => _CounselingScreenState();
}

class _CounselingScreenState extends ConsumerState<CounselingScreen> {
  bool _isSaving = false;

  // Consent form context (hospital + doctor name) resolved lazily.
  String _hospitalName = '';
  String _doctorName = '';

  /// Normalized visit type — auto-detected from the screen that opened this
  /// counseling session. There is deliberately no manual OPD/IPD toggle.
  String get _visitType => widget.visitType == 'ipd' ? 'ipd' : 'opd';

  /// The id of the visit/admission this session is attached to.
  String? get _visitId =>
      _visitType == 'ipd' ? widget.ipdAdmissionId : widget.opdRegistrationId;

  @override
  void initState() {
    super.initState();
    _loadContextNames();
    // Recording hamesha portrait mode mein ho — isliye counseling screen
    // khulte hi orientation portrait par lock kar dete hain. Screen chhodne
    // par (dispose) default orientations wapas restore ho jaati hain.
    _lockPortrait();
  }

  @override
  void dispose() {
    _unlockOrientation();
    super.dispose();
  }

  /// Locks the device to portrait while the counseling recorder is open so the
  /// recorded video comes out in portrait (not landscape) orientation.
  Future<void> _lockPortrait() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } catch (_) {
      // Web/desktop par orientation lock supported nahi — ignore.
    }
  }

  /// Restores all orientations once this screen is closed.
  Future<void> _unlockOrientation() async {
    try {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } catch (_) {
      // Web/desktop par orientation lock supported nahi — ignore.
    }
  }

  /// Resolves the current doctor + hospital display names for the consent form.
  Future<void> _loadContextNames() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final hospitalId = ref.read(currentHospitalIdProvider);

      final doctor = await db.getCurrentUserRecord();
      final doctorName = [
        doctor?['first_name'],
        doctor?['last_name'],
      ].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ').trim();

      var hospitalName = '';
      if (hospitalId != null && hospitalId.isNotEmpty) {
        final hospital = await db.getById(
          ApiConstants.hospitalsTable,
          hospitalId,
        );
        hospitalName = hospital?['name']?.toString() ?? '';
      }

      if (!mounted) return;
      setState(() {
        _doctorName = doctorName;
        _hospitalName = hospitalName;
      });
    } catch (_) {
      // Non-critical — the consent sheet still opens with whatever it has.
    }
  }

  // ---------------------------------------------------------------------------
  // Recording helpers
  // ---------------------------------------------------------------------------

  Future<void> _startMediaRecording(CounselingRecordingService rec) async {
    // Consent form auto-generates the moment a recording starts.
    rec.ensureConsent(
      patientName: widget.patientName.isEmpty ? 'Patient' : widget.patientName,
      uhid: widget.uhid.isEmpty ? 'N/A' : widget.uhid,
      hospitalName: _hospitalName,
      doctorName: _doctorName,
    );

    final ok = await rec.startRecording(rec.mode);
    if (!ok && rec.lastError != null && mounted) {
      _showMessage(rec.lastError!, isError: true);
    }
  }

  Future<void> _openConsentSheet(CounselingRecordingService rec) async {
    await showCounselingConsentSheet(
      context,
      recordingService: rec,
      patientName: widget.patientName.isEmpty ? 'Patient' : widget.patientName,
      uhid: widget.uhid.isEmpty ? 'N/A' : widget.uhid,
      hospitalName: _hospitalName,
      doctorName: _doctorName,
    );
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    final patientId = widget.patientId.trim();
    final visitType = _visitType;
    final visitId = (_visitId ?? '').trim();

    if (patientId.isEmpty) {
      _showMessage('Patient information is missing.', isError: true);
      return;
    }

    if (visitId.isEmpty) {
      _showMessage(
        'Visit context is missing. Open counseling from the '
        '${visitType == 'ipd' ? 'IPD admission' : 'OPD consultation'} screen.',
        isError: true,
      );
      return;
    }

    final rec = ref.read(counselingRecordingServiceProvider);
    if (!rec.hasMedia) {
      _showMessage(
        'Pehle video/audio counseling record karein — bina recording ke '
        'session save nahi ho sakta.',
        isError: true,
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final storage = ref.read(storageServiceProvider);
      final doctorId = await db.getCurrentUsersTableId();
      final hospitalId = ref.read(currentHospitalIdProvider);

      // 1. Save the counseling session record, linked to THIS visit/admission.
      final record = await db.saveCounselingRecord({
        'patient_id': patientId,
        'visit_type': visitType,
        'doctor_id': doctorId,
        if (visitType == 'ipd')
          'ipd_admission_id': visitId
        else
          'opd_registration_id': visitId,
      }, hospitalId: hospitalId);
      final recordId = record['id']?.toString() ?? '';

      // 2. Upload + save video/audio recordings with GPS stamp metadata.
      if (recordId.isNotEmpty) {
        if (rec.hasVideo && rec.videoPath != null) {
          final url = await _uploadMediaFile(
            storage,
            patientId: patientId,
            mediaType: 'video',
            path: rec.videoPath!,
          );
          await db.saveCounselingMedia({
            'counseling_record_id': recordId,
            'patient_id': patientId,
            'media_type': 'video',
            'file_url': url,
            'local_file_path': rec.videoPath,
            'duration_seconds': rec.elapsed.inSeconds,
            'file_size_bytes': await _mediaFileSize(rec.videoPath!),
            'gps_latitude': rec.gps.latitude,
            'gps_longitude': rec.gps.longitude,
            'gps_accuracy': rec.gps.accuracy,
            'gps_address': rec.gps.hasFix ? rec.gps.coordinatesLabel : null,
            'recorded_at': rec.gps.capturedAt?.toUtc().toIso8601String(),
          }, hospitalId: hospitalId);
        }

        if (rec.hasAudio && rec.audioPath != null) {
          final url = await _uploadMediaFile(
            storage,
            patientId: patientId,
            mediaType: 'audio',
            path: rec.audioPath!,
          );
          await db.saveCounselingMedia({
            'counseling_record_id': recordId,
            'patient_id': patientId,
            'media_type': 'audio',
            'file_url': url,
            'local_file_path': rec.audioPath,
            'duration_seconds': rec.elapsed.inSeconds,
            'file_size_bytes': await _mediaFileSize(rec.audioPath!),
            'gps_latitude': rec.gps.latitude,
            'gps_longitude': rec.gps.longitude,
            'gps_accuracy': rec.gps.accuracy,
            'gps_address': rec.gps.hasFix ? rec.gps.coordinatesLabel : null,
            'recorded_at': rec.gps.capturedAt?.toUtc().toIso8601String(),
          }, hospitalId: hospitalId);
        }

        // Session duration for the history list.
        await db.updateCounselingRecord(recordId, {
          'duration_seconds': rec.elapsed.inSeconds,
        }, hospitalId: hospitalId);
      }

      // 3. Save consent (auto-generated + digital signature / signed copy).
      final consentDraft = rec.consent;
      if (consentDraft != null && recordId.isNotEmpty) {
        var signedUrl = consentDraft.signedImageUrl;
        if (consentDraft.signedImagePath != null) {
          signedUrl = await _uploadMediaFile(
            storage,
            patientId: patientId,
            mediaType: 'consent',
            path: consentDraft.signedImagePath!,
          );
        }
        await db.saveCounselingConsent({
          'counseling_record_id': recordId,
          'patient_id': patientId,
          ...consentDraft.toJson(),
          'signed_consent_url': signedUrl,
        }, hospitalId: hospitalId);
      }

      // Clear local recording files once everything is uploaded.
      await rec.clearMedia();

      final visitParams = CounselingVisitParams(
        visitType: visitType,
        visitId: visitId,
      );
      ref.invalidate(counselingRecordsByVisitProvider(visitParams));
      ref.invalidate(counselingSessionHistoryByVisitProvider(visitParams));

      if (!mounted) return;
      _showMessage('Counseling recording saved successfully.');
      context.pop();
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to save counseling record: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Uploads a local recording/consent file to Supabase Storage.
  ///
  /// On web the recorder plugins return blob URLs instead of real file paths,
  /// so bytes are read through [XFile] and uploaded via `uploadBinary`.
  /// Native platforms use the regular file upload path.
  Future<String> _uploadMediaFile(
    StorageService storage, {
    required String patientId,
    required String mediaType,
    required String path,
  }) async {
    if (kIsWeb) {
      final xfile = XFile(path);
      final bytes = await xfile.readAsBytes();
      final extension = mediaType == 'video'
          ? 'mp4'
          : mediaType == 'audio'
          ? 'm4a'
          : 'jpg';
      return storage.uploadBytes(
        path: 'counseling/$patientId/$mediaType',
        bytes: bytes,
        fileName:
            'recording_${DateTime.now().millisecondsSinceEpoch}.$extension',
      );
    }
    return storage.uploadFile(
      path: 'counseling/$patientId/$mediaType',
      file: File(path),
    );
  }

  /// File size in bytes; works for both native paths and web blob URLs.
  Future<int> _mediaFileSize(String path) async {
    try {
      return await XFile(path).length();
    } catch (_) {
      return 0;
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watch the recording service for the whole screen lifetime so the
    // autoDispose provider stays alive until this screen unmounts (the save
    // flow below reads it across async gaps).
    final recService = ref.watch(counselingRecordingServiceProvider);

    return Scaffold(
      appBar: SmartAppBar(
        title: const Text('Record Counseling'),
        actions: [
          IconButton(
            tooltip: 'Session history',
            icon: const Icon(Icons.history),
            onPressed: () {
              final nameParam = Uri.encodeComponent(widget.patientName);
              final visitId = _visitId ?? '';
              context.push(
                '/counseling/history?patientId=${widget.patientId}'
                '&patientName=$nameParam&visitType=$_visitType'
                '&visitId=$visitId',
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildPatientCard(theme),
            const SizedBox(height: 16),
            _buildVisitContextCard(theme),
            const SizedBox(height: 16),
            _buildCameraPreview(recService, theme),
            const SizedBox(height: 12),
            _buildRecordingControls(recService, theme),
            const SizedBox(height: 12),
            _buildGpsCard(recService, theme),
            const SizedBox(height: 12),
            _buildConsentStatusCard(recService, theme),
            const SizedBox(height: 24),
            _buildSaveButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildPatientCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.person,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.patientName.isEmpty ? 'Patient' : widget.patientName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'UHID: ${widget.uhid.isEmpty ? 'N/A' : widget.uhid}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Read-only visit context card. The visit type is auto-detected from the
  /// module that opened this screen — users cannot toggle OPD/IPD here.
  Widget _buildVisitContextCard(ThemeData theme) {
    final isIpd = _visitType == 'ipd';
    final visitId = _visitId ?? '';
    final shortId = visitId.length <= 12
        ? visitId
        : '${visitId.substring(0, 8)}...';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: (isIpd ? Colors.green : Colors.blue).withValues(
                alpha: 0.12,
              ),
              child: Icon(
                isIpd ? Icons.bed_outlined : Icons.local_hospital_outlined,
                color: isIpd ? Colors.green : Colors.blue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isIpd ? 'IPD Admission' : 'OPD Visit',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    visitId.isEmpty
                        ? 'Visit context missing'
                        : 'Sessions will be linked to this '
                              '${isIpd ? 'admission' : 'visit'} '
                              '($shortId)',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.auto_awesome,
              size: 18,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 4),
            Text(
              'AUTO',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview(CounselingRecordingService rec, ThemeData theme) {
    final controller = rec.cameraController;

    if (controller == null || !controller.value.isInitialized) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                rec.isCameraAvailable
                    ? Icons.camera_alt_outlined
                    : Icons.no_photography_outlined,
                size: 40,
                color: rec.isCameraAvailable
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                rec.isCameraAvailable
                    ? 'Tap Start to begin recording'
                    : rec.lastError ??
                          'Camera is not available on this device.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // CameraPreview khud portrait/landscape ke hisaab se rotate hota hai —
    // outer AspectRatio bhi usi ratio ka hona chahiye, warna portrait phone
    // par preview landscape (16:9) mein squeeze ho kar dikhta hai. Plugin ki
    // orientation logic mirror karke ratio nikaalte hain (portrait => 9:16).
    final value = controller.value;
    final applicableOrientation = value.isRecordingVideo
        ? value.recordingOrientation!
        : (value.previewPauseOrientation ??
              value.lockedCaptureOrientation ??
              value.deviceOrientation);
    final isLandscape =
        applicableOrientation == DeviceOrientation.landscapeLeft ||
        applicableOrientation == DeviceOrientation.landscapeRight;
    final previewAspectRatio = isLandscape
        ? controller.value.aspectRatio
        : 1 / controller.value.aspectRatio;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: previewAspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(controller),
            // GPS watermark overlay (live stamp while recording).
            Positioned(
              top: 8,
              left: 8,
              child: _GpsWatermark(text: rec.gps.coordinatesLabel),
            ),
            if (rec.isRecording || rec.isPaused)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    if (rec.isRecording)
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    if (rec.isRecording) const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        rec.elapsedLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingControls(
    CounselingRecordingService rec,
    ThemeData theme,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (rec.isRecording)
                  Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                if (rec.isRecording) const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recording Timer',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  rec.elapsedLabel,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Auto-stop: ${rec.autoStopLimit.inMinutes} min'
              '${rec.isRecording || rec.isPaused ? ' • Remaining ${rec.remaining.inMinutes}:${(rec.remaining.inSeconds % 60).toString().padLeft(2, '0')}' : ''}'
              ' • Size: ${rec.fileSizeLabel}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (rec.isIdle)
                  FilledButton.icon(
                    onPressed: () => _startMediaRecording(rec),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Start Recording'),
                  ),
                if (rec.phase == CounselingRecordingPhase.preparing)
                  FilledButton.icon(
                    onPressed: null,
                    icon: const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    label: const Text('Preparing...'),
                  ),
                if (rec.isRecording)
                  OutlinedButton.icon(
                    onPressed: rec.pause,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                if (rec.isPaused)
                  FilledButton.icon(
                    onPressed: rec.resume,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Resume'),
                  ),
                if (rec.isRecording || rec.isPaused)
                  FilledButton.icon(
                    onPressed: rec.stop,
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                if (rec.isCompleted)
                  FilledButton.tonalIcon(
                    onPressed: rec.clearMedia,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Record Again'),
                  ),
                if (rec.isCameraAvailable && rec.wantsVideo) ...[
                  IconButton.outlined(
                    tooltip: 'Switch camera',
                    onPressed: (rec.isRecording || rec.isPaused)
                        ? null
                        : rec.toggleCamera,
                    icon: const Icon(Icons.cameraswitch_outlined),
                  ),
                  IconButton.outlined(
                    tooltip: rec.isFlashOn ? 'Flash off' : 'Flash on',
                    onPressed: (rec.isRecording || rec.isPaused)
                        ? null
                        : rec.toggleFlash,
                    icon: Icon(
                      rec.isFlashOn ? Icons.flash_on : Icons.flash_off,
                    ),
                  ),
                ],
              ],
            ),
            if (rec.lastError != null && rec.lastError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                rec.lastError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGpsCard(CounselingRecordingService rec, ThemeData theme) {
    final gps = rec.gps;
    final accuracyOk = gps.accuracy != null && gps.accuracy! <= 10;

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
                  color: gps.hasFix
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'GPS Location Stamp',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (gps.hasFix)
                  Icon(
                    accuracyOk
                        ? Icons.check_circle
                        : Icons.warning_amber_rounded,
                    size: 18,
                    color: accuracyOk ? Colors.green : Colors.orange,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!gps.hasFix)
              Text(
                rec.lastError ?? 'GPS will be captured when recording starts.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                gps.coordinatesLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Accuracy: ${gps.accuracyLabel}'
                '${accuracyOk ? ' (within 10 m)' : ' (target < 10 m)'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accuracyOk ? Colors.green : Colors.orange,
                ),
              ),
              if (gps.capturedAt != null)
                Text(
                  'Captured: ${gps.capturedAt!.toLocal().toString().split('.').first}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConsentStatusCard(
    CounselingRecordingService rec,
    ThemeData theme,
  ) {
    final consent = rec.consent;
    final status = consent?.status ?? 'not_generated';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status == 'signed'
                      ? Icons.fact_check
                      : Icons.fact_check_outlined,
                  color: status == 'signed'
                      ? Colors.green
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Consent Form',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _ConsentStatusChip(status: status),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              consent == null
                  ? 'Consent form will be auto-generated when recording starts.'
                  : 'Version ${consent.version}'
                        '${consent.signedAt != null ? ' • Signed ${consent.signedAt!.toLocal().toString().split('.').first}' : ' • Awaiting signature'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _openConsentSheet(rec),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(
                consent == null ? 'Open Consent Form' : 'Manage Consent',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: _isSaving ? null : _save,
        icon: _isSaving
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save),
        label: Text(_isSaving ? 'Saving...' : 'Save Counseling Recording'),
      ),
    );
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

/// Semi-transparent GPS watermark shown over the live camera preview while
/// recording (the co-ordinates are also persisted with the media row).
class _GpsWatermark extends StatelessWidget {
  const _GpsWatermark({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}

class _ConsentStatusChip extends StatelessWidget {
  const _ConsentStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (status) {
      'signed' => (Colors.green, Icons.check_circle),
      'expired' => (theme.colorScheme.error, Icons.timer_off_outlined),
      'pending' => (Colors.orange, Icons.pending_outlined),
      _ => (theme.colorScheme.outline, Icons.help_outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        status == 'not_generated' ? 'NOT GENERATED' : status.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
