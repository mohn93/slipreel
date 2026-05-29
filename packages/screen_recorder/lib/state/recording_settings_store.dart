// packages/screen_recorder/lib/state/recording_settings_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/app_logger.dart';

/// User-facing recording preferences. Grows as more recording prefs land.
class RecordingSettings {
  const RecordingSettings({this.countdownSeconds = 3});
  final int countdownSeconds;

  RecordingSettings copyWith({int? countdownSeconds}) => RecordingSettings(
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      );

  Map<String, dynamic> toJson() => {'countdownSeconds': countdownSeconds};

  static const defaults = RecordingSettings();

  /// Only these countdown values are allowed; anything else falls back to the default.
  static const _validCountdowns = {0, 3, 5};

  static RecordingSettings fromJson(Map<String, dynamic> json) {
    final raw = json['countdownSeconds'];
    final countdown =
        (raw is int && _validCountdowns.contains(raw)) ? raw : defaults.countdownSeconds;
    return RecordingSettings(countdownSeconds: countdown);
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
