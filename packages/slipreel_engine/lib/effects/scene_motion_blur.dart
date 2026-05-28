import 'dart:ui' as ui;
import 'dart:ui' show BlendMode, Canvas, Offset, Paint, Rect, Size;

import 'package:flutter/rendering.dart' show CustomPainter;

/// Which scene-level motion-blur pipeline to use.
enum SceneBlurMode {
  /// Single-velocity directional shader. The current and previous camera
  /// state are reduced to one `(scaleDelta, translation)` vector, baked
  /// into the [SceneMotionBlurShader] uniforms, and applied uniformly
  /// across the captured composition. Cheap (one image draw) but the
  /// blur is a linear smear regardless of how the camera actually
  /// trajected through the exposure window.
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
  });

  final Duration position;
  final Offset focal;
  final double scale;

  /// Converts source-video motion into the output canvas coordinate
  /// system. The main preview/export render at native canvas size, so
  /// this is usually 1.0; playground previews inside a fitted viewport
  /// can pass their fitted scale.
  final double screenScale;
}

class SceneMotionBlurSignal {
  const SceneMotionBlurSignal({
    required this.scaleDelta,
    required this.translation,
  });

  static const zero = SceneMotionBlurSignal(
    scaleDelta: 0,
    translation: Offset.zero,
  );

  final double scaleDelta;
  final Offset translation;

  bool get hasMotion =>
      scaleDelta.abs() > 0.00005 || translation.distance > 0.01;
}

/// Stateless scene-motion-blur signal compute.
///
/// The smear shader is intentionally simple: it needs only a radial
/// zoom delta and a uniform pan vector. Those two values are a pure
/// function of `(position, sampleAt, exposure, maxTranslation)` — no
/// history, no EMA, no `smooth:` flag. Determinism is the contract:
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
    final current = sampleAt(position);
    return SceneMotionBlurSignal(
      scaleDelta: _rawScaleDelta(current, zoomExposure, sampleAt),
      translation: _rawTranslation(
        current,
        movementExposure,
        maxTranslation,
        sampleAt,
      ),
    );
  }

  static double _rawScaleDelta(
    SceneCameraSample current,
    Duration exposure,
    SceneCameraSample Function(Duration) sampleAt,
  ) {
    if (exposure <= Duration.zero || current.scale == 0) return 0;
    final prev = sampleAt(current.position - exposure);
    return 1.0 - prev.scale / current.scale;
  }

  static Offset _rawTranslation(
    SceneCameraSample current,
    Duration exposure,
    double maxTranslation,
    SceneCameraSample Function(Duration) sampleAt,
  ) {
    if (exposure <= Duration.zero) return Offset.zero;
    final prev = sampleAt(current.position - exposure);
    final raw =
        (prev.focal - current.focal) * prev.scale * current.screenScale;
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
    required this.speedCurveExp,
    required this.speedCurveRefPx,
    required this.devicePixelRatio,
  });

  final ui.Image image;
  final ui.FragmentProgram program;
  final SceneMotionBlurSignal signal;
  final int sampleCount;
  final double speedCurveExp;
  final double speedCurveRefPx;
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
      speedCurveExp: speedCurveExp,
      speedCurveRefPx: speedCurveRefPx,
      devicePixelRatio: devicePixelRatio,
    );
  }

  @override
  bool shouldRepaint(covariant SceneMotionBlurPainter old) {
    return old.image != image ||
        old.program != program ||
        old.signal.scaleDelta != signal.scaleDelta ||
        old.signal.translation != signal.translation ||
        old.sampleCount != sampleCount ||
        old.speedCurveExp != speedCurveExp ||
        old.speedCurveRefPx != speedCurveRefPx ||
        old.devicePixelRatio != devicePixelRatio;
  }
}

void paintSceneMotionBlur({
  required Canvas canvas,
  required ui.Image image,
  required ui.FragmentProgram program,
  required Size size,
  required SceneMotionBlurSignal signal,
  required int sampleCount,
  required double speedCurveExp,
  required double speedCurveRefPx,
  required double devicePixelRatio,
}) {
  final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  final shader = program.fragmentShader()
    ..setImageSampler(0, image)
    ..setFloat(0, size.width * dpr)
    ..setFloat(1, size.height * dpr)
    ..setFloat(2, size.width * dpr / 2)
    ..setFloat(3, size.height * dpr / 2)
    ..setFloat(4, signal.scaleDelta)
    ..setFloat(5, sampleCount.toDouble())
    ..setFloat(6, signal.translation.dx * dpr)
    ..setFloat(7, signal.translation.dy * dpr)
    ..setFloat(8, speedCurveExp)
    ..setFloat(9, speedCurveRefPx * dpr);

  // Draw the smear into an isolated offscreen layer so we can clip it
  // to the foreground footprint at the end. The shader fills the
  // whole `size` rect; without clipping, pixels at the trailing edge
  // of the smear bleed into the padding area (where the captured
  // image was transparent), producing translucent foreground-coloured
  // streaks on top of the sticky wallpaper. dstIn with the original
  // image's alpha zeroes any pixel outside the foreground.
  final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
  canvas.saveLayer(dstRect, Paint());

  canvas.save();
  canvas.scale(1.0 / dpr);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.width * dpr, size.height * dpr),
    Paint()..shader = shader,
  );
  canvas.restore();

  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    dstRect,
    Paint()..blendMode = BlendMode.dstIn,
  );

  canvas.restore();
}
