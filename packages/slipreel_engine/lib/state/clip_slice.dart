/// Slices sped past this factor have their audio auto-silenced in export and
/// preview — sped-up audio above ~4× is unusable (chipmunk noise). The mute is
/// DERIVED from speed (see [ClipSlice.audioSilencedBySpeed]); it never touches
/// the user's micMuted/systemMuted flags.
const double kSpeedAudioMuteThreshold = 4.0;

/// A temporal segment of the source video with its own playback,
/// audio, fade, and cursor settings. Sliceable timelines are addressed
/// via `Timeline.clips`.
///
/// Cut bounds (`cutStart`, `cutEnd`) are immutable — they're where the
/// user cut, fixing where the slice's source-range lives.
///
/// Trim bounds (`trimStart`, `trimEnd`) are mutable — they're the
/// effective playable range inside the cut bounds. Trimming inward
/// removes content from playback/export; dragging the trim handle
/// back outward restores it, up to the cut bound.
///
/// Invariants:
///   cutStart <= trimStart <= trimEnd <= cutEnd
///   trimEnd - trimStart >= 100ms (degenerate JSON gets clamped)
class ClipSlice {
  ClipSlice({
    required this.cutStart,
    required this.cutEnd,
    Duration? trimStart,
    Duration? trimEnd,
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    int micGainPercent = 100,
    this.micMuted = false,
    int systemGainPercent = 100,
    this.systemMuted = false,
    this.hideCursor = false,
    this.disableSmoothMouse = false,
  }) : trimStart = _clampTrimStart(cutStart, cutEnd, trimStart ?? cutStart),
       trimEnd = _clampTrimEnd(
         cutStart,
         cutEnd,
         _clampTrimStart(cutStart, cutEnd, trimStart ?? cutStart),
         trimEnd ?? cutEnd,
       ),
       micGainPercent = _clampGain(micGainPercent),
       systemGainPercent = _clampGain(systemGainPercent);

  final Duration cutStart;
  final Duration cutEnd;
  final Duration trimStart;
  final Duration trimEnd;
  final double playbackSpeed;
  final Duration fadeIn;
  final Duration fadeOut;
  final int micGainPercent;
  final bool micMuted;
  final int systemGainPercent;
  final bool systemMuted;
  final bool hideCursor;
  final bool disableSmoothMouse;

  /// B-era alias: pre-cut-tool callers asked for "the playable left
  /// edge" via `start` — that's the trim start now.
  Duration get start => trimStart;

  /// B-era alias: pre-cut-tool callers asked for "the playable right
  /// edge" via `end` — that's the trim end now.
  Duration get end => trimEnd;

  /// Total cut span (immutable cut bounds). Read by trim-handle clamp
  /// code: a trim handle can extend back out to its slice's cutEnd /
  /// cutStart.
  Duration get cutSpan => cutEnd - cutStart;

  /// Effective playable length in SOURCE time — the trim range, before
  /// any speed adjustment.
  Duration get effectiveLength => trimEnd - trimStart;

  /// Output-time length: how long this slice plays in the final edit
  /// after speed adjustment (`effectiveLength / playbackSpeed`). This
  /// is what drives the timeline's visual width and the total edited
  /// duration — a 30s slice at 2x speed renders as 15s on the ruler.
  Duration get editedLength {
    if (playbackSpeed <= 0) return effectiveLength;
    return Duration(
      microseconds: (effectiveLength.inMicroseconds / playbackSpeed).round(),
    );
  }

  /// True when the user has trimmed the slice's left side inward from
  /// the original cut. UI draws a notched chevron on this side to
  /// indicate "drag to restore".
  bool get isLeftTrimmed => trimStart > cutStart;

  /// True when the user has trimmed the slice's right side inward.
  bool get isRightTrimmed => trimEnd < cutEnd;

  /// Total trimmed-away duration, summed across both sides. Used by
  /// the slice-editor header subtitle ("trimmed Ns").
  Duration get trimmedDuration => cutSpan - effectiveLength;

  /// Whether this slice's audio should be dropped purely because it is sped up
  /// past [kSpeedAudioMuteThreshold]. Non-destructive: lowering the speed back
  /// to ≤ the threshold restores audio.
  bool get audioSilencedBySpeed => playbackSpeed > kSpeedAudioMuteThreshold;

  static const Duration _minLen = Duration(milliseconds: 100);

  static int _clampGain(int v) => v < 0 ? 0 : (v > 200 ? 200 : v);

  static Duration _clampTrimStart(Duration cs, Duration ce, Duration ts) {
    if (ts < cs) return cs;
    // Reserve room for at least _minLen between trimStart and cutEnd
    // (so trimEnd has somewhere to live).
    final cap = ce - _minLen;
    if (cap < cs) return cs; // degenerate cut span < _minLen
    if (ts > cap) return cap;
    return ts;
  }

  static Duration _clampTrimEnd(
    Duration cs,
    Duration ce,
    Duration ts,
    Duration te,
  ) {
    if (te > ce) te = ce;
    if (te < ts + _minLen) te = ts + _minLen;
    if (te > ce) te = ce; // unreachable unless cut span < _minLen
    return te;
  }

  ClipSlice copyWith({
    Duration? cutStart,
    Duration? cutEnd,
    Duration? trimStart,
    Duration? trimEnd,
    double? playbackSpeed,
    Duration? fadeIn,
    Duration? fadeOut,
    int? micGainPercent,
    bool? micMuted,
    int? systemGainPercent,
    bool? systemMuted,
    bool? hideCursor,
    bool? disableSmoothMouse,
  }) => ClipSlice(
    cutStart: cutStart ?? this.cutStart,
    cutEnd: cutEnd ?? this.cutEnd,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
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
    'cutStartMicros': cutStart.inMicroseconds,
    'cutEndMicros': cutEnd.inMicroseconds,
    'trimStartMicros': trimStart.inMicroseconds,
    'trimEndMicros': trimEnd.inMicroseconds,
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
    final csRaw = json['cutStartMicros'];
    final ceRaw = json['cutEndMicros'];
    if (csRaw is! num || ceRaw is! num) {
      throw const FormatException(
        'ClipSlice.fromJson: cutStartMicros and cutEndMicros are required',
      );
    }
    final cs = Duration(microseconds: csRaw.toInt());
    final ce = Duration(microseconds: ceRaw.toInt());
    final tsRaw = json['trimStartMicros'];
    final teRaw = json['trimEndMicros'];
    return ClipSlice(
      cutStart: cs,
      cutEnd: ce,
      trimStart: tsRaw is num ? Duration(microseconds: tsRaw.toInt()) : null,
      trimEnd: teRaw is num ? Duration(microseconds: teRaw.toInt()) : null,
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
      systemMuted: json['systemMuted'] is bool
          ? json['systemMuted'] as bool
          : false,
      hideCursor: json['hideCursor'] is bool
          ? json['hideCursor'] as bool
          : false,
      disableSmoothMouse: json['disableSmoothMouse'] is bool
          ? json['disableSmoothMouse'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipSlice &&
          other.cutStart == cutStart &&
          other.cutEnd == cutEnd &&
          other.trimStart == trimStart &&
          other.trimEnd == trimEnd &&
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
    cutStart,
    cutEnd,
    trimStart,
    trimEnd,
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

/// Returns the slice covering [position] in source time. Falls back to
/// the last slice when [position] is at or past the final trimEnd
/// (final-frame behaviour for cursor lookup); falls back to a fresh
/// empty slice when [clips] is empty.
///
/// This is the B-era helper kept for cursor/preview-cosmetic lookups
/// that always want SOME slice. The cut-tool playback-skip path uses
/// the strictly-containing variant in `edited_time.dart`.
ClipSlice clipSliceAt(List<ClipSlice> clips, Duration position) {
  if (clips.isEmpty) {
    return ClipSlice(cutStart: Duration.zero, cutEnd: Duration.zero);
  }
  for (final s in clips) {
    if (position >= s.trimStart && position < s.trimEnd) return s;
  }
  return clips.last;
}

/// Index of the slice that strictly contains [position] in source time.
/// Returns -1 in trimmed-away gaps and for an empty timeline.
int clipSliceIndexContaining(List<ClipSlice> clips, Duration position) {
  for (var i = 0; i < clips.length; i++) {
    final slice = clips[i];
    if (position >= slice.trimStart && position < slice.trimEnd) return i;
  }
  return -1;
}

/// The slice strictly containing [position], or null in a hard-cut gap.
ClipSlice? clipSliceContaining(List<ClipSlice> clips, Duration position) {
  final index = clipSliceIndexContaining(clips, position);
  return index < 0 ? null : clips[index];
}
