import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import 'package:screen_recorder/effects/accumulation_cursor_painter.dart';
import 'package:screen_recorder/effects/motion_blur_tuning.dart';
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
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: RepaintBoundary(
              key: _captureKey,
              child: _buildCanvas(),
            ),
          ),
        ),
        _buildTransport(),
      ],
    );
  }

  /// Single canvas for both modes — the only differences are
  /// [cursorBlurMode] (shader vs accumulation), the optional chrome
  /// frame, and the demo zoom regions. Wallpaper / padding / zoom
  /// transform all flow through PlaybackCanvas the same way they
  /// would in production.
  Widget _buildCanvas() {
    final blurMode = _mode == _RenderMode.accumulation
        ? CursorBlurMode.accumulation
        : CursorBlurMode.shader;
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
                value: _RenderMode.accumulation, label: Text('Accumulation')),
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

enum _RenderMode { shader, accumulation }

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
