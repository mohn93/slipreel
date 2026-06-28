import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';

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
/// Static per-frame trace toggle, exposed at the public widget class
/// so a VM-service extension (or a hot-reload edit) can flip it without
/// poking at the State's privates. Off by default — every paint emits
/// a structured `[SceneBlur frame]` line when on, which is too noisy
/// for normal interactive use.
bool sceneBlurTraceEnabled = false;

/// Assembles the scene-blur tree so [framedChild] ALWAYS occupies the
/// same slot (the `Stack`'s child 0) whether or not [smearOverlay] is
/// present. The smear is layered on top; adding or removing it never
/// disturbs the child's slot.
///
/// This is the linchpin of the mid-zoom "camera jump" fix: the child
/// is the `PlaybackCanvas`, which owns the live `ZoomFocalController`
/// spring. If the child's slot changed shape (e.g. bare child when
/// there's no smear vs. nested-under-Stack when there is), Flutter
/// would remount it, recreating the controller and snapping the camera
/// focal to the zoom rect's centre. Keeping a single stable shape here
/// preserves the controller across smear on/off transitions.
///
/// Exposed for the behavioral remount test; `_SceneBlurOverlayState`'s
/// build is the only production caller.
@visibleForTesting
Widget buildSceneBlurTree({required Widget framedChild, Widget? smearOverlay}) {
  return Stack(
    fit: StackFit.expand,
    children: [framedChild, if (smearOverlay != null) smearOverlay],
  );
}

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
    this.clips = const <ClipSlice>[],
    this.framing,
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

  /// Clip slices for the current timeline. Forwarded to the
  /// [DeterministicFocalTrack] so the scene-blur camera trajectory
  /// follows the speed-aware cursor. Empty ⇒ speed 1.0 ⇒ unchanged.
  final List<ClipSlice> clips;

  /// Device-bezel framing. When null the overlay resolves identity framing
  /// from [videoSize], reproducing the legacy behavior byte-for-byte.
  /// Pass a [ZoomFraming.device] instance (built the same way
  /// [PlaybackCanvas] builds it) to route focal clamps through canvas
  /// space so the scene-blur camera matches the export compositor.
  final ZoomFraming? framing;

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

  // The blur signal is a stateless function of `(pos, sampleAt)` —
  // [SceneMotionBlurController.compute] reads the camera state at
  // `pos` and `pos − exposure` from `_approxSampleAt`, which uses
  // the same raw-cursor + zoom-transform machinery on both sides.
  // No focal/cursor smoother state is kept here: determinism (pause
  // == play == export at the same playhead) is the contract, and
  // any stateful smoothing would re-introduce the path-dependence
  // that this refactor exists to remove.
  final ZoomTransformer _zoomTransformer = ZoomTransformer();

  /// Cached deterministic spring-camera focal track for the most recently
  /// queried [ZoomRegion]. Rebuilt lazily whenever the region or any
  /// configuration parameter changes (verified by [DeterministicFocalTrack.matches]).
  DeterministicFocalTrack? _focalTrack;

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
    // No signal-state to reset: the blur is a pure function of pos +
    // sampleAt. Knob changes only need a fresh capture-paint so the
    // shader picks up the new exposure window the next frame.
    if (oldWidget.motionBlur != widget.motionBlur ||
        oldWidget.screenMovementBlur != widget.screenMovementBlur ||
        oldWidget.screenZoomBlur != widget.screenZoomBlur ||
        oldWidget.zoomRegions != widget.zoomRegions ||
        oldWidget.clips != widget.clips ||
        oldWidget.framing != widget.framing) {
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

    // `child` (the PlaybackCanvas) is ALWAYS hosted at the same slot —
    // under this keyed RepaintBoundary, at index 0 of the Stack —
    // regardless of whether a smear is drawn this frame. Earlier this
    // method returned the bare `child` when there was nothing to smear
    // and a `Stack[RepaintBoundary(child), painter]` when there was;
    // toggling those two tree shapes changed child's slot type and
    // made Flutter REMOUNT PlaybackCanvas, which recreates its
    // ScenePassBuilder/ZoomFocalController and snaps the camera focal
    // back to the zoom rect's centre — a visible "jump" every time the
    // blur turned on/off (which, with the deterministic signal, is
    // every brief cursor pause). Keeping the host stable preserves the
    // camera spring across smear on/off transitions; the painter is
    // layered on top only when there's motion to smear.
    Widget? smearOverlay;

    final wantsPass =
        widget.motionBlur > 0 &&
        widget.zoomRegions.isNotEmpty &&
        (widget.screenMovementBlur > 0 || widget.screenZoomBlur > 0);
    final program = _program;

    if (!wantsPass || program == null) {
      _currentSignal = SceneMotionBlurSignal.zero;
      _disposeCapture();
    } else {
      final pos =
          widget.smoothPlayhead?.position ?? widget.controller.value.position;
      final signal = _computeSignal(pos);
      _currentSignal = signal;

      if (!signal.hasMotion) {
        _disposeCapture();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _captureScene());
        if (_capturedScene != null) {
          final dpr = MediaQuery.of(context).devicePixelRatio;
          smearOverlay = IgnorePointer(
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
          );
        }
      }
    }

    return buildSceneBlurTree(
      framedChild: RepaintBoundary(key: _boundaryKey, child: child),
      smearOverlay: smearOverlay,
    );
  }

  SceneMotionBlurSignal _computeSignal(Duration pos) {
    final movementExposure = Duration(
      microseconds:
          (_baseExposureMs *
                  widget.motionBlur *
                  widget.screenMovementBlur *
                  1000)
              .round(),
    );
    final zoomExposure = Duration(
      microseconds:
          (_baseExposureMs * widget.motionBlur * widget.screenZoomBlur * 1000)
              .round(),
    );

    final signal = SceneMotionBlurController.compute(
      position: pos,
      sampleAt: _approxSampleAt,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: _maxTranslation,
    );

    // Knob-change one-shot log (kept from the original instrumentation):
    // confirms the slider is actually feeding new exposures into the
    // compute path. Quiet during steady-state.
    assert(() {
      final key =
          '${widget.motionBlur.toStringAsFixed(6)}|'
          '${widget.screenMovementBlur.toStringAsFixed(6)}|'
          '${widget.screenZoomBlur.toStringAsFixed(6)}';
      if (key != _lastDebugKey) {
        _lastDebugKey = key;
        debugPrint(
          '[SceneBlur knob] '
          'master=${widget.motionBlur.toStringAsExponential(2)} '
          'move=${widget.screenMovementBlur.toStringAsExponential(2)} '
          'zoom=${widget.screenZoomBlur.toStringAsExponential(2)} '
          '| mExp=${(movementExposure.inMicroseconds / 1000).toStringAsFixed(2)}ms '
          'zExp=${(zoomExposure.inMicroseconds / 1000).toStringAsFixed(2)}ms',
        );
      }
      return true;
    }());

    // Per-frame trace, gated by [sceneBlurTraceEnabled] so it doesn't
    // flood by default. The MCP `get_logs` tool reads this back when
    // we want a frame-by-frame view of the blur signal (e.g. to
    // diagnose smear jitter that propagates into the cursor sprite).
    // Toggle via `ext.slipreel.setSceneBlurTrace` (registered in
    // main.dart).
    assert(() {
      if (sceneBlurTraceEnabled) {
        // Sample the same current/prev pair the controller saw so the
        // log shows exactly what fed the math, not a re-derivation.
        final cur = _approxSampleAt(pos);
        final prev = _approxSampleAt(
          pos -
              (movementExposure > Duration.zero
                  ? movementExposure
                  : zoomExposure),
        );
        debugPrint(
          '[SceneBlur frame] '
          'pos=${pos.inMicroseconds / 1000}ms '
          'isPlaying=${widget.controller.value.isPlaying} '
          '| cur=(${cur.focal.dx.toStringAsFixed(1)},${cur.focal.dy.toStringAsFixed(1)}) '
          'scale=${cur.scale.toStringAsFixed(4)} '
          '| prev=(${prev.focal.dx.toStringAsFixed(1)},${prev.focal.dy.toStringAsFixed(1)}) '
          'scale=${prev.scale.toStringAsFixed(4)} '
          '| trans=(${signal.translation.dx.toStringAsFixed(2)},'
          '${signal.translation.dy.toStringAsFixed(2)}) '
          '|trans|=${signal.translation.distance.toStringAsFixed(2)}px '
          'scaleDelta=${signal.scaleDelta.toStringAsExponential(2)}',
        );
      }
      return true;
    }());

    return signal;
  }

  String _lastDebugKey = '';

  /// Returns the [DeterministicFocalTrack] for [region], rebuilding it only
  /// when the region or any relevant configuration parameter has changed.
  /// Returns `null` when [region.followCursor] is false (static focal).
  DeterministicFocalTrack? _trackFor(ZoomRegion region, ZoomFraming framing) {
    if (!region.followCursor) return null;
    final cached = _focalTrack;
    if (cached != null &&
        cached.matches(
          region: region,
          cursorRecording: widget.cursorRecording,
          cursorAnimationConfig: widget.cursorAnimationConfig,
          cursorPostProcess: widget.cursorPostProcess,
          videoSize: widget.videoSize,
          fps: widget.fps,
          screenRampCurve: widget.screenAnimationConfig.rampCurve,
          rampDurationScale: widget.screenAnimationConfig.rampDurationScale,
          clips: widget.clips,
          framing: framing,
        )) {
      return cached;
    }
    return _focalTrack = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: widget.cursorRecording,
      cursorAnimationConfig: widget.cursorAnimationConfig,
      cursorPostProcess: widget.cursorPostProcess,
      videoSize: widget.videoSize,
      fps: widget.fps,
      screenRampCurve: widget.screenAnimationConfig.rampCurve,
      rampDurationScale: widget.screenAnimationConfig.rampDurationScale,
      clips: widget.clips,
      framing: framing,
    );
  }

  SceneCameraSample _approxSampleAt(Duration t) {
    // Resolve framing once per sample — identity when caller doesn't pass one.
    final framing = widget.framing ?? ZoomFraming.identity(widget.videoSize);

    if (t.isNegative) {
      return SceneCameraSample(
        position: t,
        focal: widget.videoSize.center(Offset.zero),
        scale: 1.0,
      );
    }

    // Closed-interval lookup ([start, end]) — matches the visible camera
    // (`ZoomTransformer.getTransform` → `activeAt`) and the export pipeline
    // (`FrameCompositor._sceneSampleAt`). The previous half-open
    // `region.isActive(t)` loop excluded `t == endTime`, so `current` at
    // a region's end snapped to identity while `prev = sampleAt(t − exposure)`
    // stayed inside the ramp — producing a HUGE artificial smear whenever
    // the playhead parked at a region's endTime (most visibly at video end,
    // where auto-zoom regions are clamped to videoDuration and the playhead
    // pins there indefinitely).
    final active = ZoomRegion.activeAt(t, widget.zoomRegions);
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
      final track = _trackFor(active, framing);
      if (track != null) {
        // Spring-camera focal (matches the visible camera), evaluated
        // deterministically so pause == play == export at this playhead.
        focal = track.focalAt(t);
      } else {
        final s = cursorAtFiltered(
          widget.cursorRecording,
          t,
          widget.cursorPostProcess,
        );
        focal = s == null
            ? widget.videoSize.center(Offset.zero)
            : Offset(
                s.x.toDouble().clamp(0, widget.videoSize.width),
                s.y.toDouble().clamp(0, widget.videoSize.height),
              );
      }
    }

    final matrix = _zoomTransformer.getTransform(
      position: t,
      zoomRegion: active,
      videoSize: widget.videoSize,
      focalPoint: focal,
      rampCurve:
          active.rampCurveOverride?.toFlutterCurve() ??
          widget.screenAnimationConfig.rampCurve,
      rampDurationScale: widget.screenAnimationConfig.rampDurationScale,
      framing: framing,
    );
    final scale = matrix.storage[0];
    // Measure the VISIBLE camera, not the raw controller focal. getTransform
    // clamps the focal so the zoomed viewport stays inside the canvas; for an
    // edge cursor the spring focal chases the raw cursor past that clamp once
    // the enter ramp ends, so smearing by the raw focal paints a phantom
    // trail over an image that is actually pinned at the edge — the "flicker
    // as the zoom settles". Clamp via framing (canvas-space for device frames,
    // video-space for identity) — kept in lock-step with
    // FrameCompositor._sceneSampleAt so preview == export.
    final visibleFocal = framing.clampFocal(focal, scale);
    return SceneCameraSample(position: t, focal: visibleFocal, scale: scale);
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
