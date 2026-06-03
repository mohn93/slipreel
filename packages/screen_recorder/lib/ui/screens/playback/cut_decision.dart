import 'package:slipreel_engine/snap/snap_resolver.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

/// The post-snap cut decision for a Cmd+K or scissors-mode tap.
class CutDecision {
  const CutDecision({required this.time, required this.snapTarget});

  /// The edited-time at which the cut should land — either the raw
  /// playhead or a snapped candidate.
  final Duration time;

  /// The candidate that was snapped to (and that the UI flashes), or
  /// null if no snap occurred.
  final Duration? snapTarget;
}

/// Computes the cut-time + snap-flash target for a cut at [playheadEdited].
///
/// When [snapEnabled] is false or [overrideSnap] is true, returns the raw
/// playhead with no snap. Otherwise builds snap candidates from the
/// supplied source-time [clickTimesSource] plus [zoomEdgesSource] edges
/// (both mapped to edited-time via [sourceToEdited]), sorts them, and
/// queries [resolveSnap].
CutDecision decideCut({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required List<Duration> clickTimesSource,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) {
    return CutDecision(time: playheadEdited, snapTarget: null);
  }
  final candidates = <Duration>[
    for (final t in clickTimesSource) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  final result = resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  );
  return CutDecision(time: result.time, snapTarget: result.snappedFrom);
}
