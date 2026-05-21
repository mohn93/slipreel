import 'package:flutter/painting.dart';

import 'package:screen_recorder/effects/ema_velocity_filter.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/state/cursor_post_process.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';

/// Per-frame "scene state": everything both the live preview and the
/// export pipeline need to draw one frame. Produced by
/// [ScenePassBuilder]. Owning the stateful spring controllers in one
/// place means preview and export cannot drift — every consumer reads
/// the same focal, the same cursor sprite position, and the same
/// EMA-filtered cursor velocity.
///
/// Excludes pure-render artefacts (the zoom Transform matrix, the
/// scene-blur shader signal) because those are consumed differently by
/// each call site — preview wraps a `Transform` widget around a
/// CustomPaint tree, export builds a Canvas transform manually.
/// Sharing them would require dragging widget-tree concerns into the
/// builder. They can be derived from [focalUpdate] when needed.
class ScenePass {
  const ScenePass({
    required this.motion,
    required this.activeZoom,
    required this.cursorForFocal,
    required this.focalUpdate,
    required this.rawCursorVelocity,
    required this.filteredCursorVelocity,
  });

  /// Spring-smoothed cursor sprite sample for this frame, or null when
  /// the recording has no cursor data (legacy / window-source) or no
  /// sample is yet available at [Duration] zero.
  final CursorMotionUpdate? motion;

  /// The zoom region active at the current position, or null when the
  /// playhead is between regions.
  final ZoomRegion? activeZoom;

  /// The cursor position fed to the focal controller. In predictive
  /// follow mode this is the rolling median over the recording (dwell
  /// location). In every other mode this is `motion?.screenPos` — the
  /// spring-smoothed sprite — so the camera and the cursor visibly
  /// agree.
  final Offset? cursorForFocal;

  /// The zoom focal/region pair, or null when no zoom is active.
  final ZoomFocalUpdate? focalUpdate;

  /// Raw scene velocity of the cursor in px/s. Zero when motion is
  /// null. Fed unmodified to the [ZoomFocalController] gate.
  final Offset rawCursorVelocity;

  /// EMA-smoothed cursor velocity in px/s. Cursor motion blur uses
  /// this to avoid magnitude/direction flap on per-frame noise. Equals
  /// [rawCursorVelocity] when the filter was bypassed (hover-scrub).
  final Offset filteredCursorVelocity;
}

/// Single source of truth for per-frame scene state, shared by the
/// live preview ([PlaybackCanvas]) and the export pipeline
/// ([FrameCompositor]).
///
/// Owns three stateful pieces:
///
/// 1. [CursorMotionController] — spring smoothing for the cursor
///    sprite, plus the scene-velocity finite difference.
/// 2. [ZoomFocalController] — bounded / centered / predictive camera
///    follow with the velocity-aware deadzone gate.
/// 3. [EmaVelocityFilter] — smoothing for cursor motion blur so the
///    trail doesn't flap on per-frame velocity noise.
///
/// One instance per "scene playthrough" (preview canvas, export
/// session). [build] must be called in monotonically non-decreasing
/// [position] order — same as the underlying controllers' contract.
class ScenePassBuilder {
  ScenePassBuilder({
    CursorMotionController? motion,
    ZoomFocalController? focal,
    EmaVelocityFilter? velocityFilter,
  })  : motion = motion ?? CursorMotionController(),
        focal = focal ?? ZoomFocalController(),
        velocityFilter = velocityFilter ?? EmaVelocityFilter();

  final CursorMotionController motion;
  final ZoomFocalController focal;
  final EmaVelocityFilter velocityFilter;

  /// Compute one frame of scene state.
  ///
  /// [position] is the playhead. [hasCursorData] gates the cursor
  /// pipeline — pass false for legacy / window-source recordings where
  /// the cursor recording was never populated.
  ///
  /// [forceSnap] forces the focal controller to snap rather than
  /// spring-integrate; used during hover-scrub on the timeline so the
  /// preview reflects the user's exact playhead position. Export never
  /// passes this.
  ///
  /// [bypassVelocityFilter] short-circuits the EMA so the filtered
  /// velocity equals the raw velocity. Use during hover-scrub: with
  /// the filter engaged, the same timestamp would render differently
  /// depending on which direction the user scrubbed from.
  ScenePass build({
    required Duration position,
    required List<ZoomRegion> zoomRegions,
    required CursorAnimationConfig cursorAnimationConfig,
    required CursorRecording cursorRecording,
    required Size videoSize,
    required int fps,
    required bool hasCursorData,
    Duration cursorDelay = Duration.zero,
    CursorPostProcess cursorPostProcess = CursorPostProcess.none,
    bool forceSnap = false,
    bool bypassVelocityFilter = false,
  }) {
    final motionSample = hasCursorData
        ? motion.update(
            position: position,
            cursorRecording: cursorRecording,
            config: cursorAnimationConfig,
            fps: fps,
            cursorDelay: cursorDelay,
            postProcess: cursorPostProcess,
          )
        : null;

    // Predictive follow targets the dwell location, not the
    // instantaneous cursor — its whole purpose is to ignore brief
    // excursions and frame whatever the user is looking at. Other
    // modes track the spring sprite so the camera and the visible
    // cursor never disagree.
    final activeZoom = _activeZoomAt(position, zoomRegions);
    final Offset? cursorForFocal =
        activeZoom?.followMode == FollowMode.predictive
            ? medianCursorOver(
                recording: cursorRecording,
                t: position,
                window: activeZoom!.predictiveWindow,
              )
            : motionSample?.screenPos;

    final rawVelocity = motionSample?.velocityPxPerSec ?? Offset.zero;

    final focalUpdate = focal.update(
      position: position,
      zoomRegions: zoomRegions,
      cursor: cursorForFocal,
      videoSize: videoSize,
      cursorVelocity: rawVelocity,
      forceSnap: forceSnap,
    );

    final filteredVelocity = bypassVelocityFilter
        ? rawVelocity
        : velocityFilter.filter(rawVelocity, position);

    return ScenePass(
      motion: motionSample,
      activeZoom: activeZoom,
      cursorForFocal: cursorForFocal,
      focalUpdate: focalUpdate,
      rawCursorVelocity: rawVelocity,
      filteredCursorVelocity: filteredVelocity,
    );
  }

  ZoomRegion? _activeZoomAt(Duration position, List<ZoomRegion> regions) {
    for (final z in regions) {
      if (z.isActive(position)) return z;
    }
    return null;
  }
}
