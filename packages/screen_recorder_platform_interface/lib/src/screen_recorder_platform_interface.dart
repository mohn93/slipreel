import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'models/audio_data.dart';
import 'models/audio_device_info.dart';
import 'models/cursor_position.dart';
import 'models/frame_data.dart';
import 'models/recording_settings.dart';
import 'models/screen_info.dart';
import 'models/window_info.dart';

/// The interface that platform-specific implementations must extend.
abstract class ScreenRecorderPlatform extends PlatformInterface {
  ScreenRecorderPlatform() : super(token: _token);

  static final Object _token = Object();
  static ScreenRecorderPlatform? _instance;

  /// The default instance of [ScreenRecorderPlatform] to use.
  static ScreenRecorderPlatform get instance {
    if (_instance == null) {
      throw UnimplementedError(
        'ScreenRecorderPlatform has not been implemented. '
        'Make sure to register a platform implementation.',
      );
    }
    return _instance!;
  }

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ScreenRecorderPlatform]
  static set instance(ScreenRecorderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // Discovery methods

  /// Get list of available screens/displays
  Future<List<ScreenInfo>> getAvailableScreens() {
    throw UnimplementedError('getAvailableScreens() has not been implemented.');
  }

  /// Get list of available windows
  Future<List<WindowInfo>> getAvailableWindows() {
    throw UnimplementedError('getAvailableWindows() has not been implemented.');
  }

  /// Get list of available audio devices
  Future<List<AudioDeviceInfo>> getAudioDevices() {
    throw UnimplementedError('getAudioDevices() has not been implemented.');
  }

  // Recording control methods

  /// Start recording with the given settings
  Future<void> startRecording(RecordingSettings settings) {
    throw UnimplementedError('startRecording() has not been implemented.');
  }

  /// Pause the current recording
  Future<void> pauseRecording() {
    throw UnimplementedError('pauseRecording() has not been implemented.');
  }

  /// Resume a paused recording
  Future<void> resumeRecording() {
    throw UnimplementedError('resumeRecording() has not been implemented.');
  }

  /// Stop recording and return the file path
  Future<String> stopRecording() {
    throw UnimplementedError('stopRecording() has not been implemented.');
  }

  // Permission methods

  /// Request necessary permissions (screen recording, audio)
  Future<bool> requestPermissions() {
    throw UnimplementedError('requestPermissions() has not been implemented.');
  }

  /// Check if permissions are granted
  Future<bool> checkPermissions() {
    throw UnimplementedError('checkPermissions() has not been implemented.');
  }

  // Real-time data streams

  /// Stream of video frames during recording
  Stream<FrameData> get frameStream {
    throw UnimplementedError('frameStream has not been implemented.');
  }

  /// Stream of audio samples during recording
  Stream<AudioData> get audioStream {
    throw UnimplementedError('audioStream has not been implemented.');
  }

  /// Stream of cursor positions during recording
  Stream<CursorPosition> get cursorStream {
    throw UnimplementedError('cursorStream has not been implemented.');
  }
}
