import 'package:slipreel_engine/state/clip_slice.dart';

/// Returns the total source-duration "hidden" at the seam between
/// `clips[seamIndex]` and `clips[seamIndex + 1]`. Sums:
///   1. The left slice's right-side trim (cutEnd - trimEnd).
///   2. The right slice's left-side trim (trimStart - cutStart).
///   3. Any source-time gap between the two slices' cut bounds
///      (right.cutStart - left.cutEnd), clamped to non-negative.
///
/// Returns Duration.zero for out-of-range seamIndex or empty clips.
Duration hiddenSecondsAtSeam(List<ClipSlice> clips, int seamIndex) {
  if (seamIndex < 0 || seamIndex >= clips.length - 1) return Duration.zero;
  final left = clips[seamIndex];
  final right = clips[seamIndex + 1];
  final leftTrim = left.cutEnd - left.trimEnd;
  final rightTrim = right.trimStart - right.cutStart;
  final gap = right.cutStart - left.cutEnd;
  final gapClamped = gap.isNegative ? Duration.zero : gap;
  return leftTrim + rightTrim + gapClamped;
}

/// Same as [hiddenSecondsAtSeam] but EXCLUDES the source-gap term.
/// Counts only what `clearSeamTrims` would actually restore — the
/// inner trim on either side of the seam. The cut-marker UI routes on
/// this: trim > 0 → first click clears trim, second merges. Gap-only
/// seams (left after slice deletion) go straight to merge on the
/// first click since there's no trim to restore.
Duration trimmedSecondsAtSeam(List<ClipSlice> clips, int seamIndex) {
  if (seamIndex < 0 || seamIndex >= clips.length - 1) return Duration.zero;
  final left = clips[seamIndex];
  final right = clips[seamIndex + 1];
  return (left.cutEnd - left.trimEnd) + (right.trimStart - right.cutStart);
}
