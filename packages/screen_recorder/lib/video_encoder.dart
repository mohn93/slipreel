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

  bool get isActive => _isActive;
  String? get outputPath => _outputPath;
  int get width => _width;
  int get height => _height;
  int get fps => _fps;
}
