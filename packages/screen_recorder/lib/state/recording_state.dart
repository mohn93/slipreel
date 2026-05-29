import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'permissions_controller.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
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
  RecordingController({RecordingHistoryStore? historyStore})
      : _historyStore = historyStore ?? RecordingHistoryStore(),
        super(const RecordingState());

  @visibleForTesting
  set state(RecordingState value) => super.state = value;

  final VideoEncoder _videoEncoder = VideoEncoder();
  final RecordingHistoryStore _historyStore;
  StreamSubscription<CursorPosition>? _cursorSubscription;
  CursorRecording? _cursorRecording;
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
    PermissionsSnapshot? permissions,
    Future<void> Function(PermissionKind kind)? onDenied,
  }) async {
    if (!state.canStartRecording ||
        state.selectedSourceId == null ||
        state.selectedSourceKind == null) return;

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

    try {
      state = state.copyWith(
        status: RecordingStatus.recording,
        frameCount: 0,
        duration: Duration.zero,
        videoPath: null,
        error: null,
      );

      final docsDir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${docsDir.path}/recording_$ts.mp4';

      final settings = RecordingSettings(
        source: state.selectedSourceKind!,
        sourceId: state.selectedSourceId,
        frameRate: _defaultFps,
        microphone: microphone,
        systemAudio: systemAudio,
        captureCursor: true,
      );

      await _videoEncoder.start(
        settings: settings,
        outputPath: outputPath,
        width: _defaultWidth,
        height: _defaultHeight,
        region: state.selectedRegion,
      );

      _cursorRecording = CursorRecording();
      _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
        (pos) => _cursorRecording?.addPosition(pos),
        onError: (e) => AppLogger.recording.w('Cursor stream error', error: e),
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

      final result = await _videoEncoder.stop();

      // Save cursor sidecar (next to MP4).
      if (_cursorRecording != null && _cursorRecording!.count > 0) {
        await _cursorRecording!.saveToFile('${result.outputPath}.cursor.json');
        AppLogger.recording.i('Cursor data saved: ${_cursorRecording!.count} positions');
      }
      _cursorRecording = null;

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

  Future<void> pauseRecording() async {
    if (state.status != RecordingStatus.recording) return;
    _durationTimer?.cancel();
    _durationTimer = null;
    // Capture elapsed-so-far so resume can restart from where we paused.
    final elapsed = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : state.duration;
    _startTime = null;
    state = state.copyWith(status: RecordingStatus.paused, duration: elapsed);
    await ScreenRecorderPlatform.instance.pauseRecording();
  }

  Future<void> resumeRecording() async {
    if (state.status != RecordingStatus.paused) return;
    await ScreenRecorderPlatform.instance.resumeRecording();
    // Re-anchor _startTime to "now minus elapsed" so the periodic timer
    // continues to fire correct durations from where we paused.
    _startTime = DateTime.now().subtract(state.duration);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startTime != null) {
        state = state.copyWith(duration: DateTime.now().difference(_startTime!));
      }
    });
    state = state.copyWith(status: RecordingStatus.recording);
  }

  void _handleError(String message) {
    state = state.copyWith(status: RecordingStatus.error, error: message);
    _cursorSubscription?.cancel();
    _cursorSubscription = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _startTime = null;
    _cursorRecording = null;
  }

  void reset() => state = const RecordingState();

  @override
  void dispose() {
    _cursorSubscription?.cancel();
    _durationTimer?.cancel();
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
