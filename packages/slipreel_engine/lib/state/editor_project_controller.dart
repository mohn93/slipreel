import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

/// Single source of truth for per-recording editor settings.
///
/// Owns the same data the playback screen used to keep in private
/// `setState`-driven fields. Every inspector slider, toggle, or tab
/// action routes through one of the named mutators here, the new
/// [EditorProjectState] is published, and any widget reading the
/// provider via `ref.watch` rebuilds with the new value.
///
/// State is treated as immutable: every mutator builds the next state
/// via `state.copyWith(...)`, so undo/redo (P1-7) can push the
/// previous reference onto its stack without snapshotting.
class EditorProjectController extends StateNotifier<EditorProjectState> {
  EditorProjectController({EditorProjectState? initial})
      : super(initial ?? EditorProjectState.defaults());

  /// Public read accessor for the current state. `StateNotifier.state`
  /// is protected to subclasses; external callers (e.g.
  /// [EditorHistoryController], persistence, debug tooling) read
  /// through this without tripping the analyzer's
  /// invalid_use_of_protected_member warning.
  EditorProjectState get current => state;

  /// Swap the entire state. Used by the project loader: hand it a
  /// fully-built state and the controller pushes it through.
  void replace(EditorProjectState next) {
    state = next;
  }

  // ---- single-field mutators -------------------------------------------

  void setCursorSize(double value) =>
      state = state.copyWith(cursorSize: value);

  void setCursorStyle(CursorStyle value) =>
      state = state.copyWith(cursorStyle: value);

  void setCursorClickEffect(CursorClickEffect value) =>
      state = state.copyWith(cursorClickEffect: value);

  void setHideCursorOverlay(bool value) =>
      state = state.copyWith(hideCursorOverlay: value);

  void setMotionBlur(double value) =>
      state = state.copyWith(motionBlur: value);

  void setCursorMovementBlur(double value) =>
      state = state.copyWith(cursorMovementBlur: value);

  void setScreenMovementBlur(double value) =>
      state = state.copyWith(screenMovementBlur: value);

  void setScreenZoomBlur(double value) =>
      state = state.copyWith(screenZoomBlur: value);

  void setCursorShadow(double value) =>
      state = state.copyWith(cursorShadow: value);

  void setClickSpring(ClickSpring value) =>
      state = state.copyWith(clickSpring: value);

  void setCursorDelay(Duration value) =>
      state = state.copyWith(cursorDelay: value);

  void setCursorPostProcess(CursorPostProcess value) =>
      state = state.copyWith(cursorPostProcess: value);

  void setScreenAnimationConfig(ScreenAnimationConfig value) =>
      state = state.copyWith(screenAnimationConfig: value);

  void setCursorAnimationConfig(CursorAnimationConfig value) =>
      state = state.copyWith(cursorAnimationConfig: value);

  void setWindowFrame(WindowFrame value) =>
      state = state.copyWith(windowFrame: value);

  void setOutputAspect(OutputAspect value) =>
      state = state.copyWith(outputAspect: value);

  /// Set the timeline horizontal scale. Clamped to [1.0, 8.0]. The
  /// optional [anchorTime] is a one-shot hint stored on the next
  /// state's [EditorProjectState.pendingScaleAnchor] for the timeline
  /// widget to consume; the widget then calls
  /// [clearPendingScaleAnchor]. Persistence is handled by the
  /// playback screen's debounced `ref.listen` — no need to debounce
  /// here.
  void setTimelineScale(double scale, {Duration? anchorTime}) {
    final clamped = scale.isNaN ? 1.0 : scale.clamp(1.0, 8.0);
    if (clamped == state.timelineScale && anchorTime == null) return;
    state = state.copyWith(
      timelineScale: clamped,
      pendingScaleAnchor: anchorTime,
      clearPendingScaleAnchor: anchorTime == null,
    );
  }

  /// Reset the transient anchor hint. Called by the timeline widget
  /// after applying an anchor-preserving scale change. No-ops when
  /// the anchor is already null so it doesn't dirty the state stream.
  void clearPendingScaleAnchor() {
    if (state.pendingScaleAnchor == null) return;
    state = state.copyWith(clearPendingScaleAnchor: true);
  }

  // ---- zoom region list -------------------------------------------------
  //
  // Mutates the active (first) zoom track on the timeline. Reaches
  // into Timeline directly rather than going through the
  // `state.zoomRegions` getter shim — the controller is the place
  // where zoom data is *created*, so it should know the concrete
  // shape. UI read sites stay on the shim for now and will migrate
  // when the inspector grows multi-track awareness.

  /// Returns the regions of the active (first) zoom track, or an
  /// empty list when no tracks exist. Centralised so the mutators
  /// don't each re-derive the same lookup.
  List<ZoomRegion> _activeRegions() {
    final tracks = state.timeline.zoomTracks;
    return tracks.isEmpty ? const <ZoomRegion>[] : tracks.first.regions;
  }

  /// Returns the next timeline with [regions] installed on the active
  /// (first) zoom track. Creates a single track if the timeline is
  /// empty so first-write isn't a special case at the call site.
  Timeline _timelineWithActiveRegions(List<ZoomRegion> regions) {
    final immutable = List<ZoomRegion>.unmodifiable(regions);
    final tracks = state.timeline.zoomTracks;
    // Preserve existing clips — Timeline's constructor defaults clips to
    // const [], so omitting this here wipes the slice list whenever the
    // user adds/edits/removes a zoom region (clip lane goes blank).
    final clips = state.timeline.clips;
    if (tracks.isEmpty) {
      return Timeline(
        zoomTracks: [ZoomTrack(regions: immutable)],
        clips: clips,
      );
    }
    final updated = List<ZoomTrack>.from(tracks);
    updated[0] = tracks[0].copyWith(regions: immutable);
    return Timeline(zoomTracks: updated, clips: clips);
  }

  void replaceZoomRegions(List<ZoomRegion> regions) =>
      state = state.copyWith(timeline: _timelineWithActiveRegions(regions));

  void addZoom(ZoomRegion zoom) {
    final next = List<ZoomRegion>.from(_activeRegions())..add(zoom);
    state = state.copyWith(timeline: _timelineWithActiveRegions(next));
  }

  void updateZoomAt(int index, ZoomRegion zoom) {
    final regions = _activeRegions();
    if (index < 0 || index >= regions.length) return;
    final next = List<ZoomRegion>.from(regions);
    next[index] = zoom;
    state = state.copyWith(timeline: _timelineWithActiveRegions(next));
  }

  void removeZoomAt(int index) {
    final regions = _activeRegions();
    if (index < 0 || index >= regions.length) return;
    final next = List<ZoomRegion>.from(regions)..removeAt(index);
    state = state.copyWith(timeline: _timelineWithActiveRegions(next));
  }

  // ---- slice mutators ---------------------------------------------------

  ClipSlice? _slice(int sliceIndex) {
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return null;
    return clips[sliceIndex];
  }

  void _replaceSlice(int sliceIndex, ClipSlice next) {
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return;
    final updated = List<ClipSlice>.from(clips);
    updated[sliceIndex] = next;
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }

  void setSliceSpeed(int sliceIndex, double speed) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (speed.isNaN || !speed.isFinite) return;
    final clamped = speed.clamp(0.25, 4.0);
    if (clamped == s.playbackSpeed) return;
    _replaceSlice(sliceIndex, s.copyWith(playbackSpeed: clamped));
  }

  void setSliceFadeIn(int sliceIndex, Duration value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = value < Duration.zero ? Duration.zero : value;
    if (clamped == s.fadeIn) return;
    _replaceSlice(sliceIndex, s.copyWith(fadeIn: clamped));
  }

  void setSliceFadeOut(int sliceIndex, Duration value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = value < Duration.zero ? Duration.zero : value;
    if (clamped == s.fadeOut) return;
    _replaceSlice(sliceIndex, s.copyWith(fadeOut: clamped));
  }

  void setSliceMicGain(int sliceIndex, int percent) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = percent < 0 ? 0 : (percent > 200 ? 200 : percent);
    if (clamped == s.micGainPercent) return;
    _replaceSlice(sliceIndex, s.copyWith(micGainPercent: clamped));
  }

  void setSliceMicMuted(int sliceIndex, bool muted) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (muted == s.micMuted) return;
    _replaceSlice(sliceIndex, s.copyWith(micMuted: muted));
  }

  void setSliceSystemGain(int sliceIndex, int percent) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = percent < 0 ? 0 : (percent > 200 ? 200 : percent);
    if (clamped == s.systemGainPercent) return;
    _replaceSlice(sliceIndex, s.copyWith(systemGainPercent: clamped));
  }

  void setSliceSystemMuted(int sliceIndex, bool muted) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (muted == s.systemMuted) return;
    _replaceSlice(sliceIndex, s.copyWith(systemMuted: muted));
  }

  void setSliceHideCursor(int sliceIndex, bool value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (value == s.hideCursor) return;
    _replaceSlice(sliceIndex, s.copyWith(hideCursor: value));
  }

  void setSliceDisableSmoothMouse(int sliceIndex, bool value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (value == s.disableSmoothMouse) return;
    _replaceSlice(sliceIndex, s.copyWith(disableSmoothMouse: value));
  }

  /// Cuts the slice at [sliceIndex] into two at [sourcePosition].
  /// Both halves inherit all per-slice settings (speed, audio, fades,
  /// cursor flags). Returns false (and doesn't mutate state) if any
  /// precondition fails: out-of-range index, sourcePosition outside
  /// the slice's trim range, or fewer than 100ms on either side.
  bool splitSlice(int sliceIndex, Duration sourcePosition) {
    const minLen = Duration(milliseconds: 100);
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return false;
    final parent = clips[sliceIndex];
    if (sourcePosition - parent.trimStart < minLen) return false;
    if (parent.trimEnd - sourcePosition < minLen) return false;
    final left = parent.copyWith(
      cutEnd: sourcePosition,
      trimEnd: sourcePosition,
    );
    final right = parent.copyWith(
      cutStart: sourcePosition,
      trimStart: sourcePosition,
    );
    final updated = List<ClipSlice>.from(clips);
    updated.replaceRange(sliceIndex, sliceIndex + 1, [left, right]);
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
    return true;
  }

  /// Convenience: maps [editedPosition] (timeline-x-axis time) to
  /// source time, finds the containing slice, and splits there.
  /// [clips] is passed explicitly so the caller can avoid re-reading
  /// state in a tight UI event handler. Returns false when no slice
  /// contains the mapped source position or split preconditions fail.
  bool splitAtPlayhead(Duration editedPosition, List<ClipSlice> clips) {
    if (clips.isEmpty) return false;
    final sourcePosition = editedToSource(clips, editedPosition);
    for (var i = 0; i < clips.length; i++) {
      final s = clips[i];
      if (sourcePosition > s.trimStart && sourcePosition < s.trimEnd) {
        return splitSlice(i, sourcePosition);
      }
    }
    return false;
  }

  void setSliceTrimStart(int sliceIndex, Duration trimStart) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    var clamped = trimStart;
    if (clamped < s.cutStart) clamped = s.cutStart;
    final upper = s.trimEnd - const Duration(milliseconds: 100);
    if (clamped > upper) clamped = upper < s.cutStart ? s.cutStart : upper;
    if (clamped == s.trimStart) return;
    _replaceSlice(sliceIndex, s.copyWith(trimStart: clamped));
  }

  void setSliceTrimEnd(int sliceIndex, Duration trimEnd) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    var clamped = trimEnd;
    if (clamped > s.cutEnd) clamped = s.cutEnd;
    final lower = s.trimStart + const Duration(milliseconds: 100);
    if (clamped < lower) clamped = lower > s.cutEnd ? s.cutEnd : lower;
    if (clamped == s.trimEnd) return;
    _replaceSlice(sliceIndex, s.copyWith(trimEnd: clamped));
  }

  void removeSlice(int sliceIndex) {
    final clips = state.timeline.clips;
    if (clips.length <= 1) return;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return;
    final updated = List<ClipSlice>.from(clips)..removeAt(sliceIndex);
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }
}

/// Riverpod provider for the per-recording editor settings. Scoped via
/// a `ProviderScope` override on entry to the playback screen so each
/// opened recording gets its own controller seeded with the loaded
/// project state.
final editorProjectControllerProvider =
    StateNotifierProvider<EditorProjectController, EditorProjectState>(
  (ref) => EditorProjectController(),
);
