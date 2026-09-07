// packages/screen_recorder/lib/state/recording_settings_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;
import 'package:slipreel_engine/utils/app_logger.dart';

/// User-facing recording preferences. Grows as more recording prefs land.
class RecordingSettings {
  const RecordingSettings({
    this.countdownSeconds = 3,
    this.microphone,
    this.systemAudio,
    this.camera,
  });
  final int countdownSeconds;

  /// Last-used microphone selection, or null for "don't record microphone".
  final MicrophoneConfig? microphone;

  /// Last-used system-audio selection, or null for "don't record system audio".
  final SystemAudioConfig? systemAudio;

  /// Last-used camera selection, or null for "don't record camera".
  final CameraConfig? camera;

  static const Object _unset = Object();

  RecordingSettings copyWith({
    int? countdownSeconds,
    Object? microphone = _unset,
    Object? systemAudio = _unset,
    Object? camera = _unset,
  }) =>
      RecordingSettings(
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
        microphone: identical(microphone, _unset)
            ? this.microphone
            : microphone as MicrophoneConfig?,
        systemAudio: identical(systemAudio, _unset)
            ? this.systemAudio
            : systemAudio as SystemAudioConfig?,
        camera:
            identical(camera, _unset) ? this.camera : camera as CameraConfig?,
      );

  Map<String, dynamic> toJson() => {
        'countdownSeconds': countdownSeconds,
        if (microphone != null) 'microphone': microphone!.toJson(),
        if (systemAudio != null) 'systemAudio': systemAudio!.toJson(),
        if (camera != null) 'camera': camera!.toJson(),
      };

  static const defaults = RecordingSettings();

  /// Only these countdown values are allowed; anything else falls back to the default.
  static const _validCountdowns = {0, 3, 5};

  static RecordingSettings fromJson(Map<String, dynamic> json) {
    final raw = json['countdownSeconds'];
    final countdown =
        (raw is int && _validCountdowns.contains(raw)) ? raw : defaults.countdownSeconds;
    MicrophoneConfig? mic;
    SystemAudioConfig? sys;
    CameraConfig? cam;
    try {
      final m = json['microphone'];
      if (m is Map) mic = MicrophoneConfig.fromJson(m.cast<String, dynamic>());
      final s = json['systemAudio'];
      if (s is Map) sys = SystemAudioConfig.fromJson(s.cast<String, dynamic>());
      final c = json['camera'];
      if (c is Map) cam = CameraConfig.fromJson(c.cast<String, dynamic>());
    } catch (_) {
      // Malformed capture config → treat as off; countdown still honored.
    }
    return RecordingSettings(
      countdownSeconds: countdown,
      microphone: mic,
      systemAudio: sys,
      camera: cam,
    );
  }
}

/// JSON sidecar under getApplicationSupportDirectory(). Mirrors the
/// MotionTuningStore pattern.
class RecordingSettingsStore {
  RecordingSettingsStore({required this.path});
  final String path;

  Future<RecordingSettings> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return RecordingSettings.defaults;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return RecordingSettings.fromJson(json);
    } catch (e, st) {
      AppLogger.platform.w('RecordingSettingsStore.load failed; falling back',
          error: e, stackTrace: st);
      return RecordingSettings.defaults;
    }
  }

  Future<void> save(RecordingSettings settings) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
