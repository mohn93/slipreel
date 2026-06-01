import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/effects/motion_blur_tuning.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/frame_painter.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:screen_recorder/ui/widgets/inspector/motion_blur_tuning_panel.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:slipreel_engine/rendering/cursor_motion_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';
import 'package:slipreel_engine/rendering/zoom_focal_controller.dart';

/// A dev-only screen for iterating on the cursor motion-blur algorithm
/// without rebuilding the entire editor every time. Loads a recording
/// (video + cursor sidecar), exposes the [MotionBlurTuning] knobs,
/// and shows live readouts of the velocity/chord/ramp values the
/// painter is currently computing at the scrubbed timestamp.
///
/// Accessed via long-press on a recent recording. Not wired into the
/// production navigation graph — strictly a workshop bench.
class MotionBlurPlaygroundScreen extends StatefulWidget {
  const MotionBlurPlaygroundScreen({super.key, required this.videoPath});

  final String videoPath;

  @override
  State<MotionBlurPlaygroundScreen> createState() =>
      _MotionBlurPlaygroundScreenState();
}

class _MotionBlurPlaygroundScreenState extends State<MotionBlurPlaygroundScreen>
    with TickerProviderStateMixin {
  late VideoPlayerController _controller;
  SmoothPlayheadController? _smoothPlayhead;
  // Playground-local chrome state. Mirrors the editor's per-clip
  // windowFrame but lives in a `setState`-driven field so we can swap
  // it without standing up Riverpod scopes for the workshop bench.
  WindowFrame _frame = WindowFrame.rounded();
  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
  bool _ready = false;
  String? _error;

  // Playground state — local, never persisted.
  //
  // Slider ranges intentionally smaller than 1.0 to keep the maximum
  // visual blur within a tasteful range — at master × channel × base
  // exposure, going past 50% master pushed the smear into "screen
  // wipe" territory rather than cinematic motion blur. Channel knobs
  // still span 0–100% so the user can lean one channel harder than
  // the others, but the master caps the combined intensity.
  static const double _maxMotionBlurIntensity = 0.5;
  MotionBlurTuning _tuning = MotionBlurTuning.defaults;
  // Default at half the new max so the playground opens with a
  // moderate amount of blur to see, not at the saturated cap.
  double _motionBlur = 0.25;
  final GlobalKey _captureKey = GlobalKey();

  // Render mode: legacy shader/stretched-smear, cursor accumulation,
  // or whole-frame post-process passes driven by renderer-known motion.
  _RenderMode _mode = _RenderMode.shader;
  double _accumExposureMs = 40.0;
  int _accumSampleCount = 32;
  // Peak Gaussian σ (px) for the cursor-type-change "vanish into a glow"
  // crossfade. 0 disables it.
  double _cursorTypeChangeBlurSigma = 4.0;
  double _cursorMovementBlur = 1.0;
  double _screenMovementBlur = 1.0;
  double _screenZoomBlur = 1.0;

  // Scene-level toggles so we can see the blur with realistic context.
  bool _chromeOn = true;
  bool _zoomsOn = true;

  // Scene Pass renderer: legacy single-velocity directional shader vs.
  // true accumulation that re-stamps the captured composition under N
  // sub-frame transforms (mirrors the cursor accumulation approach).
  SceneBlurMode _sceneBlurMode = SceneBlurMode.shader;
  int _sceneAccumSampleCount = 16;

  // Frame-blur mode state. The captured scene image is rasterized
  // from the RepaintBoundary in postFrameCallback and consumed by
  // the next paint (≈ 16 ms lag).
  ui.FragmentProgram? _sceneBlurProgram;
  ui.Image? _capturedScene;
  // Playhead at the time _capturedScene was captured. Shader
  // uniforms are computed from THIS playhead, not the current
  // playhead, so the smear matches the captured content's state
  // (eliminates the 1-frame mismatch that produces jitter).
  Duration _capturedPlayhead = Duration.zero;
  // Build-time playhead snapshot. Used to track the playhead that
  // matches the live composition's current render — so when we
  // capture in postFrameCallback we can record THIS value as the
  // captured playhead rather than the slightly-later playhead that
  // smoothPlayhead would report post-paint.
  Duration _buildTimePlayhead = Duration.zero;
  final GlobalKey _sceneBoundaryKey = GlobalKey();
  final ZoomTransformer _zoomTransformer = ZoomTransformer();
  final CursorMotionController _sceneCursorMotionController =
      CursorMotionController();
  final ZoomFocalController _sceneZoomFocalController = ZoomFocalController();
  final List<_SceneCameraSample> _sceneCameraHistory = <_SceneCameraSample>[];
  Duration? _lastSceneCameraQueryPosition;
  Duration? _lastSceneMotionPlayhead;
  double _sceneScaleDelta = 0;
  Offset _sceneTranslation = Offset.zero;
  double _capturedSceneScaleDelta = 0;
  Offset _capturedSceneTranslation = Offset.zero;
  double _frameBlurSampleCount = 48;
  // Frame-blur uses its own exposure window because the cursor-
  // accumulation default (40 ms) is too aggressive for whole-frame
  // radial blur — 40 ms during a zoom ramp can smear edges by 40+
  // pixels and the result looks more like a screen wipe than a
  // motion blur. 16 ms ≈ one 60 Hz frame interval ≈ 360° shutter,
  // matches what a real camera would produce.
  double _frameBlurExposureMs = 16.0;
  // Cap on the translation vector magnitude in logical pixels.
  // The raw `S_prev × (F_prev − F_now)` formula can spike to many
  // hundreds of pixels during fast cursor flicks because we use
  // raw cursorAt() as the focal, while production's focal smoother
  // (FIR + follow tween) limits how fast the camera can actually
  // track. The cap approximates that limit without porting the
  // smoother's stateful logic.
  double _frameBlurMaxTranslation = 60.0;
  // Speed-curve exponent: 1.0 = linear (smear ∝ speed), > 1 = slow
  // motions blur less, fast motions blur more (cinematic dynamic
  // range). Reference is the pivot magnitude — motion at that
  // magnitude gives the same smear at any exponent value.
  double _frameBlurSpeedCurveExp = 1.0;
  double _frameBlurSpeedCurveRefPx = 10.0;

  bool _pendingCapturePaint = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _controller = VideoPlayerController.file(File(widget.videoPath));
      await _controller.initialize();
      _metadata = await RecordingMetadata.loadForVideo(widget.videoPath);
      try {
        _cursorRecording = await CursorRecording.loadFromFile(
          '${widget.videoPath}.cursor.json',
        );
      } catch (_) {
        _cursorRecording = CursorRecording();
      }
      _smoothPlayhead = SmoothPlayheadController(
        videoController: _controller,
        vsync: this,
      );
      unawaited(_controller.setVolume(0)); // mute playground; result unneeded
      _controller.addListener(_onTick);
      // Also tick off the smoothPlayhead — it runs an internal Ticker
      // at animation-frame rate (60 Hz) while playing, whereas the
      // VideoPlayerController only emits position updates a few times
      // per second. Without this the canvas redrew at controller pace
      // and looked like ~5–10 fps.
      _smoothPlayhead!.addListener(_onTick);
      // Default to a chromed frame so the wallpaper backdrop is visible
      // — that's the realistic preview context. `_frame` is already
      // seeded with `WindowFrame.rounded()` at field-init time, so no
      // mutation is needed here.
      // Load the scene motion blur shader. Used by the frameBlur mode
      // to apply a radial motion smear to a captured snapshot of the
      // composition. Loaded lazily so the playground doesn't block
      // startup waiting for it.
      // Shader lives in the slipreel_engine package (P0-3 phase 2);
      // load via the package-prefixed asset path.
      _sceneBlurProgram = await ui.FragmentProgram.fromAsset(
        'packages/slipreel_engine/shaders/scene_motion_blur.frag',
      );
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to load: $e');
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _smoothPlayhead?.removeListener(_onTick);
    _smoothPlayhead?.dispose();
    _controller.dispose();
    _capturedScene?.dispose();
    super.dispose();
  }

  void _stepFrames(int delta) {
    final fps = _metadata?.fps ?? 60;
    final frameMicros = (1e6 / fps).round();
    final cur = _controller.value.position.inMicroseconds;
    final next = (cur + delta * frameMicros).clamp(
      0,
      _controller.value.duration.inMicroseconds,
    );
    _controller.pause();
    _controller.seekTo(Duration(microseconds: next));
  }

  Future<void> _dumpFrame() async {
    final boundary =
        _captureKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return;
    final ts = _controller.value.position.inMilliseconds;
    final home = Platform.environment['HOME'] ?? '/tmp';
    final out = File(
      '$home/Desktop/playground_${ts.toString().padLeft(6, '0')}ms.png',
    );
    await out.writeAsBytes(bytes.buffer.asUint8List());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved ${out.path}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        appBar: AppBar(title: const Text('Motion blur playground')),
        body: Center(
          child: Text(_error!, style: const TextStyle(color: Colors.white)),
        ),
      );
    }
    if (!_ready) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        appBar: AppBar(title: const Text('Motion blur playground')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2B2B3D),
        title: const Text('Motion blur playground'),
        actions: [
          IconButton(
            tooltip: 'Save frame to ~/Desktop',
            icon: const Icon(Icons.save_alt),
            onPressed: _dumpFrame,
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildLeft()),
          SizedBox(width: 360, child: _buildRight()),
        ],
      ),
    );
  }

  Widget _buildLeft() {
    if (_usesSceneCapture) {
      // Refresh the stabilized playhead first; everything downstream
      // (live readout, captured playhead, shader uniforms) reads it.
      _refreshStablePlayhead();
      _buildTimePlayhead = _frameAlignedPlayhead();
      WidgetsBinding.instance.addPostFrameCallback((_) => _captureScene());
    }
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: RepaintBoundary(
              key: _captureKey,
              child: _usesSceneCapture
                  ? _buildSceneCaptureCanvas()
                  : _buildCanvas(),
            ),
          ),
        ),
        _buildTransport(),
      ],
    );
  }

  bool get _usesSceneCapture => _usesSceneShader;

  // The playground's external capture-and-shader pipeline is used for
  // both the legacy frame-blur prototype AND the recommended scene-pass
  // mode. PlaybackCanvas has its own internal scene blur, but it lags
  // one frame behind the body (postFrameCallback capture) which makes
  // it visibly jitter during scrubs and knob drags — the playground's
  // pipeline doesn't have the same problem here, so we route through
  // it. The PlaybackCanvas's scene blur is disabled by passing
  // screenMovementBlur=0 and screenZoomBlur=0 in scene-pass mode,
  // preventing the double-application that previously made the knob's
  // 1–100% range look identical.
  bool get _usesSceneShader =>
      _mode == _RenderMode.frameBlur || _mode == _RenderMode.scenePass;

  /// Composition rendered into a RepaintBoundary so we can capture
  /// it to a ui.Image each frame, then drawn AGAIN through a
  /// fragment-shader-equipped CustomPaint that consumes the image
  /// and applies a radial + translation motion-blur smear. The
  /// captured image has a one-frame lag relative to live state —
  /// acceptable for the preview because the scene only changes
  /// between frames anyway.
  Widget _buildSceneCaptureCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final outputSize = Size(constraints.maxWidth, constraints.maxHeight);
        _updateSceneMotionSignal(outputSize);
        return Stack(
          fit: StackFit.expand,
          children: [
            // Bottom layer: render the composition normally into the
            // boundary we capture from. Hidden visually under the
            // shader overlay (which fills the same rect).
            RepaintBoundary(key: _sceneBoundaryKey, child: _buildCanvas()),
            // Top layer: the captured frame, redrawn through the
            // radial+translation motion-blur shader. Until at least
            // one frame is captured, the bottom live composition
            // shows through.
            if (_usesSceneShader &&
                _capturedScene != null &&
                _sceneBlurProgram != null)
              IgnorePointer(
                child: CustomPaint(
                  painter: _SceneMotionBlurPainter(
                    image: _capturedScene!,
                    program: _sceneBlurProgram!,
                    // Uniforms computed at the captured playhead, NOT
                    // the live playhead. Smear matches captured
                    // content's state — eliminates the 1-frame
                    // mismatch that produced per-frame oscillation.
                    scaleDelta: _capturedSceneScaleDelta,
                    translation: _capturedSceneTranslation,
                    sampleCount: _frameBlurSampleCount.round(),
                    speedCurveExp: _frameBlurSpeedCurveExp,
                    speedCurveRefPx: _frameBlurSpeedCurveRefPx,
                    devicePixelRatio: dpr,
                  ),
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                ),
              ),
          ],
        );
      },
    );
  }

  void _captureScene() {
    if (!mounted) return;
    final boundary =
        _sceneBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    try {
      // Don't gate on boundary.debugNeedsPaint — toImageSync forces a
      // repaint internally if the layer is dirty, so skipping was
      // turning some frames into stale-image gaps that read as
      // jitter. Always capture; catch the rare exception.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final image = boundary.toImageSync(pixelRatio: dpr);
      // Use the BUILD-time playhead, not the current (post-paint)
      // playhead. The captured image's content was rendered with
      // the build-time playhead, so matching uniforms to that value
      // gives a frame-for-frame consistent shader output.
      _capturedScene?.dispose();
      _capturedScene = image;
      _capturedPlayhead = _buildTimePlayhead;
      _capturedSceneScaleDelta = _sceneScaleDelta;
      _capturedSceneTranslation = _sceneTranslation;
      if (_pendingCapturePaint) {
        _pendingCapturePaint = false;
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Capture can occasionally fail mid-layout — keep the previous
      // capture so we don't flash a blank frame.
    }
  }

  /// `1 - S_prev / S_now`. Positive ⇒ zoom ramping in (scene scales
  /// outward from the focal); negative ⇒ ramping out (scene shrinks
  /// toward the focal). Zero ⇒ no motion, shader passes the captured
  /// image through unchanged.
  /// Stabilized playhead used everywhere the frame-blur math reads
  /// "current time". Updated by [_refreshStablePlayhead] at the
  /// start of every build.
  Duration _stablePlayhead = Duration.zero;

  /// Updates [_stablePlayhead] based on the current playback state:
  ///
  ///   - PLAYING: advance smoothly with smoothPlayhead (the natural
  ///     per-vsync interpolation looks fine in motion).
  ///   - PAUSED: lock the playhead. Only release the lock if the
  ///     incoming raw playhead deviates by more than 100 ms (the
  ///     user must have scrubbed). Without this lock,
  ///     micro-jitter from the video controller (~1–3 ms per
  ///     frame, occasionally crossing a video-frame boundary)
  ///     leaks into scaleDelta/translation and the shader output.
  void _refreshStablePlayhead() {
    final raw = (_smoothPlayhead?.position) ?? _controller.value.position;
    if (!_controller.value.isPlaying) {
      final diff = (raw.inMicroseconds - _stablePlayhead.inMicroseconds).abs();
      if (_stablePlayhead == Duration.zero || diff > 100000) {
        _stablePlayhead = raw;
      }
      return;
    }
    _stablePlayhead = raw;
  }

  /// Current stabilized playhead — see [_refreshStablePlayhead] for
  /// when it locks vs follows.
  Duration _frameAlignedPlayhead() => _stablePlayhead;

  void _updateSceneMotionSignal(Size outputSize) {
    final current = _currentSceneCameraSample(outputSize);
    _appendSceneCameraSample(current);

    final rawScaleDelta = _rawSceneScaleDelta(current);
    final rawTranslation = _rawSceneTranslation(current);
    _smoothSceneMotionSignal(
      position: current.position,
      rawScaleDelta: rawScaleDelta,
      rawTranslation: rawTranslation,
    );
  }

  _SceneCameraSample _currentSceneCameraSample(Size outputSize) {
    final position = _buildTimePlayhead;
    _prepareSceneCameraControllers(position);

    final videoSize = _metadata == null
        ? const Size(1728, 1117)
        : Size(_metadata!.widthPx.toDouble(), _metadata!.heightPx.toDouble());
    final totalSize = FramePainter.calculateTotalSize(
      frame: _frame,
      videoSize: videoSize,
      aspect: OutputAspect.auto,
    );
    final fitScale = _sceneFitScale(outputSize, totalSize);
    final centre = videoSize.center(Offset.zero);

    if (!_zoomsOn) {
      _sceneZoomFocalController.update(
        position: position,
        zoomRegions: const <ZoomRegion>[],
        cursor: null,
        videoSize: videoSize,
      );
      return _SceneCameraSample(
        position: position,
        focal: centre,
        scale: 1,
        fitScale: fitScale,
      );
    }

    final zooms = _demoZooms();
    final activeZoomForCursor = _activeZoomAt(zooms, position);
    final hasCursorData =
        (_metadata?.isPureSource ?? true) && _cursorRecording.count > 0;
    final motion = hasCursorData
        ? _sceneCursorMotionController.update(
            position: position,
            cursorRecording: _cursorRecording,
            config: const CursorAnimationConfig.preset(
              CursorAnimationStyle.smooth,
            ),
            fps: _metadata?.fps ?? 60,
          )
        : null;

    final cursorForFocal =
        activeZoomForCursor?.followMode == FollowMode.predictive
        ? medianCursorOver(
            recording: _cursorRecording,
            t: position,
            window: activeZoomForCursor!.predictiveWindow,
          )
        : motion?.screenPos;

    final focalUpdate = _sceneZoomFocalController.update(
      position: position,
      zoomRegions: zooms,
      cursor: cursorForFocal,
      videoSize: videoSize,
    );

    if (focalUpdate == null) {
      return _SceneCameraSample(
        position: position,
        focal: centre,
        scale: 1,
        fitScale: fitScale,
      );
    }

    final activeZoom = focalUpdate.zoom;
    final transform = _zoomTransformer.getTransform(
      position: position,
      zoomRegion: activeZoom,
      videoSize: videoSize,
      focalPoint: focalUpdate.focal,
      rampCurve:
          activeZoom.rampCurveOverride?.toFlutterCurve() ??
          const ScreenAnimationConfig.preset(
            ScreenAnimationStyle.smooth,
          ).rampCurve,
    );

    return _SceneCameraSample(
      position: position,
      focal: focalUpdate.focal,
      scale: transform.storage[0],
      fitScale: fitScale,
    );
  }

  void _prepareSceneCameraControllers(Duration position) {
    final last = _lastSceneCameraQueryPosition;
    if (last != null) {
      final dt = position.inMicroseconds - last.inMicroseconds;
      if (dt < 0 || dt > 100000) {
        _sceneCursorMotionController.reset();
        _sceneZoomFocalController.reset();
        _sceneCameraHistory.clear();
        _lastSceneMotionPlayhead = null;
        _sceneScaleDelta = 0;
        _sceneTranslation = Offset.zero;
      }
    }
    _lastSceneCameraQueryPosition = position;
  }

  double _sceneFitScale(Size outputSize, Size naturalSize) {
    if (outputSize.width <= 0 ||
        outputSize.height <= 0 ||
        naturalSize.width <= 0 ||
        naturalSize.height <= 0) {
      return 1.0;
    }
    return math.min(
      outputSize.width / naturalSize.width,
      outputSize.height / naturalSize.height,
    );
  }

  void _appendSceneCameraSample(_SceneCameraSample sample) {
    if (_sceneCameraHistory.isNotEmpty) {
      final last = _sceneCameraHistory.last;
      if (sample.position == last.position) {
        _sceneCameraHistory[_sceneCameraHistory.length - 1] = sample;
        return;
      }
      if (sample.position < last.position) {
        _sceneCameraHistory.clear();
      }
    }

    _sceneCameraHistory.add(sample);
    final oldestAllowed = sample.position - const Duration(milliseconds: 700);
    while (_sceneCameraHistory.length > 2 &&
        _sceneCameraHistory.first.position < oldestAllowed) {
      _sceneCameraHistory.removeAt(0);
    }
  }

  double _rawSceneScaleDelta(_SceneCameraSample current) {
    final exposure = _effectiveScreenZoomExposure;
    if (exposure <= Duration.zero || current.scale == 0) return 0;

    final prev =
        _sceneCameraSampleAt(current.position - exposure) ??
        _approxSceneCameraSampleAt(
          current.position - exposure,
          current.fitScale,
        );
    return 1.0 - prev.scale / current.scale;
  }

  Offset _rawSceneTranslation(_SceneCameraSample current) {
    final exposure = _effectiveScreenMovementExposure;
    if (exposure <= Duration.zero) return Offset.zero;

    final prev =
        _sceneCameraSampleAt(current.position - exposure) ??
        _approxSceneCameraSampleAt(
          current.position - exposure,
          current.fitScale,
        );

    final raw = (prev.focal - current.focal) * prev.scale * current.fitScale;
    if (raw.distance > _frameBlurMaxTranslation) {
      return raw * (_frameBlurMaxTranslation / raw.distance);
    }
    return raw;
  }

  _SceneCameraSample? _sceneCameraSampleAt(Duration position) {
    if (_sceneCameraHistory.isEmpty) return null;
    if (position == _sceneCameraHistory.last.position) {
      return _sceneCameraHistory.last;
    }
    if (position < _sceneCameraHistory.first.position ||
        position > _sceneCameraHistory.last.position) {
      return null;
    }

    for (var i = 1; i < _sceneCameraHistory.length; i++) {
      final a = _sceneCameraHistory[i - 1];
      final b = _sceneCameraHistory[i];
      if (position == a.position) return a;
      if (position == b.position) return b;
      if (position > a.position && position < b.position) {
        final span = b.position.inMicroseconds - a.position.inMicroseconds;
        if (span <= 0) return b;
        final t = (position.inMicroseconds - a.position.inMicroseconds) / span;
        return _SceneCameraSample(
          position: position,
          focal: Offset.lerp(a.focal, b.focal, t)!,
          scale: ui.lerpDouble(a.scale, b.scale, t)!,
          fitScale: ui.lerpDouble(a.fitScale, b.fitScale, t)!,
        );
      }
    }
    return null;
  }

  _SceneCameraSample _approxSceneCameraSampleAt(
    Duration position,
    double fitScale,
  ) {
    final videoSize = _metadata == null
        ? const Size(1728, 1117)
        : Size(_metadata!.widthPx.toDouble(), _metadata!.heightPx.toDouble());
    return _SceneCameraSample(
      position: position,
      focal: _focalAt(position, videoSize),
      scale: _zoomScaleAt(position, videoSize),
      fitScale: fitScale,
    );
  }

  void _smoothSceneMotionSignal({
    required Duration position,
    required double rawScaleDelta,
    required Offset rawTranslation,
  }) {
    final last = _lastSceneMotionPlayhead;
    final dtUs = last == null
        ? 0
        : position.inMicroseconds - last.inMicroseconds;
    final snap =
        !_controller.value.isPlaying ||
        last == null ||
        dtUs <= 0 ||
        dtUs > 100000;

    if (snap) {
      _sceneScaleDelta = rawScaleDelta;
      _sceneTranslation = rawTranslation;
      _lastSceneMotionPlayhead = position;
      return;
    }

    final dtMs = dtUs / 1000.0;
    final scaleChangingDirection =
        _sceneScaleDelta.abs() > 0.0001 &&
        rawScaleDelta.abs() > 0.0001 &&
        (_sceneScaleDelta.sign != rawScaleDelta.sign);
    final scaleTauMs = scaleChangingDirection
        ? 45.0
        : rawScaleDelta.abs() > _sceneScaleDelta.abs()
        ? 55.0
        : 120.0;
    final translationChangingDirection =
        _sceneTranslation.distance > 0.01 &&
        rawTranslation.distance > 0.01 &&
        _dot(_sceneTranslation, rawTranslation) < 0;
    final translationTauMs = translationChangingDirection
        ? 45.0
        : rawTranslation.distance > _sceneTranslation.distance
        ? 55.0
        : 120.0;

    _sceneScaleDelta = ui.lerpDouble(
      _sceneScaleDelta,
      rawScaleDelta,
      _emaAlpha(dtMs, scaleTauMs),
    )!;
    _sceneTranslation = Offset.lerp(
      _sceneTranslation,
      rawTranslation,
      _emaAlpha(dtMs, translationTauMs),
    )!;
    _lastSceneMotionPlayhead = position;
  }

  double _emaAlpha(double dtMs, double tauMs) {
    if (tauMs <= 0) return 1;
    return 1 - math.exp(-dtMs / tauMs);
  }

  double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  void _resetSceneMotionTracking() {
    _sceneCursorMotionController.reset();
    _sceneZoomFocalController.reset();
    _sceneCameraHistory.clear();
    _lastSceneCameraQueryPosition = null;
    _lastSceneMotionPlayhead = null;
    _sceneScaleDelta = 0;
    _sceneTranslation = Offset.zero;
    _capturedSceneScaleDelta = 0;
    _capturedSceneTranslation = Offset.zero;
  }

  /// Effective exposure window for camera pan / screen movement.
  /// Master intensity scales the per-channel cap, so dragging the
  /// top slider preserves the relative Cursor / Screen movement /
  /// Screen zoom balance set in the advanced knobs.
  Duration get _effectiveScreenMovementExposure => Duration(
    microseconds:
        (_frameBlurExposureMs *
                _motionBlur *
                (_mode == _RenderMode.scenePass ? _screenMovementBlur : 1.0) *
                1000)
            .round(),
  );

  /// Effective exposure window for zoom scale blur. Kept separate
  /// from movement so a user can have punchy pan streaks without
  /// over-smearing radial zooms, or the opposite.
  Duration get _effectiveScreenZoomExposure => Duration(
    microseconds:
        (_frameBlurExposureMs *
                _motionBlur *
                (_mode == _RenderMode.scenePass ? _screenZoomBlur : 1.0) *
                1000)
            .round(),
  );

  double _computeScaleDelta([Duration? at]) {
    if (!_zoomsOn) return 0.0;
    final now = at ?? _frameAlignedPlayhead();
    final exposure = _effectiveScreenZoomExposure;
    final prev = now - exposure;
    final w = (_metadata?.widthPx ?? 1728).toDouble();
    final h = (_metadata?.heightPx ?? 1117).toDouble();
    final size = Size(w, h);
    final scaleNow = _zoomScaleAt(now, size);
    final scalePrev = _zoomScaleAt(prev, size);
    if (scaleNow == 0) return 0;
    return 1.0 - scalePrev / scaleNow;
  }

  double _zoomScaleAt(Duration t, Size videoSize) {
    if (!_zoomsOn) return 1.0;
    for (final region in _demoZooms()) {
      if (region.isActive(t)) {
        final m = _zoomTransformer.getTransform(
          position: t,
          zoomRegion: region,
          videoSize: videoSize,
        );
        return m.storage[0]; // matches Matrix4 column-major x-scale
      }
    }
    return 1.0;
  }

  /// Focal point in video pixels at time [t]. For a cursor-following
  /// region, approximates production's smoothed focal with a
  /// **fixed-lag** cursor lookup — `focal(t) = cursorAt(t - lag)`.
  ///
  /// Previously we used a moving average over the last 400 ms. That
  /// produced sub-pixel noise per frame because the 12 sample times
  /// shifted forward by 16 ms each frame, and `cursorAt`'s linear-
  /// interpolation between recorded cursor samples produced slightly
  /// different averages every frame. The noise propagated into the
  /// `translation` uniform and made the shader smear sub-pixel-shimmer
  /// every frame — visible as jitter on high-contrast edges.
  ///
  /// Fixed-lag is bit-stable when the cursor was stationary at the
  /// lagged time (so `focal_now == focal_prev` exactly ⇒ zero
  /// translation ⇒ no shader noise) and smoothly evolves when the
  /// cursor was moving.
  Offset _focalAt(Duration t, Size videoSize) {
    final defaultFocal = videoSize.center(Offset.zero);
    if (!_zoomsOn) return defaultFocal;
    for (final region in _demoZooms()) {
      if (!region.isActive(t)) continue;
      if (!region.followCursor) return region.rect.center;
      // 200 ms ≈ half of production's 400 ms follow duration. The
      // rendered camera lags the cursor by roughly half its follow
      // window in steady state; this matches without needing the
      // controller's full stateful tween.
      final laggedT = t - const Duration(milliseconds: 200);
      if (laggedT.isNegative) return region.rect.center;
      final s = cursorAt(_cursorRecording, laggedT);
      if (s == null) return region.rect.center;
      return Offset(
        s.x.toDouble().clamp(0, videoSize.width),
        s.y.toDouble().clamp(0, videoSize.height),
      );
    }
    return defaultFocal;
  }

  /// Translation component of the per-frame motion blur in logical
  /// pixels: `S_prev × (F_prev − F_now)`. Captures rigid camera pan
  /// when the focal is moving — even during the hold phase of a
  /// zoom region where the scale is constant.
  Offset _computeTranslation([Duration? at]) {
    if (!_zoomsOn) return Offset.zero;
    final now = at ?? _frameAlignedPlayhead();
    final exposure = _effectiveScreenMovementExposure;
    final prev = now - exposure;
    final w = (_metadata?.widthPx ?? 1728).toDouble();
    final h = (_metadata?.heightPx ?? 1117).toDouble();
    final size = Size(w, h);
    final fNow = _focalAt(now, size);
    final fPrev = _focalAt(prev, size);
    final sPrev = _zoomScaleAt(prev, size);
    final raw = (fPrev - fNow) * sPrev;
    // Clamp the magnitude so a fast cursor flick can't blow the
    // smear up to several hundred pixels — see comment on the
    // _frameBlurMaxTranslation field.
    if (raw.distance > _frameBlurMaxTranslation) {
      return raw * (_frameBlurMaxTranslation / raw.distance);
    }
    return raw;
  }

  /// Single canvas for all cursor/scene modes — the differences are
  /// [cursorBlurMode] (shader vs accumulation), the optional chrome
  /// frame, and the demo zoom regions. Wallpaper / padding / zoom
  /// transform all flow through PlaybackCanvas the same way they
  /// would in production.
  Widget _buildCanvas() {
    // Per-mode cursor pipeline:
    //
    //   shader      → legacy chord-stretched single sprite.
    //   accumulation → multi-stamp cursor accumulation.
    //   frameBlur /
    //   scenePass   → cursor uses accumulation too AND the
    //                 post-process radial+translation shader runs
    //                 on top. The cursor smears via its sub-frame
    //                 stamps; the frame post-process adds camera-
    //                 motion smear on top. Frame-blur translation
    //                 is now driven by a smoothed focal approximation,
    //                 so cursor flicks no longer trigger huge frame
    //                 smear.
    final blurMode = _mode == _RenderMode.shader
        ? CursorBlurMode.shader
        : CursorBlurMode.accumulation;
    final inScenePass = _mode == _RenderMode.scenePass;
    // Sync chrome toggle into the playground's local frame. Deferred to
    // post-frame so the build doesn't setState reentrantly.
    final desiredFrame = _chromeOn ? WindowFrame.rounded() : WindowFrame.none();
    if (_frame != desiredFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _frame = desiredFrame);
      });
    }
    return PlaybackCanvas(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      frame: _frame,
      outputAspect: OutputAspect.auto,
      metadata: _metadata,
      cursorRecording: _cursorRecording,
      hideCursorOverlay: false,
      cursorSize: inScenePass ? 4.0 : 1.0,
      cursorStyle: CursorStyle.classic,
      cursorClickEffect: CursorClickEffect.none,
      showZoomDebug: false,
      zoomRegions: _zoomsOn ? _demoZooms() : const <ZoomRegion>[],
      screenAnimationConfig: const ScreenAnimationConfig.preset(
        ScreenAnimationStyle.smooth,
      ),
      cursorAnimationConfig: const CursorAnimationConfig.preset(
        CursorAnimationStyle.smooth,
      ),
      // Master intensity. Per-channel knobs (cursor / screen movement /
      // screen zoom) are forwarded separately below. In scene-pass mode
      // the playground applies its OWN scene blur externally (see
      // `_buildSceneCaptureCanvas`), so we disable PlaybackCanvas's
      // internal scene blur by passing 0 for the screen channels —
      // otherwise both layers would scale with the same knob and the
      // result would be either double-applied (saturated) or jittery
      // from the internal pipeline's 1-frame capture lag during
      // scrubs/knob drags. The cursor channel stays live because
      // cursor accumulation runs entirely inside PlaybackCanvas (no
      // capture lag — it stamps from the recording).
      motionBlur: _motionBlur,
      cursorMovementBlur: inScenePass ? _cursorMovementBlur : 1.0,
      screenMovementBlur: inScenePass ? 0.0 : 1.0,
      screenZoomBlur: inScenePass ? 0.0 : 1.0,
      motionBlurTuning: _tuning,
      cursorShadow: 0.0,
      clickSpring: ClickSpring.snappy,
      isHoverScrubbing: false,
      cursorBlurMode: blurMode,
      // In scene mode the cursor sprite is 4× bigger (~128 video px at
      // sizeMultiplier=4), so the trail has to be hundreds of pixels
      // long before it pokes visibly past the sprite. At typical UI
      // cursor velocity (~300–700 px/s), 150 ms exposure produces a
      // 45–105 px trail — still inside or barely past the sprite,
      // which is why every knob position 1–100% looked the same.
      // Bumping the base to 300 ms gives 90–210 px trail at the same
      // velocities — clearly past the sprite at moderate motion, and
      // the knob's 0–200% range now maps to 0–600 ms of exposure.
      accumulationExposureMs: inScenePass ? 300.0 : _accumExposureMs,
      accumulationSampleCount: _accumSampleCount,
      cursorTypeChangeBlurSigmaPx: _cursorTypeChangeBlurSigma,
      sceneBlurMode: _mode == _RenderMode.scenePass
          ? _sceneBlurMode
          : SceneBlurMode.shader,
      sceneAccumSampleCount: _sceneAccumSampleCount,
    );
  }

  /// A pair of demo zoom regions so we can see how the cursor blur
  /// interacts with camera transitions. Tuned for the canned recording
  /// (1728×1117, 16s long): one zoom early to show the enter ramp,
  /// one late to bracket the fast cursor flick around 13.2s.
  List<ZoomRegion> _demoZooms() {
    final w = (_metadata?.widthPx ?? 1728).toDouble();
    final h = (_metadata?.heightPx ?? 1117).toDouble();
    // Cursor-following is left on (default) so the demo matches
    // the original preview behaviour. The shader's radial model
    // doesn't account for the per-frame focal translation that
    // cursor-following adds — for now that small directional
    // mismatch is accepted as the price of matching production
    // camera motion.
    return [
      ZoomRegion(
        rect: Rect.fromCenter(
          center: Offset(w * 0.5, h * 0.4),
          width: w * 0.3,
          height: h * 0.3,
        ),
        startTime: const Duration(milliseconds: 1500),
        duration: const Duration(milliseconds: 3000),
        zoomLevel: 1.8,
        videoBounds: Size(w, h),
      ),
      ZoomRegion(
        rect: Rect.fromCenter(
          center: Offset(w * 0.48, h * 0.6),
          width: w * 0.25,
          height: h * 0.25,
        ),
        startTime: const Duration(milliseconds: 12500),
        duration: const Duration(milliseconds: 2500),
        zoomLevel: 2.0,
        videoBounds: Size(w, h),
      ),
    ];
  }

  ZoomRegion? _activeZoomAt(List<ZoomRegion> zooms, Duration t) {
    for (final zoom in zooms) {
      if (zoom.isActive(t)) return zoom;
    }
    return null;
  }

  Widget _buildTransport() {
    final pos = _controller.value.position;
    final dur = _controller.value.duration;
    final posMs = pos.inMilliseconds;
    final durMs = dur.inMilliseconds == 0 ? 1 : dur.inMilliseconds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: const Color(0xFF2B2B3D),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white70),
                tooltip: '-10 frames',
                onPressed: () => _stepFrames(-10),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.white70),
                tooltip: '-1 frame',
                onPressed: () => _stepFrames(-1),
              ),
              IconButton(
                icon: Icon(
                  _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () {
                  if (_controller.value.isPlaying) {
                    _controller.pause();
                  } else {
                    _controller.play();
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: Colors.white70),
                tooltip: '+1 frame',
                onPressed: () => _stepFrames(1),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white70),
                tooltip: '+10 frames',
                onPressed: () => _stepFrames(10),
              ),
              const SizedBox(width: 12),
              Text(
                '${(posMs / 1000).toStringAsFixed(3)}s / ${(durMs / 1000).toStringAsFixed(2)}s',
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          Slider(
            value: posMs.toDouble().clamp(0.0, durMs.toDouble()),
            min: 0,
            max: durMs.toDouble(),
            onChanged: (v) {
              _controller.pause();
              _controller.seekTo(Duration(milliseconds: v.round()));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRight() {
    return Container(
      color: const Color(0xFF1E1E2E),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _modeToggle(),
          const SizedBox(height: 16),
          _ReadoutsCard(
            position: _controller.value.position,
            cursorRecording: _cursorRecording,
            tuning: _tuning,
            videoSize: _metadata == null
                ? const Size(1, 1)
                : Size(
                    _metadata!.widthPx.toDouble(),
                    _metadata!.heightPx.toDouble(),
                  ),
          ),
          const SizedBox(height: 16),
          Slider(
            value: _motionBlur.clamp(0.0, _maxMotionBlurIntensity),
            min: 0,
            max: _maxMotionBlurIntensity,
            divisions: 50,
            onChanged: (v) => _updatePlaygroundState(() => _motionBlur = v),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Master intensity — ${(_motionBlur * 100).toStringAsFixed(0)}%\n'
              'Caps at 50%; multiplies the Cursor / Screen movement / '
              'Screen zoom channels below. Going past 50% pushes the '
              'smear from "motion blur" into "screen wipe" territory.',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          const SizedBox(height: 16),
          if (_mode == _RenderMode.accumulation) _accumulationKnobs(),
          if (_mode == _RenderMode.frameBlur) _frameBlurKnobs(),
          if (_mode == _RenderMode.scenePass) ...[
            _recommendedStackNote(),
            const SizedBox(height: 16),
            _sceneRendererToggle(),
            const SizedBox(height: 16),
            _screenStudioChannelKnobs(),
          ],
          if (_mode == _RenderMode.shader)
            MotionBlurTuningPanel(
              tuning: _tuning,
              onChanged: (t) => _updatePlaygroundState(() => _tuning = t),
            ),
        ],
      ),
    );
  }

  Widget _modeToggle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_RenderMode>(
          segments: const [
            ButtonSegment(
              value: _RenderMode.shader,
              label: Text('Shader'),
              tooltip: 'Legacy cursor shader',
            ),
            ButtonSegment(
              value: _RenderMode.accumulation,
              label: Text('Cursor'),
              tooltip: 'Cursor accumulation only',
            ),
            ButtonSegment(
              value: _RenderMode.frameBlur,
              label: Text('Frame'),
              tooltip: 'Original frame-blur prototype',
            ),
            ButtonSegment(
              value: _RenderMode.scenePass,
              label: Text('Scene'),
              tooltip: 'Recommended whole-frame scene pass',
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => _setMode(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _modeDescription,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Chrome',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                value: _chromeOn,
                onChanged: (v) => _updatePlaygroundState(() => _chromeOn = v),
              ),
            ),
            Expanded(
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Zooms',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                value: _zoomsOn,
                onChanged: (v) => _updatePlaygroundState(() {
                  _zoomsOn = v;
                  _resetSceneMotionTracking();
                }),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _setMode(_RenderMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _capturedScene?.dispose();
      _capturedScene = null;
      _capturedPlayhead = Duration.zero;
      _resetSceneMotionTracking();
      _pendingCapturePaint = _usesSceneCapture;
    });
  }

  void _updatePlaygroundState(VoidCallback update) {
    setState(() {
      update();
      if (_usesSceneCapture) _pendingCapturePaint = true;
    });
  }

  String get _modeDescription {
    switch (_mode) {
      case _RenderMode.shader:
        return 'Legacy cursor-only shader. Fast straight-line smear for the cursor sprite.';
      case _RenderMode.accumulation:
        return 'Cursor-only accumulation. Stamps the cursor along its recorded path.';
      case _RenderMode.frameBlur:
        return 'Original whole-frame prototype. Captures the composition and runs the scene shader.';
      case _RenderMode.scenePass:
        return 'Screen Studio-style stack. Cursor, screen movement, and screen zoom blur are controlled separately.';
    }
  }

  Widget _recommendedStackNote() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'SCREEN STUDIO-STYLE STACK\n\n'
        'Only renderer-known motion is blurred: cursor movement, camera '
        'pan/screen movement, and camera zoom. If the camera is still and '
        'the recorded app contents move internally, those pixels stay sharp.',
        style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.35),
      ),
    );
  }

  Widget _sceneRendererToggle() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SCENE RENDERER',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<SceneBlurMode>(
            segments: const [
              ButtonSegment(
                value: SceneBlurMode.shader,
                label: Text('Shader'),
                tooltip: 'Single-velocity directional smear',
              ),
              ButtonSegment(
                value: SceneBlurMode.accumulation,
                label: Text('Accum'),
                tooltip: 'N sub-frame stamps of the captured composition',
              ),
            ],
            selected: {_sceneBlurMode},
            onSelectionChanged: (s) =>
                _updatePlaygroundState(() => _sceneBlurMode = s.first),
          ),
          if (_sceneBlurMode == SceneBlurMode.accumulation) ...[
            const SizedBox(height: 12),
            Text(
              'Sub-frame stamps — $_sceneAccumSampleCount',
              style: const TextStyle(color: Colors.white),
            ),
            Slider(
              value: _sceneAccumSampleCount.toDouble(),
              min: 2,
              max: 48,
              divisions: 46,
              onChanged: (v) => _updatePlaygroundState(
                () => _sceneAccumSampleCount = v.round(),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            _sceneBlurMode == SceneBlurMode.shader
                ? 'Shader: one (scaleDelta, translation) vector applied uniformly across the captured composition. Linear smear — fast, single direction.'
                : 'Accumulation: re-stamps the captured composition under N sub-frame transforms with 1/N alpha each, additively. Smear follows the actual camera trajectory (curves with cursor-following pan, ramps with the zoom curve). N image draws per frame.',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _screenStudioChannelKnobs() {
    Widget channelSlider({
      required String label,
      required double value,
      required ValueChanged<double> onChanged,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label — ${(value * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: value.clamp(0.0, 1.0),
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: onChanged,
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ADVANCED CHANNEL CAPS',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          channelSlider(
            label: 'Cursor movement',
            value: _cursorMovementBlur,
            onChanged: (v) =>
                _updatePlaygroundState(() => _cursorMovementBlur = v),
          ),
          channelSlider(
            label: 'Screen movement',
            value: _screenMovementBlur,
            onChanged: (v) =>
                _updatePlaygroundState(() => _screenMovementBlur = v),
          ),
          channelSlider(
            label: 'Screen zoom',
            value: _screenZoomBlur,
            onChanged: (v) => _updatePlaygroundState(() => _screenZoomBlur = v),
          ),
          const SizedBox(height: 4),
          Text(
            'Effective cursor: ${(_motionBlur * _cursorMovementBlur * 100).toStringAsFixed(0)}%\n'
            'Cursor exposure: ${(300.0 * _motionBlur * _cursorMovementBlur).toStringAsFixed(1)} ms (base 300 in Scene)\n'
            'Effective movement shutter: ${(_effectiveScreenMovementExposure.inMicroseconds / 1000).toStringAsFixed(1)} ms\n'
            'Effective zoom shutter: ${(_effectiveScreenZoomExposure.inMicroseconds / 1000).toStringAsFixed(1)} ms',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The master intensity multiplies these caps. Cursor movement '
            'drives cursor accumulation; screen movement drives camera-pan '
            'translation blur; screen zoom drives radial scale blur.',
            style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _frameBlurKnobs() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FRAME BLUR (POST-PROCESS)',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Shutter (ms) — ${_frameBlurExposureMs.toStringAsFixed(0)}',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _frameBlurExposureMs,
            min: 2,
            max: 80,
            onChanged: (v) =>
                _updatePlaygroundState(() => _frameBlurExposureMs = v),
          ),
          Text(
            'Shader taps — ${_frameBlurSampleCount.round()}',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _frameBlurSampleCount,
            min: 2,
            max: 64,
            divisions: 62,
            onChanged: (v) =>
                _updatePlaygroundState(() => _frameBlurSampleCount = v),
          ),
          Text(
            'Max translation (px) — ${_frameBlurMaxTranslation.toStringAsFixed(0)}',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _frameBlurMaxTranslation,
            min: 5,
            max: 300,
            onChanged: (v) =>
                _updatePlaygroundState(() => _frameBlurMaxTranslation = v),
          ),
          Text(
            'Speed curve (p) — ${_frameBlurSpeedCurveExp.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _frameBlurSpeedCurveExp,
            min: 0.5,
            max: 3.0,
            onChanged: (v) =>
                _updatePlaygroundState(() => _frameBlurSpeedCurveExp = v),
          ),
          Text(
            'Speed curve ref (px) — ${_frameBlurSpeedCurveRefPx.toStringAsFixed(0)}',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _frameBlurSpeedCurveRefPx,
            min: 1,
            max: 60,
            onChanged: (v) =>
                _updatePlaygroundState(() => _frameBlurSpeedCurveRefPx = v),
          ),
          const SizedBox(height: 4),
          () {
            final liveT = _frameAlignedPlayhead();
            final sdLive = _computeScaleDelta();
            final trLive = _computeTranslation();
            final sdCap = _computeScaleDelta(_capturedPlayhead);
            final trCap = _computeTranslation(_capturedPlayhead);
            return Text(
              'live   t=${(liveT.inMicroseconds / 1e6).toStringAsFixed(4)}\n'
              '       scaleD=${sdLive.toStringAsFixed(7)}\n'
              '       trans =(${trLive.dx.toStringAsFixed(3)}, '
              '${trLive.dy.toStringAsFixed(3)}) |${trLive.distance.toStringAsFixed(3)}|\n'
              'cap    t=${(_capturedPlayhead.inMicroseconds / 1e6).toStringAsFixed(4)}\n'
              '       scaleD=${sdCap.toStringAsFixed(7)}\n'
              '       trans =(${trCap.dx.toStringAsFixed(3)}, '
              '${trCap.dy.toStringAsFixed(3)}) |${trCap.distance.toStringAsFixed(3)}|\n'
              'gap    ${((liveT - _capturedPlayhead).inMicroseconds / 1000).toStringAsFixed(2)}ms',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            );
          }(),
          const SizedBox(height: 8),
          const Text(
            'Captures the composition each frame, then redraws it '
            'through a radial directional-blur shader. Per pixel: '
            'motion = (pixel - centre) × scaleDelta; sample [taps] '
            'points along that vector, average. scaleDelta ≠ 0 only '
            'during a zoom ramp, so a static-camera section passes '
            'through unchanged.',
            style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _accumulationKnobs() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ACCUMULATION',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Shutter (ms) — ${_accumExposureMs.toStringAsFixed(0)}',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _accumExposureMs,
            min: 4,
            max: 200,
            onChanged: (v) =>
                _updatePlaygroundState(() => _accumExposureMs = v),
          ),
          Text(
            'Sub-frame samples — $_accumSampleCount',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _accumSampleCount.toDouble(),
            min: 1,
            max: 32,
            divisions: 31,
            onChanged: (v) =>
                _updatePlaygroundState(() => _accumSampleCount = v.round()),
          ),
          const SizedBox(height: 4),
          const Text(
            'For each output frame, the cursor sprite is stamped at '
            "[sampleCount] sub-frame timestamps across [exposure] ms, "
            "each at 1/sampleCount alpha. Stationary stamps sum back "
            "to alpha=1; motion spreads them along the actual recorded "
            "path.",
            style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 16),
          Text(
            'Type-change blur σ — '
            '${_cursorTypeChangeBlurSigma.toStringAsFixed(1)} px',
            style: const TextStyle(color: Colors.white),
          ),
          Slider(
            value: _cursorTypeChangeBlurSigma,
            min: 0,
            max: 16,
            onChanged: (v) =>
                _updatePlaygroundState(() => _cursorTypeChangeBlurSigma = v),
          ),
          const SizedBox(height: 4),
          const Text(
            "When the recorded cursor state changes (arrow→I-beam→hand), "
            "stamps near the change get a Gaussian blur that peaks at the "
            "boundary and tapers to 0 across the exposure window. The "
            "cursor visibly dissolves into a soft glow and re-condenses "
            "as the new type, instead of hard-cutting between sprites. "
            "Set to 0 to disable.",
            style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

enum _RenderMode { shader, accumulation, frameBlur, scenePass }

class _SceneCameraSample {
  const _SceneCameraSample({
    required this.position,
    required this.focal,
    required this.scale,
    required this.fitScale,
  });

  final Duration position;
  final Offset focal;
  final double scale;
  final double fitScale;
}

/// Draws a captured snapshot of the composition through the
/// scene-motion-blur fragment shader. The shader smears each pixel
/// radially outward from the canvas centre by an amount proportional
/// to [scaleDelta], simulating the per-pixel motion vector of a
/// zoom transition.
class _SceneMotionBlurPainter extends CustomPainter {
  _SceneMotionBlurPainter({
    required this.image,
    required this.program,
    required this.scaleDelta,
    required this.translation,
    required this.sampleCount,
    required this.speedCurveExp,
    required this.speedCurveRefPx,
    required this.devicePixelRatio,
  });

  final ui.Image image;
  final ui.FragmentProgram program;
  final double scaleDelta;
  final Offset translation;
  final int sampleCount;
  final double speedCurveExp;
  final double speedCurveRefPx;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final shader = program.fragmentShader()
      ..setImageSampler(0, image)
      ..setFloat(0, size.width * dpr)
      ..setFloat(1, size.height * dpr)
      ..setFloat(2, size.width * dpr / 2)
      ..setFloat(3, size.height * dpr / 2)
      ..setFloat(4, scaleDelta)
      ..setFloat(5, sampleCount.toDouble())
      // Translation in image pixels = translation in logical px × dpr.
      ..setFloat(6, translation.dx * dpr)
      ..setFloat(7, translation.dy * dpr)
      // Speed-curve exponent + reference (in image pixels).
      ..setFloat(8, speedCurveExp)
      ..setFloat(9, speedCurveRefPx * dpr);
    // Draw into the logical (un-DPR-scaled) widget rect; the shader
    // is parameterised in image pixels (captured at full dpr) but
    // outputs at the canvas's logical resolution.
    canvas.save();
    canvas.scale(1.0 / dpr);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * dpr, size.height * dpr),
      Paint()..shader = shader,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SceneMotionBlurPainter old) {
    return old.image != image ||
        old.scaleDelta != scaleDelta ||
        old.translation != translation ||
        old.sampleCount != sampleCount ||
        old.speedCurveExp != speedCurveExp ||
        old.speedCurveRefPx != speedCurveRefPx ||
        old.devicePixelRatio != devicePixelRatio;
  }
}

/// Live numeric readouts of what the painter is computing at the
/// current scrubber position. Independent computation — doesn't peek
/// into the painter — but uses the same `cursorAt` + tuning the
/// painter does, so the numbers match what's being drawn.
class _ReadoutsCard extends StatelessWidget {
  const _ReadoutsCard({
    required this.position,
    required this.cursorRecording,
    required this.tuning,
    required this.videoSize,
  });

  final Duration position;
  final CursorRecording cursorRecording;
  final MotionBlurTuning tuning;
  final Size videoSize;

  static double _smoothstep(double lo, double hi, double x) {
    if (x <= lo) return 0.0;
    if (x >= hi) return 1.0;
    final t = (x - lo) / (hi - lo);
    return t * t * (3 - 2 * t);
  }

  @override
  Widget build(BuildContext context) {
    final t = position;
    final cur = cursorAt(cursorRecording, t);
    final exposureSec = tuning.maxExposureMs / 1000.0;
    final expStart = Duration(
      microseconds: t.inMicroseconds - (exposureSec * 1e6).round(),
    );
    final vLook = Duration(
      microseconds:
          t.inMicroseconds - (tuning.velocityLookbackMs * 1000).round(),
    );
    final gLook = Duration(
      microseconds: t.inMicroseconds - (tuning.gateLookbackMs * 1000).round(),
    );
    final prevExp = expStart.inMicroseconds >= 0
        ? cursorAt(cursorRecording, expStart)
        : null;
    final prevV = vLook.inMicroseconds >= 0
        ? cursorAt(cursorRecording, vLook)
        : null;
    final prevG = gLook.inMicroseconds >= 0
        ? cursorAt(cursorRecording, gLook)
        : null;

    double chord = 0;
    if (cur != null && prevExp != null) {
      chord = math
          .sqrt(math.pow(cur.x - prevExp.x, 2) + math.pow(cur.y - prevExp.y, 2))
          .toDouble();
    }
    double vTaper = 0;
    if (cur != null && prevV != null) {
      final d = math.sqrt(
        math.pow(cur.x - prevV.x, 2) + math.pow(cur.y - prevV.y, 2),
      );
      vTaper = (d / (tuning.velocityLookbackMs / 1000.0)).toDouble();
    }
    double vGate = 0;
    if (cur != null && prevG != null) {
      final d = math.sqrt(
        math.pow(cur.x - prevG.x, 2) + math.pow(cur.y - prevG.y, 2),
      );
      vGate = (d / (tuning.gateLookbackMs / 1000.0)).toDouble();
    }
    final ramp = _smoothstep(
      tuning.vTriggerLowPxPerSec,
      tuning.vTriggerHighPxPerSec,
      vGate,
    );
    final taperLen = vTaper * exposureSec;
    final lenBeforeRamp = math.min<double>(chord, taperLen);
    final lenAfterRamp = lenBeforeRamp * ramp;
    final lenCapped = math.min<double>(lenAfterRamp, tuning.maxTrailPx);

    String fmt(double v, [int frac = 1]) => v.toStringAsFixed(frac);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'monospace',
          color: Colors.white,
          fontSize: 12,
          height: 1.5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'READOUTS',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text('t          ${fmt(t.inMicroseconds / 1e6, 3)} s'),
            Text(
              cur == null
                  ? 'pos        — (no sample)'
                  : 'pos        (${fmt(cur.x.toDouble())}, ${fmt(cur.y.toDouble())}) of ${videoSize.width.toInt()}×${videoSize.height.toInt()}',
            ),
            const Divider(color: Colors.white12),
            Text(
              'chord      ${fmt(chord)} px  (exposure ${fmt(tuning.maxExposureMs, 0)}ms)',
            ),
            Text(
              'v_taper    ${fmt(vTaper, 0)} px/s  (lookback ${fmt(tuning.velocityLookbackMs)}ms)',
            ),
            Text(
              'v_gate     ${fmt(vGate, 0)} px/s  (lookback ${fmt(tuning.gateLookbackMs)}ms)',
            ),
            const Divider(color: Colors.white12),
            Text(
              'ramp       ${fmt(ramp, 3)}  (${fmt(tuning.vTriggerLowPxPerSec, 0)}→${fmt(tuning.vTriggerHighPxPerSec, 0)} px/s)',
            ),
            Text('taper_len  ${fmt(taperLen)} px  (v_taper × exposure)'),
            Text('len/ramp   ${fmt(lenAfterRamp)} px'),
            Text(
              'final_len  ${fmt(lenCapped)} px  (cap ${fmt(tuning.maxTrailPx, 0)})',
            ),
          ],
        ),
      ),
    );
  }
}
