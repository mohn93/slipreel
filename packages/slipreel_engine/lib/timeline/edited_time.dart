import 'package:slipreel_engine/state/clip_slice.dart';

/// Total edited timeline duration: sum of all slices' effectiveLength.
/// The visual timeline x-axis covers this duration; trimmed-away
/// portions of source time are not part of it.
Duration totalEditedDuration(List<ClipSlice> clips) {
  var acc = Duration.zero;
  for (final c in clips) {
    acc += c.effectiveLength;
  }
  return acc;
}

/// Maps an edited-time position to its corresponding source-time
/// position. Walks slices in order, consuming effectiveLength at each
/// step until [editedTime] is exhausted; the offset inside the
/// containing slice is added to that slice's trimStart.
///
/// If [editedTime] is past the end of the edited timeline, returns the
/// final slice's trimEnd. Returns zero on empty input.
Duration editedToSource(List<ClipSlice> clips, Duration editedTime) {
  if (clips.isEmpty) return Duration.zero;
  var acc = Duration.zero;
  for (final c in clips) {
    final next = acc + c.effectiveLength;
    if (editedTime <= next) {
      return c.trimStart + (editedTime - acc);
    }
    acc = next;
  }
  return clips.last.trimEnd;
}

/// Maps a source-time position back to its corresponding edited-time
/// position. Source positions inside trimmed-away regions (before a
/// slice's trimStart, between slices, or after the final trimEnd) snap
/// to the nearest edge in edited time — typically the start of the
/// next slice or the end of the timeline.
Duration sourceToEdited(List<ClipSlice> clips, Duration sourceTime) {
  if (clips.isEmpty) return Duration.zero;
  var acc = Duration.zero;
  for (final c in clips) {
    if (sourceTime < c.trimStart) return acc;
    if (sourceTime <= c.trimEnd) return acc + (sourceTime - c.trimStart);
    acc += c.effectiveLength;
  }
  return acc;
}

/// When playback reaches the end of a slice's trim range (or lands in
/// a removed region during a stray seek), returns the next valid
/// source-time position to jump to. Returns null when the entire
/// timeline has been consumed.
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
