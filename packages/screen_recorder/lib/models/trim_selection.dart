/// Represents a trim selection on a video timeline.
///
/// The trim selection defines the start and end points for trimming a video.
/// The constructor automatically swaps start/end if inverted and constrains
/// both values to be within the video duration.
class TrimSelection {
  /// The start position of the trim selection.
  final Duration start;

  /// The end position of the trim selection.
  final Duration end;

  /// The total duration of the video being trimmed.
  final Duration videoDuration;

  /// Creates a trim selection with the given start and end positions.
  ///
  /// Automatically swaps [start] and [end] if [start] > [end].
  /// Constrains both values to be within [0, videoDuration].
  TrimSelection({
    required Duration start,
    required Duration end,
    required this.videoDuration,
  })  : start = _constrain(start < end ? start : end, videoDuration),
        end = _constrain(start < end ? end : start, videoDuration);

  /// Constrains a duration to be within [0, videoDuration].
  static Duration _constrain(Duration value, Duration max) {
    if (value < Duration.zero) return Duration.zero;
    if (value > max) return max;
    return value;
  }

  /// The duration of the trim selection (end - start).
  Duration get duration => end - start;

  /// Returns true if the given [position] is within the trim selection.
  bool contains(Duration position) {
    return position >= start && position <= end;
  }

  /// Creates a copy of this trim selection with the given fields replaced.
  TrimSelection copyWith({
    Duration? start,
    Duration? end,
    Duration? videoDuration,
  }) {
    return TrimSelection(
      start: start ?? this.start,
      end: end ?? this.end,
      videoDuration: videoDuration ?? this.videoDuration,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrimSelection &&
        other.start == start &&
        other.end == end &&
        other.videoDuration == videoDuration;
  }

  @override
  int get hashCode => Object.hash(start, end, videoDuration);
}
