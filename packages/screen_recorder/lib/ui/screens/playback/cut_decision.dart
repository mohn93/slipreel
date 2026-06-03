// packages/screen_recorder/lib/ui/screens/playback/cut_decision.dart
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/snap/snap_resolver.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

/// Returns the edited-time at which a Cmd+K cut should land, applying
/// snap when enabled and not overridden.
Duration decideCutTime({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required CursorRecording cursor,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) return playheadEdited;
  final candidates = <Duration>[
    for (final t in cursor.eventIndex.clickTimes) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  return resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  ).time;
}

/// Returns the snap target (for [SnapFlashOverlay]) corresponding to the
/// decision above, or null if the cut did NOT snap.
Duration? decideSnapTarget({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required CursorRecording cursor,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) return null;
  final candidates = <Duration>[
    for (final t in cursor.eventIndex.clickTimes) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  return resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  ).snappedFrom;
}
