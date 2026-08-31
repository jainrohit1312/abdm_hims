import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Recording mode selected on the counseling Recording tab.
enum CounselingRecordingMode {
  videoOnly('Video only'),
  audioOnly('Audio only'),
  both('Both');

  const CounselingRecordingMode(this.label);

  final String label;
}

/// Lifecycle of the media recorder.
enum CounselingRecordingPhase { idle, preparing, recording, paused, completed }

/// Auto-generated consent form for the current counseling session.
///
/// Created as soon as a recording starts and kept in memory until the session
/// is saved. The consent sheet can mark it `signed` (digital signature pad or
/// uploaded signed copy) and the save flow persists it into
/// `counseling_consents`.
class CounselingConsentDraft {
  CounselingConsentDraft({
    required this.patientName,
    required this.uhid,
    required this.hospitalName,
    required this.doctorName,
    DateTime? generatedAt,
  }) : generatedAt = generatedAt ?? DateTime.now();

  final String patientName;
  final String uhid;
  final String hospitalName;
  final String doctorName;
  final DateTime generatedAt;

  String status = 'pending'; // pending | signed | expired
  int version = 1;
  DateTime? signedAt;
  Uint8List? signaturePng;
  String? signedImagePath;
  String? signedImageUrl;

  bool get isSigned => status == 'signed';

  Map<String, dynamic> toJson() => {
    'patient_name': patientName,
    'uhid': uhid,
    'hospital_name': hospitalName,
    'doctor_name': doctorName,
    'status': status,
    'consent_version': version,
    'signed_at': signedAt?.toUtc().toIso8601String(),
    'signature_data': signaturePng == null ? null : base64Encode(signaturePng!),
  };
}

/// Controller for the counseling Recording tab.
///
/// Owns:
/// * camera preview + video recording (`camera`)
/// * audio recording (`record`)
/// * recording timer with auto-stop (10 min video / 30 min audio)
/// * live file-size indicator
/// * auto-generated consent draft
///
/// GPS capture is deliberately NOT part of this controller anymore — location
/// fetch was slow on mobile and the video preview now carries a text info
/// stamp (hospital / doctor / patient / complaint) instead.
class CounselingRecordingService extends ChangeNotifier {
  static const Duration videoAutoStop = Duration(minutes: 10);
  static const Duration audioAutoStop = Duration(minutes: 30);

  // -- camera ---------------------------------------------------------------
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];
  CameraLensDirection _lens = CameraLensDirection.back;
  bool _flashOn = false;
  bool _cameraInitialized = false;
  bool _cameraAvailable = false;

  // -- audio ----------------------------------------------------------------
  final AudioRecorder _audioRecorder = AudioRecorder();

  // -- state ----------------------------------------------------------------
  // Counseling ab hamesha Audio + Video dono ek saath record karta hai —
  // isliye default mode `both` hai aur UI se mode selector hata diya gaya hai.
  CounselingRecordingMode mode = CounselingRecordingMode.both;
  CounselingRecordingPhase phase = CounselingRecordingPhase.idle;
  Duration elapsed = Duration.zero;
  int fileSizeBytes = 0;
  String? videoPath;
  String? audioPath;
  String? lastError;
  CounselingConsentDraft? consent;

  Timer? _timer;
  Timer? _sizeTimer;
  DateTime? _segmentStart;
  Duration _accumulated = Duration.zero;
  bool _autoStopping = false;

  // -- getters --------------------------------------------------------------
  bool get isRecording => phase == CounselingRecordingPhase.recording;
  bool get isPaused => phase == CounselingRecordingPhase.paused;
  bool get isIdle => phase == CounselingRecordingPhase.idle;
  bool get isCompleted => phase == CounselingRecordingPhase.completed;
  bool get hasVideo => videoPath != null;
  bool get hasAudio => audioPath != null;
  bool get hasMedia => hasVideo || hasAudio;
  bool get isCameraInitialized => _cameraInitialized;
  bool get isCameraAvailable => _cameraAvailable;
  bool get isFlashOn => _flashOn;
  CameraController? get cameraController => _camera;
  CameraLensDirection get lensDirection => _lens;
  bool get wantsVideo => mode != CounselingRecordingMode.audioOnly;
  bool get wantsAudio => mode != CounselingRecordingMode.videoOnly;

  Duration get autoStopLimit =>
      mode == CounselingRecordingMode.audioOnly ? audioAutoStop : videoAutoStop;

  Duration get remaining => autoStopLimit - elapsed;

  String get elapsedLabel {
    final h = elapsed.inHours.toString().padLeft(2, '0');
    final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get fileSizeLabel {
    if (fileSizeBytes <= 0) return '0 B';
    const kb = 1024;
    const mb = kb * 1024;
    if (fileSizeBytes >= mb) {
      return '${(fileSizeBytes / mb).toStringAsFixed(2)} MB';
    }
    if (fileSizeBytes >= kb) {
      return '${(fileSizeBytes / kb).toStringAsFixed(1)} KB';
    }
    return '$fileSizeBytes B';
  }

  // -------------------------------------------------------------------------
  // Camera helpers
  // -------------------------------------------------------------------------

  /// Changes the recording mode (only allowed while idle) and notifies the UI.
  void selectMode(CounselingRecordingMode newMode) {
    if (!isIdle) return;
    mode = newMode;
    notifyListeners();
  }

  Future<bool> initCamera() async {
    if (_cameraInitialized && _camera != null) return true;
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _cameraAvailable = false;
        notifyListeners();
        return false;
      }

      final selected = _cameras.firstWhere(
        (c) => c.lensDirection == _lens,
        orElse: () => _cameras.first,
      );

      final controller = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: true,
      );
      await controller.initialize();
      _camera = controller;
      _cameraInitialized = true;
      _cameraAvailable = true;
      notifyListeners();
      return true;
    } catch (e) {
      lastError = 'Camera not available: $e';
      _cameraAvailable = false;
      _cameraInitialized = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> toggleCamera() async {
    if (isRecording || isPaused) return; // camera can't be swapped mid-take
    _lens = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final old = _camera;
    _camera = null;
    _cameraInitialized = false;
    await old?.dispose();
    await initCamera();
  }

  Future<void> toggleFlash() async {
    if (isRecording || isPaused) return;
    _flashOn = !_flashOn;
    notifyListeners();
    try {
      await _camera?.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {
      // Torch unsupported on this device — keep the UI in sync anyway.
    }
  }

  // -------------------------------------------------------------------------
  // Consent
  // -------------------------------------------------------------------------

  /// Returns the session consent, creating it on first call (auto-generation
  /// when a recording starts).
  CounselingConsentDraft ensureConsent({
    required String patientName,
    required String uhid,
    required String hospitalName,
    required String doctorName,
  }) {
    consent ??= CounselingConsentDraft(
      patientName: patientName,
      uhid: uhid,
      hospitalName: hospitalName,
      doctorName: doctorName,
    );
    return consent!;
  }

  /// Marks the consent as digitally signed and bumps its version.
  void markConsentSigned({Uint8List? signaturePng, String? signedImagePath}) {
    final draft = consent;
    if (draft == null) return;
    draft.status = 'signed';
    draft.signedAt = DateTime.now();
    draft.version += 1;
    if (signaturePng != null) draft.signaturePng = signaturePng;
    if (signedImagePath != null) draft.signedImagePath = signedImagePath;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Recording lifecycle
  // -------------------------------------------------------------------------

  Future<bool> _ensureMicPermission() async {
    try {
      if (await _audioRecorder.hasPermission()) return true;
      return await _audioRecorder.hasPermission();
    } catch (_) {
      return true; // let the recorder itself surface the real error
    }
  }

  Future<bool> startRecording(CounselingRecordingMode selectedMode) async {
    if (isRecording || phase == CounselingRecordingPhase.preparing) {
      return false;
    }

    mode = selectedMode;
    lastError = null;
    _autoStopping = false;
    phase = CounselingRecordingPhase.preparing;
    notifyListeners();

    // 1. Camera (video modes) — initialise before we touch the recorders so a
    //    failure never leaves an orphaned file behind.
    if (wantsVideo) {
      final ok = await initCamera();
      if (!ok) {
        phase = CounselingRecordingPhase.idle;
        notifyListeners();
        return false;
      }
    }

    // 2. Microphone permission (audio modes + video with sound).
    final micOk = await _ensureMicPermission();
    if (!micOk) {
      lastError = 'Microphone permission denied.';
    }

    // 3. Prepare output files.
    //
    //    Combined (both) mode mein camera video ke saath audio bhi record kar
    //    leta hai (`enableAudio: true`), isliye alag audio file sirf
    //    audio-only mode ke liye banate hain. Isse ek hi combined recording
    //    banti hai — playback par video aur audio alag-alag nahi dikhte.
    //
    //    Web par `path_provider` ka `getTemporaryDirectory` available nahi
    //    hota (MissingPluginException) — browser recorders khud blob URLs
    //    return karte hain, isliye wahan placeholder path set karke aage
    //    badhte hain aur `stop()` par actual blob URL assign hota hai.
    try {
      if (kIsWeb) {
        videoPath = wantsVideo ? 'web_video' : null;
        audioPath = (wantsAudio && !wantsVideo) ? 'web_audio' : null;
      } else {
        final dir = await getTemporaryDirectory();
        final stamp = DateTime.now().millisecondsSinceEpoch;
        videoPath = wantsVideo
            ? '${dir.path}${Platform.pathSeparator}counseling_video_$stamp.mp4'
            : null;
        audioPath = (wantsAudio && !wantsVideo)
            ? '${dir.path}${Platform.pathSeparator}counseling_audio_$stamp.m4a'
            : null;
      }
    } catch (e) {
      phase = CounselingRecordingPhase.idle;
      lastError = 'Could not prepare recording files: $e';
      notifyListeners();
      return false;
    }

    // 4. Start both recorders.
    try {
      if (videoPath != null && _camera != null) {
        await _camera!.startVideoRecording();
      }
      if (audioPath != null) {
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: audioPath!,
        );
      }
    } catch (e) {
      // Roll back anything that may have started.
      try {
        if (videoPath != null &&
            _camera != null &&
            _camera!.value.isRecordingVideo) {
          await _camera!.stopVideoRecording();
        }
      } catch (_) {}
      try {
        if (audioPath != null) await _audioRecorder.cancel();
      } catch (_) {}
      phase = CounselingRecordingPhase.idle;
      lastError = 'Could not start recording: $e';
      notifyListeners();
      return false;
    }

    _accumulated = Duration.zero;
    _segmentStart = DateTime.now();
    phase = CounselingRecordingPhase.recording;
    _startTimer();
    notifyListeners();
    return true;
  }

  Future<void> pause() async {
    if (!isRecording) return;
    try {
      if (videoPath != null && _camera != null) {
        await _camera!.pauseVideoRecording();
      }
      if (audioPath != null) {
        await _audioRecorder.pause();
      }
    } catch (_) {
      // Best-effort pause — keep going.
    }
    _stopTimer();
    _accumulated = elapsed;
    phase = CounselingRecordingPhase.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (!isPaused) return;
    try {
      if (videoPath != null && _camera != null) {
        await _camera!.resumeVideoRecording();
      }
      if (audioPath != null) {
        await _audioRecorder.resume();
      }
    } catch (_) {
      // Best-effort resume.
    }
    _segmentStart = DateTime.now();
    phase = CounselingRecordingPhase.recording;
    _startTimer();
    notifyListeners();
  }

  Future<void> stop() async {
    if (!isRecording && !isPaused) return;
    if (isRecording) {
      _stopTimer();
      _accumulated = elapsed;
    }

    try {
      if (videoPath != null &&
          _camera != null &&
          _camera!.value.isRecordingVideo) {
        // Camera plugin actual recorded file khud decide karta hai (native
        // temp path ya web blob URL) — wahi use karna hota hai, isliye
        // return hone wala XFile path assign karte hain.
        final file = await _camera!.stopVideoRecording();
        videoPath = file.path;
      }
    } catch (e) {
      lastError = 'Video stop error: $e';
    }

    try {
      if (audioPath != null) {
        final path = await _audioRecorder.stop();
        // Web par recorder blob URL return karta hai (path pre-set nahi tha
        // actual file), native par yahi wahi path hai jo start mein diya tha.
        audioPath = kIsWeb ? path : (path ?? audioPath);
      }
    } catch (e) {
      lastError = 'Audio stop error: $e';
    }

    await _refreshFileSize();
    phase = CounselingRecordingPhase.completed;
    notifyListeners();
  }

  /// Clears recorded files after a successful save (consent is kept until the
  /// screen is disposed). On web the plugins return blob URLs that don't need
  /// to be deleted from the file system.
  Future<void> clearMedia() async {
    _stopTimer();
    if (!kIsWeb) {
      try {
        if (videoPath != null) {
          final f = File(videoPath!);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
      try {
        if (audioPath != null) {
          final f = File(audioPath!);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
    }
    videoPath = null;
    audioPath = null;
    fileSizeBytes = 0;
    elapsed = Duration.zero;
    _accumulated = Duration.zero;
    _autoStopping = false;
    phase = CounselingRecordingPhase.idle;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Timer + file size
  // -------------------------------------------------------------------------

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _sizeTimer?.cancel();
    _sizeTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshFileSize(),
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _sizeTimer?.cancel();
    _sizeTimer = null;
  }

  void _onTick() {
    final start = _segmentStart;
    if (start == null) return;
    elapsed = _accumulated + DateTime.now().difference(start);
    notifyListeners();

    if (!_autoStopping && elapsed >= autoStopLimit) {
      _autoStopping = true;
      // Fire-and-forget: stop() notifies listeners itself.
      unawaited(stop());
    }
  }

  Future<void> _refreshFileSize() async {
    if (kIsWeb) return; // web recorders expose blob URLs, not File paths
    var total = 0;
    for (final path in [videoPath, audioPath]) {
      if (path == null) continue;
      try {
        final file = File(path);
        if (await file.exists()) total += await file.length();
      } catch (_) {}
    }
    fileSizeBytes = total;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTimer();
    _camera?.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }
}
