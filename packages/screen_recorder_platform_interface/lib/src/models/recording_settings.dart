import 'microphone_config.dart';
import 'system_audio_config.dart';

/// Settings for a recording session
class RecordingSettings {
  final RecordingSource source;
  final String? sourceId;
  final int frameRate;

  /// The microphone to record, or null for "don't record microphone".
  final MicrophoneConfig? microphone;

  /// The system-audio selection, or null for "don't record system audio".
  final SystemAudioConfig? systemAudio;

  final bool captureCursor;
  final int? maxDurationSeconds;

  const RecordingSettings({
    required this.source,
    this.sourceId,
    this.frameRate = 30,
    this.microphone,
    this.systemAudio,
    this.captureCursor = true,
    this.maxDurationSeconds,
  });

  Map<String, dynamic> toJson() {
    return {
      'source': source.name,
      'sourceId': sourceId,
      'frameRate': frameRate,
      'microphone': microphone?.toJson(),
      'systemAudio': systemAudio?.toJson(),
      'captureCursor': captureCursor,
      'maxDurationSeconds': maxDurationSeconds,
    };
  }

  factory RecordingSettings.fromJson(Map<String, dynamic> json) {
    final mic = json['microphone'];
    final sys = json['systemAudio'];
    return RecordingSettings(
      source: RecordingSource.values.firstWhere(
        (e) => e.name == json['source'],
        orElse: () => RecordingSource.screen,
      ),
      sourceId: json['sourceId'] as String?,
      frameRate: json['frameRate'] as int? ?? 30,
      microphone: mic == null
          ? null
          : MicrophoneConfig.fromJson(Map<String, dynamic>.from(mic as Map)),
      systemAudio: sys == null
          ? null
          : SystemAudioConfig.fromJson(Map<String, dynamic>.from(sys as Map)),
      captureCursor: json['captureCursor'] as bool? ?? true,
      maxDurationSeconds: json['maxDurationSeconds'] as int?,
    );
  }

  /// Creates a copy with the given fields replaced.
  ///
  /// Nullable fields ([sourceId], [microphone], [systemAudio],
  /// [maxDurationSeconds]) use a sentinel pattern so callers can pass
  /// `null` to clear them — omitting the parameter preserves the current
  /// value, while passing `null` resets the field to null. (The naive
  /// `field ?? this.field` idiom can't distinguish "not provided" from
  /// "provided as null".)
  RecordingSettings copyWith({
    RecordingSource? source,
    Object? sourceId = _unset,
    int? frameRate,
    Object? microphone = _unset,
    Object? systemAudio = _unset,
    bool? captureCursor,
    Object? maxDurationSeconds = _unset,
  }) {
    return RecordingSettings(
      source: source ?? this.source,
      sourceId: identical(sourceId, _unset)
          ? this.sourceId
          : sourceId as String?,
      frameRate: frameRate ?? this.frameRate,
      microphone: identical(microphone, _unset)
          ? this.microphone
          : microphone as MicrophoneConfig?,
      systemAudio: identical(systemAudio, _unset)
          ? this.systemAudio
          : systemAudio as SystemAudioConfig?,
      captureCursor: captureCursor ?? this.captureCursor,
      maxDurationSeconds: identical(maxDurationSeconds, _unset)
          ? this.maxDurationSeconds
          : maxDurationSeconds as int?,
    );
  }

  /// Sentinel used by [copyWith] to distinguish "parameter omitted"
  /// from "parameter explicitly passed as null".
  static const Object _unset = Object();

  @override
  String toString() {
    return 'RecordingSettings(source: $source, sourceId: $sourceId, fps: $frameRate, mic: ${microphone?.deviceLabel ?? "off"}, cursor: $captureCursor)';
  }
}

enum RecordingSource {
  screen,
  window,
  area,
}
