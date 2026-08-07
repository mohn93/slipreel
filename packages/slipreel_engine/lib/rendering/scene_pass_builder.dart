import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/effects/ema_velocity_filter.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

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
    required this.enterCursorTarget,
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

  /// Raw-recording settle target sampled at the followCursor enter-ramp end,
  /// when one exists. Passed to [ZoomFocalController] and surfaced for runtime
  /// focal traces so preview logs can show whether the controller was aiming
  /// at the intended enter target.
  final Offset? enterCursorTarget;

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
  }) : motion = motion ?? CursorMotionController(),
       focal = focal ?? ZoomFocalController(),
       velocityFilter = velocityFilter ?? EmaVelocityFilter();

  final CursorMotionController motion;
  final ZoomFocalController focal;
  final EmaVelocityFilter velocityFilter;
  Duration? _lastPosition;
  int? _lastClipIndex;
  ClipSlice? _lastClip;

  /// Propagate a new [MotionTuning] to the owned spring controllers
  /// so a preset-picker swap or JSON reload takes effect on the next
  /// frame without disposing the springs' accumulated state.
  void setTuning(MotionTuning tuning) {
    motion.tuning = tuning;
    focal.tuning = tuning;
  }

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

    /// Clip slices for the current timeline, used to resolve the
    /// playback speed of the slice covering [position] (source time).
    /// Defaults to empty ⇒ speed 1.0 ⇒ cursor smoothing unchanged.
    List<ClipSlice> clips = const <ClipSlice>[],
    Curve screenRampCurve = Curves.easeInOutQuad,
    double rampDurationScale = 1.0,
    bool forceSnap = false,
    bool bypassVelocityFilter = false,

    /// When non-null, replaces the natural `ZoomRegion.activeAt`
    /// lookup result for this frame. Used by the editor's manual
    /// placement picker to live-preview a drag-in-flight rect, and by
    /// any other caller that wants to bypass timing-driven activation
    /// for one frame. Cleared by the caller when the preview ends.
    ZoomRegion? activeRegionOverride,

    /// Device-bezel framing that routes all focal clamps through the
    /// canvas geometry. Null ⇒ identity framing ⇒ byte-identical to
    /// the legacy no-device-frame behavior.
    ZoomFraming? framing,
  }) {
    // Resolve once, here in the shared builder, so preview and export —
    // the only two callers — cannot resolve slice speed differently.
    final activeClipIndex = clips.isEmpty
        ? 0
        : clipSliceIndexContaining(clips, position);
    final activeClip = clips.isEmpty || activeClipIndex < 0
        ? null
        : clips[activeClipIndex];
    final activeRun = clips.isEmpty
        ? null
        : contiguousClipRunBounds(clips, position);
    var crossedHardBoundary = forceSnap;
    if (clips.isNotEmpty && activeClipIndex < 0) {
      crossedHardBoundary = true;
    } else if (clips.isNotEmpty &&
        _lastClipIndex != null &&
        _lastClipIndex! >= 0) {
      if (_lastClipIndex! >= clips.length || _lastClip == null) {
        crossedHardBoundary = true;
      } else if (activeClipIndex != _lastClipIndex) {
        crossedHardBoundary =
            activeClipIndex < _lastClipIndex! ||
            activeClip!.trimStart != _lastClip!.trimEnd;
      } else if (activeClip != _lastClip &&
          (activeClip!.cutStart != _lastClip!.cutStart ||
              activeClip.cutEnd != _lastClip!.cutEnd)) {
        crossedHardBoundary = true;
      }
    }
    Duration? elapsedWallTime;
    final previousPosition = _lastPosition;
    if (previousPosition != null && !crossedHardBoundary) {
      elapsedWallTime = clips.isEmpty
          ? position - previousPosition
          : sourceToEdited(clips, position) -
                sourceToEdited(clips, previousPosition);
    }
    if (crossedHardBoundary) {
      focal.reset();
      velocityFilter.reset();
    }
    if (clips.isNotEmpty && activeClipIndex < 0) {
      motion.reset();
    }
    final playbackSpeed = activeClip?.playbackSpeed ?? 1.0;
    final effectiveCursorAnimationConfig = cursorAnimationConfigAt(
      clips: clips,
      position: position,
      base: cursorAnimationConfig,
    );
    final motionSample =
        hasCursorData && (clips.isEmpty || activeClipIndex >= 0)
        ? motion.update(
            position: position,
            cursorRecording: cursorRecording,
            config: effectiveCursorAnimationConfig,
            fps: fps,
            cursorDelay: cursorDelay,
            postProcess: cursorPostProcess,
            playbackSpeed: playbackSpeed,
            clipStart: activeRun?.start,
            clipEnd: activeRun?.end,
            elapsedWallTime: elapsedWallTime,
            forceSnap: crossedHardBoundary,
          )
        : null;

    final activeZoom =
        activeRegionOverride ?? _activeZoomAt(position, zoomRegions);
    // Every follow mode tracks the spring-smoothed sprite cursor so the camera
    // and the visible cursor never disagree. Smart's speed-aware look-ahead is
    // applied inside SmartFollowStrategy.
    final Offset? cursorForFocal = motionSample?.screenPos;

    final rawVelocity = motionSample?.velocityPxPerSec ?? Offset.zero;

    // SETTLE target for a followCursor enter pan: the RAW cursor at the
    // end of the enter ramp — where the cursor will be once the zoom is
    // fully in. The focal controller pans the enter straight here instead
    // of chasing the lagging smoothed cursor (whose catch-up path read as
    // "the zoom goes to the wrong spot then slides to the cursor"). Sampled
    // from the recording at a fixed source time, so play == scrub == export.
    Offset? enterCursorTarget;
    if (activeZoom != null && activeZoom.followCursor && hasCursorData) {
      // Sample the settle target at the RESOLVED enter-ramp end so it tracks
      // where the cursor actually is when the (feel-scaled) zoom completes.
      // ZoomRegion.resolvedRampsUs is the shared ramp geometry used by the
      // focal/transform math, so this includes the proportional squeeze a
      // region shorter than its own ramps gets — sampling the unsqueezed end
      // aims a short followCursor zoom at a cursor position it never reaches.
      final enterEnd =
          activeZoom.startTime +
          Duration(
            microseconds: activeZoom.resolvedRampsUs(rampDurationScale).enterUs,
          );
      var queryEnd = enterEnd - cursorDelay;
      ClipSlice? targetClip = clips.isEmpty
          ? null
          : clipSliceContaining(clips, enterEnd);
      if (targetClip == null) {
        for (final clip in clips.reversed) {
          if (clip.trimEnd == enterEnd) {
            targetClip = clip;
            break;
          }
        }
      }
      final targetConfig = targetClip?.disableSmoothMouse == true
          ? const CursorAnimationConfig.preset(CursorAnimationStyle.none)
          : cursorAnimationConfig;
      final targetRun = clips.isEmpty
          ? null
          : contiguousClipRunBounds(clips, enterEnd);
      final targetLower = targetRun?.start ?? targetClip?.trimStart;
      final targetUpper = targetRun?.end ?? targetClip?.trimEnd;
      if (targetLower != null && queryEnd < targetLower) {
        queryEnd = targetLower;
      }
      if (targetUpper != null && queryEnd > targetUpper) {
        queryEnd = targetUpper;
      }
      final sigma = targetConfig.pathSmoothingSigma;
      final raw = sigma <= Duration.zero
          ? cursorAtFiltered(cursorRecording, queryEnd, cursorPostProcess)
          : smoothedCursorAt(
              cursorRecording,
              queryEnd,
              cursorPostProcess,
              sigma,
              lowerBound: targetLower,
              upperBound: targetUpper,
            );
      if (raw != null) {
        enterCursorTarget = Offset(
          raw.x.toDouble().clamp(0, videoSize.width),
          raw.y.toDouble().clamp(0, videoSize.height),
        );
      }
    }

    final focalUpdate = focal.update(
      position: position,
      zoomRegions: zoomRegions,
      cursor: cursorForFocal,
      videoSize: videoSize,
      cursorVelocity: rawVelocity,
      forceSnap: crossedHardBoundary,
      activeRegionOverride: activeRegionOverride,
      screenRampCurve: screenRampCurve,
      rampDurationScale: rampDurationScale,
      enterCursorTarget: enterCursorTarget,
      framing: framing,
      playbackSpeed: playbackSpeed,
      elapsedWallTime: elapsedWallTime,
    );

    final filteredVelocity = bypassVelocityFilter
        ? rawVelocity
        : velocityFilter.filter(rawVelocity, position);

    _lastPosition = position;
    _lastClipIndex = activeClipIndex;
    _lastClip = activeClip;
    return ScenePass(
      motion: motionSample,
      activeZoom: activeZoom,
      cursorForFocal: cursorForFocal,
      enterCursorTarget: enterCursorTarget,
      focalUpdate: focalUpdate,
      rawCursorVelocity: rawVelocity,
      filteredCursorVelocity: filteredVelocity,
    );
  }

  // Delegates to [ZoomRegion.activeAt] so this matches the focal
  // controller and frame compositor at the closed end edge — at
  // `position == endTime` the just-ended region (or, for a shared
  // edge, the earlier one) is still reported as active. Debug overlays
  // and the predictive window setup downstream depend on this not
  // going null for the exit-ramp completion frame.
  ZoomRegion? _activeZoomAt(Duration position, List<ZoomRegion> regions) =>
      ZoomRegion.activeAt(position, regions);
}

/// Resolves the per-slice "Disable smooth mouse" override at [position].
/// Keeping this shared prevents the preview painter, camera replay, and export
/// compositor from selecting different cursor trajectories.
CursorAnimationConfig cursorAnimationConfigAt({
  required List<ClipSlice> clips,
  required Duration position,
  required CursorAnimationConfig base,
}) {
  if (clips.isEmpty || !clipSliceAt(clips, position).disableSmoothMouse) {
    return base;
  }
  return const CursorAnimationConfig.preset(CursorAnimationStyle.none);
}
