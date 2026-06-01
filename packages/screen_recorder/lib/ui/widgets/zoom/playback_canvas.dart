import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';
import 'package:slipreel_engine/effects/motion_blur_tuning.dart';
import 'package:slipreel_engine/effects/scene_accumulation_painter.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/frame_painter.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/rendering/cursor_overlay_painter.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_debug_painter.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';

/// The composed playback canvas: wallpaper layer, framed video,
/// cursor overlay, optional debug HUD, all wrapped in a zoom Transform
/// that pushes the entire composition together when a zoom region is
/// active. Sized via AspectRatio + FittedBox so the canvas scales to
/// fit its parent without distorting the source aspect ratio.
///
/// Owns three per-frame controllers — [ZoomTransformer],
/// [ZoomFocalController], [CursorMotionController] — so the parent
/// screen doesn't need to manage their lifecycles or expose their
/// state. Reads its inputs purely as widget props; settings flow in
/// through [frame] / [screenAnimationConfig] /
/// [cursorAnimationConfig] etc., and changes there rebuild the canvas
/// without rebuilding the surrounding shell.

/// Per-frame trace of the VISIBLE camera focal (the spring-driven
/// `ZoomFocalController` output that positions the rendered frame),
/// gated so it only logs when an agent flips it via
/// `ext.slipreel.setCameraFocalTrace`. Off by default — every frame
/// emits a `[CamFocal]` line when on. Used to characterize camera
/// jumps (smooth fast pan vs. gate snap/overshoot) that the
/// scene-blur trace can't see.
bool cameraFocalTraceEnabled = false;

class PlaybackCanvas extends ConsumerStatefulWidget {
  const PlaybackCanvas({
    super.key,
    required this.controller,
    required this.smoothPlayhead,
    required this.frame,
    required this.metadata,
    required this.cursorRecording,
    required this.hideCursorOverlay,
    required this.cursorSize,
    required this.cursorStyle,
    required this.cursorClickEffect,
    required this.showZoomDebug,
    required this.zoomRegions,
    required this.screenAnimationConfig,
    required this.cursorAnimationConfig,
    required this.motionBlur,
    this.cursorMovementBlur = 1.0,
    this.screenMovementBlur = 1.0,
    this.screenZoomBlur = 1.0,
    required this.motionBlurTuning,
    required this.cursorShadow,
    required this.clickSpring,
    required this.isHoverScrubbing,
    this.cursorDelay = Duration.zero,
    this.cursorBlurMode = CursorBlurMode.shader,
    this.accumulationExposureMs = 40.0,
    this.accumulationSampleCount = 32,
    this.accumulationCameraFocalAt,
    this.accumulationCameraScaleAt,
    this.cursorTypeChangeBlurSigmaPx = 0.0,
    this.cursorTypeChangeBlurHalfWidthMs,
    this.cursorPostProcess = CursorPostProcess.none,
    this.sceneBlurMode = SceneBlurMode.shader,
    this.sceneAccumSampleCount = 16,
    this.debugSnapshot,
    this.zoomPreviewOverride,
    required this.outputAspect,
  });

  final VideoPlayerController controller;
  final SmoothPlayheadController? smoothPlayhead;
  /// Chrome (wallpaper, padding, corners, shadow, blur) for the current
  /// recording. Read on every build to derive the composition layout
  /// and drive scene-blur capture invalidation.
  final WindowFrame frame;
  final RecordingMetadata? metadata;
  final CursorRecording cursorRecording;
  final bool hideCursorOverlay;
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;
  final bool showZoomDebug;

  /// When set AND [showZoomDebug] is true, every build publishes a
  /// fresh [ZoomDebugSnapshot] of the controller's state so the
  /// playback screen can render the readout in screen-fixed
  /// coordinates outside the zoom Transform. The on-canvas painter
  /// still draws the visual overlays (focal ring, deadzone box,
  /// trail) — those need to live inside the Transform to align with
  /// the video pixels.
  final ValueNotifier<ZoomDebugSnapshot?>? debugSnapshot;

  /// Editor-only: when non-null, the canvas reads its current value
  /// per build and passes it to `ScenePassBuilder.build` so a manual
  /// placement-picker drag live-previews the proposed rect. Pure
  /// playback callers leave this null.
  final ZoomPreviewOverride? zoomPreviewOverride;

  final List<ZoomRegion> zoomRegions;
  final ScreenAnimationConfig screenAnimationConfig;
  final CursorAnimationConfig cursorAnimationConfig;

  /// Slider value 0..1 from the inspector's Animation tab. 0 means
  /// "no motion blur" and short-circuits the screen ImageFilter and
  /// the cursor multi-stamp path.
  final double motionBlur;
  final double cursorMovementBlur;
  final double screenMovementBlur;
  final double screenZoomBlur;

  /// Live-tunable knobs for the motion-blur path (debug UI). See
  /// [MotionBlurTuning] for the available levers.
  final MotionBlurTuning motionBlurTuning;

  /// Slider 0..1 from the cursor inspector. 0 disables the soft drop
  /// shadow rendered under every cursor glyph; values closer to 1
  /// push it further down with more blur and opacity.
  final double cursorShadow;

  /// Spring controlling the press-pulse animation (cursor shrinks on
  /// mousedown, snaps back on mouseup). Tuned in the cursor tab's
  /// Springs section; default is snappy / critically damped.
  final ClickSpring clickSpring;

  /// Debug knob — shifts the cursor track's *query* time backward by
  /// this much, so the rendered cursor sprite shows the recorded
  /// position from N ms ago. Lets the user offset our overlay to
  /// visually sync with an app's UI redraw delay (a button highlight
  /// that takes 100 ms to animate would need ~100 ms of delay so the
  /// cursor sprite arrives at the button the same moment the highlight
  /// shows in the recording). Zero = no delay = current behavior.
  final Duration cursorDelay;

  /// True when the user is hover-scrubbing the timeline (mouse hover,
  /// no real playback running). The cursor- and zoom-related stateful
  /// smoothers (EMA velocity, focal-tween catch-up) are bypassed in
  /// this mode so the preview at any timestamp T is deterministic —
  /// a forward and a backward approach to the same T render the same
  /// frame, matching what the user expects from a scrub preview.
  final bool isHoverScrubbing;

  /// Which cursor motion-blur pipeline to use. [CursorBlurMode.shader]
  /// is the production path: a chord-stretched single sprite produced
  /// by the motion-blur fragment program. [CursorBlurMode.accumulation]
  /// is the new path: the cursor sprite is stamped at sub-frame
  /// positions across the exposure window with 1/N alpha each, so
  /// the smear follows the actual recorded path (the cinematic
  /// motion-blur approach Screen Studio uses). The playground wires
  /// this up so we can A/B both pipelines under the full chrome +
  /// zoom transform.
  final CursorBlurMode cursorBlurMode;

  /// Virtual shutter window for [CursorBlurMode.accumulation] in ms.
  final double accumulationExposureMs;

  /// Number of sub-frame stamps for [CursorBlurMode.accumulation].
  final int accumulationSampleCount;

  /// Optional camera-state lookup for camera-aware sub-frame
  /// cursor stamping (focal at any sub-frame time, video coords).
  /// Pair with [accumulationCameraScaleAt]. When both are provided,
  /// the painter places stamps at the cursor's *viewport* position
  /// at each sub-frame time — so cursor-following zooms keep the
  /// cursor visually stationary on screen instead of trailing
  /// based on raw video-pixel positions. The playground sets these
  /// up in Frame-blur mode.
  final Offset Function(Duration)? accumulationCameraFocalAt;
  final double Function(Duration)? accumulationCameraScaleAt;

  /// Peak Gaussian σ (widget px) for the cursor-type-change blur bump.
  /// When the cursor's recorded state changes (arrow→I-beam→hand), the
  /// stamps near the change moment get blurred so the cursor visibly
  /// dissolves into a soft glow and re-condenses as the new type, rather
  /// than hard-cutting between sprites. 0 disables it.
  final double cursorTypeChangeBlurSigmaPx;

  /// Half-width (ms) of the cursor-type-change blur bump. Null falls
  /// back to [accumulationExposureMs].
  final double? cursorTypeChangeBlurHalfWidthMs;

  /// Cursor post-processing settings from the project (end-freeze,
  /// despike, state-debounce). Applied wherever the canvas looks up
  /// the recorded cursor — sprite position, smear sub-frames, focal
  /// follow target — so a single edit in the inspector flows through
  /// everything that paints the cursor.
  final CursorPostProcess cursorPostProcess;

  /// Which scene-level motion-blur pipeline to use when the camera
  /// is moving (zoom ramp or pan). See [SceneBlurMode].
  final SceneBlurMode sceneBlurMode;

  /// Number of sub-frame stamps for [SceneBlurMode.accumulation]. Each
  /// stamp is a full draw of the captured composition with a per-stamp
  /// transform, so cost is linear in N. 16 is a reasonable starting
  /// point — visibly different from the shader without tanking the
  /// frame rate on a typical recording.
  final int sceneAccumSampleCount;

  /// Desired output canvas aspect ratio. Passed to [OutputCanvasResolver]
  /// on every build so the canvas size and the video inset both reflect
  /// the chosen ratio.
  final OutputAspect outputAspect;

  @override
  ConsumerState<PlaybackCanvas> createState() => _PlaybackCanvasState();
}

class _PlaybackCanvasState extends ConsumerState<PlaybackCanvas> {
  // Scene-blur knobs come from [MotionTuning] so the preview canvas
  // and the export pipeline (FrameCompositor) share one source of
  // truth (P2-8 phase B). The instance field is refreshed at the top
  // of build() from [motionTuningProvider]; the spring controllers
  // owned by [ScenePassBuilder] receive the same value via
  // `setTuning(...)` so a preset-picker swap takes effect on the
  // next frame (P2-8 phase C-2).
  MotionTuning _tuning = MotionTuning.defaults;
  double get _sceneBlurExposureMs => _tuning.sceneBlurExposureMs;
  double get _sceneBlurMaxTranslation => _tuning.sceneBlurMaxTranslation;
  int get _sceneBlurSampleCount => _tuning.sceneBlurSampleCount;
  double get _sceneBlurSpeedCurveExp => _tuning.sceneBlurSpeedCurveExp;
  double get _sceneBlurSpeedCurveRefPx => _tuning.sceneBlurSpeedCurveRefPx;
  int get _pauseStabilizeThresholdMicros =>
      _tuning.pauseStabilizeThreshold.inMicroseconds;

  final ZoomTransformer _zoomTransformer = ZoomTransformer();

  /// Single source of truth for per-frame scene state (cursor sprite,
  /// focal trajectory, EMA-filtered cursor velocity). Shared with the
  /// export pipeline ([FrameCompositor]) — same instance class, same
  /// inputs in, same outputs out — so preview and export cannot drift.
  final ScenePassBuilder _scenePassBuilder = ScenePassBuilder();
  ZoomFocalController get _zoomFocalController => _scenePassBuilder.focal;
  final GlobalKey _sceneBoundaryKey = GlobalKey();
  ui.FragmentProgram? _sceneBlurProgram;
  ui.Image? _capturedScene;
  SceneMotionBlurSignal _capturedSceneSignal = SceneMotionBlurSignal.zero;
  SceneMotionBlurSignal _currentSceneSignal = SceneMotionBlurSignal.zero;
  WindowFrame? _lastSeenFrame;
  bool _pendingSceneCapturePaint = false;
  // Locked playhead during pause to filter smoothPlayhead's per-tick
  // micro-jitter out of the scene-blur signal. See the comment in
  // build() where it's read for the full rationale.
  Duration? _stablePos;

  bool get _scenePassEnabled =>
      widget.motionBlur > 0 &&
      widget.zoomRegions.isNotEmpty &&
      _sceneBlurProgram != null;

  @override
  void initState() {
    super.initState();
    _loadSceneBlurProgram();
    widget.zoomPreviewOverride?.addListener(_onPreviewChanged);
  }

  @override
  void didUpdateWidget(covariant PlaybackCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomPreviewOverride != widget.zoomPreviewOverride) {
      oldWidget.zoomPreviewOverride?.removeListener(_onPreviewChanged);
      widget.zoomPreviewOverride?.addListener(_onPreviewChanged);
    }
    // The scene-blur signal is now a pure function of (pos, sampleAt),
    // so there is no per-controller state to reset on trajectory
    // changes — `compute` reads fresh on every call.
    if (oldWidget.motionBlur != widget.motionBlur ||
        oldWidget.cursorMovementBlur != widget.cursorMovementBlur ||
        oldWidget.screenMovementBlur != widget.screenMovementBlur ||
        oldWidget.screenZoomBlur != widget.screenZoomBlur ||
        oldWidget.zoomRegions != widget.zoomRegions ||
        oldWidget.screenAnimationConfig != widget.screenAnimationConfig ||
        oldWidget.frame != widget.frame) {
      _pendingSceneCapturePaint = true;
    }
    if (!_scenePassEnabled) {
      _disposeCapturedScene();
    }
  }

  @override
  void dispose() {
    widget.zoomPreviewOverride?.removeListener(_onPreviewChanged);
    _disposeCapturedScene();
    super.dispose();
  }

  void _onPreviewChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSceneBlurProgram() async {
    try {
      final program = await SceneMotionBlurShader.ensureLoaded();
      if (!mounted) return;
      setState(() {
        _sceneBlurProgram = program;
        _pendingSceneCapturePaint = true;
      });
    } catch (_) {
      // Keep preview usable if the shader asset is unavailable in a
      // dev/test build; export/build verification catches asset issues.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pick up the latest MotionTuning from the provider so preset
    // changes from the cursor-tab picker (or a JSON reload at app
    // startup) flow through to the scene-blur knobs read in this
    // build AND to the spring controllers owned by the
    // ScenePassBuilder.
    _tuning = ref.watch(motionTuningProvider);
    _scenePassBuilder.setTuning(_tuning);
    final videoSize = widget.controller.value.size;
    final currentFrame = widget.frame;
    if (_lastSeenFrame != currentFrame) {
      _lastSeenFrame = currentFrame;
      _pendingSceneCapturePaint = true;
    }
    final resolved = OutputCanvasResolver.resolve(
      videoSize: videoSize,
      padding: currentFrame.padding,
      aspect: widget.outputAspect,
    );
    final totalSize = resolved.canvasSize;
    // Top-left of the video inside the canvas. Replaces the previous
    // `effPadding.left / .top` use sites verbatim — the resolver already
    // returns the inset, including any aspect-driven recentering.
    final videoOriginX = resolved.videoRect.left;
    final videoOriginY = resolved.videoRect.top;

    // Single AnimatedBuilder rebuilt per frame: drives the cursor
    // overlay (needs current playhead) AND the zoom Transform. The
    // VideoPlayer is held as `child` so its widget isn't reconstructed
    // each frame even though the surrounding Stack is.
    //
    // Zoom Transform wraps the ENTIRE composition (wallpaper + frame
    // + video + cursor + dev HUD) so when zoom kicks in everything
    // pushes in together rather than only the video pixels scaling
    // while the wallpaper stays put. ClipRect on the outside keeps
    // the scaled-up tail inside the frame so it doesn't leak across
    // the editor backdrop.
    Widget framedVideo = SizedBox(
      width: totalSize.width,
      height: totalSize.height,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.controller,
            widget.smoothPlayhead,
          ]),
          child: VideoPlayer(widget.controller),
          builder: (context, videoPlayer) {
            // Stabilize the playhead when paused. smoothPlayhead's
            // internal ticker keeps firing at vsync rate even after
            // the video pauses, and the position can micro-fluctuate
            // by 1–3 ms per rebuild. Those tiny deltas leak into the
            // scene-blur signal (`prev.focal − current.focal` over a
            // 16 ms exposure is dominated by them) and the smear
            // visibly jitters even though the camera is still. So:
            // free during playback, lock during pause. Release the
            // lock only if the raw playhead deviates by >100 ms,
            // meaning the user actually scrubbed.
            final rawPos = widget.smoothPlayhead?.position ??
                widget.controller.value.position;
            final Duration pos;
            if (widget.controller.value.isPlaying) {
              _stablePos = rawPos;
              pos = rawPos;
            } else {
              final stable = _stablePos;
              if (stable == null ||
                  (rawPos.inMicroseconds - stable.inMicroseconds).abs() >
                      _pauseStabilizeThresholdMicros) {
                _stablePos = rawPos;
                pos = rawPos;
              } else {
                pos = stable;
              }
            }
            // Cursor motion is computed whenever cursor data exists,
            // independent of `hideCursorOverlay` — the zoom focal
            // needs the smoothed cursor even when the sprite is
            // hidden, so the camera and the sprite always agree.
            final hasCursorData =
                widget.metadata?.isPureSource == true &&
                widget.cursorRecording.count > 0;
            final showCursor = hasCursorData && !widget.hideCursorOverlay;

            // Single call into the shared scene builder. The export
            // pipeline calls the same builder with the same inputs in
            // FrameCompositor.compose, guaranteeing that what the user
            // sees in the editor is bit-equivalent to what lands in the
            // MP4 (modulo per-frame dt vs. fixed-fps integration noise,
            // which sub-stepping bounds).
            //
            // Hover-scrub bypasses the EMA filter so the same timestamp
            // renders the same regardless of approach direction.
            final scenePass = _scenePassBuilder.build(
              position: pos,
              zoomRegions: widget.zoomRegions,
              cursorAnimationConfig: widget.cursorAnimationConfig,
              cursorDelay: widget.cursorDelay,
              cursorPostProcess: widget.cursorPostProcess,
              cursorRecording: widget.cursorRecording,
              videoSize: videoSize,
              fps: widget.metadata?.fps ?? 60,
              hasCursorData: hasCursorData,
              // When the placement-picker override is active we want the
              // focal to lock onto the previewed rect immediately — the
              // spring otherwise barely advances while the video is paused
              // (no frame loop to integrate), so the user sees nothing
              // change until they resume playback.
              forceSnap: widget.isHoverScrubbing ||
                  widget.zoomPreviewOverride?.value != null,
              bypassVelocityFilter: widget.isHoverScrubbing,
              activeRegionOverride: widget.zoomPreviewOverride?.value,
            );
            final motion = scenePass.motion;
            final focalUpdate = scenePass.focalUpdate;
            final effectiveCursorBlur =
                widget.motionBlur * widget.cursorMovementBlur;
            final effectiveCursorTuning = widget.motionBlurTuning.copyWith(
              maxExposureMs:
                  widget.motionBlurTuning.maxExposureMs *
                  widget.cursorMovementBlur,
            );
            final combinedCursorVelocity = scenePass.filteredCursorVelocity;

            // Visible-camera focal trace. Logs the spring focal, its
            // velocity, the bounded-gate state, and the most recent
            // snap reason for the LIVE render path (once per frame).
            // Lets us tell a smooth-but-fast pan from a gate snap or
            // overshoot during a fast cursor flick. See
            // [cameraFocalTraceEnabled].
            assert(() {
              if (cameraFocalTraceEnabled) {
                final fc = _zoomFocalController;
                final f = focalUpdate?.focal;
                final raw = motion?.screenPos;
                debugPrint(
                  '[CamFocal] pos=${pos.inMicroseconds / 1000}ms '
                  'play=${widget.controller.value.isPlaying} '
                  '| focal=${f == null ? "null" : "(${f.dx.toStringAsFixed(1)},${f.dy.toStringAsFixed(1)})"} '
                  'vel=${fc.focalVelocity.distance.toStringAsFixed(0)}px/s '
                  'inFlight=${fc.inFlight} '
                  'snap=${fc.lastSnapReason ?? "-"}@${fc.lastSnapAt?.inMilliseconds ?? -1} '
                  '| rawCur=${raw == null ? "null" : "(${raw.dx.toStringAsFixed(0)},${raw.dy.toStringAsFixed(0)})"} '
                  'filtVel=${combinedCursorVelocity.distance.toStringAsFixed(0)}px/s',
                );
              }
              return true;
            }());

            // Cursor is extracted from the body composition so the
            // scene-blur shader (which captures and smears the entire
            // composition) doesn't double-smear it. The AccumulationCursorPainter
            // already produces the correct per-path smear via frame-stamping;
            // applying the scene-level translation/radial shader on top of
            // that during a cursor-following zoom was making the cursor
            // jump to max blur regardless of its actual recorded speed.
            // The overlay is rendered on top of the scene-blur output by
            // `_buildSceneMotionBlurPass` (and ALSO put through the same
            // zoom Transform in the zoom branch below).
            // The accumulation cursor paints onto a canvas the size
            // of the FULL composition (totalSize), not just the video
            // rect — we tell the painter where the video lives via
            // `videoRect`. Sizing the canvas to videoSize previously
            // clipped cursor stamps at the video frame's edge:
            // recorded positions near or just outside the video had
            // their sprites cropped at the frame boundary instead of
            // bleeding onto the surrounding wallpaper padding.
            //
            // The shader path doesn't yet support a videoRect, so it
            // keeps the legacy Positioned + SizedBox(videoSize) layout
            // and accepts the edge clipping. Production uses
            // accumulation, so this is fine for now.
            Widget? cursorOverlay;
            if (showCursor && motion != null) {
              if (widget.cursorBlurMode == CursorBlurMode.accumulation) {
                cursorOverlay = IgnorePointer(
                  child: SizedBox(
                    width: totalSize.width,
                    height: totalSize.height,
                    child: CustomPaint(
                      painter: AccumulationCursorPainter(
                        cursorRecording: widget.cursorRecording,
                        position: pos,
                        videoSize: videoSize,
                        exposureMs:
                            widget.accumulationExposureMs *
                            effectiveCursorBlur,
                        sampleCount: widget.accumulationSampleCount,
                        sizeMultiplier: widget.cursorSize,
                        style: widget.cursorStyle,
                        cursorState: motion.state,
                        devicePixelRatio:
                            MediaQuery.of(context).devicePixelRatio,
                        currentFocalVideo: focalUpdate?.focal,
                        currentScale: focalUpdate?.zoom.zoomLevel ?? 1.0,
                        focalAt: widget.accumulationCameraFocalAt,
                        scaleAt: widget.accumulationCameraScaleAt,
                        videoRect: Rect.fromLTWH(
                          videoOriginX,
                          videoOriginY,
                          videoSize.width,
                          videoSize.height,
                        ),
                        typeChangeBlurSigmaPx:
                            widget.cursorTypeChangeBlurSigmaPx,
                        typeChangeBlurHalfWidthMs:
                            widget.cursorTypeChangeBlurHalfWidthMs,
                        postProcess: widget.cursorPostProcess,
                        clickEffect: widget.cursorClickEffect,
                        clickSpring: widget.clickSpring,
                      ),
                    ),
                  ),
                );
              } else {
                cursorOverlay = IgnorePointer(
                  child: SizedBox(
                    width: totalSize.width,
                    height: totalSize.height,
                    child: Stack(
                      children: [
                        Positioned(
                          left: videoOriginX,
                          top: videoOriginY,
                          child: SizedBox(
                            width: videoSize.width,
                            height: videoSize.height,
                            child: CustomPaint(
                              painter: CursorOverlayPainter(
                                cursorRecording: widget.cursorRecording,
                                position: pos,
                                screenPos: motion.screenPos,
                                videoSize: videoSize,
                                screenSize: videoSize,
                                sizeMultiplier: widget.cursorSize,
                                style: widget.cursorStyle,
                                clickEffect: widget.cursorClickEffect,
                                velocityPxPerSec: combinedCursorVelocity,
                                motionBlurIntensity: effectiveCursorBlur,
                                tuning: effectiveCursorTuning,
                                cursorState: motion.state,
                                cursorShadow: widget.cursorShadow,
                                clickSpring: widget.clickSpring,
                                devicePixelRatio:
                                    MediaQuery.of(context).devicePixelRatio,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
            }

            // Wallpaper is rendered as a *sticky* layer behind the
            // composition: it never goes through the zoom Transform and
            // never enters the RepaintBoundary captured for scene blur.
            // So the backdrop stays anchored while the foreground zooms
            // / pans, and the scene shader / accumulation pass only
            // smears the actual moving content. Pulled out of the
            // composition Stack for that reason.
            final Widget? stickyBackground = currentFrame.wallpaperCategory ==
                    null
                ? null
                : _wallpaperLayer(
                    category: currentFrame.wallpaperCategory!,
                    index: currentFrame.wallpaperIndex,
                    blur: currentFrame.backgroundBlur,
                  );

            final composition = Stack(
              children: [
                CustomPaint(
                  size: totalSize,
                  painter: FramePainter(
                    frame: currentFrame,
                    videoSize: videoSize,
                    aspect: widget.outputAspect,
                  ),
                ),
                Positioned(
                  left: videoOriginX,
                  top: videoOriginY,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      currentFrame.cornerRadius,
                    ),
                    child: SizedBox(
                      width: videoSize.width,
                      height: videoSize.height,
                      child: videoPlayer!,
                    ),
                  ),
                ),
                if (widget.showZoomDebug)
                  Positioned(
                    left: currentFrame.padding.left,
                    top: currentFrame.padding.top,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: videoSize.width,
                        height: videoSize.height,
                        child: CustomPaint(
                          painter: ZoomFocalDebugPainter(
                            cursorRecording: widget.cursorRecording,
                            position: pos,
                            videoSize: videoSize,
                            smoothedFocal: _zoomFocalController.smoothedFocal,
                            activeZoom: focalUpdate?.zoom,
                            inFlight: _zoomFocalController.inFlight,
                            focalVelocity:
                                _zoomFocalController.focalVelocity,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Debug readout publication: when the HUD is on AND a
                // notifier was supplied, push a fresh snapshot of the
                // controller's per-frame state up to the screen so it
                // can render the text panel at screen-fixed coords
                // (the canvas itself is inside a zoom Transform that
                // would move/clip an inline overlay during zoom-ins).
                if (widget.showZoomDebug && widget.debugSnapshot != null)
                  Builder(builder: (_) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) {
                      if (!mounted) return;
                      final raw = cursorAt(widget.cursorRecording, pos);
                      final positions = widget.cursorRecording.positions;
                      (double, double)? xRange;
                      (double, double)? yRange;
                      if (positions.isNotEmpty) {
                        var minX = positions.first.x;
                        var maxX = positions.first.x;
                        var minY = positions.first.y;
                        var maxY = positions.first.y;
                        for (final p in positions) {
                          if (p.x < minX) minX = p.x;
                          if (p.x > maxX) maxX = p.x;
                          if (p.y < minY) minY = p.y;
                          if (p.y > maxY) maxY = p.y;
                        }
                        xRange = (minX, maxX);
                        yRange = (minY, maxY);
                      }
                      widget.debugSnapshot!.value = ZoomDebugSnapshot(
                        cursor:
                            raw == null ? null : Offset(raw.x, raw.y),
                        smoothedFocal:
                            _zoomFocalController.smoothedFocal,
                        activeZoom: focalUpdate?.zoom,
                        inFlight: _zoomFocalController.inFlight,
                        focalVelocity:
                            _zoomFocalController.focalVelocity,
                        cursorVelocity:
                            motion?.velocityPxPerSec ?? Offset.zero,
                        videoSize: videoSize,
                        cursorSampleCount:
                            widget.cursorRecording.count,
                        position: pos,
                        cursorXRange: xRange,
                        cursorYRange: yRange,
                        lastSnapReason:
                            _zoomFocalController.lastSnapReason,
                        lastSnapAt:
                            _zoomFocalController.lastSnapAt,
                      );
                    });
                    return const SizedBox.shrink();
                  }),
              ],
            );

            if (focalUpdate == null) {
              return _buildSceneMotionBlurPass(
                body: composition,
                cursorOverlay: cursorOverlay,
                stickyBackground: stickyBackground,
                position: pos,
                totalSize: totalSize,
                videoSize: videoSize,
                currentTransform: Matrix4.identity(),
              );
            }

            final activeZoom = focalUpdate.zoom;
            final focalForFrame = focalUpdate.focal;

            // Smoothly interpolate the rendered zoom level when the
            // user changes it via the badge — otherwise stepping the
            // level produces a visual snap.
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(end: activeZoom.zoomLevel),
              duration: widget.screenAnimationConfig.badgeDuration,
              curve: widget.screenAnimationConfig.badgeCurve,
              child: composition,
              builder: (context, animatedZoom, transformChild) {
                final tweenedRegion = activeZoom.copyWith(
                  zoomLevel: animatedZoom,
                );
                final transform = _zoomTransformer.getTransform(
                  position: pos,
                  zoomRegion: tweenedRegion,
                  videoSize: videoSize,
                  focalPoint: focalForFrame,
                  rampCurve:
                      activeZoom.rampCurveOverride?.toFlutterCurve() ??
                      widget.screenAnimationConfig.rampCurve,
                );
                // Screen-pan tracker is now ticked in the AnimatedBuilder
                // above (for combined velocity). Don't double-tick here.
                final transformed = Transform(
                  transform: transform,
                  alignment: Alignment.center,
                  child: transformChild,
                );
                // Cursor goes through the same zoom transform but is
                // applied OUTSIDE the scene-blur capture, so the shader
                // smear never touches it.
                final transformedCursor = cursorOverlay == null
                    ? null
                    : Transform(
                        transform: transform,
                        alignment: Alignment.center,
                        child: cursorOverlay,
                      );
                return _buildSceneMotionBlurPass(
                  body: transformed,
                  cursorOverlay: transformedCursor,
                  stickyBackground: stickyBackground,
                  position: pos,
                  totalSize: totalSize,
                  videoSize: videoSize,
                  currentTransform: transform,
                );
              },
            );
          },
        ),
      ),
    );

    return AspectRatio(
      aspectRatio: totalSize.width / totalSize.height,
      child: FittedBox(fit: BoxFit.contain, child: framedVideo),
    );
  }

  Widget _buildSceneMotionBlurPass({
    required Widget body,
    Widget? cursorOverlay,
    Widget? stickyBackground,
    required Duration position,
    required Size totalSize,
    required Size videoSize,
    required Matrix4 currentTransform,
  }) {
    // Compose sticky-background + body + cursor overlay for the
    // early-return cases where the scene shader isn't applied. The
    // background goes at the bottom (sticky), body next, cursor on top.
    Widget bodyWithCursor() {
      final layers = <Widget>[
        if (stickyBackground != null) stickyBackground,
        body,
        if (cursorOverlay != null) cursorOverlay,
      ];
      if (layers.length == 1) return layers.first;
      return Stack(fit: StackFit.expand, children: layers);
    }

    final wantsScenePass =
        widget.motionBlur > 0 &&
        widget.zoomRegions.isNotEmpty &&
        (widget.screenMovementBlur > 0 || widget.screenZoomBlur > 0);
    if (!wantsScenePass) {
      _currentSceneSignal = SceneMotionBlurSignal.zero;
      return bodyWithCursor();
    }

    final movementExposure = Duration(
      microseconds:
          (_sceneBlurExposureMs *
                  widget.motionBlur *
                  widget.screenMovementBlur *
                  1000)
              .round(),
    );
    final zoomExposure = Duration(
      microseconds:
          (_sceneBlurExposureMs *
                  widget.motionBlur *
                  widget.screenZoomBlur *
                  1000)
              .round(),
    );
    // Stateless: both `current` (at `position`) and `prev` (at
    // `position − exposure`) come from `_approxSceneSampleAt`, so the
    // smear vector is symmetric by construction and the editor
    // preview matches what export produces at the same playhead.
    final signal = SceneMotionBlurController.compute(
      position: position,
      sampleAt: (t) => _approxSceneSampleAt(t, videoSize),
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: _sceneBlurMaxTranslation,
    );
    _currentSceneSignal = signal;

    final program = _sceneBlurProgram;
    final useShader = widget.sceneBlurMode == SceneBlurMode.shader;
    if (useShader && program == null) return bodyWithCursor();
    if (!signal.hasMotion) {
      _disposeCapturedScene();
      return bodyWithCursor();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _captureSceneForBlur());

    Widget? blurOverlay;
    if (_capturedScene != null) {
      if (useShader && program != null) {
        blurOverlay = IgnorePointer(
          child: CustomPaint(
            painter: SceneMotionBlurPainter(
              image: _capturedScene!,
              program: program,
              signal: _capturedSceneSignal,
              sampleCount: _sceneBlurSampleCount,
              speedCurveExp: _sceneBlurSpeedCurveExp,
              speedCurveRefPx: _sceneBlurSpeedCurveRefPx,
              devicePixelRatio: MediaQuery.of(context).devicePixelRatio,
            ),
            size: totalSize,
          ),
        );
      } else if (widget.sceneBlurMode == SceneBlurMode.accumulation) {
        final deltas = _computeSubFrameDeltas(
          position: position,
          currentTransform: currentTransform,
          totalSize: totalSize,
          videoSize: videoSize,
        );
        if (deltas.length > 1) {
          blurOverlay = IgnorePointer(
            child: CustomPaint(
              painter: AccumulationScenePainter(
                image: _capturedScene!,
                deltaTransforms: deltas,
              ),
              size: totalSize,
            ),
          );
        }
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Sticky wallpaper sits at the bottom — it is intentionally
        // OUTSIDE the captured RepaintBoundary so the scene blur pass
        // can't see it and therefore can't smear it. When the camera
        // pans/zooms, the backdrop stays anchored; only the moving
        // body above gets the directional smear.
        if (stickyBackground != null) stickyBackground,
        // Body goes through the RepaintBoundary so we can capture it
        // for the blur pass. The cursor is deliberately NOT inside this
        // boundary — its own accumulation smear is the only blur it
        // should receive, never the scene-level translation+radial
        // smear (which dwarfs cursor motion during a cursor-following
        // zoom and made the cursor look like it was jumping to max).
        RepaintBoundary(key: _sceneBoundaryKey, child: body),
        if (blurOverlay != null) blurOverlay,
        if (cursorOverlay != null) cursorOverlay,
      ],
    );
  }

  /// Produces the N delta transforms consumed by [AccumulationScenePainter].
  ///
  /// For each sub-frame timestamp `t_i = position − i·Δ` inside the exposure
  /// window, computes the alignment-centered zoom matrix `A_i` at that
  /// time, then derives `delta_i = A_i × A_current^{-1}` (centered around
  /// `totalSize.center`). Applying `delta_i` to the captured composition —
  /// which has `A_current` baked in — produces the body as it would look
  /// at sub-frame `t_i`'s camera. `delta_0` is identity by construction.
  List<Matrix4> _computeSubFrameDeltas({
    required Duration position,
    required Matrix4 currentTransform,
    required Size totalSize,
    required Size videoSize,
  }) {
    final n = widget.sceneAccumSampleCount;
    if (n <= 1) return const <Matrix4>[];

    // Use the broader of the two channels for the exposure window so a
    // user who only raised one knob still sees its effect.
    final exposureMultiplier =
        widget.motionBlur *
        (widget.screenMovementBlur > widget.screenZoomBlur
            ? widget.screenMovementBlur
            : widget.screenZoomBlur);
    final exposureUs = (_sceneBlurExposureMs * exposureMultiplier * 1000)
        .round();
    if (exposureUs <= 0) return const <Matrix4>[];

    final dtUs = exposureUs ~/ (n - 1);

    Matrix4 invCurrent;
    try {
      invCurrent = Matrix4.inverted(currentTransform);
    } catch (_) {
      invCurrent = Matrix4.identity();
    }
    final cx = totalSize.width / 2;
    final cy = totalSize.height / 2;

    final deltas = <Matrix4>[];
    for (var i = 0; i < n; i++) {
      final t = Duration(microseconds: position.inMicroseconds - i * dtUs);
      if (t.isNegative) break;

      final mI = _subFrameTransformAt(t, videoSize);
      // delta_i = Translate(+c) × M_i × inv(M_current) × Translate(-c).
      final delta = Matrix4.identity()
        ..translateByDouble(cx, cy, 0, 1.0)
        ..multiply(mI)
        ..multiply(invCurrent)
        ..translateByDouble(-cx, -cy, 0, 1.0);
      deltas.add(delta);
    }
    return deltas;
  }

  /// Stateless `(focal, scale)` lookup at an arbitrary timestamp, used
  /// as the controller's fallback when its history doesn't have a
  /// sample at the requested time (paused/scrubbed state). Same math
  /// the old playground prototype used so the blur output stays stable
  /// across the play→pause transition.
  SceneCameraSample _approxSceneSampleAt(Duration t, Size videoSize) {
    if (t.isNegative) {
      return SceneCameraSample(
        position: t,
        focal: videoSize.center(Offset.zero),
        scale: 1.0,
      );
    }

    ZoomRegion? active;
    for (final region in widget.zoomRegions) {
      if (region.isActive(t)) {
        active = region;
        break;
      }
    }
    if (active == null) {
      return SceneCameraSample(
        position: t,
        focal: videoSize.center(Offset.zero),
        scale: 1.0,
      );
    }

    Offset focal;
    if (!active.followCursor) {
      focal = active.rect.center;
    } else {
      // Raw cursor at `t` — no smoother-emulation lag. See the
      // matching comment in SceneBlurOverlay._approxSampleAt; the
      // 200 ms lag here was creating a focal-difference of ~200 ms
      // of cursor motion against the (converged-during-pause) live
      // current.focal, saturating the translation cap.
      final sample = cursorAtFiltered(
        widget.cursorRecording,
        t,
        widget.cursorPostProcess,
      );
      focal = sample == null
          ? active.rect.center
          : Offset(
              sample.x.toDouble().clamp(0, videoSize.width),
              sample.y.toDouble().clamp(0, videoSize.height),
            );
    }

    final matrix = _zoomTransformer.getTransform(
      position: t,
      zoomRegion: active,
      videoSize: videoSize,
      focalPoint: focal,
      rampCurve:
          active.rampCurveOverride?.toFlutterCurve() ??
          widget.screenAnimationConfig.rampCurve,
    );
    return SceneCameraSample(
      position: t,
      focal: focal,
      scale: matrix.storage[0],
    );
  }

  /// Stateless lookup of the zoom matrix at an arbitrary sub-frame
  /// timestamp. Uses the same machinery as the main render (zoom
  /// region's ramp curve, cursor-following focal with a 200 ms lag
  /// approximation) but does NOT touch the smoothing controllers,
  /// so it can be called N times per frame without corrupting their
  /// state. Returns identity when no zoom region is active at [t].
  Matrix4 _subFrameTransformAt(Duration t, Size videoSize) {
    if (t.isNegative) return Matrix4.identity();

    ZoomRegion? active;
    for (final region in widget.zoomRegions) {
      if (region.isActive(t)) {
        active = region;
        break;
      }
    }
    if (active == null) return Matrix4.identity();

    Offset focal;
    if (!active.followCursor) {
      focal = active.rect.center;
    } else {
      // Raw cursor at `t` — see the comment in _approxSceneSampleAt
      // for the rationale (the previous 200 ms lag was over-emulating
      // the focal smoother and producing 200 ms of cursor motion as
      // "translation" during pause).
      final sample = cursorAtFiltered(
        widget.cursorRecording,
        t,
        widget.cursorPostProcess,
      );
      focal = sample == null
          ? active.rect.center
          : Offset(
              sample.x.toDouble().clamp(0, videoSize.width),
              sample.y.toDouble().clamp(0, videoSize.height),
            );
    }

    return _zoomTransformer.getTransform(
      position: t,
      zoomRegion: active,
      videoSize: videoSize,
      focalPoint: focal,
      rampCurve:
          active.rampCurveOverride?.toFlutterCurve() ??
          widget.screenAnimationConfig.rampCurve,
    );
  }

  void _captureSceneForBlur() {
    if (!mounted) return;
    final boundary =
        _sceneBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final image = boundary.toImageSync(pixelRatio: dpr);
      final shouldRepaint = _capturedScene == null || _pendingSceneCapturePaint;
      _capturedScene?.dispose();
      _capturedScene = image;
      _capturedSceneSignal = _currentSceneSignal;
      if (shouldRepaint) {
        _pendingSceneCapturePaint = false;
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Keep the previous capture for this frame. RenderObject capture
      // can fail briefly during layout/resize.
    }
  }

  void _disposeCapturedScene() {
    _capturedScene?.dispose();
    _capturedScene = null;
    _capturedSceneSignal = SceneMotionBlurSignal.zero;
    _currentSceneSignal = SceneMotionBlurSignal.zero;
  }

  Widget _wallpaperLayer({
    required String category,
    required int index,
    required double blur,
  }) {
    final fill = Container(decoration: wallpaperDecoration(category, index));
    if (blur <= 0) return fill;
    // ClipRect prevents the gaussian tail from leaking outside the
    // frame's totalSize. ImageFiltered does a saveLayer internally,
    // which is why we skip it altogether at sigma 0.
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: fill,
      ),
    );
  }
}
