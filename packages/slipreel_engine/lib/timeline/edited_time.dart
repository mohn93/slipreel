import 'package:slipreel_engine/state/clip_slice.dart';

/// Total edited timeline duration: sum of each slice's [ClipSlice.editedLength]
/// (i.e. `effectiveLength / playbackSpeed`). The visual timeline x-axis
/// covers this duration; trimmed-away portions of source time are removed,
/// and per-slice speed compresses/expands the on-timeline width.
Duration totalEditedDuration(List<ClipSlice> clips) {
  var acc = Duration.zero;
  for (final c in clips) {
    acc += c.editedLength;
  }
  return acc;
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
  var acc = Duration.zero;
  for (final c in clips) {
    final next = acc + c.editedLength;
    if (editedTime <= next) {
      final editedOffset = editedTime - acc;
      final sourceOffsetMicros = (editedOffset.inMicroseconds * c.playbackSpeed)
          .round();
      return c.trimStart + Duration(microseconds: sourceOffsetMicros);
    }
    acc = next;
  }
  return clips.last.trimEnd;
}

/// Maps a SOURCE-time position back to its corresponding edited-time
/// position. Inside a slice, the source offset from trimStart divided
/// by playbackSpeed yields the edited offset. Source positions in
/// trimmed-away regions snap to the nearest edge in edited time.
Duration sourceToEdited(List<ClipSlice> clips, Duration sourceTime) {
  if (clips.isEmpty) return Duration.zero;
  var acc = Duration.zero;
  for (final c in clips) {
    if (sourceTime < c.trimStart) return acc;
    if (sourceTime <= c.trimEnd) {
      final sourceOffset = sourceTime - c.trimStart;
      final speed = c.playbackSpeed > 0 ? c.playbackSpeed : 1.0;
      final editedOffsetMicros = (sourceOffset.inMicroseconds / speed).round();
      return acc + Duration(microseconds: editedOffsetMicros);
    }
    acc += c.editedLength;
  }
  return acc;
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
  for (final c in clips) {
    if (sourcePosition >= c.trimStart - margin &&
        sourcePosition <= c.trimEnd + margin) {
      return true;
    }
  }
  return false;
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
  var index = clipSliceIndexContaining(clips, position);
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
  var activeIndex = clipSliceIndexContaining(clips, position);
  if (activeIndex < 0) {
    activeIndex = clips.lastIndexWhere((clip) => clip.trimEnd == position);
  }
  if (activeIndex < 0) return null;
  var first = activeIndex;
  var last = activeIndex;
  while (first > 0 && clips[first - 1].trimEnd == clips[first].trimStart) {
    first--;
  }
  while (last + 1 < clips.length &&
      clips[last].trimEnd == clips[last + 1].trimStart) {
    last++;
  }
  return (start: clips[first].trimStart, end: clips[last].trimEnd);
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
