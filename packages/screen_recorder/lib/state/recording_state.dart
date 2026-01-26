import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../video_encoder.dart';
import '../models/cursor_recording.dart';

/// Recording status enum
enum RecordingStatus {
  idle,
  recording,
  processing,
  completed,
  error,
}

/// Recording state class
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

/// Recording controller
class RecordingController extends StateNotifier<RecordingState> {
  RecordingController() : super(const RecordingState());

  VideoEncoder? _videoEncoder;
  StreamSubscription<FrameData>? _frameSubscription;
  StreamSubscription<AudioData>? _audioSubscription;
  StreamSubscription<CursorPosition>? _cursorSubscription;
  CursorRecording? _cursorRecording;
  Timer? _durationTimer;
  DateTime? _startTime;

  /// Select a window for recording
  void selectWindow(String? windowId) {
    state = state.copyWith(selectedWindowId: windowId);
  }

  /// Start recording
  Future<void> startRecording() async {
    if (!state.canStartRecording || state.selectedWindowId == null) {
      return;
    }

    try {
      // Reset state
      state = state.copyWith(
        status: RecordingStatus.recording,
        frameCount: 0,
        duration: Duration.zero,
        videoPath: null,
        error: null,
      );

      // Create output path
      final docsDir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${docsDir.path}/recording_$timestamp.mp4';

      // Initialize video encoder
      _videoEncoder = VideoEncoder();

      // Subscribe to frame stream
      var firstFrame = true;
      _frameSubscription =
          ScreenRecorderPlatform.instance.frameStream.listen(
        (frameData) async {
          // Initialize encoder with first frame dimensions
          if (firstFrame && _videoEncoder != null) {
            await _videoEncoder!.initialize(
              outputPath: outputPath,
              width: frameData.width,
              height: frameData.height,
              fps: 30,
            );
            firstFrame = false;
          }

          // Add frame to encoder
          if (_videoEncoder != null && _videoEncoder!.isInitialized) {
            await _videoEncoder!.addFrame(frameData);
          }

          // Update frame count
          state = state.copyWith(frameCount: state.frameCount + 1);
        },
        onError: (error) {
          _handleError('Frame stream error: $error');
        },
      );

      // Subscribe to audio stream
      _audioSubscription =
          ScreenRecorderPlatform.instance.audioStream.listen(
        (audioData) async {
          // Add audio sample to encoder
          if (_videoEncoder != null && _videoEncoder!.isInitialized) {
            await _videoEncoder!.addAudioSample(
              audioData.data,
              audioData.sampleRate,
              audioData.channels,
            );
          }
        },
        onError: (error) {
          print('Audio stream error: $error');
          // Don't fail the entire recording if audio fails
        },
      );

      // Start duration timer
      _startTime = DateTime.now();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_startTime != null) {
          final duration = DateTime.now().difference(_startTime!);
          state = state.copyWith(duration: duration);
        }
      });

      // Start platform recording
      final settings = RecordingSettings(
        source: RecordingSource.window,
        sourceId: state.selectedWindowId,
        frameRate: 30,
        captureAudio: true,
        captureCursor: true,
      );
      await ScreenRecorderPlatform.instance.startRecording(settings);

      // Subscribe to cursor stream if cursor capture enabled
      if (settings.captureCursor) {
        _cursorRecording = CursorRecording();

        _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
          (cursorData) {
            _cursorRecording?.addPosition(cursorData);
          },
          onError: (error) {
            print('Cursor stream error: $error');
          },
        );
      }
    } catch (e) {
      _handleError('Failed to start recording: $e');
    }
  }

  /// Stop recording
  Future<void> stopRecording() async {
    if (!state.isRecording) {
      return;
    }

    try {
      // Update status to processing
      state = state.copyWith(status: RecordingStatus.processing);

      // Stop platform recording
      await ScreenRecorderPlatform.instance.stopRecording();

      // Cancel streams and timers
      await _frameSubscription?.cancel();
      _frameSubscription = null;
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      _durationTimer?.cancel();
      _durationTimer = null;
      _startTime = null;

      // Cancel cursor subscription and save data
      await _cursorSubscription?.cancel();
      _cursorSubscription = null;

      // Save cursor data if captured
      if (_cursorRecording != null && _cursorRecording!.count > 0) {
        final docsDir = await getApplicationDocumentsDirectory();
        final cursorPath = '${docsDir.path}/cursor_${DateTime.now().millisecondsSinceEpoch}.json';
        await _cursorRecording!.saveToFile(cursorPath);
        print('Cursor data saved: ${_cursorRecording!.count} positions');

        // TODO: Pass cursor data to video encoder for rendering
      }

      // Finalize video encoding
      if (_videoEncoder != null && _videoEncoder!.frameCount > 0) {
        final videoPath = await _videoEncoder!.finalize();

        // Check file exists
        final file = File(videoPath);
        if (await file.exists()) {
          state = state.copyWith(
            status: RecordingStatus.completed,
            videoPath: videoPath,
          );
        } else {
          _handleError('Video file was not created');
        }
      } else {
        _handleError('No frames to encode');
      }

      _videoEncoder = null;
    } catch (e) {
      _handleError('Failed to stop recording: $e');
    }
  }

  void _handleError(String errorMessage) {
    state = state.copyWith(
      status: RecordingStatus.error,
      error: errorMessage,
    );

    // Cleanup
    _frameSubscription?.cancel();
    _frameSubscription = null;
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _cursorSubscription?.cancel();
    _cursorSubscription = null;
    _cursorRecording = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _startTime = null;
    _videoEncoder?.cancel();
    _videoEncoder = null;
  }

  /// Reset to idle state
  void reset() {
    state = const RecordingState();
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    _audioSubscription?.cancel();
    _cursorSubscription?.cancel();
    _durationTimer?.cancel();
    _videoEncoder?.cancel();
    super.dispose();
  }
}

/// Recording controller provider
final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>((ref) {
  return RecordingController();
});

/// Helper provider for formatted duration
final formattedDurationProvider = Provider<String>((ref) {
  final duration = ref.watch(
    recordingControllerProvider.select((state) => state.duration),
  );

  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
});

/// Helper provider for FPS calculation
final fpsProvider = Provider<double>((ref) {
  final state = ref.watch(recordingControllerProvider);

  if (state.frameCount == 0 || state.duration.inSeconds == 0) {
    return 0.0;
  }

  return state.frameCount / state.duration.inSeconds;
});
