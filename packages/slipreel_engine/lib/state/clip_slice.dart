/// A temporal segment of the source video with its own playback,
/// audio, fade, and cursor settings. Sliceable timelines are
/// addressed via `Timeline.clips`; in sub-project B every project
/// has exactly one slice covering the whole video, sub-project C
/// introduces the cut tool that splits a slice into multiple.
class ClipSlice {
  ClipSlice({
    required this.start,
    required this.end,
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    int micGainPercent = 100,
    this.micMuted = false,
    int systemGainPercent = 100,
    this.systemMuted = false,
    this.hideCursor = false,
    this.disableSmoothMouse = false,
  })  : micGainPercent = _clampGain(micGainPercent),
        systemGainPercent = _clampGain(systemGainPercent);

  final Duration start;
  final Duration end;
  final double playbackSpeed;
  final Duration fadeIn;
  final Duration fadeOut;
  final int micGainPercent;
  final bool micMuted;
  final int systemGainPercent;
  final bool systemMuted;
  final bool hideCursor;
  final bool disableSmoothMouse;

  Duration get length => end - start;

  static int _clampGain(int v) => v < 0 ? 0 : (v > 200 ? 200 : v);

  ClipSlice copyWith({
    Duration? start,
    Duration? end,
    double? playbackSpeed,
    Duration? fadeIn,
    Duration? fadeOut,
    int? micGainPercent,
    bool? micMuted,
    int? systemGainPercent,
    bool? systemMuted,
    bool? hideCursor,
    bool? disableSmoothMouse,
  }) =>
      ClipSlice(
        start: start ?? this.start,
        end: end ?? this.end,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        micGainPercent: micGainPercent ?? this.micGainPercent,
        micMuted: micMuted ?? this.micMuted,
        systemGainPercent: systemGainPercent ?? this.systemGainPercent,
        systemMuted: systemMuted ?? this.systemMuted,
        hideCursor: hideCursor ?? this.hideCursor,
        disableSmoothMouse: disableSmoothMouse ?? this.disableSmoothMouse,
      );

  Map<String, dynamic> toJson() => {
        'startMicros': start.inMicroseconds,
        'endMicros': end.inMicroseconds,
        'playbackSpeed': playbackSpeed,
        'fadeInMicros': fadeIn.inMicroseconds,
        'fadeOutMicros': fadeOut.inMicroseconds,
        'micGainPercent': micGainPercent,
        'micMuted': micMuted,
        'systemGainPercent': systemGainPercent,
        'systemMuted': systemMuted,
        'hideCursor': hideCursor,
        'disableSmoothMouse': disableSmoothMouse,
      };

  factory ClipSlice.fromJson(Map<String, dynamic> json) {
    final startRaw = json['startMicros'];
    final endRaw = json['endMicros'];
    if (startRaw is! num || endRaw is! num) {
      throw const FormatException(
        'ClipSlice.fromJson: startMicros and endMicros are required',
      );
    }
    return ClipSlice(
      start: Duration(microseconds: startRaw.toInt()),
      end: Duration(microseconds: endRaw.toInt()),
      playbackSpeed: json['playbackSpeed'] is num
          ? (json['playbackSpeed'] as num).toDouble()
          : 1.0,
      fadeIn: json['fadeInMicros'] is num
          ? Duration(microseconds: (json['fadeInMicros'] as num).toInt())
          : Duration.zero,
      fadeOut: json['fadeOutMicros'] is num
          ? Duration(microseconds: (json['fadeOutMicros'] as num).toInt())
          : Duration.zero,
      micGainPercent: json['micGainPercent'] is num
          ? (json['micGainPercent'] as num).toInt()
          : 100,
      micMuted: json['micMuted'] is bool ? json['micMuted'] as bool : false,
      systemGainPercent: json['systemGainPercent'] is num
          ? (json['systemGainPercent'] as num).toInt()
          : 100,
      systemMuted:
          json['systemMuted'] is bool ? json['systemMuted'] as bool : false,
      hideCursor:
          json['hideCursor'] is bool ? json['hideCursor'] as bool : false,
      disableSmoothMouse: json['disableSmoothMouse'] is bool
          ? json['disableSmoothMouse'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipSlice &&
          other.start == start &&
          other.end == end &&
          other.playbackSpeed == playbackSpeed &&
          other.fadeIn == fadeIn &&
          other.fadeOut == fadeOut &&
          other.micGainPercent == micGainPercent &&
          other.micMuted == micMuted &&
          other.systemGainPercent == systemGainPercent &&
          other.systemMuted == systemMuted &&
          other.hideCursor == hideCursor &&
          other.disableSmoothMouse == disableSmoothMouse;

  @override
  int get hashCode => Object.hash(
        start,
        end,
        playbackSpeed,
        fadeIn,
        fadeOut,
        micGainPercent,
        micMuted,
        systemGainPercent,
        systemMuted,
        hideCursor,
        disableSmoothMouse,
      );
}

/// Returns the slice covering [position]. Falls back to the last slice
/// when [position] is at or past the final end (final frame); falls
/// back to a fresh empty slice when [clips] is empty. The lookup is
/// linear (O(n)) — fine for B (n=1) and for typical slice counts in C.
ClipSlice clipSliceAt(List<ClipSlice> clips, Duration position) {
  if (clips.isEmpty) {
    return ClipSlice(start: Duration.zero, end: Duration.zero);
  }
  for (final s in clips) {
    if (position >= s.start && position < s.end) return s;
  }
  return clips.last;
}
