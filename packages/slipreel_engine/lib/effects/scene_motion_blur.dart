import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Offset, Paint, Rect, Size;

import 'package:flutter/rendering.dart' show CustomPainter, Matrix4;

/// Perceptual response used by the scene-blur controls in both preview and
/// export. Keeping this math here prevents mid-range slider values from
/// producing different exposure lengths in the two renderers.
double sceneBlurMasterResponse(double value) => value * value * value / 0.25;

double sceneBlurChannelResponse(double value) => value * value * value;

double sceneBlurExposureScale({
  required double master,
  required double channel,
}) => sceneBlurMasterResponse(master) * sceneBlurChannelResponse(channel);

/// Which scene-level motion-blur pipeline to use.
enum SceneBlurMode {
  /// Short-shutter projective shader. The current camera pose and one prior
  /// pose are reduced to a z=0 homography, then sampled along one bounded
  /// exposure interval. This keeps pan, zoom, and 3D Sweep directional while
  /// avoiding the readable multi-frame ghosts produced by a long trajectory.
  shader,

  /// True frame accumulation. The captured composition is re-stamped at
  /// N sub-frame camera transforms with `1/N` alpha each, summed
  /// additively. Follows the actual camera path (e.g. a curving
  /// cursor-following zoom) instead of linearizing it, mirroring how
  /// the cursor's accumulation painter works. More expensive — N image
  /// draws per frame — but the smear shape matches the camera motion.
  accumulation,
}

/// Loads the post-process shader used for renderer-known scene motion:
/// camera zoom and camera pan/screen movement. Internal motion inside
/// the source video does not feed this pass.
class SceneMotionBlurShader {
  SceneMotionBlurShader._();

  static ui.FragmentProgram? _program;

  static ui.FragmentProgram? get maybeProgram => _program;

  static Future<ui.FragmentProgram> ensureLoaded() async {
    // Asset is declared in slipreel_engine/pubspec.yaml. From a
    // depending app (the screen_recorder shell) it resolves through
    // the package-prefixed path. From inside the engine's own tests
    // it resolves through the bare path. Try the depending-app path
    // first since that's the production lookup; fall back for tests.
    if (_program != null) return _program!;
    try {
      _program = await ui.FragmentProgram.fromAsset(
        'packages/slipreel_engine/shaders/scene_motion_blur.frag',
      );
    } catch (_) {
      _program = await ui.FragmentProgram.fromAsset(
        'shaders/scene_motion_blur.frag',
      );
    }
    return _program!;
  }
}

class SceneCameraSample {
  const SceneCameraSample({
    required this.position,
    required this.focal,
    required this.scale,
    this.screenScale = 1.0,
    this.transform,
    this.transformOrigin = Offset.zero,
  });

  final Duration position;
  final Offset focal;
  final double scale;

  /// Converts source-video motion into the output canvas coordinate
  /// system. The main preview/export render at native canvas size, so
  /// this is usually 1.0; playground previews inside a fitted viewport
  /// can pass their fitted scale.
  final double screenScale;

  /// Full camera transform at [position], expressed around [transformOrigin].
  ///
  /// The scalar [focal]/[scale] fields preserve the independently adjustable
  /// pan and zoom channels. This matrix supplies the projective residual that
  /// those two scalars cannot represent: 3D yaw/pitch, perspective, and any
  /// movement transform folded into the camera matrix.
  final Matrix4? transform;
  final Offset transformOrigin;
}

/// Canvas-space homography mapping a pixel in the current camera pose to the
/// position occupied by the same scene point in an earlier pose.
///
/// A Flutter 3D transform applied to the z=0 content plane is a 3x3 projective
/// mapping after perspective divide. Keeping the reduced homography here lets
/// the fragment shader reconstruct the real endpoint of a 3D Sweep trail
/// without passing or inverting a 4x4 matrix per pixel.
class SceneProjectiveTransform {
  const SceneProjectiveTransform._(this.values);

  static const identity = SceneProjectiveTransform._(<double>[
    1,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
  ]);

  final List<double> values;

  static SceneProjectiveTransform between({
    required Matrix4 current,
    required Matrix4 previous,
    required Offset origin,
  }) {
    final currentCanvas = _aroundOrigin(current, origin);
    final previousCanvas = _aroundOrigin(previous, origin);
    final currentPlane = _planeHomography(currentCanvas);
    final previousPlane = _planeHomography(previousCanvas);
    final inverseCurrent = _invert3(currentPlane);
    if (inverseCurrent == null) return identity;
    return SceneProjectiveTransform._(
      List<double>.unmodifiable(_multiply3(previousPlane, inverseCurrent)),
    );
  }

  Offset transformPoint(Offset point) {
    final x = point.dx;
    final y = point.dy;
    final w = values[6] * x + values[7] * y + values[8];
    if (w.abs() < 1e-9) return point;
    return Offset(
      (values[0] * x + values[1] * y + values[2]) / w,
      (values[3] * x + values[4] * y + values[5]) / w,
    );
  }

  bool get isIdentity {
    const expected = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];
    for (var i = 0; i < values.length; i++) {
      if ((values[i] - expected[i]).abs() > 1e-8) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SceneProjectiveTransform) return false;
    for (var i = 0; i < values.length; i++) {
      if (values[i] != other.values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);

  static Matrix4 _aroundOrigin(Matrix4 transform, Offset origin) =>
      (Matrix4.identity()..translateByDouble(origin.dx, origin.dy, 0, 1.0))
          .multiplied(transform)
          .multiplied(
            Matrix4.identity()
              ..translateByDouble(-origin.dx, -origin.dy, 0, 1.0),
          );

  static List<double> _planeHomography(Matrix4 matrix) => <double>[
    matrix.entry(0, 0),
    matrix.entry(0, 1),
    matrix.entry(0, 3),
    matrix.entry(1, 0),
    matrix.entry(1, 1),
    matrix.entry(1, 3),
    matrix.entry(3, 0),
    matrix.entry(3, 1),
    matrix.entry(3, 3),
  ];

  static List<double> _multiply3(List<double> a, List<double> b) {
    final out = List<double>.filled(9, 0);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        out[row * 3 + col] =
            a[row * 3] * b[col] +
            a[row * 3 + 1] * b[3 + col] +
            a[row * 3 + 2] * b[6 + col];
      }
    }
    return out;
  }

  static List<double>? _invert3(List<double> m) {
    final a = m[0], b = m[1], c = m[2];
    final d = m[3], e = m[4], f = m[5];
    final g = m[6], h = m[7], i = m[8];
    final determinant =
        a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (determinant.abs() < 1e-12) return null;
    final inv = 1.0 / determinant;
    return <double>[
      (e * i - f * h) * inv,
      (c * h - b * i) * inv,
      (b * f - c * e) * inv,
      (f * g - d * i) * inv,
      (a * i - c * g) * inv,
      (c * d - a * f) * inv,
      (d * h - e * g) * inv,
      (b * g - a * h) * inv,
      (a * e - b * d) * inv,
    ];
  }
}

class SceneMotionBlurSignal {
  const SceneMotionBlurSignal({
    required this.scaleDelta,
    required this.translation,
    this.projectiveTransform,
    this.projectiveScaleDelta = 0,
    this.projectiveTranslation = Offset.zero,
  });

  static const zero = SceneMotionBlurSignal(
    scaleDelta: 0,
    translation: Offset.zero,
  );

  final double scaleDelta;
  final Offset translation;

  /// Exact current→previous camera mapping at the zoom/orientation exposure.
  /// [projectiveScaleDelta] and [projectiveTranslation] are the old scalar
  /// approximation over that same window. The shader subtracts that baseline
  /// before adding the projective result, so the independent movement/zoom
  /// channel exposure lengths remain authoritative.
  final SceneProjectiveTransform? projectiveTransform;
  final double projectiveScaleDelta;
  final Offset projectiveTranslation;

  bool get hasMotion =>
      scaleDelta.abs() > 0.00005 ||
      translation.distance > 0.01 ||
      (projectiveTransform != null && !projectiveTransform!.isIdentity);
}

/// Stateless scene-motion-blur signal compute.
///
/// The shader signal contains the current-to-previous camera step. It is a
/// pure function of
/// `(position, sampleAt, exposure, maxTranslation)` — no history, no EMA, no
/// `smooth:` flag. Determinism is the contract:
/// the editor preview (pause, play, scrub) and the export pipeline
/// must all produce the same signal at the same playhead, by
/// construction.
///
/// Earlier versions of this class held a history list and an EMA
/// across `update()` calls so the blur didn't pop frame-to-frame.
/// That made pause-vs-play diverge (pause skipped the EMA, play
/// applied it), and made the signal path-dependent (scrub-to-T ≠
/// played-up-to-T). The EMA was also masking real content variation —
/// motion blur is supposed to be bigger on a fast frame than a slow
/// one. The popping it was hiding came from playhead micro-jitter
/// (now fixed at the source) and history-edge crossings (no longer
/// possible without history). So the smoother is gone.
class SceneMotionBlurController {
  SceneMotionBlurController._();

  /// Returns the scene-blur signal at [position], given a stateless
  /// `(focal, scale)` lookup [sampleAt] callable at any timestamp.
  /// Both the current sample and the prev sample (at `position −
  /// exposure`) come from [sampleAt] — same engine on both sides
  /// keeps the translation symmetric.
  static SceneMotionBlurSignal compute({
    required Duration position,
    required SceneCameraSample Function(Duration) sampleAt,
    required Duration movementExposure,
    required Duration zoomExposure,
    required double maxTranslation,
  }) {
    final samples = <int, SceneCameraSample>{};
    SceneCameraSample cachedSampleAt(Duration time) =>
        samples.putIfAbsent(time.inMicroseconds, () => sampleAt(time));

    final current = cachedSampleAt(position);
    final movementPrevious = movementExposure <= Duration.zero
        ? null
        : cachedSampleAt(current.position - movementExposure);
    final projectivePrevious = zoomExposure <= Duration.zero
        ? null
        : cachedSampleAt(current.position - zoomExposure);
    final projectiveTransform =
        current.transform == null || projectivePrevious?.transform == null
        ? null
        : SceneProjectiveTransform.between(
            current: current.transform!,
            previous: projectivePrevious!.transform!,
            origin: current.transformOrigin,
          );
    return SceneMotionBlurSignal(
      scaleDelta: _scaleDeltaBetween(current, projectivePrevious),
      translation: _translationBetween(
        current,
        movementPrevious,
        maxTranslation,
      ),
      projectiveTransform: projectiveTransform,
      projectiveScaleDelta: _scaleDeltaBetween(current, projectivePrevious),
      projectiveTranslation: _translationBetween(
        current,
        projectivePrevious,
        double.infinity,
      ),
    );
  }

  static double _scaleDeltaBetween(
    SceneCameraSample current,
    SceneCameraSample? previous,
  ) {
    if (previous == null || current.scale == 0) return 0;
    return 1.0 - previous.scale / current.scale;
  }

  static Offset _translationBetween(
    SceneCameraSample current,
    SceneCameraSample? previous,
    double maxTranslation,
  ) {
    if (previous == null) return Offset.zero;
    final raw =
        (previous.focal - current.focal) * previous.scale * current.screenScale;
    if (raw.distance > maxTranslation) {
      return raw * (maxTranslation / raw.distance);
    }
    return raw;
  }
}

class SceneMotionBlurPainter extends CustomPainter {
  SceneMotionBlurPainter({
    required this.image,
    required this.program,
    required this.signal,
    required this.sampleCount,
    // Accepted for source compatibility with the former speed-curve shader.
    double? speedCurveExp,
    double? speedCurveRefPx,
    required this.devicePixelRatio,
  });

  final ui.Image image;
  final ui.FragmentProgram program;
  final SceneMotionBlurSignal signal;
  final int sampleCount;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    paintSceneMotionBlur(
      canvas: canvas,
      image: image,
      program: program,
      size: size,
      signal: signal,
      sampleCount: sampleCount,
      devicePixelRatio: devicePixelRatio,
    );
  }

  @override
  bool shouldRepaint(covariant SceneMotionBlurPainter old) {
    return old.image != image ||
        old.program != program ||
        old.signal.scaleDelta != signal.scaleDelta ||
        old.signal.translation != signal.translation ||
        old.signal.projectiveTransform != signal.projectiveTransform ||
        old.signal.projectiveScaleDelta != signal.projectiveScaleDelta ||
        old.signal.projectiveTranslation != signal.projectiveTranslation ||
        old.sampleCount != sampleCount ||
        old.devicePixelRatio != devicePixelRatio;
  }
}

// One shader reused across paints (the documented Flutter pattern:
// create once, mutate uniforms per frame). fragmentShader() allocates
// GPU-side state; creating one per composed/previewed frame was pure
// churn. Safe because every uniform and the sampler are re-set on every
// call below — no state carries over (pinned by the shader-reuse test
// in frame_compositor_test.dart) — and the display list snapshots
// uniform data at record time, so a pending raster never observes the
// next frame's mutation.
ui.FragmentShader? _cachedShader;
ui.FragmentProgram? _cachedShaderProgram;

void paintSceneMotionBlur({
  required Canvas canvas,
  required ui.Image image,
  required ui.FragmentProgram program,
  required Size size,
  required SceneMotionBlurSignal signal,
  required int sampleCount,
  // Accepted for source compatibility with the former speed-curve shader.
  double? speedCurveExp,
  double? speedCurveRefPx,
  required double devicePixelRatio,
}) {
  final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  ui.FragmentShader shader;
  if (_cachedShaderProgram == program && _cachedShader != null) {
    shader = _cachedShader!;
  } else {
    shader = program.fragmentShader();
    _cachedShader = shader;
    _cachedShaderProgram = program;
  }
  shader
    ..setImageSampler(0, image)
    ..setFloat(0, size.width * dpr)
    ..setFloat(1, size.height * dpr)
    ..setFloat(2, size.width * dpr / 2)
    ..setFloat(3, size.height * dpr / 2)
    ..setFloat(4, signal.scaleDelta)
    ..setFloat(5, sampleCount.toDouble())
    ..setFloat(6, signal.translation.dx * dpr)
    ..setFloat(7, signal.translation.dy * dpr)
    ..setFloat(8, signal.projectiveTransform == null ? 0.0 : 1.0);

  final projective = signal.projectiveTransform;
  final projectiveValues =
      projective?.values ?? SceneProjectiveTransform.identity.values;
  shader
    ..setFloat(9, projectiveValues[0])
    ..setFloat(10, projectiveValues[1])
    ..setFloat(11, projectiveValues[2])
    ..setFloat(12, projectiveValues[3])
    ..setFloat(13, projectiveValues[4])
    ..setFloat(14, projectiveValues[5])
    ..setFloat(15, projectiveValues[6])
    ..setFloat(16, projectiveValues[7])
    ..setFloat(17, projectiveValues[8])
    ..setFloat(18, signal.projectiveScaleDelta)
    ..setFloat(19, signal.projectiveTranslation.dx * dpr)
    ..setFloat(20, signal.projectiveTranslation.dy * dpr)
    ..setFloat(21, dpr);

  // Draw the premultiplied accumulation directly. The shader normalises blur
  // colour by sampled coverage and reapplies the current scene alpha, keeping
  // the screen/card silhouette stable without the inward feather caused by a
  // post-process dstIn mask.
  canvas.save();
  canvas.scale(1.0 / dpr);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.width * dpr, size.height * dpr),
    Paint()..shader = shader,
  );
  canvas.restore();
}
