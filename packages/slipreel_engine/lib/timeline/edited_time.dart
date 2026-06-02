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
      final sourceOffsetMicros =
          (editedOffset.inMicroseconds * c.playbackSpeed).round();
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
      final editedOffsetMicros =
          (sourceOffset.inMicroseconds / speed).round();
      return acc + Duration(microseconds: editedOffsetMicros);
    }
    acc += c.editedLength;
  }
  return acc;
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
