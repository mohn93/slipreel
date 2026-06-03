import 'package:slipreel_engine/state/clip_slice.dart';

/// Direction of slice keyboard navigation.
enum NavDirection { next, previous }

/// Returns the next slice index for keyboard navigation.
///
/// - [currentIndex] < 0 means "no selection":
///     [NavDirection.next] -> 0
///     [NavDirection.previous] -> sliceCount - 1
/// - At a boundary (last + next, or first + previous) the [currentIndex]
///   is returned unchanged so the caller can render no-op feedback.
/// - Empty list returns -1.
int nextSliceIndex({
  required int currentIndex,
  required int sliceCount,
  required NavDirection direction,
}) {
  if (sliceCount <= 0) return -1;
  if (currentIndex < 0) {
    return direction == NavDirection.next ? 0 : sliceCount - 1;
  }
  if (direction == NavDirection.next) {
    return currentIndex >= sliceCount - 1 ? currentIndex : currentIndex + 1;
  }
  return currentIndex <= 0 ? currentIndex : currentIndex - 1;
}

/// Returns the edited-time start of the slice at [index] — the sum of
/// `editedLength` for all preceding slices.
///
/// Throws [RangeError] if [index] is out of bounds.
Duration sliceEditedStart(List<ClipSlice> clips, int index) {
  RangeError.checkValidIndex(index, clips);
  var acc = Duration.zero;
  for (var i = 0; i < index; i++) {
    acc += clips[i].editedLength;
  }
  return acc;
}
