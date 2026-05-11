import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import 'package:screen_recorder/effects/accumulation_cursor_painter.dart';
import 'package:screen_recorder/effects/motion_blur_tuning.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/motion_blur_tuning_panel.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';

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
  final FrameSettingsProvider _frameSettings = FrameSettingsProvider();
  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
  bool _ready = false;
  String? _error;

  // Playground state — local, never persisted.
  MotionBlurTuning _tuning = MotionBlurTuning.defaults;
  double _motionBlur = 1.0;
  final GlobalKey _captureKey = GlobalKey();

  // Render mode: legacy shader/stretched-smear OR the new accumulation
  // prototype that stamps the cursor at sub-frame positions.
  _RenderMode _mode = _RenderMode.shader;
  double _accumExposureMs = 40.0;
  int _accumSampleCount = 32;

  // Scene-level toggles so we can see the blur with realistic context.
  bool _chromeOn = true;
  bool _zoomsOn = true;

  // Frame-blur mode state. The captured scene image is rasterized
  // from the RepaintBoundary in postFrameCallback and consumed by
  // the next paint (≈ 16 ms lag).
  ui.FragmentProgram? _sceneBlurProgram;
  ui.Image? _capturedScene;
  final GlobalKey _sceneBoundaryKey = GlobalKey();
  final ZoomTransformer _zoomTransformer = ZoomTransformer();
  double _frameBlurSampleCount = 16;
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
            '${widget.videoPath}.cursor.json');
      } catch (_) {
        _cursorRecording = CursorRecording();
      }
      _smoothPlayhead =
          SmoothPlayheadController(videoController: _controller, vsync: this);
      _controller.setVolume(0);
      _controller.addListener(_onTick);
      // Also tick off the smoothPlayhead — it runs an internal Ticker
      // at animation-frame rate (60 Hz) while playing, whereas the
      // VideoPlayerController only emits position updates a few times
      // per second. Without this the canvas redrew at controller pace
      // and looked like ~5–10 fps.
      _smoothPlayhead!.addListener(_onTick);
      // Default to a chromed frame so the wallpaper backdrop is visible
      // — that's the realistic preview context.
      _frameSettings.setFrame(WindowFrame.rounded());
      // Load the scene motion blur shader. Used by the frameBlur mode
      // to apply a radial motion smear to a captured snapshot of the
      // composition. Loaded lazily so the playground doesn't block
      // startup waiting for it.
      _sceneBlurProgram =
          await ui.FragmentProgram.fromAsset('shaders/scene_motion_blur.frag');
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
    _frameSettings.dispose();
    _capturedScene?.dispose();
    super.dispose();
  }

  void _stepFrames(int delta) {
    final fps = _metadata?.fps ?? 60;
    final frameMicros = (1e6 / fps).round();
    final cur = _controller.value.position.inMicroseconds;
    final next = (cur + delta * frameMicros)
        .clamp(0, _controller.value.duration.inMicroseconds);
    _controller.pause();
    _controller.seekTo(Duration(microseconds: next));
  }

  Future<void> _dumpFrame() async {
    final boundary = _captureKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return;
    final ts = _controller.value.position.inMilliseconds;
    final home = Platform.environment['HOME'] ?? '/tmp';
    final out = File('$home/Desktop/playground_${ts.toString().padLeft(6, '0')}ms.png');
    await out.writeAsBytes(bytes.buffer.asUint8List());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved ${out.path}'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        appBar: AppBar(title: const Text('Motion blur playground')),
        body: Center(child: Text(_error!, style: const TextStyle(color: Colors.white))),
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
    // After this frame is on screen, capture the composition into
    // _capturedScene so the *next* frame's post-process pass has
    // something to apply the radial blur shader to. Cheap: only
    // active in frame-blur mode, only when we have an active zoom
    // (when no zoom is happening the shader short-circuits anyway).
    if (_mode == _RenderMode.frameBlur) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _captureScene());
    }
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: RepaintBoundary(
              key: _captureKey,
              child: _mode == _RenderMode.frameBlur
                  ? _buildFrameBlurCanvas()
                  : _buildCanvas(),
            ),
          ),
        ),
        _buildTransport(),
      ],
    );
  }

  /// Composition rendered into a RepaintBoundary so we can capture
  /// it to a ui.Image each frame, then drawn AGAIN through a
  /// fragment-shader-equipped CustomPaint that consumes the image
  /// and applies a radial motion-blur smear. The captured image
  /// has a one-frame lag relative to live state — acceptable for
  /// the preview because the scene only changes between frames
  /// anyway.
  Widget _buildFrameBlurCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Bottom layer: render the composition normally into the
            // boundary we capture from. Hidden visually under the
            // shader overlay (which fills the same rect).
            RepaintBoundary(
              key: _sceneBoundaryKey,
              child: _buildCanvas(),
            ),
            // Top layer: the captured frame, redrawn through the
            // radial motion-blur shader. Until we've captured at
            // least one frame, falls through to the bottom layer.
            if (_capturedScene != null && _sceneBlurProgram != null)
              IgnorePointer(
                child: CustomPaint(
                  painter: _SceneMotionBlurPainter(
                    image: _capturedScene!,
                    program: _sceneBlurProgram!,
                    scaleDelta: _computeScaleDelta(),
                    translation: _computeTranslation(),
                    sampleCount: _frameBlurSampleCount.round(),
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
    final boundary = _sceneBoundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null || boundary.debugNeedsPaint) return;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final image = boundary.toImageSync(pixelRatio: dpr);
      _capturedScene?.dispose();
      _capturedScene = image;
    } catch (_) {
      // Capture can fail mid-layout — skip this frame.
    }
  }

  /// `1 - S_prev / S_now`. Positive ⇒ zoom ramping in (scene scales
  /// outward from the focal); negative ⇒ ramping out (scene shrinks
  /// toward the focal). Zero ⇒ no motion, shader passes the captured
  /// image through unchanged.
  /// Effective exposure window for the frame blur. Scaled by the
  /// master motion-blur intensity so the top slider mutes both
  /// cursor accumulation AND frame blur together — when intensity
  /// is 0, exposure goes to 0 so scaleDelta and translation both
  /// collapse to 0 (no blur).
  Duration get _effectiveFrameBlurExposure => Duration(
      microseconds: (_frameBlurExposureMs * _motionBlur * 1000).round());

  double _computeScaleDelta() {
    if (!_zoomsOn) return 0.0;
    final now = (_smoothPlayhead?.position) ?? _controller.value.position;
    final exposure = _effectiveFrameBlurExposure;
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
  /// region, approximates production's smoothed focal with a moving
  /// average of the cursor over the last ~400 ms — matches the
  /// follow-duration of `ZoomFocalController` so the focal's
  /// frame-to-frame velocity stays close to what the actual rendered
  /// camera does. Using raw `cursorAt(t)` made every cursor flick
  /// trigger a full-frame blur even though the rendered camera
  /// barely moved.
  Offset _focalAt(Duration t, Size videoSize) {
    final defaultFocal = videoSize.center(Offset.zero);
    if (!_zoomsOn) return defaultFocal;
    for (final region in _demoZooms()) {
      if (!region.isActive(t)) continue;
      if (!region.followCursor) return region.rect.center;
      // Uniform mean over [t-400ms, t]. Production uses an FIR with
      // a similar response shape; the mean is close enough and
      // doesn't need any per-frame state.
      const windowMs = 400;
      const samples = 12;
      var sx = 0.0, sy = 0.0, count = 0;
      for (var i = 0; i < samples; i++) {
        final lookback = (windowMs * i / (samples - 1)).round();
        final ti = t - Duration(milliseconds: lookback);
        if (ti.isNegative) continue;
        final s = cursorAt(_cursorRecording, ti);
        if (s == null) continue;
        sx += s.x;
        sy += s.y;
        count++;
      }
      if (count == 0) return region.rect.center;
      return Offset(
        (sx / count).clamp(0, videoSize.width),
        (sy / count).clamp(0, videoSize.height),
      );
    }
    return defaultFocal;
  }

  /// Translation component of the per-frame motion blur in logical
  /// pixels: `S_prev × (F_prev − F_now)`. Captures rigid camera pan
  /// when the focal is moving — even during the hold phase of a
  /// zoom region where the scale is constant.
  Offset _computeTranslation() {
    if (!_zoomsOn) return Offset.zero;
    final now = (_smoothPlayhead?.position) ?? _controller.value.position;
    final exposure = _effectiveFrameBlurExposure;
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

  /// Single canvas for both modes — the only differences are
  /// [cursorBlurMode] (shader vs accumulation), the optional chrome
  /// frame, and the demo zoom regions. Wallpaper / padding / zoom
  /// transform all flow through PlaybackCanvas the same way they
  /// would in production.
  Widget _buildCanvas() {
    // Per-mode cursor pipeline:
    //
    //   shader      → legacy chord-stretched single sprite.
    //   accumulation → multi-stamp cursor accumulation.
    //   frameBlur   → cursor uses accumulation too AND the
    //                 post-process radial+translation shader runs
    //                 on top. The cursor smears via its sub-frame
    //                 stamps; the frame post-process adds camera-
    //                 motion smear on top. Frame-blur translation
    //                 is now driven by a 400 ms smoothed focal
    //                 (matches production's smoother), so cursor
    //                 flicks no longer trigger huge frame smear.
    final blurMode = _mode == _RenderMode.shader
        ? CursorBlurMode.shader
        : CursorBlurMode.accumulation;
    // Sync chrome toggle into the frame provider. setFrame is a no-op
    // when the frame matches, so doing it from build is fine.
    final desiredFrame = _chromeOn ? WindowFrame.rounded() : WindowFrame.none();
    if (_frameSettings.currentFrame != desiredFrame) {
      // Defer mutation so we don't notifyListeners inside build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _frameSettings.setFrame(desiredFrame);
      });
    }
    return PlaybackCanvas(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      frameSettings: _frameSettings,
      metadata: _metadata,
      cursorRecording: _cursorRecording,
      hideCursorOverlay: false,
      cursorSize: 1.0,
      cursorStyle: CursorStyle.classic,
      cursorClickEffect: CursorClickEffect.none,
      showZoomDebug: false,
      zoomRegions: _zoomsOn ? _demoZooms() : const <ZoomRegion>[],
      screenAnimationConfig:
          const ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth),
      cursorAnimationConfig:
          const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
      motionBlur: _motionBlur,
      motionBlurTuning: _tuning,
      cursorShadow: 0.0,
      isHoverScrubbing: false,
      cursorBlurMode: blurMode,
      accumulationExposureMs: _accumExposureMs,
      accumulationSampleCount: _accumSampleCount,
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
                    color: Colors.white),
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
                    color: Colors.white70, fontFamily: 'monospace'),
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
                : Size(_metadata!.widthPx.toDouble(),
                    _metadata!.heightPx.toDouble()),
          ),
          const SizedBox(height: 16),
          Slider(
            value: _motionBlur,
            min: 0,
            max: 1,
            onChanged: (v) => setState(() => _motionBlur = v),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('Motion blur intensity (0..1)',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          const SizedBox(height: 16),
          if (_mode == _RenderMode.accumulation) _accumulationKnobs(),
          if (_mode == _RenderMode.frameBlur) _frameBlurKnobs(),
          if (_mode == _RenderMode.shader)
            MotionBlurTuningPanel(
              tuning: _tuning,
              onChanged: (t) => setState(() => _tuning = t),
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
            ButtonSegment(value: _RenderMode.shader, label: Text('Shader')),
            ButtonSegment(
                value: _RenderMode.accumulation, label: Text('Cursor accum.')),
            ButtonSegment(
                value: _RenderMode.frameBlur, label: Text('Frame blur')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Chrome',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                value: _chromeOn,
                onChanged: (v) => setState(() => _chromeOn = v),
              ),
            ),
            Expanded(
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Zooms',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                value: _zoomsOn,
                onChanged: (v) => setState(() => _zoomsOn = v),
              ),
            ),
          ],
        ),
      ],
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
          const Text('FRAME BLUR (POST-PROCESS)',
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text('Exposure (ms) — ${_frameBlurExposureMs.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white)),
          Slider(
            value: _frameBlurExposureMs,
            min: 2,
            max: 80,
            onChanged: (v) => setState(() => _frameBlurExposureMs = v),
          ),
          Text('Shader taps — ${_frameBlurSampleCount.round()}',
              style: const TextStyle(color: Colors.white)),
          Slider(
            value: _frameBlurSampleCount,
            min: 2,
            max: 32,
            divisions: 30,
            onChanged: (v) => setState(() => _frameBlurSampleCount = v),
          ),
          Text(
              'Max translation (px) — ${_frameBlurMaxTranslation.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white)),
          Slider(
            value: _frameBlurMaxTranslation,
            min: 5,
            max: 300,
            onChanged: (v) =>
                setState(() => _frameBlurMaxTranslation = v),
          ),
          const SizedBox(height: 4),
          Text(
            'scaleDelta = ${_computeScaleDelta().toStringAsFixed(4)}\n'
            'translation = (${_computeTranslation().dx.toStringAsFixed(1)}, '
            '${_computeTranslation().dy.toStringAsFixed(1)}) px',
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'monospace'),
          ),
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
          const Text('ACCUMULATION',
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text('Exposure (ms) — ${_accumExposureMs.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white)),
          Slider(
            value: _accumExposureMs,
            min: 4,
            max: 200,
            onChanged: (v) => setState(() => _accumExposureMs = v),
          ),
          Text('Sub-frame samples — $_accumSampleCount',
              style: const TextStyle(color: Colors.white)),
          Slider(
            value: _accumSampleCount.toDouble(),
            min: 1,
            max: 32,
            divisions: 31,
            onChanged: (v) => setState(() => _accumSampleCount = v.round()),
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
        ],
      ),
    );
  }
}

enum _RenderMode { shader, accumulation, frameBlur }

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
    required this.devicePixelRatio,
  });

  final ui.Image image;
  final ui.FragmentProgram program;
  final double scaleDelta;
  final Offset translation;
  final int sampleCount;
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
      ..setFloat(7, translation.dy * dpr);
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
    final expStart =
        Duration(microseconds: t.inMicroseconds - (exposureSec * 1e6).round());
    final vLook = Duration(
        microseconds:
            t.inMicroseconds - (tuning.velocityLookbackMs * 1000).round());
    final gLook = Duration(
        microseconds:
            t.inMicroseconds - (tuning.gateLookbackMs * 1000).round());
    final prevExp =
        expStart.inMicroseconds >= 0 ? cursorAt(cursorRecording, expStart) : null;
    final prevV =
        vLook.inMicroseconds >= 0 ? cursorAt(cursorRecording, vLook) : null;
    final prevG =
        gLook.inMicroseconds >= 0 ? cursorAt(cursorRecording, gLook) : null;

    double chord = 0;
    if (cur != null && prevExp != null) {
      chord = math.sqrt(
        math.pow(cur.x - prevExp.x, 2) + math.pow(cur.y - prevExp.y, 2),
      ).toDouble();
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
        tuning.vTriggerLowPxPerSec, tuning.vTriggerHighPxPerSec, vGate);
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
            const Text('READOUTS',
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('t          ${fmt(t.inMicroseconds / 1e6, 3)} s'),
            Text(cur == null
                ? 'pos        — (no sample)'
                : 'pos        (${fmt(cur.x.toDouble())}, ${fmt(cur.y.toDouble())}) of ${videoSize.width.toInt()}×${videoSize.height.toInt()}'),
            const Divider(color: Colors.white12),
            Text('chord      ${fmt(chord)} px  (exposure ${fmt(tuning.maxExposureMs, 0)}ms)'),
            Text('v_taper    ${fmt(vTaper, 0)} px/s  (lookback ${fmt(tuning.velocityLookbackMs)}ms)'),
            Text('v_gate     ${fmt(vGate, 0)} px/s  (lookback ${fmt(tuning.gateLookbackMs)}ms)'),
            const Divider(color: Colors.white12),
            Text('ramp       ${fmt(ramp, 3)}  (${fmt(tuning.vTriggerLowPxPerSec, 0)}→${fmt(tuning.vTriggerHighPxPerSec, 0)} px/s)'),
            Text('taper_len  ${fmt(taperLen)} px  (v_taper × exposure)'),
            Text('len/ramp   ${fmt(lenAfterRamp)} px'),
            Text('final_len  ${fmt(lenCapped)} px  (cap ${fmt(tuning.maxTrailPx, 0)})'),
          ],
        ),
      ),
    );
  }
}
