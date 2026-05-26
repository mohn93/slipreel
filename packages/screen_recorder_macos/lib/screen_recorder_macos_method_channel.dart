import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// macOS implementation of [ScreenRecorderPlatform] using method channels.
class MethodChannelScreenRecorderMacos extends ScreenRecorderPlatform {
  /// The method channel for recording control
  final _recordingChannel = const MethodChannel(ScreenRecorderChannels.recording);

  /// Event channel for video frames
  final _framesChannel = const EventChannel(ScreenRecorderChannels.frames);

  /// Event channel for audio samples
  final _audioChannel = const EventChannel(ScreenRecorderChannels.audio);

  /// Event channel for cursor positions
  final _cursorChannel = const EventChannel(ScreenRecorderChannels.cursor);

  /// Event channel for live microphone level
  final _micLevelChannel = const EventChannel(ScreenRecorderChannels.micLevel);

  @override
  Future<List<ScreenInfo>> getAvailableScreens() async {
    final result = await _recordingChannel.invokeMethod<List<dynamic>>(
      ScreenRecorderMethods.getAvailableScreens,
    );
    if (result == null) return [];
    return result
        .map((e) => ScreenInfo.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<WindowInfo>> getAvailableWindows() async {
    final result = await _recordingChannel.invokeMethod<List<dynamic>>(
      ScreenRecorderMethods.getAvailableWindows,
    );
    if (result == null) return [];
    return result
        .map((e) => WindowInfo.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<AudioDeviceInfo>> getAudioDevices() async {
    final result = await _recordingChannel.invokeMethod<List<dynamic>>(
      ScreenRecorderMethods.getAudioDevices,
    );
    if (result == null) return [];
    return result
        .map((e) => AudioDeviceInfo.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<void> startRecording(RecordingSettings settings) async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.startRecording,
      settings.toJson(),
    );
  }

  @override
  Future<void> pauseRecording() async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.pauseRecording,
    );
  }

  @override
  Future<void> resumeRecording() async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.resumeRecording,
    );
  }

  @override
  Future<String> stopRecording() async {
    final result = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.stopRecording,
    );
    return result ?? '';
  }

  @override
  Future<bool> requestPermissions() async {
    final result = await _recordingChannel.invokeMethod<bool>(
      ScreenRecorderMethods.requestPermissions,
    );
    return result ?? false;
  }

  @override
  Future<bool> checkPermissions() async {
    final result = await _recordingChannel.invokeMethod<bool>(
      ScreenRecorderMethods.checkPermissions,
    );
    return result ?? false;
  }

  @override
  Future<bool> isAccessibilityTrusted() async {
    final result = await _recordingChannel.invokeMethod<bool>(
      'isAccessibilityTrusted',
    );
    return result ?? false;
  }

  @override
  Future<void> requestAccessibilityPermission() async {
    await _recordingChannel.invokeMethod<void>(
      'requestAccessibilityPermission',
    );
  }

  @override
  Future<Map<String, StockCursorImage>> getStockCursorImages() async {
    final raw = await _recordingChannel
        .invokeMapMethod<String, dynamic>('getStockCursorImages');
    if (raw == null) return const {};
    final out = <String, StockCursorImage>{};
    for (final entry in raw.entries) {
      final inner = entry.value;
      if (inner is Map) {
        out[entry.key] = StockCursorImage.fromMap(inner);
      }
    }
    return out;
  }

  @override
  Stream<FrameData> get frameStream {
    return _framesChannel.receiveBroadcastStream().map((event) {
      return FrameData.fromJson(Map<String, dynamic>.from(event as Map));
    });
  }

  @override
  Stream<AudioData> get audioStream {
    return _audioChannel.receiveBroadcastStream().map((event) {
      try {
        final map = event as Map;
        return AudioData.fromJson(Map<String, dynamic>.from(map));
      } catch (e) {
        throw Exception('Failed to parse audio data: $e');
      }
    }).handleError((error) {
      print('[ScreenRecorder] Audio stream error: $error');
      throw error;
    });
  }

  @override
  Stream<CursorPosition> get cursorStream {
    return _cursorChannel.receiveBroadcastStream().map((event) {
      return CursorPosition.fromJson(Map<String, dynamic>.from(event as Map));
    });
  }

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    final args = <String, dynamic>{
      ...settings.toJson(),
      'outputPath': outputPath,
      'width': width,
      'height': height,
    };
    if (region != null) {
      args['region'] = region.toMap();
    }
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.startLiveRecording,
      args,
    );
  }

  @override
  Future<RecordingResult> stopLiveRecording() async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.stopLiveRecording,
    );
    if (raw == null) {
      throw StateError('stopLiveRecording returned null');
    }
    return RecordingResult.fromMap(raw);
  }

  @override
  Future<SourceList> listSources({bool strictFilter = true}) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.listSources,
      {'strictFilter': strictFilter},
    );
    if (raw == null) return const SourceList();
    return SourceList.fromMap(raw);
  }

  @override
  Future<Uint8List?> captureThumbnail(
    String id,
    RecordingSource kind, {
    int maxDimension = 480,
  }) async {
    if (kind != RecordingSource.window && kind != RecordingSource.screen) {
      throw ArgumentError('captureThumbnail kind must be window or screen, got $kind');
    }
    final result = await _recordingChannel.invokeMethod<Uint8List>(
      ScreenRecorderMethods.captureThumbnail,
      {
        'id': id,
        'kind': kind.name,
        'maxDimension': maxDimension,
      },
    );
    return result;
  }

  @override
  Future<RegionSelection?> selectRegion() async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.selectRegion,
    );
    if (raw == null) return null;
    return RegionSelection.fromMap(raw);
  }

  @override
  Future<PickedSource?> pickSource(RecordingSource kind) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.pickSource,
      {'kind': kind == RecordingSource.window ? 'window' : 'screen'},
    );
    if (raw == null) return null;
    return PickedSource.fromMap(raw);
  }

  @override
  Future<MicrophoneMenuResult> showMicrophoneMenu(MicrophoneConfig? current) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.showMicrophoneMenu,
      current?.toJson(),
    );
    if (raw == null) {
      return const MicrophoneMenuResult(cancelled: true);
    }
    return MicrophoneMenuResult.fromJson(raw);
  }

  @override
  Future<SystemAudioMenuResult> showSystemAudioMenu(
      SystemAudioConfig? current) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.showSystemAudioMenu,
      current?.toJson(),
    );
    if (raw == null) {
      return const SystemAudioMenuResult(cancelled: true);
    }
    return SystemAudioMenuResult.fromJson(raw);
  }

  @override
  Stream<double> get micLevelStream => _micLevelChannel
      .receiveBroadcastStream()
      .map((event) => (event as num).toDouble());

  @override
  Future<void> startMicMonitor(MicrophoneConfig config) async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.startMicMonitor,
      config.toJson(),
    );
  }

  @override
  Future<void> stopMicMonitor() async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.stopMicMonitor,
    );
  }
}
