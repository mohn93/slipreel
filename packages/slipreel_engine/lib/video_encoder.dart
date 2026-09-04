import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Façade over the platform's live HW-encoded recording API.
///
/// Started before the platform-side capture begins; stopped after capture
/// ends. The output MP4 is written directly by the native side during
/// capture; this class does not see frame bytes.
class VideoEncoder {
  String? _outputPath;
  int _width = 0;
  int _height = 0;
  int _fps = 30;
  bool _isActive = false;

  /// Start a live recording session that will write to [outputPath].
  /// Must be called before [ScreenRecorderPlatform.startLiveRecording] would
  /// otherwise be triggered (see [RecordingController]).
  Future<void> start({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    _outputPath = outputPath;
    _width = width;
    _height = height;
    _fps = settings.frameRate;
    await ScreenRecorderPlatform.instance.startLiveRecording(
      settings: settings,
      outputPath: outputPath,
      width: width,
      height: height,
      region: region,
    );
    _isActive = true;
    AppLogger.videoEncoder.i('Live recording started: ${_width}x$_height @ ${_fps}fps -> $_outputPath');
  }

  /// Start a device (iPhone/iPad over USB) recording session.
  ///
  /// Unlike [start] this calls [ScreenRecorderPlatform.startDeviceRecording]
  /// (an AVCaptureSession-backed path) rather than [startLiveRecording], but
  /// the native side finalizes it through the SAME stopLiveRecording path, so
  /// the encoder is marked active here and torn down by [stop]/[forceReset]
  /// exactly like a screen recording. The MP4 is written by the native side.
  Future<void> startDevice({
    required String deviceId,
    required bool captureDeviceAudio,
    required MicrophoneConfig? microphone,
    required String outputPath,
  }) async {
    _outputPath = outputPath;
    await ScreenRecorderPlatform.instance.startDeviceRecording(
      deviceId: deviceId,
      captureDeviceAudio: captureDeviceAudio,
      microphone: microphone,
      outputPath: outputPath,
    );
    _isActive = true;
    AppLogger.videoEncoder.i('Device recording started -> $_outputPath');
  }

  /// Stop the live recording and return the result (path + native perf stats).
  Future<RecordingResult> stop() async {
    if (!_isActive) {
      throw StateError('VideoEncoder.stop called when not active');
    }
    final result = await ScreenRecorderPlatform.instance.stopLiveRecording();
    _isActive = false;
    AppLogger.videoEncoder.i('Live recording finished: ${result.outputPath}');
    return result;
  }

  /// Best-effort teardown for the abandon/error path. Clears [isActive]
  /// synchronously (so a subsequent [start] can't double-record), then asks
  /// the native side to stop, swallowing any failure. Unlike [stop] it never
  /// throws and returns no result — used when a recording is being discarded
  /// (see RecordingController._handleError) so a failed or partial session
  /// can't leave the native capture running or contend for the next start.
  Future<void> forceReset() async {
    if (!_isActive) return;
    _isActive = false;
    try {
      await ScreenRecorderPlatform.instance.stopLiveRecording();
    } catch (e, st) {
      AppLogger.videoEncoder
          .w('forceReset: stopLiveRecording failed', error: e, stackTrace: st);
    }
  }

  bool get isActive => _isActive;
  String? get outputPath => _outputPath;
  int get width => _width;
  int get height => _height;
  int get fps => _fps;
}
