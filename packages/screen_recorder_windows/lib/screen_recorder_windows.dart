import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Windows implementation of the ScreenRecorderPlatform
class ScreenRecorderWindows extends ScreenRecorderPlatform {
  static const MethodChannel _channel =
      MethodChannel('com.screenflow_studio.screen_recorder/methods');

  static const EventChannel _framesChannel =
      EventChannel('com.screenflow_studio.screen_recorder/frames');

  static const EventChannel _cursorChannel =
      EventChannel('com.screenflow_studio.screen_recorder/cursor');

  static const EventChannel _audioChannel =
      EventChannel('com.screenflow_studio.screen_recorder/audio');

  /// Registers this class as the default instance of [ScreenRecorderPlatform]
  static void registerWith() {
    ScreenRecorderPlatform.instance = ScreenRecorderWindows();
  }

  @override
  Future<bool> requestPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermissions');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error requesting permission: ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> checkPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkPermissions');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error checking permissions: ${e.message}');
      return false;
    }
  }

  @override
  Future<List<WindowInfo>> getAvailableWindows() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAvailableWindows');

      return result.map((window) {
        final map = window as Map<dynamic, dynamic>;
        return WindowInfo(
          id: map['id'] as String,
          title: map['title'] as String,
          ownerName: map['ownerName'] as String,
          x: map['x'] as int? ?? 0,
          y: map['y'] as int? ?? 0,
          width: map['width'] as int? ?? 0,
          height: map['height'] as int? ?? 0,
          isOnScreen: map['isOnScreen'] as bool? ?? true,
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting windows: ${e.message}');
      return [];
    }
  }

  @override
  Future<List<ScreenInfo>> getAvailableScreens() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAvailableScreens');

      return result.map((screen) {
        final map = screen as Map<dynamic, dynamic>;
        return ScreenInfo(
          id: map['id'] as String,
          name: map['name'] as String,
          width: map['width'] as int,
          height: map['height'] as int,
          isPrimary: map['isPrimary'] as bool? ?? false,
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting screens: ${e.message}');
      return [];
    }
  }

  @override
  Future<List<AudioDeviceInfo>> getAudioDevices() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAudioDevices');

      return result.map((device) {
        final map = device as Map<dynamic, dynamic>;
        return AudioDeviceInfo(
          id: map['id'] as String,
          name: map['name'] as String,
          type: AudioDeviceType.values.firstWhere(
            (e) => e.name == map['type'],
            orElse: () => AudioDeviceType.unknown,
          ),
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting audio devices: ${e.message}');
      return [];
    }
  }

  @override
  Future<void> startRecording(RecordingSettings settings) async {
    try {
      await _channel.invokeMethod('startRecording', settings.toJson());
    } on PlatformException catch (e) {
      throw Exception('Failed to start recording: ${e.message}');
    }
  }

  @override
  Future<void> pauseRecording() async {
    try {
      await _channel.invokeMethod('pauseRecording');
    } on PlatformException catch (e) {
      throw Exception('Failed to pause recording: ${e.message}');
    }
  }

  @override
  Future<void> resumeRecording() async {
    try {
      await _channel.invokeMethod('resumeRecording');
    } on PlatformException catch (e) {
      throw Exception('Failed to resume recording: ${e.message}');
    }
  }

  @override
  Future<String> stopRecording() async {
    try {
      final result = await _channel.invokeMethod<String>('stopRecording');
      return result ?? '';
    } on PlatformException catch (e) {
      throw Exception('Failed to stop recording: ${e.message}');
    }
  }

  @override
  Stream<FrameData> get frameStream {
    return _framesChannel.receiveBroadcastStream().map((data) {
      final map = data as Map<dynamic, dynamic>;
      return FrameData(
        data: map['data'] as Uint8List,
        width: map['width'] as int,
        height: map['height'] as int,
        timestampMicros: map['timestampMicros'] as int,
        format: PixelFormat.values.firstWhere(
          (e) => e.name == map['format'],
          orElse: () => PixelFormat.bgra,
        ),
      );
    });
  }

  @override
  Stream<AudioData> get audioStream {
    return _audioChannel.receiveBroadcastStream().map((data) {
      final map = data as Map<dynamic, dynamic>;
      return AudioData(
        data: map['data'] as Uint8List,
        sampleRate: map['sampleRate'] as int,
        channels: map['channels'] as int,
        timestampMicros: map['timestampMicros'] as int,
      );
    });
  }

  @override
  Stream<CursorPosition> get cursorStream {
    return _cursorChannel.receiveBroadcastStream().map((data) {
      final map = data as Map<dynamic, dynamic>;
      return CursorPosition(
        x: map['x'] as double,
        y: map['y'] as double,
        isClicked: map['isClicked'] as bool? ?? false,
        timestampMicros: map['timestampMicros'] as int,
      );
    });
  }
}
