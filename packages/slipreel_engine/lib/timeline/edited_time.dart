import 'package:slipreel_engine/state/clip_slice.dart';

final Expando<_PreparedClipTimeline> _preparedTimelines =
    Expando<_PreparedClipTimeline>('prepared clip timeline');

_PreparedClipTimeline _prepared(List<ClipSlice> clips) {
  // Only Timeline's immutable marker list is safe to memoize by identity.
  // Public helpers also accept ordinary mutable lists; rebuilding their small
  // index prevents append/replace/remove operations from observing stale
  // prefix sums or out-of-range run arrays.
  if (clips is! SourceOrderedClipList) return _PreparedClipTimeline(clips);
  return _preparedTimelines[clips] ??= _PreparedClipTimeline(clips);
}

class _PreparedClipTimeline {
  _PreparedClipTimeline(this.clips)
    : cumulativeEdited = List<Duration>.filled(clips.length + 1, Duration.zero),
      runFirst = List<int>.filled(clips.length, 0),
      runLast = List<int>.filled(clips.length, 0) {
    for (var i = 0; i < clips.length; i++) {
      cumulativeEdited[i + 1] = cumulativeEdited[i] + clips[i].editedLength;
      if (i > 0 && clips[i - 1].trimStart > clips[i].trimStart) {
        sorted = false;
      }
    }
    var first = 0;
    for (var i = 0; i < clips.length; i++) {
      if (i == 0 || clips[i - 1].trimEnd != clips[i].trimStart) first = i;
      runFirst[i] = first;
    }
    var last = clips.length - 1;
    for (var i = clips.length - 1; i >= 0; i--) {
      if (i == clips.length - 1 || clips[i].trimEnd != clips[i + 1].trimStart) {
        last = i;
      }
      runLast[i] = last;
    }
  }

  final List<ClipSlice> clips;
  final List<Duration> cumulativeEdited;
  final List<int> runFirst;
  final List<int> runLast;
  bool sorted = true;

  int containing(Duration position) {
    if (!sorted) {
      for (var i = 0; i < clips.length; i++) {
        if (position >= clips[i].trimStart && position < clips[i].trimEnd) {
          return i;
        }
      }
      return -1;
    }
    return clipSliceIndexContaining(clips, position);
  }

  ({Duration start, Duration end})? runBounds(Duration position) {
    var index = containing(position);
    if (index < 0) {
      // Preserve final-frame ownership at an exact trim end.
      if (!sorted) {
        index = clips.lastIndexWhere((clip) => clip.trimEnd == position);
      }
    }
    if (index < 0) {
      var lo = 0, hi = clips.length - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final cmp = clips[mid].trimEnd.compareTo(position);
        if (cmp == 0) {
          index = mid;
          break;
        }
        if (cmp < 0) {
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
    }
    if (index < 0) return null;
    return (
      start: clips[runFirst[index]].trimStart,
      end: clips[runLast[index]].trimEnd,
    );
  }

  Duration sourceToEdited(Duration sourceTime) {
    if (!sorted) {
      for (var i = 0; i < clips.length; i++) {
        final c = clips[i];
        if (sourceTime < c.trimStart) return cumulativeEdited[i];
        if (sourceTime <= c.trimEnd) return _insideEdited(i, sourceTime);
      }
      return cumulativeEdited.last;
    }
    var lo = 0, hi = clips.length - 1, candidate = clips.length;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (clips[mid].trimEnd >= sourceTime) {
        candidate = mid;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    if (candidate == clips.length) return cumulativeEdited.last;
    final clip = clips[candidate];
    if (sourceTime < clip.trimStart) return cumulativeEdited[candidate];
    return _insideEdited(candidate, sourceTime);
  }

  Duration editedToSource(Duration editedTime) {
    if (editedTime > cumulativeEdited.last) return clips.last.trimEnd;

    // Find the first cumulative end >= editedTime. Equality intentionally
    // belongs to the preceding clip, preserving the historical final-frame
    // behavior at an edited slice boundary.
    var lo = 1;
    var hi = cumulativeEdited.length - 1;
    var boundary = hi;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cumulativeEdited[mid] >= editedTime) {
        boundary = mid;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    final index = boundary - 1;
    final clip = clips[index];
    final editedOffset = editedTime - cumulativeEdited[index];
    final sourceOffsetMicros =
        (editedOffset.inMicroseconds * clip.playbackSpeed).round();
    return clip.trimStart + Duration(microseconds: sourceOffsetMicros);
  }

  Duration _insideEdited(int index, Duration sourceTime) {
    final clip = clips[index];
    final speed = clip.playbackSpeed > 0 ? clip.playbackSpeed : 1.0;
    final offset = ((sourceTime - clip.trimStart).inMicroseconds / speed)
        .round();
    return cumulativeEdited[index] + Duration(microseconds: offset);
  }
}

/// Total edited timeline duration: sum of each slice's [ClipSlice.editedLength]
/// (i.e. `effectiveLength / playbackSpeed`). The visual timeline x-axis
/// covers this duration; trimmed-away portions of source time are removed,
/// and per-slice speed compresses/expands the on-timeline width.
Duration totalEditedDuration(List<ClipSlice> clips) {
  if (clips.isEmpty) return Duration.zero;
  return _prepared(clips).cumulativeEdited.last;
}

/// Maps an edited-time position (timeline x-axis, output time) to its
/// corresponding SOURCE-time position. Walks slices in order, consuming
/// editedLength per step; inside the containing slice, the edited-time
/// offset multiplied by playbackSpeed is added to that slice's trimStart.
///
/// If [editedTime] is past the end of the edited timeline, returns the
/// final slice's trimEnd. Returns zero on empty input.
Duration editedToSource(List<ClipSlice> clips, Duration editedTime) {
  if (clips.isEmpty) return Duration.zero;
  return _prepared(clips).editedToSource(editedTime);
}

/// Maps a SOURCE-time position back to its corresponding edited-time
/// position. Inside a slice, the source offset from trimStart divided
/// by playbackSpeed yields the edited offset. Source positions in
/// trimmed-away regions snap to the nearest edge in edited time.
Duration sourceToEdited(List<ClipSlice> clips, Duration sourceTime) {
  if (clips.isEmpty) return Duration.zero;
  final prepared = _prepared(clips);
  return prepared.sourceToEdited(sourceTime);
}

/// Fraction (0..1) of the edited output completed once export has
/// consumed source time up to [sourcePosition].
///
/// Export feeds frames at SOURCE cadence but the output has EDITED
/// length — comparing a source-frame count against an edited-duration
/// denominator overshoots on any leading trim, gap, or speed != 1
/// (the progress bar pinned at 100% early). Mapping the source
/// position through [sourceToEdited] makes pre-trim and gap frames
/// contribute zero and sped-up slices advance at their edited rate.
///
/// With empty [clips] (no slice data), edited time equals source time;
/// [sourceFallbackTotal] (the probed source duration) becomes the
/// denominator. Returns null when no positive denominator exists —
/// callers should leave the bar indeterminate rather than lie.
double? editedProgressAtSource(
  List<ClipSlice> clips,
  Duration sourcePosition, {
  Duration? sourceFallbackTotal,
}) {
  final Duration done;
  final Duration total;
  if (clips.isEmpty) {
    if (sourceFallbackTotal == null) return null;
    done = sourcePosition;
    total = sourceFallbackTotal;
  } else {
    done = sourceToEdited(clips, sourcePosition);
    total = totalEditedDuration(clips);
  }
  if (total <= Duration.zero) return null;
  return (done.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);
}

/// Whether the source frame at [sourcePosition] can appear in the exported
/// output — i.e. it lies inside (or within [margin] of) some slice's
/// `[trimStart, trimEnd]` window. Frames outside every window are dropped by
/// ffmpeg's per-slice `trim=` nodes, so the export pipeline substitutes a
/// blank buffer for them instead of paying full composition.
///
/// [margin] absorbs frame-boundary rounding between the pipeline's
/// index/fps timestamps and the filter graph's fractional trim seconds:
/// blanking a frame ffmpeg unexpectedly keeps would flash black in the
/// output, so boundary frames within one frame period stay fully composed.
/// An empty [clips] list (no slice data) keeps every frame.
bool sourceFrameContributes(
  List<ClipSlice> clips,
  Duration sourcePosition, {
  required Duration margin,
}) {
  if (clips.isEmpty) return true;
  final prepared = _prepared(clips);
  if (!prepared.sorted) {
    for (final c in clips) {
      if (sourcePosition >= c.trimStart - margin &&
          sourcePosition <= c.trimEnd + margin) {
        return true;
      }
    }
    return false;
  }
  // Find the last slice whose expanded start is <= the frame. Only that slice
  // can contain the frame in a source-ordered, non-overlapping timeline.
  var lo = 0, hi = clips.length - 1, candidate = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (clips[mid].trimStart - margin <= sourcePosition) {
      candidate = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return candidate >= 0 && sourcePosition <= clips[candidate].trimEnd + margin;
}

/// Maps a wall/output-time lookback from [position] onto source time.
/// Traverses contiguous slices using each slice's speed and stops at a real
/// source discontinuity, so temporal effects never smear across a hard cut.
Duration sourceTimeBeforeWallDuration(
  List<ClipSlice> clips,
  Duration position,
  Duration wallLookback,
) {
  if (clips.isEmpty || wallLookback <= Duration.zero) return position;
  var index = _prepared(clips).containing(position);
  if (index < 0) return position;
  var sourceCursor = position;
  var remainingWallMicros = wallLookback.inMicroseconds.toDouble();

  while (index >= 0) {
    final slice = clips[index];
    final speed = slice.playbackSpeed > 0.05 ? slice.playbackSpeed : 0.05;
    final availableSourceMicros =
        sourceCursor.inMicroseconds - slice.trimStart.inMicroseconds;
    final availableWallMicros = availableSourceMicros / speed;
    if (remainingWallMicros <= availableWallMicros) {
      return Duration(
        microseconds:
            sourceCursor.inMicroseconds - (remainingWallMicros * speed).round(),
      );
    }

    remainingWallMicros -= availableWallMicros;
    if (index == 0 || clips[index - 1].trimEnd != slice.trimStart) {
      return slice.trimStart;
    }
    index--;
    sourceCursor = clips[index].trimEnd;
  }
  return clips.first.trimStart;
}

/// Start of the contiguous edited run containing [position].
Duration contiguousClipRunStart(List<ClipSlice> clips, Duration position) {
  return contiguousClipRunBounds(clips, position)?.start ?? position;
}

/// Source-time bounds of the maximal contiguous slice run containing
/// [position]. If the position is an otherwise-unowned exact trim end, the
/// preceding slice owns that final frame. Ordinary splits remain one
/// trajectory; only a real source gap creates a clamp boundary for cursor
/// delay and path smoothing.
({Duration start, Duration end})? contiguousClipRunBounds(
  List<ClipSlice> clips,
  Duration position,
) {
  if (clips.isEmpty) return null;
  return _prepared(clips).runBounds(position);
}

/// The lower/upper clamp for dragging a region's edge (zoom or camera pill),
/// expressed in EDITED time so the visual gap to neighbors stays constant.
///
/// [prevEndSource]/[nextStartSource] are the adjacent regions' bounds in
/// SOURCE time and are mapped through [sourceToEdited]. The open-ended
/// fallbacks — when a region has no neighbor on that side — are the timeline
/// extremes (`0` and [timelineDuration]) which are ALREADY in edited time and
/// must NOT be re-mapped. Passing [timelineDuration] through [sourceToEdited]
/// double-compresses it on sped-up/trimmed clips, capping the region short of
/// the real timeline end (the M2 bug).
({Duration min, Duration max}) editedRegionDragBounds({
  required List<ClipSlice> clips,
  required Duration? prevEndSource,
  required Duration? nextStartSource,
  required Duration timelineDuration,
}) {
  Duration toEdited(Duration t) => clips.isEmpty ? t : sourceToEdited(clips, t);
  return (
    min: prevEndSource != null ? toEdited(prevEndSource) : Duration.zero,
    max: nextStartSource != null ? toEdited(nextStartSource) : timelineDuration,
  );
}

/// When playback reaches the end of a slice's trim range (or lands in
/// a removed region during a stray seek), returns the next valid
/// source-time position to jump to. Returns null when the entire
/// timeline has been consumed. Speed-independent — operates entirely
/// in source time.
///
/// - Before any slice's trimStart -> first slice's trimStart.
/// - Inside [trimStart, trimEnd) -> the same position (no skip needed).
/// - At trimEnd or in a between-slices gap -> next slice's trimStart.
/// - Past final trimEnd -> null.
Duration? nextPlayPosition(List<ClipSlice> clips, Duration sourcePosition) {
  for (final c in clips) {
    if (sourcePosition < c.trimStart) return c.trimStart;
    if (sourcePosition < c.trimEnd) return sourcePosition;
  }
  return null;
}
