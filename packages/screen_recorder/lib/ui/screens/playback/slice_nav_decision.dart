import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart';

/// Outcome of a single slice keyboard-navigation press.
class SliceNavDecision {
  const SliceNavDecision({
    required this.nextIndex,
    required this.seekTo,
    required this.isBoundaryNoOp,
  });

  /// The slice index to select after the press.
  final int nextIndex;

  /// The edited-time to seek the player to.
  final Duration seekTo;

  /// True when the press fell on a boundary (last + next, first + prev)
  /// and the caller should render no-op feedback instead of advancing.
  final bool isBoundaryNoOp;
}

/// Returns the navigation outcome for a single Option+] / Option+[
/// press. Returns null when [clips] is empty so the caller can no-op.
SliceNavDecision? decideSliceNav({
  required int? currentIndex,
  required List<ClipSlice> clips,
  required NavDirection direction,
}) {
  if (clips.isEmpty) return null;
  final from = currentIndex ?? -1;
  final next = nextSliceIndex(
    currentIndex: from,
    sliceCount: clips.length,
    direction: direction,
  );
  if (next == from && from >= 0) {
    return SliceNavDecision(
      nextIndex: from,
      seekTo: sliceEditedStart(clips, from),
      isBoundaryNoOp: true,
    );
  }
  return SliceNavDecision(
    nextIndex: next,
    seekTo: sliceEditedStart(clips, next),
    isBoundaryNoOp: false,
  );
}
