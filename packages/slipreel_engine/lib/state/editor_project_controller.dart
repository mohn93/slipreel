import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

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

  // ---- zoom region list -------------------------------------------------

  void replaceZoomRegions(List<ZoomRegion> regions) =>
      state = state.copyWith(zoomRegions: List<ZoomRegion>.unmodifiable(regions));

  void addZoom(ZoomRegion zoom) {
    final next = List<ZoomRegion>.from(state.zoomRegions)..add(zoom);
    state = state.copyWith(zoomRegions: List.unmodifiable(next));
  }

  void updateZoomAt(int index, ZoomRegion zoom) {
    if (index < 0 || index >= state.zoomRegions.length) return;
    final next = List<ZoomRegion>.from(state.zoomRegions);
    next[index] = zoom;
    state = state.copyWith(zoomRegions: List.unmodifiable(next));
  }

  void removeZoomAt(int index) {
    if (index < 0 || index >= state.zoomRegions.length) return;
    final next = List<ZoomRegion>.from(state.zoomRegions)..removeAt(index);
    state = state.copyWith(zoomRegions: List.unmodifiable(next));
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
