import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import 'package:screen_recorder/effects/scene_motion_blur.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/state/cursor_post_process.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';

/// Wraps a [child] (typically a [PlaybackCanvas]) and renders the
/// scene-level motion blur as a captured-and-shadered overlay on top.
///
/// This is the "external" scene-blur pipeline that the motion-blur
/// playground used in scene mode and that the user wants in
/// production. It deliberately captures the **entire** rendered output
/// of the child — wallpaper, body, cursor — into a [ui.Image] each
/// frame and runs the scene-blur fragment shader over it. The captured
/// image is fully opaque (wallpaper fills the totalSize backdrop), so
/// the shader's smear never has transparent edges to shimmer against
/// during scrubs and knob drags. The visible result is a uniformly
/// smeared scene, which the user described as "perfect" in playground
/// testing.
///
/// To avoid double-application, callers should pass `0` for
/// `screenMovementBlur` and `screenZoomBlur` to the inner
/// [PlaybackCanvas] (its internal scene-blur pass short-circuits
/// when both channels are zero). The cursor channel stays on inside
/// [PlaybackCanvas] — cursor accumulation runs there.
///
/// Note: there is intentionally no `cursorMovementBlur` prop on this
/// widget. The cursor smear is path-stamped from the recording
/// (`AccumulationCursorPainter` inside [PlaybackCanvas]) and has no
/// capture lag, so it doesn't need to ride along the external
/// capture-and-shader pipeline.
class SceneBlurOverlay extends StatefulWidget {
  const SceneBlurOverlay({
    super.key,
    required this.child,
    required this.controller,
    required this.smoothPlayhead,
    required this.cursorRecording,
    required this.zoomRegions,
    required this.cursorAnimationConfig,
    required this.screenAnimationConfig,
    required this.motionBlur,
    required this.screenMovementBlur,
    required this.screenZoomBlur,
    required this.isHoverScrubbing,
    required this.videoSize,
    this.fps = 60,
    this.cursorPostProcess = CursorPostProcess.none,
  });

  /// The widget tree to apply the scene-blur smear to. Usually the
  /// [PlaybackCanvas] with its own scene blur disabled.
  final Widget child;

  final VideoPlayerController controller;
  final SmoothPlayheadController? smoothPlayhead;
  final CursorRecording cursorRecording;
  final List<ZoomRegion> zoomRegions;
  final CursorAnimationConfig cursorAnimationConfig;
  final ScreenAnimationConfig screenAnimationConfig;
  final double motionBlur;
  final double screenMovementBlur;
  final double screenZoomBlur;
  final bool isHoverScrubbing;

  /// Source-video resolution in pixels. Used both to drive the
  /// camera-state computation (focal lookups, zoom-region transforms)
  /// and as the natural canvas size for the shader.
  final Size videoSize;

  /// Playback rate hint for the cursor smoother — passed through to
  /// [CursorMotionController]. Defaults to 60 fps to match the editor.
  final int fps;

  /// Per-project cursor filters. Forwarded to the fallback `cursorAt`
  /// lookup inside this overlay (used for the scene-blur focal at
  /// arbitrary sub-frame times) so the camera doesn't track shakes or
  /// the freeze-zone past the cap.
  final CursorPostProcess cursorPostProcess;

  @override
  State<SceneBlurOverlay> createState() => _SceneBlurOverlayState();
}

class _SceneBlurOverlayState extends State<SceneBlurOverlay> {
  // Base shutter window for the scene blur, in milliseconds. The user
  // knobs (master × channel) multiply this. Scene blur is inherently
  // subtler than cursor blur — it's a shader smear of the already-
  // composited frame, and small (scaleDelta, translation) signals
  // produce visually imperceptible effects. To give the master
  // slider real authority over screen-movement / zoom blur (rather
  // than the slider feeling like a no-op while it visibly drives
  // the cursor), the base needs enough headroom that master=50% ×
  // channel=100% produces a clearly visible smear at typical camera-
  // follow speeds. 80 ms ≈ five 60-Hz frames at max — heavy enough
  // to read as motion blur on moderate cursor pans / zoom ramps, but
  // not so heavy that it dominates the foreground at slider mid-
  // points (40 ms max effective ≈ a 240° shutter).
  static const double _baseExposureMs = 80.0;

  // Cap on the translation vector magnitude in logical pixels. Set
  // high enough that moderate camera-follow speeds at the full
  // slider don't saturate against it — otherwise the slider's upper
  // range flattens (all values past saturation produce the same
  // 60-px smear, which reads as "the slider does nothing"). 160 px
  // is roughly the point where a smear stops looking like motion
  // blur and starts looking like a screen wipe, which is our actual
  // ceiling.
  static const double _maxTranslation = 160.0;

  // Shader sample count + speed-curve parameters. Kept in sync with
  // the playground's defaults so the visual result is identical.
  static const int _sampleCount = 48;
  static const double _speedCurveExp = 1.0;
  static const double _speedCurveRefPx = 10.0;

  // Camera-state controllers — independent copies of what
  // [PlaybackCanvas] runs internally. Duplicating the smoothing state
  // is intentional: it keeps the overlay self-contained so the inner
  // canvas doesn't need a separate API for exposing focal/scale, and
  // the two controllers' outputs only ever drive their own rendering
  // (PlaybackCanvas for the body transform, overlay for the smear
  // signal). They see the same inputs each frame so they stay in
  // lockstep.
  final ZoomTransformer _zoomTransformer = ZoomTransformer();
  final ZoomFocalController _focalController = ZoomFocalController();
  final CursorMotionController _cursorMotion = CursorMotionController();

  final SceneMotionBlurController _signalController =
      SceneMotionBlurController();

  final GlobalKey _boundaryKey = GlobalKey();
  ui.FragmentProgram? _program;

  // Capture state. `_currentSignal` is the signal computed for the
  // frame we're about to paint; `_capturedSignal` is the signal at
  // the moment of the most recent capture (used by the shader so
  // its uniforms match the captured pixels' state — avoids a
  // 1-frame mismatch between the shader's blur direction and the
  // captured image's content).
  ui.Image? _capturedScene;
  SceneMotionBlurSignal _capturedSignal = SceneMotionBlurSignal.zero;
  SceneMotionBlurSignal _currentSignal = SceneMotionBlurSignal.zero;
  bool _pendingCapturePaint = false;

  // Deferred disposal queue. When [_captureScene] replaces the
  // current image, the previous painter (from the most recent build)
  // still references it via `_capturedScene!`. Disposing the old
  // image immediately means: if a paint happens before the next
  // build replaces that painter — common during scrub-and-pause,
  // where an ancestor can trigger a repaint without retriggering
  // our AnimatedBuilder — the painter crashes with "Image has been
  // disposed". Queueing instead, then flushing at the START of the
  // next build, guarantees the painter is about to be rebuilt
  // before its image is freed.
  final List<ui.Image> _disposeQueue = <ui.Image>[];

  // Stable playhead lock. smoothPlayhead's ticker continues firing at
  // vsync rate after the video pauses, and the position micro-
  // fluctuates by 1–3 ms per rebuild — those tiny deltas leak into
  // the scene-blur signal (`prev.focal − current.focal` over a 16 ms
  // exposure is dominated by them) and the smear jitters even though
  // the camera is still. Free during playback, lock during pause.
  // Release only on a >100 ms deviation, meaning the user scrubbed.
  Duration _stablePos = Duration.zero;
  bool _hasStablePos = false;

  @override
  void initState() {
    super.initState();
    _loadProgram();
  }

  Future<void> _loadProgram() async {
    try {
      final program = await SceneMotionBlurShader.ensureLoaded();
      if (!mounted) return;
      setState(() => _program = program);
    } catch (_) {
      // Asset missing in dev/test builds — overlay silently disables.
    }
  }

  @override
  void didUpdateWidget(covariant SceneBlurOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset only when the camera trajectory itself changes. Knob
    // changes only rescale the exposure window — they don't
    // invalidate the history, and resetting on them wipes the very
    // samples the signal computation needs (most visible when paused,
    // where no new samples come in to refill).
    if (oldWidget.controller != widget.controller ||
        oldWidget.cursorRecording != widget.cursorRecording ||
        oldWidget.zoomRegions != widget.zoomRegions ||
        oldWidget.cursorAnimationConfig != widget.cursorAnimationConfig ||
        oldWidget.screenAnimationConfig != widget.screenAnimationConfig) {
      _signalController.reset();
      _currentSignal = SceneMotionBlurSignal.zero;
      _capturedSignal = SceneMotionBlurSignal.zero;
    }
    if (oldWidget.motionBlur != widget.motionBlur ||
        oldWidget.screenMovementBlur != widget.screenMovementBlur ||
        oldWidget.screenZoomBlur != widget.screenZoomBlur ||
        oldWidget.zoomRegions != widget.zoomRegions) {
      _pendingCapturePaint = true;
    }
  }

  @override
  void dispose() {
    // Flush the deferred-disposal queue AND the current image —
    // safe to do directly here because the State is going away and
    // no further paints can occur against any painter we created.
    for (final img in _disposeQueue) {
      img.dispose();
    }
    _disposeQueue.clear();
    _capturedScene?.dispose();
    _capturedScene = null;
    super.dispose();
  }

  /// Marks the current captured scene for deferred disposal and
  /// clears the field. The old image is held by the painter from
  /// the previous build until the NEXT build runs and flushes the
  /// queue. See the comment on [_disposeQueue] for the rationale.
  void _disposeCapture() {
    final scene = _capturedScene;
    if (scene != null) {
      _disposeQueue.add(scene);
      _capturedScene = null;
    }
    _capturedSignal = SceneMotionBlurSignal.zero;
    _currentSignal = SceneMotionBlurSignal.zero;
  }

  /// Drains the deferred-disposal queue. Called at the start of every
  /// `_buildBody` so any image that was queued during the previous
  /// frame's postFrame is released right before this build's painter
  /// takes its place in the tree.
  void _flushDisposeQueue() {
    if (_disposeQueue.isEmpty) return;
    for (final img in _disposeQueue) {
      img.dispose();
    }
    _disposeQueue.clear();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.smoothPlayhead == null
          ? widget.controller
          : Listenable.merge([widget.controller, widget.smoothPlayhead]),
      child: widget.child,
      builder: (context, child) => _buildBody(context, child!),
    );
  }

  Widget _buildBody(BuildContext context, Widget child) {
    // The painter from the previous build is about to be replaced in
    // the element tree by whatever this build produces. Any image
    // queued in the previous frame's postFrame is therefore safe to
    // release now — the painter still holding it will be GC'd as
    // soon as this build's reconciliation runs.
    _flushDisposeQueue();

    final wantsPass =
        widget.motionBlur > 0 &&
        widget.zoomRegions.isNotEmpty &&
        (widget.screenMovementBlur > 0 || widget.screenZoomBlur > 0);
    if (!wantsPass) {
      _signalController.reset();
      _currentSignal = SceneMotionBlurSignal.zero;
      _disposeCapture();
      return child;
    }

    final pos = _resolveStablePlayhead();
    final signal = _computeSignal(pos);
    _currentSignal = signal;

    final program = _program;
    if (program == null) return child;
    if (!signal.hasMotion) {
      _disposeCapture();
      return child;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _captureScene());

    final dpr = MediaQuery.of(context).devicePixelRatio;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _boundaryKey, child: child),
        if (_capturedScene != null)
          IgnorePointer(
            child: CustomPaint(
              painter: SceneMotionBlurPainter(
                image: _capturedScene!,
                program: program,
                // Uniforms computed at the captured playhead, NOT the
                // live one. The smear must match the captured content's
                // state — using the live signal here was the source of
                // per-frame oscillation in the original playground
                // prototype.
                signal: _capturedSignal,
                sampleCount: _sampleCount,
                speedCurveExp: _speedCurveExp,
                speedCurveRefPx: _speedCurveRefPx,
                devicePixelRatio: dpr,
              ),
            ),
          ),
      ],
    );
  }

  /// Lock the playhead during pause to keep the scene-blur signal
  /// stable. See the comment on [_stablePos] for the full rationale.
  Duration _resolveStablePlayhead() {
    final raw =
        widget.smoothPlayhead?.position ?? widget.controller.value.position;
    if (widget.controller.value.isPlaying) {
      _stablePos = raw;
      _hasStablePos = true;
      return raw;
    }
    if (!_hasStablePos ||
        (raw.inMicroseconds - _stablePos.inMicroseconds).abs() > 100000) {
      _stablePos = raw;
      _hasStablePos = true;
    }
    return _stablePos;
  }

  SceneMotionBlurSignal _computeSignal(Duration pos) {
    final hasCursorData = widget.cursorRecording.count > 0;
    final cursorMotion = hasCursorData
        ? _cursorMotion.update(
            position: pos,
            cursorRecording: widget.cursorRecording,
            config: widget.cursorAnimationConfig,
            fps: widget.fps,
          )
        : null;
    final activeZoom = _activeZoomAt(pos);
    final cursorForFocal = activeZoom?.followMode == FollowMode.predictive
        ? medianCursorOver(
            recording: widget.cursorRecording,
            t: pos,
            window: activeZoom!.predictiveWindow,
          )
        : cursorMotion?.screenPos;
    final focalUpdate = _focalController.update(
      position: pos,
      zoomRegions: widget.zoomRegions,
      cursor: cursorForFocal,
      videoSize: widget.videoSize,
      forceSnap: widget.isHoverScrubbing,
    );

    Offset focal;
    double scale;
    if (focalUpdate != null) {
      final matrix = _zoomTransformer.getTransform(
        position: pos,
        zoomRegion: focalUpdate.zoom,
        videoSize: widget.videoSize,
        focalPoint: focalUpdate.focal,
        rampCurve:
            focalUpdate.zoom.rampCurveOverride?.toFlutterCurve() ??
            widget.screenAnimationConfig.rampCurve,
      );
      focal = focalUpdate.focal;
      scale = matrix.storage[0];
    } else {
      focal = widget.videoSize.center(Offset.zero);
      scale = 1.0;
    }

    final movementExposure = Duration(
      microseconds:
          (_baseExposureMs * widget.motionBlur * widget.screenMovementBlur * 1000)
              .round(),
    );
    final zoomExposure = Duration(
      microseconds:
          (_baseExposureMs * widget.motionBlur * widget.screenZoomBlur * 1000)
              .round(),
    );

    final signal = _signalController.update(
      current: SceneCameraSample(position: pos, focal: focal, scale: scale),
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: _maxTranslation,
      smooth: !widget.isHoverScrubbing && widget.controller.value.isPlaying,
      // Stateless fallback for prev-sample lookups when history is
      // empty (immediately after scrub / mode-switch / fresh mount).
      // Same machinery [PlaybackCanvas] uses; ensures the signal
      // doesn't collapse to zero during interactive paused testing.
      approxSampleAt: _approxSampleAt,
    );

    // TEMP debug: log signal values whenever a knob changes so we can
    // see what the slider is actually doing under the hood. Throttled
    // by a key so we only print on transitions, not every frame.
    assert(() {
      final key = '${widget.motionBlur.toStringAsFixed(6)}|'
          '${widget.screenMovementBlur.toStringAsFixed(6)}|'
          '${widget.screenZoomBlur.toStringAsFixed(6)}';
      if (key != _lastDebugKey) {
        _lastDebugKey = key;
        debugPrint(
          '[SceneBlur] '
          'masterCurved=${widget.motionBlur.toStringAsExponential(2)} '
          'moveCurved=${widget.screenMovementBlur.toStringAsExponential(2)} '
          'zoomCurved=${widget.screenZoomBlur.toStringAsExponential(2)} '
          '| mExp=${(movementExposure.inMicroseconds / 1000).toStringAsFixed(3)}ms '
          'zExp=${(zoomExposure.inMicroseconds / 1000).toStringAsFixed(3)}ms '
          '| scaleDelta=${signal.scaleDelta.toStringAsExponential(2)} '
          'trans=${signal.translation.distance.toStringAsFixed(2)}px '
          'hasMotion=${signal.hasMotion}',
        );
      }
      return true;
    }());
    return signal;
  }

  String _lastDebugKey = '';

  SceneCameraSample _approxSampleAt(Duration t) {
    if (t.isNegative) {
      return SceneCameraSample(
        position: t,
        focal: widget.videoSize.center(Offset.zero),
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
        focal: widget.videoSize.center(Offset.zero),
        scale: 1.0,
      );
    }

    Offset focal;
    if (!active.followCursor) {
      focal = active.rect.center;
    } else {
      // Query raw cursor at exactly `t`. We used to subtract a
      // 200 ms "smoother-delay approximation" here, but it only
      // matches the live focal smoother during playback (when the
      // smoother is mid-tween). During pause the smoother fully
      // converges to the cursor's actual position, so `current.focal`
      // is unlagged — comparing it against a 200-ms-lagged prev
      // focal produced ~200 ms of cursor motion as the "translation",
      // saturating the cap at every slider position. Using raw cursor
      // at `t` for the fallback keeps current and prev consistent.
      final s = cursorAtFiltered(
        widget.cursorRecording,
        t,
        widget.cursorPostProcess,
      );
      focal = s == null
          ? active.rect.center
          : Offset(
              s.x.toDouble().clamp(0, widget.videoSize.width),
              s.y.toDouble().clamp(0, widget.videoSize.height),
            );
    }

    final matrix = _zoomTransformer.getTransform(
      position: t,
      zoomRegion: active,
      videoSize: widget.videoSize,
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

  ZoomRegion? _activeZoomAt(Duration t) {
    for (final z in widget.zoomRegions) {
      if (z.isActive(t)) return z;
    }
    return null;
  }

  void _captureScene() {
    if (!mounted) return;
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final image = boundary.toImageSync(pixelRatio: dpr);
      final shouldRebuild = _capturedScene == null || _pendingCapturePaint;
      // Queue the previous image for disposal on the NEXT build.
      // Disposing immediately would invalidate the painter from this
      // frame's build, which still references the old image via
      // `_capturedScene!`. If no rebuild follows (paused, no
      // dependents requesting frames), a subsequent paint of that
      // painter would trip the "Image has been disposed" assertion.
      final previous = _capturedScene;
      _capturedScene = image;
      _capturedSignal = _currentSignal;
      if (previous != null) _disposeQueue.add(previous);
      if (shouldRebuild) {
        _pendingCapturePaint = false;
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Keep the previous capture for this frame.
    }
  }
}
