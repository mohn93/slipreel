/// Settings for a recording session
class RecordingSettings {
  final RecordingSource source;
  final String? sourceId;
  final int frameRate;
  final bool captureAudio;
  final List<String> audioDeviceIds;
  final bool captureCursor;
  final int? maxDurationSeconds;

  const RecordingSettings({
    required this.source,
    this.sourceId,
    this.frameRate = 30,
    this.captureAudio = true,
    this.audioDeviceIds = const [],
    this.captureCursor = true,
    this.maxDurationSeconds,
  });

  Map<String, dynamic> toJson() {
    return {
      'source': source.name,
      'sourceId': sourceId,
      'frameRate': frameRate,
      'captureAudio': captureAudio,
      'audioDeviceIds': audioDeviceIds,
      'captureCursor': captureCursor,
      'maxDurationSeconds': maxDurationSeconds,
    };
  }

  factory RecordingSettings.fromJson(Map<String, dynamic> json) {
    return RecordingSettings(
      source: RecordingSource.values.firstWhere(
        (e) => e.name == json['source'],
        orElse: () => RecordingSource.screen,
      ),
      sourceId: json['sourceId'] as String?,
      frameRate: json['frameRate'] as int? ?? 30,
      captureAudio: json['captureAudio'] as bool? ?? true,
      audioDeviceIds: (json['audioDeviceIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      captureCursor: json['captureCursor'] as bool? ?? true,
      maxDurationSeconds: json['maxDurationSeconds'] as int?,
    );
  }

  RecordingSettings copyWith({
    RecordingSource? source,
    String? sourceId,
    int? frameRate,
    bool? captureAudio,
    List<String>? audioDeviceIds,
    bool? captureCursor,
    int? maxDurationSeconds,
  }) {
    return RecordingSettings(
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      frameRate: frameRate ?? this.frameRate,
      captureAudio: captureAudio ?? this.captureAudio,
      audioDeviceIds: audioDeviceIds ?? this.audioDeviceIds,
      captureCursor: captureCursor ?? this.captureCursor,
      maxDurationSeconds: maxDurationSeconds ?? this.maxDurationSeconds,
    );
  }

  @override
  String toString() {
    return 'RecordingSettings(source: $source, sourceId: $sourceId, fps: $frameRate, audio: $captureAudio, cursor: $captureCursor)';
  }
}

enum RecordingSource {
  screen,
  window,
  area,
}
