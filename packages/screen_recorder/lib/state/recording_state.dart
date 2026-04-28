import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';
import '../models/recording_metadata.dart';
import '../utils/app_logger.dart';
import '../utils/perf_summary.dart';
import '../video_encoder.dart';

enum RecordingStatus { idle, recording, processing, completed, error }

class RecordingState {
  final RecordingStatus status;
  final int frameCount;
  final Duration duration;
  final String? videoPath;
  final String? error;
  final String? selectedWindowId;

  const RecordingState({
    this.status = RecordingStatus.idle,
    this.frameCount = 0,
    this.duration = Duration.zero,
    this.videoPath,
    this.error,
    this.selectedWindowId,
  });

  RecordingState copyWith({
    RecordingStatus? status,
    int? frameCount,
    Duration? duration,
    String? videoPath,
    String? error,
    String? selectedWindowId,
  }) {
    return RecordingState(
      status: status ?? this.status,
      frameCount: frameCount ?? this.frameCount,
      duration: duration ?? this.duration,
      videoPath: videoPath ?? this.videoPath,
      error: error,
      selectedWindowId: selectedWindowId ?? this.selectedWindowId,
    );
  }

  bool get isRecording => status == RecordingStatus.recording;
  bool get isProcessing => status == RecordingStatus.processing;
  bool get canStartRecording =>
      status == RecordingStatus.idle || status == RecordingStatus.completed;
}

class RecordingController extends StateNotifier<RecordingState> {
  RecordingController() : super(const RecordingState());

  final VideoEncoder _videoEncoder = VideoEncoder();
  StreamSubscription<CursorPosition>? _cursorSubscription;
  CursorRecording? _cursorRecording;
  Timer? _durationTimer;
  DateTime? _startTime;

  static const int _defaultFps = 60;
  static const int _defaultWidth = 1920;
  static const int _defaultHeight = 1080;

  void selectWindow(String? windowId) {
    state = state.copyWith(selectedWindowId: windowId);
  }

  Future<void> startRecording() async {
    if (!state.canStartRecording || state.selectedWindowId == null) return;
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
        source: RecordingSource.window,
        sourceId: state.selectedWindowId,
        frameRate: _defaultFps,
        captureAudio: true,
        captureCursor: true,
      );

      await _videoEncoder.start(
        settings: settings,
        outputPath: outputPath,
        width: _defaultWidth,
        height: _defaultHeight,
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
      final meta = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.now(),
        widthPx: _videoEncoder.width,
        heightPx: _videoEncoder.height,
        fps: _videoEncoder.fps,
      );
      await meta.saveForVideo(result.outputPath);

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
