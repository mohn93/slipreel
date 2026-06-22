/// Which recorded audio track a caption track was transcribed from.
enum CaptionAudioSource {
  mic,
  system,
  mixed;

  String get label => switch (this) {
        CaptionAudioSource.mic => 'Microphone',
        CaptionAudioSource.system => 'System audio',
        CaptionAudioSource.mixed => 'Both (mixed)',
      };
}

/// One caption line shown over the video for the half-open time span
/// `[startMicros, endMicros)`. [id] is a stable handle for list keys and
/// edit operations; it is not interpreted by the renderer.
class CaptionSegment {
  const CaptionSegment({
    required this.id,
    required this.startMicros,
    required this.endMicros,
    required this.text,
  });

  final String id;
  final int startMicros;
  final int endMicros;
  final String text;

  Duration get start => Duration(microseconds: startMicros);
  Duration get end => Duration(microseconds: endMicros);

  /// Half-open `[startMicros, endMicros)` — matches `ZoomRegion`/`CameraRegion`
  /// so a shared edge resolves to the later segment with no one-frame overlap.
  bool isActiveAtMicros(int t) => t >= startMicros && t < endMicros;

  CaptionSegment copyWith({
    String? id,
    int? startMicros,
    int? endMicros,
    String? text,
  }) =>
      CaptionSegment(
        id: id ?? this.id,
        startMicros: startMicros ?? this.startMicros,
        endMicros: endMicros ?? this.endMicros,
        text: text ?? this.text,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'startMicros': startMicros,
        'endMicros': endMicros,
        'text': text,
      };

  factory CaptionSegment.fromJson(Map<String, dynamic> json) => CaptionSegment(
        id: json['id'] as String? ?? '',
        startMicros: (json['startMicros'] as num?)?.toInt() ?? 0,
        endMicros: (json['endMicros'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptionSegment &&
          other.id == id &&
          other.startMicros == startMicros &&
          other.endMicros == endMicros &&
          other.text == text;

  @override
  int get hashCode => Object.hash(id, startMicros, endMicros, text);
}
