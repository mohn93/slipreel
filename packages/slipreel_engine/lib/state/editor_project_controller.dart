import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
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

  void setKeystrokeOverlay(KeystrokeOverlaySettings value) =>
      state = state.copyWith(keystrokeOverlay: value);

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
  ///
  /// Uses [Timeline.copyWith] so that ALL other timeline fields
  /// (clips, cameraTracks, …) are preserved — the raw [Timeline]
  /// constructor defaults those to `const []`, which silently wiped
  /// the camera lane on every zoom mutation before this fix.
  Timeline _timelineWithActiveRegions(List<ZoomRegion> regions) {
    final immutable = List<ZoomRegion>.unmodifiable(regions);
    final tracks = state.timeline.zoomTracks;
    if (tracks.isEmpty) {
      return state.timeline.copyWith(
        zoomTracks: [ZoomTrack(regions: immutable)],
      );
    }
    final updated = List<ZoomTrack>.from(tracks)
      ..[0] = tracks[0].copyWith(regions: immutable);
    return state.timeline.copyWith(zoomTracks: updated);
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

  // ---- camera region list + settings ------------------------------------
  //
  // Mirrors the zoom-region mutators: operate on the active (first) camera
  // track, creating it on first write so call sites aren't special-cased.

  void setCameraSettings(CameraSettings settings) {
    if (settings == state.cameraSettings) return;
    state = state.copyWith(cameraSettings: settings);
  }

  List<CameraRegion> _activeCameraRegions() {
    final tracks = state.timeline.cameraTracks;
    return tracks.isEmpty ? const <CameraRegion>[] : tracks.first.regions;
  }

  Timeline _timelineWithActiveCameraRegions(List<CameraRegion> regions) {
    final immutable = List<CameraRegion>.unmodifiable(regions);
    final tracks = state.timeline.cameraTracks;
    if (tracks.isEmpty) {
      return state.timeline.copyWith(
        cameraTracks: [CameraTrack(regions: immutable)],
      );
    }
    final updated = List<CameraTrack>.from(tracks)
      ..[0] = tracks[0].copyWith(regions: immutable);
    return state.timeline.copyWith(cameraTracks: updated);
  }

  void replaceCameraRegions(List<CameraRegion> regions) => state =
      state.copyWith(timeline: _timelineWithActiveCameraRegions(regions));

  void addCameraRegion(CameraRegion region) {
    final next = List<CameraRegion>.from(_activeCameraRegions())..add(region);
    state = state.copyWith(timeline: _timelineWithActiveCameraRegions(next));
  }

  void updateCameraRegionAt(int index, CameraRegion region) {
    final regions = _activeCameraRegions();
    if (index < 0 || index >= regions.length) return;
    final next = List<CameraRegion>.from(regions)..[index] = region;
    state = state.copyWith(timeline: _timelineWithActiveCameraRegions(next));
  }

  void removeCameraRegionAt(int index) {
    final regions = _activeCameraRegions();
    if (index < 0 || index >= regions.length) return;
    final next = List<CameraRegion>.from(regions)..removeAt(index);
    state = state.copyWith(timeline: _timelineWithActiveCameraRegions(next));
  }

  // ---- Captions ---------------------------------------------------------

  void setCaptionStyle(CaptionStyle value) =>
      state = state.copyWith(captionStyle: value);

  void setCaptionSource(CaptionAudioSource source) =>
      state = state.copyWith(captionSource: source);

  void replaceCaptionSegments(List<CaptionSegment> segments) =>
      state = state.copyWith(captionSegments: List.unmodifiable(segments));

  void updateCaptionTextAt(int index, String text) {
    final list = state.captions;
    if (index < 0 || index >= list.length) return;
    final next = List<CaptionSegment>.from(list);
    next[index] = next[index].copyWith(text: text);
    state = state.copyWith(captionSegments: next);
  }

  void updateCaptionTimingAt(int index, {int? startMicros, int? endMicros}) {
    final list = state.captions;
    if (index < 0 || index >= list.length) return;
    final next = List<CaptionSegment>.from(list);
    next[index] = next[index]
        .copyWith(startMicros: startMicros, endMicros: endMicros);
    state = state.copyWith(captionSegments: next);
  }

  void removeCaptionAt(int index) {
    final list = state.captions;
    if (index < 0 || index >= list.length) return;
    final next = List<CaptionSegment>.from(list)..removeAt(index);
    state = state.copyWith(captionSegments: next);
  }

  void splitCaptionAt(int index, int atMicros) {
    final list = state.captions;
    if (index < 0 || index >= list.length) return;
    final seg = list[index];
    if (atMicros <= seg.startMicros || atMicros >= seg.endMicros) return;
    final next = List<CaptionSegment>.from(list);
    next[index] = seg.copyWith(endMicros: atMicros);
    next.insert(
      index + 1,
      CaptionSegment(
        id: '${seg.id}.s$atMicros',
        startMicros: atMicros,
        endMicros: seg.endMicros,
        text: '',
      ),
    );
    state = state.copyWith(captionSegments: next);
  }

  void mergeCaptionWithNext(int index) {
    final list = state.captions;
    if (index < 0 || index + 1 >= list.length) return;
    final a = list[index];
    final b = list[index + 1];
    final mergedText = [a.text, b.text]
        .where((t) => t.isNotEmpty)
        .join(' ');
    final next = List<CaptionSegment>.from(list);
    next[index] = a.copyWith(endMicros: b.endMicros, text: mergedText);
    next.removeAt(index + 1);
    state = state.copyWith(captionSegments: next);
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
    final clamped = speed.clamp(0.25, 24.0);
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

  // m7: the inspector's "Recording audio" volume/mute is a single GLOBAL
  // control, but a cut splits the timeline into multiple slices. These apply
  // the change to every slice in one state update so later slices aren't left
  // behind at the old level.
  void setAllMicGain(int percent) {
    final clamped = percent < 0 ? 0 : (percent > 200 ? 200 : percent);
    _mapAllSlices((s) =>
        s.micGainPercent == clamped ? s : s.copyWith(micGainPercent: clamped));
  }

  void setAllMicMuted(bool muted) {
    _mapAllSlices((s) => s.micMuted == muted ? s : s.copyWith(micMuted: muted));
  }

  void setAllSystemGain(int percent) {
    final clamped = percent < 0 ? 0 : (percent > 200 ? 200 : percent);
    _mapAllSlices((s) => s.systemGainPercent == clamped
        ? s
        : s.copyWith(systemGainPercent: clamped));
  }

  void setAllSystemMuted(bool muted) {
    _mapAllSlices(
        (s) => s.systemMuted == muted ? s : s.copyWith(systemMuted: muted));
  }

  /// Maps [f] over every slice and commits once. No-ops (no notification) when
  /// [f] returns the same instance for all slices — preserving the
  /// setX(currentX)-is-a-no-op invariant the per-slice setters hold.
  void _mapAllSlices(ClipSlice Function(ClipSlice) f) {
    final clips = state.timeline.clips;
    if (clips.isEmpty) return;
    final updated = [for (final c in clips) f(c)];
    var changed = false;
    for (var i = 0; i < clips.length; i++) {
      if (!identical(updated[i], clips[i])) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
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

  /// First-click action for a cut marker: resets the inner trims of
  /// both slices adjacent to the seam at [seamIndex] back to their cut
  /// bounds. Atomic — one state mutation, one undo step.
  ///
  /// Idempotent: if both inner trims are already at their cut bounds,
  /// the state reference is left unchanged.
  void clearSeamTrims(int seamIndex) {
    final clips = state.timeline.clips;
    if (seamIndex < 0 || seamIndex >= clips.length - 1) return;
    final left = clips[seamIndex];
    final right = clips[seamIndex + 1];
    final newLeft = left.trimEnd == left.cutEnd
        ? left
        : left.copyWith(trimEnd: left.cutEnd);
    final newRight = right.trimStart == right.cutStart
        ? right
        : right.copyWith(trimStart: right.cutStart);
    if (newLeft == left && newRight == right) return;
    final updated = List<ClipSlice>.from(clips)
      ..[seamIndex] = newLeft
      ..[seamIndex + 1] = newRight;
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }

  /// Second-click action for a cut marker: fuses the two slices
  /// adjacent to the seam at [seamIndex] into a single slice covering
  /// the full source range from `left.cutStart` to `right.cutEnd`. The
  /// outer trim bounds (left.trimStart, right.trimEnd) are preserved
  /// where possible — `ClipSlice`'s constructor clamps them into the
  /// new cut span if a non-adjacent source boundary pulls them out of
  /// range. Atomic — one state mutation, one undo step.
  void mergeSeam(int seamIndex) {
    final clips = state.timeline.clips;
    if (seamIndex < 0 || seamIndex >= clips.length - 1) return;
    final left = clips[seamIndex];
    final right = clips[seamIndex + 1];
    final merged = ClipSlice(
      cutStart: left.cutStart,
      cutEnd: right.cutEnd,
      trimStart: left.trimStart,
      trimEnd: right.trimEnd,
      playbackSpeed: left.playbackSpeed,
      fadeIn: left.fadeIn,
      fadeOut: right.fadeOut,
      micGainPercent: left.micGainPercent,
      micMuted: left.micMuted,
      systemGainPercent: left.systemGainPercent,
      systemMuted: left.systemMuted,
      hideCursor: left.hideCursor,
      disableSmoothMouse: left.disableSmoothMouse,
    );
    final updated = List<ClipSlice>.from(clips)
      ..[seamIndex] = merged
      ..removeAt(seamIndex + 1);
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
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
