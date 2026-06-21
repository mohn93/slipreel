import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../services/save_directory.dart';
import 'cursor_checkpointer.dart';
import 'permissions_controller.dart';
import 'session_marker.dart';
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/utils/app_logger.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';
import 'package:slipreel_engine/video_encoder.dart';

enum RecordingStatus { idle, recording, paused, processing, completed, error }

class RecordingState {
  final RecordingStatus status;
  final int frameCount;
  final Duration duration;
  final String? videoPath;
  final String? error;
  final String? selectedSourceId;
  final RecordingSource? selectedSourceKind;
  final RegionSelection? selectedRegion;

  const RecordingState({
    this.status = RecordingStatus.idle,
    this.frameCount = 0,
    this.duration = Duration.zero,
    this.videoPath,
    this.error,
    this.selectedSourceId,
    this.selectedSourceKind,
    this.selectedRegion,
  });

  RecordingState copyWith({
    RecordingStatus? status,
    int? frameCount,
    Duration? duration,
    String? videoPath,
    String? error,
    String? selectedSourceId,
    RecordingSource? selectedSourceKind,
    RegionSelection? selectedRegion,
    bool clearSelection = false,
  }) {
    return RecordingState(
      status: status ?? this.status,
      frameCount: frameCount ?? this.frameCount,
      duration: duration ?? this.duration,
      videoPath: videoPath ?? this.videoPath,
      error: error,
      selectedSourceId:
          clearSelection ? null : (selectedSourceId ?? this.selectedSourceId),
      selectedSourceKind: clearSelection
          ? null
          : (selectedSourceKind ?? this.selectedSourceKind),
      selectedRegion:
          clearSelection ? null : (selectedRegion ?? this.selectedRegion),
    );
  }

  bool get isRecording =>
      status == RecordingStatus.recording || status == RecordingStatus.paused;
  bool get isProcessing => status == RecordingStatus.processing;
  // [error] is recoverable — the next `startRecording` call clears
  // `error` and resets `status` to `recording`. Excluding error here
  // would soft-lock the Record button after any failed attempt.
  bool get canStartRecording =>
      status == RecordingStatus.idle ||
      status == RecordingStatus.completed ||
      status == RecordingStatus.error;
}

class RecordingController extends StateNotifier<RecordingState> {
  RecordingController({
    RecordingHistoryStore? historyStore,
    SessionMarkerStore? sessionMarkerStore,
  })  : _historyStore = historyStore ?? RecordingHistoryStore(),
        _sessionMarkerStore = sessionMarkerStore,
        super(const RecordingState());

  @visibleForTesting
  set state(RecordingState value) => super.state = value;

  /// Whether a native capture session is currently live. Test hook for the
  /// error-path reset invariant (see _handleError).
  @visibleForTesting
  bool get isEncoderActive => _videoEncoder.isActive;

  final VideoEncoder _videoEncoder = VideoEncoder();
  final RecordingHistoryStore _historyStore;
  final SessionMarkerStore? _sessionMarkerStore;
  CursorCheckpointer? _cursorCheckpointer;
  String? _activeMarkerId;
  String? _activeNdjsonPath;
  StreamSubscription<CursorPosition>? _cursorSubscription;
  CursorRecording? _cursorRecording;
  StreamSubscription<KeystrokeEvent>? _keystrokeSubscription;
  KeystrokeRecording? _keystrokeRecording;
  StreamSubscription<String>? _recordingErrorSubscription;
  CameraConfig? _activeCameraConfig;
  Timer? _durationTimer;
  DateTime? _startTime;

  static const int _defaultFps = 60;
  static const int _defaultWidth = 1920;
  static const int _defaultHeight = 1080;

  void selectSource({
    required RecordingSource? kind,
    required String? id,
    RegionSelection? region,
  }) {
    if (kind == null && id == null) {
      state = state.copyWith(clearSelection: true);
      return;
    }
    state = state.copyWith(
      selectedSourceId: id,
      selectedSourceKind: kind,
      selectedRegion: region,
    );
  }

  Future<void> startRecording({
    MicrophoneConfig? microphone,
    SystemAudioConfig? systemAudio,
    CameraConfig? camera,
    PermissionsSnapshot? permissions,
    Future<void> Function(PermissionKind kind)? onDenied,
    String? defaultSaveLocation,
  }) async {
    if (!state.canStartRecording ||
        state.selectedSourceId == null ||
        state.selectedSourceKind == null) return;

    // Defense-in-depth: a prior recording whose stop failed could leave the
    // encoder active even though status==error is start-eligible. Never stack
    // a second native session on top of it. (_handleError already reaps it, so
    // this should not normally fire.)
    if (_videoEncoder.isActive) {
      AppLogger.recording
          .w('startRecording ignored: a capture session is still active');
      return;
    }

    // Permission gate: if the caller passed a snapshot AND a `onDenied`
    // callback, short-circuit when Screen Recording isn't granted.
    // (Both nullable so existing tests that don't care about permissions
    // still work — non-passing callers just get the old behavior.)
    if (permissions != null &&
        permissions.screenRec != PermissionStatus.granted &&
        permissions.screenRec != PermissionStatus.unsupported) {
      await onDenied?.call(PermissionKind.screenRecording);
      return;
    }

    if (microphone != null &&
        permissions != null &&
        permissions.microphone != PermissionStatus.granted &&
        permissions.microphone != PermissionStatus.unsupported) {
      await onDenied?.call(PermissionKind.microphone);
      return;
    }

    if (camera != null &&
        permissions != null &&
        permissions.camera != PermissionStatus.granted &&
        permissions.camera != PermissionStatus.unsupported) {
      await onDenied?.call(PermissionKind.camera);
      return;
    }

    try {
      _activeCameraConfig = camera;
      state = state.copyWith(
        status: RecordingStatus.recording,
        frameCount: 0,
        duration: Duration.zero,
        videoPath: null,
        error: null,
      );

      final docsDir = await getApplicationDocumentsDirectory();
      final saveDir = resolveSaveDirectory(
        defaultSaveLocation: defaultSaveLocation,
        documentsPath: docsDir.path,
      );
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '$saveDir/recording_$ts.mp4';

      final markerId = '$ts';
      final ndjsonPath = '$outputPath.cursor.ndjson';

      _cursorCheckpointer = CursorCheckpointer(ndjsonPath: ndjsonPath);
      try {
        await _cursorCheckpointer!.start();
      } catch (e, st) {
        AppLogger.recording.w('Cursor checkpointer start failed; cursor recovery disabled',
            error: e, stackTrace: st);
        _cursorCheckpointer = null;
      }

      final settings = RecordingSettings(
        source: state.selectedSourceKind!,
        sourceId: state.selectedSourceId,
        frameRate: _defaultFps,
        microphone: microphone,
        systemAudio: systemAudio,
        camera: camera,
        captureCursor: true,
      );

      await _videoEncoder.start(
        settings: settings,
        outputPath: outputPath,
        width: _defaultWidth,
        height: _defaultHeight,
        region: state.selectedRegion,
      );

      if (_sessionMarkerStore != null) {
        try {
          await _sessionMarkerStore.add(SessionMarker(
            id: markerId,
            videoPath: outputPath,
            cursorNdjsonPath: ndjsonPath,
            startedAt: DateTime.now().toUtc(),
            width: _videoEncoder.width,
            height: _videoEncoder.height,
            fps: _videoEncoder.fps,
          ));
          _activeMarkerId = markerId;
          _activeNdjsonPath = ndjsonPath;
        } catch (e, st) {
          AppLogger.recording.w('Failed to write session marker; recording proceeds',
              error: e, stackTrace: st);
        }
      }

      _cursorRecording = CursorRecording();
      _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
        (pos) {
          _cursorRecording?.addPosition(pos);
          _cursorCheckpointer?.add(pos);
        },
        onError: (e) => AppLogger.recording.w('Cursor stream error', error: e),
      );

      _keystrokeRecording = KeystrokeRecording();
      _keystrokeSubscription =
          ScreenRecorderPlatform.instance.keystrokeStream.listen(
        (e) => _keystrokeRecording?.addEvent(e),
        onError: (e) => AppLogger.recording.w('Keystroke stream error', error: e),
      );

      // Native capture can fail mid-recording (display unplugged, permission
      // revoked, GPU reset). The native side reports it here; we run the same
      // error path as any other failure so the UI leaves "recording" and
      // surfaces the problem instead of silently freezing.
      _recordingErrorSubscription =
          ScreenRecorderPlatform.instance.recordingErrorStream.listen(
        (message) {
          if (state.isRecording) _handleError(message);
        },
        onError: (e) =>
            AppLogger.recording.w('recordingError stream error', error: e),
      );

      _startTime = DateTime.now();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_startTime != null) {
          state = state.copyWith(duration: DateTime.now().difference(_startTime!));
        }
      });
    } catch (e) {
      _handleError('Failed to start recording: $e');
    }
  }

  /// Start recording an external device (iPhone/iPad over USB).
  ///
  /// Mirrors [startRecording]'s path-resolution and state transitions but
  /// targets [ScreenRecorderPlatform.startDeviceRecording]. A touch device has
  /// no host-side cursor/keystroke input to track, so this path does NOT start
  /// the cursor checkpointer or subscribe to the cursor/keystroke streams; the
  /// stop/finalize path consequently writes only the metadata sidecar (the
  /// cursor/keystroke sidecar blocks are skipped because their recordings stay
  /// null).
  Future<void> startDeviceRecording({
    required String deviceId,
    required bool captureDeviceAudio,
    MicrophoneConfig? microphone,
    PermissionsSnapshot? permissions,
    Future<void> Function(PermissionKind kind)? onDenied,
    String? defaultSaveLocation,
  }) async {
    if (!state.canStartRecording) return;

    // Defense-in-depth: never stack a second native session on top of a live
    // one (mirrors startRecording).
    if (_videoEncoder.isActive) {
      AppLogger.recording
          .w('startDeviceRecording ignored: a capture session is still active');
      return;
    }

    // Permission gate (mirrors startRecording). An iOS capture device is a
    // VIDEO AVCaptureDevice, so CAMERA permission is REQUIRED: short-circuit if
    // the caller passed a snapshot and camera isn't granted. (Both params are
    // nullable so existing tests that don't care about permissions still work.)
    if (permissions != null &&
        permissions.camera != PermissionStatus.granted &&
        permissions.camera != PermissionStatus.unsupported) {
      await onDenied?.call(PermissionKind.camera);
      return;
    }

    // Mic narration is OPTIONAL: only keep mic if it's granted (or ungated).
    // A mic-denied device recording proceeds WITHOUT mic instead of aborting,
    // mirroring the screen path's mic gate.
    var micConfig = microphone;
    if (micConfig != null &&
        permissions != null &&
        permissions.microphone != PermissionStatus.granted &&
        permissions.microphone != PermissionStatus.unsupported) {
      micConfig = null;
    }

    try {
      // Flip to RecordingStatus.recording BEFORE the native start awaits below.
      // This is the SAME status transition startRecording performs, and it is
      // what drives the recording-indicator UI: the bar screen listens to
      // RecordingState and morphs the window to the RecordingPill (with a Stop
      // button) whenever status becomes `recording`/`processing`
      // (see recording_bar_screen.dart). Keeping this identical to the screen
      // path guarantees a device recording shows the same pill + Stop affordance
      // instead of leaving the user with no visible recording UI. Do NOT move
      // this after the native await, or the pill won't appear until (and unless)
      // the native side returns.
      state = state.copyWith(
        status: RecordingStatus.recording,
        selectedSourceKind: RecordingSource.device,
        selectedSourceId: deviceId,
        frameCount: 0,
        duration: Duration.zero,
        videoPath: null,
        error: null,
      );

      final docsDir = await getApplicationDocumentsDirectory();
      final saveDir = resolveSaveDirectory(
        defaultSaveLocation: defaultSaveLocation,
        documentsPath: docsDir.path,
      );
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '$saveDir/recording_$ts.mp4';

      await _videoEncoder.startDevice(
        deviceId: deviceId,
        captureDeviceAudio: captureDeviceAudio,
        captureMic: micConfig != null,
        outputPath: outputPath,
      );

      // No cursor/keystroke tracking for touch devices — intentionally skip the
      // checkpointer + cursor/keystroke stream subscriptions. We still listen
      // for fatal native errors so the UI leaves "recording" on failure.
      _recordingErrorSubscription =
          ScreenRecorderPlatform.instance.recordingErrorStream.listen(
        (message) {
          if (state.isRecording) _handleError(message);
        },
        onError: (e) =>
            AppLogger.recording.w('recordingError stream error', error: e),
      );

      _startTime = DateTime.now();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_startTime != null) {
          state =
              state.copyWith(duration: DateTime.now().difference(_startTime!));
        }
      });
    } catch (e) {
      _handleError('Failed to start device recording: $e');
    }
  }

  Future<void> stopRecording() async {
    if (!state.isRecording) return;
    try {
      state = state.copyWith(status: RecordingStatus.processing);

      _durationTimer?.cancel();
      _durationTimer = null;
      final duration = _startTime != null
          ? DateTime.now().difference(_startTime!)
          : Duration.zero;
      _startTime = null;

      await _cursorSubscription?.cancel();
      _cursorSubscription = null;
      await _keystrokeSubscription?.cancel();
      _keystrokeSubscription = null;
      await _recordingErrorSubscription?.cancel();
      _recordingErrorSubscription = null;

      final result = await _videoEncoder.stop();

      // Device (iPhone/iPad) recordings have no host-side cursor/keystroke
      // input to capture, so the cursor/keystroke recordings stay null and the
      // sidecars are never written. The explicit guard documents the contract
      // (and skips the work even if a future change pre-allocates them).
      final isDevice = state.selectedSourceKind == RecordingSource.device;

      // Save cursor sidecar (next to MP4).
      if (!isDevice && _cursorRecording != null && _cursorRecording!.count > 0) {
        await _cursorRecording!.saveToFile('${result.outputPath}.cursor.json');
        AppLogger.recording.i('Cursor data saved: ${_cursorRecording!.count} positions');
      }
      _cursorRecording = null;

      // Save keystroke sidecar.
      if (!isDevice &&
          _keystrokeRecording != null &&
          _keystrokeRecording!.count > 0) {
        await _keystrokeRecording!
            .saveToFile('${result.outputPath}.keystrokes.json');
        AppLogger.recording.i(
            'Keystroke data saved: ${_keystrokeRecording!.count} events');
      }
      _keystrokeRecording = null;

      // Save camera metadata sidecar when the native side recorded a camera.
      if (result.hasCamera) {
        final camMeta = CameraSidecarMeta(
          deviceLabel: _activeCameraConfig?.deviceLabel ?? 'Camera',
          width: result.cameraWidth,
          height: result.cameraHeight,
          frameCount: result.cameraFrameCount,
          offsetMicros: result.cameraOffsetMicros,
          selfViewX: result.cameraSelfViewX,
          selfViewY: result.cameraSelfViewY,
        );
        await camMeta.saveForVideo(result.outputPath);
        AppLogger.recording.i('Camera sidecar saved: ${result.cameraFrameCount} frames');
      }
      _activeCameraConfig = null;

      // Save recording metadata sidecar.
      // The recorder is configured with showsCursor=false, so the MP4 frames
      // contain no cursor pixels. The editor renders a synthetic cursor on
      // top from the .cursor.json track when isPureSource=true, which lets
      // the inspector's "Hide cursor" toggle actually hide it.
      //
      // Prefer the actual capture dimensions returned by the native side.
      // _videoEncoder.width/height is what Dart *requested* (a hint that the
      // native side may override based on the actual window/display pixel size).
      // The fallback keeps Windows/Linux working (they don't yet return actual
      // dimensions in their stop response).
      final actualWidth = result.width > 0 ? result.width : _videoEncoder.width;
      final actualHeight =
          result.height > 0 ? result.height : _videoEncoder.height;
      final meta = RecordingMetadata(
        isPureSource: true,
        duration: duration,
        recordedAt: DateTime.now(),
        widthPx: actualWidth,
        heightPx: actualHeight,
        fps: _videoEncoder.fps,
      );
      await meta.saveForVideo(result.outputPath);

      // Append to the persisted recording history so the user can find
      // this video again later from the Recents screen. Failures here are
      // non-fatal — never block a successful recording on a prefs write.
      try {
        await _historyStore.append(RecordingHistoryEntry(
          videoPath: result.outputPath,
          recordedAt: meta.recordedAt,
          widthPx: actualWidth,
          heightPx: actualHeight,
          fps: _videoEncoder.fps,
        ));
      } catch (e) {
        AppLogger.recording.w('Failed to append to recording history: $e');
      }

      try {
        await _cursorCheckpointer?.stop();
        _cursorCheckpointer = null;
        if (_activeNdjsonPath != null && await File(_activeNdjsonPath!).exists()) {
          await File(_activeNdjsonPath!).delete();
        }
      } catch (e, st) {
        AppLogger.recording.w('CursorCheckpointer stop/cleanup failed',
            error: e, stackTrace: st);
      }
      _activeNdjsonPath = null;
      if (_activeMarkerId != null && _sessionMarkerStore != null) {
        try {
          await _sessionMarkerStore.remove(_activeMarkerId!);
        } catch (e, st) {
          AppLogger.recording.w('SessionMarker remove failed',
              error: e, stackTrace: st);
        }
        _activeMarkerId = null;
      }

      // Build and log the perf summary.
      final fileSize = await File(result.outputPath).length();
      final expectedFrames =
          (duration.inMilliseconds * _videoEncoder.fps / 1000).round();
      // The native encoder doesn't emit a precise count yet; until it does,
      // use expected frames (minus drops) as the actual count for verdict
      // purposes. fpsOk effectively becomes a "duration matches expected"
      // check, which is good enough for the PASS/FAIL gate.
      final summary = RecordingPerfSummary(
        durationSeconds: duration.inMilliseconds / 1000.0,
        frameCount: expectedFrames - result.perfStats.droppedFrames,
        expectedFrameCount: expectedFrames,
        droppedFrameCount: result.perfStats.droppedFrames,
        cpuPctAvg: result.perfStats.cpuPctAvg,
        cpuPctP95: result.perfStats.cpuPctP95,
        memPeakBytes: result.perfStats.memBytesPeak,
        outputBytes: fileSize,
        targetFps: _videoEncoder.fps,
      );
      AppLogger.recording.i(summary.format());

      state = state.copyWith(
        status: RecordingStatus.completed,
        videoPath: result.outputPath,
        duration: duration,
      );
    } catch (e) {
      _handleError('Failed to stop recording: $e');
    }
  }

  // m1: pause/resume must reach the native side in the order they were
  // requested. Chaining each transition onto the previous one serializes the
  // platform calls so a quick resume can't overtake a still-running pause. The
  // status flip happens *after* the platform await so observers never see a
  // state the native side hasn't reached yet.
  Future<void> _transition = Future<void>.value();

  Future<void> _enqueueTransition(Future<void> Function() op) {
    final result = _transition.then((_) => op());
    // Keep the chain alive even if this op throws; the caller still sees the
    // real error via `result`.
    _transition = result.catchError((_) {});
    return result;
  }

  Future<void> pauseRecording() => _enqueueTransition(() async {
        if (state.status != RecordingStatus.recording) return;
        _durationTimer?.cancel();
        _durationTimer = null;
        // Capture elapsed-so-far (before the platform await) so resume can
        // restart from exactly where the user paused.
        final elapsed = _startTime != null
            ? DateTime.now().difference(_startTime!)
            : state.duration;
        _startTime = null;
        await ScreenRecorderPlatform.instance.pauseRecording();
        state =
            state.copyWith(status: RecordingStatus.paused, duration: elapsed);
      });

  Future<void> resumeRecording() => _enqueueTransition(() async {
        if (state.status != RecordingStatus.paused) return;
        await ScreenRecorderPlatform.instance.resumeRecording();
        // Re-anchor _startTime to "now minus elapsed" so the periodic timer
        // continues to fire correct durations from where we paused.
        _startTime = DateTime.now().subtract(state.duration);
        _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_startTime != null) {
            state =
                state.copyWith(duration: DateTime.now().difference(_startTime!));
          }
        });
        state = state.copyWith(status: RecordingStatus.recording);
      });

  void _handleError(String message) {
    // Reap any live native capture so a failed/partial session can't keep
    // running (and so the next startRecording isn't blocked / doesn't
    // double-record). forceReset clears isActive synchronously and stops the
    // native side best-effort; fire-and-forget keeps _handleError synchronous.
    if (_videoEncoder.isActive) {
      _videoEncoder.forceReset().ignore();
    }
    if (_activeMarkerId != null && _sessionMarkerStore != null) {
      _sessionMarkerStore.remove(_activeMarkerId!).ignore();
      _activeMarkerId = null;
    }
    _cursorCheckpointer?.stop().ignore();
    _cursorCheckpointer = null;
    _activeNdjsonPath = null;
    state = state.copyWith(status: RecordingStatus.error, error: message);
    _cursorSubscription?.cancel();
    _cursorSubscription = null;
    _keystrokeSubscription?.cancel();
    _keystrokeSubscription = null;
    _recordingErrorSubscription?.cancel();
    _recordingErrorSubscription = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _startTime = null;
    _cursorRecording = null;
    _keystrokeRecording = null;
    _activeCameraConfig = null;
  }

  void reset() {
    // m2: never abandon a live native capture. Reap it best-effort (same
    // discipline as _handleError) before clearing back to a pristine state.
    _reapActiveCapture();
    state = const RecordingState();
  }

  /// Best-effort, synchronous teardown of any live native capture. Mirrors
  /// _handleError's reaping so reset()/dispose() can't leak the session.
  void _reapActiveCapture() {
    if (_videoEncoder.isActive) {
      _videoEncoder.forceReset().ignore();
    }
    _cursorCheckpointer?.stop().ignore();
    _cursorCheckpointer = null;
    if (_activeMarkerId != null && _sessionMarkerStore != null) {
      _sessionMarkerStore.remove(_activeMarkerId!).ignore();
      _activeMarkerId = null;
    }
    _activeNdjsonPath = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _startTime = null;
  }

  @override
  void dispose() {
    // m2: a controller disposed mid-recording must reap the native session,
    // otherwise capture keeps running with no owner.
    _reapActiveCapture();
    _cursorSubscription?.cancel();
    _keystrokeSubscription?.cancel();
    _recordingErrorSubscription?.cancel();
    super.dispose();
  }
}

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>(
        (ref) => RecordingController());

final formattedDurationProvider = Provider<String>((ref) {
  final d = ref.watch(recordingControllerProvider.select((s) => s.duration));
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
});

final fpsProvider = Provider<double>((ref) {
  final s = ref.watch(recordingControllerProvider);
  if (s.frameCount == 0 || s.duration.inSeconds == 0) return 0;
  return s.frameCount / s.duration.inSeconds;
});
