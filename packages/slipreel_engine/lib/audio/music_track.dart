import 'dart:convert';

/// Sentinel so [MusicTrack.copyWith] can tell "leave endOverride as-is" apart
/// from an explicit "clear it back to null" (drag reached the video end).
const Object _unset = Object();

/// A single music bed, placed in edited (not source-video) time.
class MusicTrack {
  const MusicTrack({
    required this.path,
    required this.name,
    required this.sourceDuration,
    this.preset,
    this.start = 0,
    this.trimStart = 0,
    this.trimEnd,
    this.endOverride,
    this.volume = 0.3,
    this.muted = false,
    this.loop = true,
    this.fadeIn = 0.5,
    this.fadeOut = 1,
    this.duck = false,
  });
  final String path, name;
  final String? preset;
  final double sourceDuration, start, trimStart, volume, fadeIn, fadeOut;
  final double? trimEnd;

  /// Explicit end of the placed bed, in edited seconds. Null means the bed
  /// runs to its natural end — the video end when [loop] is on, or
  /// start + [segmentDuration] when it is off. Set by dragging the bar's
  /// right edge, so a looping bed can stop before the video does.
  final double? endOverride;
  final bool muted, loop, duck;
  double get end =>
      (trimEnd ?? sourceDuration).clamp(trimStart, sourceDuration);
  double get segmentDuration => end - trimStart;
  double length(double projectDuration) {
    final avail = (projectDuration - start).clamp(0.0, double.infinity);
    var len = loop ? avail : segmentDuration.clamp(0.0, avail);
    final eo = endOverride;
    if (eo != null) {
      final capped = (eo - start).clamp(0.0, avail);
      if (capped < len) len = capped;
    }
    return len.clamp(0.0, double.infinity).toDouble();
  }

  MusicTrack copyWith({
    double? start,
    double? trimStart,
    double? trimEnd,
    Object? endOverride = _unset,
    double? volume,
    bool? muted,
    bool? loop,
    double? fadeIn,
    double? fadeOut,
    bool? duck,
  }) => MusicTrack(
    path: path,
    name: name,
    sourceDuration: sourceDuration,
    preset: preset,
    start: start ?? this.start,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    endOverride: identical(endOverride, _unset)
        ? this.endOverride
        : (endOverride as num?)?.toDouble(),
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    loop: loop ?? this.loop,
    fadeIn: fadeIn ?? this.fadeIn,
    fadeOut: fadeOut ?? this.fadeOut,
    duck: duck ?? this.duck,
  );
  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'sourceDuration': sourceDuration,
    'preset': preset,
    'start': start,
    'trimStart': trimStart,
    'trimEnd': trimEnd,
    'endOverride': endOverride,
    'volume': volume,
    'muted': muted,
    'loop': loop,
    'fadeIn': fadeIn,
    'fadeOut': fadeOut,
    'duck': duck,
  };
  factory MusicTrack.fromJson(Map<String, dynamic> j) {
    double number(String key, double fallback, double max) {
      final v = j[key];
      return v is num && v.isFinite ? v.toDouble().clamp(0, max) : fallback;
    }

    final duration = number('sourceDuration', 0, 86400);
    final trim = number('trimStart', 0, duration);
    final eoRaw = j['endOverride'];
    return MusicTrack(
      path: j['path'] as String,
      name: j['name'] as String,
      preset: j['preset'] as String?,
      sourceDuration: duration,
      start: number('start', 0, 86400),
      trimStart: trim,
      trimEnd: j['trimEnd'] == null ? null : number('trimEnd', duration, duration).clamp(trim, duration),
      endOverride: eoRaw is num && eoRaw.isFinite
          ? eoRaw.toDouble().clamp(0.0, 86400.0)
          : null,
      volume: number('volume', 0.3, 2),
      muted: j['muted'] == true,
      loop: j['loop'] != false,
      fadeIn: number('fadeIn', 0.5, 60),
      fadeOut: number('fadeOut', 1, 60),
      duck: j['duck'] == true,
    );
  }
  @override
  bool operator ==(Object other) =>
      other is MusicTrack && jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
