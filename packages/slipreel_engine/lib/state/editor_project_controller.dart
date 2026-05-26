import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
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

  void setPlaybackSpeed(double value) =>
      state = state.copyWith(playbackSpeed: value);

  void setFadeIn(Duration value) => state = state.copyWith(fadeIn: value);

  void setFadeOut(Duration value) => state = state.copyWith(fadeOut: value);

  void setMicGain(int percent) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(micGainPercent: percent));

  void setMicMuted(bool value) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(micMuted: value));

  void setSystemGain(int percent) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(systemGainPercent: percent));

  void setSystemMuted(bool value) => state = state.copyWith(
      audioMix: state.audioMix.copyWith(systemMuted: value));

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
    if (tracks.isEmpty) {
      return Timeline(zoomTracks: [ZoomTrack(regions: immutable)]);
    }
    final updated = List<ZoomTrack>.from(tracks);
    updated[0] = tracks[0].copyWith(regions: immutable);
    return Timeline(zoomTracks: updated);
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
}

/// Riverpod provider for the per-recording editor settings. Scoped via
/// a `ProviderScope` override on entry to the playback screen so each
/// opened recording gets its own controller seeded with the loaded
/// project state.
final editorProjectControllerProvider =
    StateNotifierProvider<EditorProjectController, EditorProjectState>(
  (ref) => EditorProjectController(),
);
