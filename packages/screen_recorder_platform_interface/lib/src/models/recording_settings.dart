import 'microphone_config.dart';

/// Settings for a recording session
class RecordingSettings {
  final RecordingSource source;
  final String? sourceId;
  final int frameRate;

  /// The microphone to record, or null for "don't record microphone".
  final MicrophoneConfig? microphone;

  final bool captureCursor;
  final int? maxDurationSeconds;

  const RecordingSettings({
    required this.source,
    this.sourceId,
    this.frameRate = 30,
    this.microphone,
    this.captureCursor = true,
    this.maxDurationSeconds,
  });

  Map<String, dynamic> toJson() {
    return {
      'source': source.name,
      'sourceId': sourceId,
      'frameRate': frameRate,
      'microphone': microphone?.toJson(),
      'captureCursor': captureCursor,
      'maxDurationSeconds': maxDurationSeconds,
    };
  }

  factory RecordingSettings.fromJson(Map<String, dynamic> json) {
    final mic = json['microphone'];
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
      captureCursor: json['captureCursor'] as bool? ?? true,
      maxDurationSeconds: json['maxDurationSeconds'] as int?,
    );
  }

  RecordingSettings copyWith({
    RecordingSource? source,
    String? sourceId,
    int? frameRate,
    MicrophoneConfig? microphone,
    bool? captureCursor,
    int? maxDurationSeconds,
  }) {
    return RecordingSettings(
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      frameRate: frameRate ?? this.frameRate,
      microphone: microphone ?? this.microphone,
      captureCursor: captureCursor ?? this.captureCursor,
      maxDurationSeconds: maxDurationSeconds ?? this.maxDurationSeconds,
    );
  }

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
