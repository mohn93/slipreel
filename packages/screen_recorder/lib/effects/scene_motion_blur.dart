import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
    return _program ??= await ui.FragmentProgram.fromAsset(
      'shaders/scene_motion_blur.frag',
    );
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

/// Stateful signal smoother for scene-level motion blur.
///
/// The smear shader is intentionally simple: it needs only a radial
/// zoom delta and a uniform pan vector. This controller derives those
/// two values from the same camera samples used by preview/export, then
/// applies a short attack/longer release so the blur does not pop from
/// huge to tiny between adjacent frames.
class SceneMotionBlurController {
  final List<SceneCameraSample> _history = <SceneCameraSample>[];
  Duration? _lastCameraPosition;
  Duration? _lastSignalPosition;
  SceneMotionBlurSignal _signal = SceneMotionBlurSignal.zero;

  SceneMotionBlurSignal update({
    required SceneCameraSample current,
    required Duration movementExposure,
    required Duration zoomExposure,
    required double maxTranslation,
    required bool smooth,
    SceneCameraSample Function(Duration)? approxSampleAt,
  }) {
    final lastCameraPosition = _lastCameraPosition;
    if (lastCameraPosition != null) {
      final dt =
          current.position.inMicroseconds - lastCameraPosition.inMicroseconds;
      if (dt < 0 || dt > _resetGap.inMicroseconds) {
        reset();
      }
    }
    _lastCameraPosition = current.position;
    _append(current);

    final raw = SceneMotionBlurSignal(
      scaleDelta: _rawScaleDelta(current, zoomExposure, approxSampleAt),
      translation: _rawTranslation(
          current, movementExposure, maxTranslation, approxSampleAt),
    );

    final lastSignalPosition = _lastSignalPosition;
    final dtUs = lastSignalPosition == null
        ? 0
        : current.position.inMicroseconds - lastSignalPosition.inMicroseconds;
    final canSmooth =
        smooth &&
        lastSignalPosition != null &&
        dtUs > 0 &&
        dtUs <= _resetGap.inMicroseconds;

    if (!canSmooth) {
      _signal = raw;
      _lastSignalPosition = current.position;
      return _signal;
    }

    final dtMs = dtUs / 1000.0;
    final scaleTauMs = _tauMs(
      currentMagnitude: _signal.scaleDelta.abs(),
      nextMagnitude: raw.scaleDelta.abs(),
      changingDirection:
          _signal.scaleDelta.abs() > 0.0001 &&
          raw.scaleDelta.abs() > 0.0001 &&
          _signal.scaleDelta.sign != raw.scaleDelta.sign,
    );
    final translationTauMs = _tauMs(
      currentMagnitude: _signal.translation.distance,
      nextMagnitude: raw.translation.distance,
      changingDirection:
          _signal.translation.distance > 0.01 &&
          raw.translation.distance > 0.01 &&
          _dot(_signal.translation, raw.translation) < 0,
    );

    _signal = SceneMotionBlurSignal(
      scaleDelta: ui.lerpDouble(
        _signal.scaleDelta,
        raw.scaleDelta,
        _emaAlpha(dtMs, scaleTauMs),
      )!,
      translation: Offset.lerp(
        _signal.translation,
        raw.translation,
        _emaAlpha(dtMs, translationTauMs),
      )!,
    );
    _lastSignalPosition = current.position;
    return _signal;
  }

  void reset() {
    _history.clear();
    _lastCameraPosition = null;
    _lastSignalPosition = null;
    _signal = SceneMotionBlurSignal.zero;
  }

  double _rawScaleDelta(
    SceneCameraSample current,
    Duration exposure,
    SceneCameraSample Function(Duration)? approxSampleAt,
  ) {
    if (exposure <= Duration.zero || current.scale == 0) return 0;
    final prevTime = current.position - exposure;
    final prev = _sampleAt(prevTime) ?? approxSampleAt?.call(prevTime);
    if (prev == null) return 0;
    return 1.0 - prev.scale / current.scale;
  }

  Offset _rawTranslation(
    SceneCameraSample current,
    Duration exposure,
    double maxTranslation,
    SceneCameraSample Function(Duration)? approxSampleAt,
  ) {
    if (exposure <= Duration.zero) return Offset.zero;
    final prevTime = current.position - exposure;
    final prev = _sampleAt(prevTime) ?? approxSampleAt?.call(prevTime);
    if (prev == null) return Offset.zero;

    final raw = (prev.focal - current.focal) * prev.scale * current.screenScale;
    if (raw.distance > maxTranslation) {
      return raw * (maxTranslation / raw.distance);
    }
    return raw;
  }

  void _append(SceneCameraSample sample) {
    if (_history.isNotEmpty) {
      final last = _history.last;
      if (sample.position == last.position) {
        _history[_history.length - 1] = sample;
        return;
      }
      if (sample.position < last.position) {
        _history.clear();
      }
    }

    _history.add(sample);
    final oldestAllowed = sample.position - const Duration(milliseconds: 700);
    while (_history.length > 2 && _history.first.position < oldestAllowed) {
      _history.removeAt(0);
    }
  }

  SceneCameraSample? _sampleAt(Duration position) {
    if (_history.isEmpty) return null;
    if (position == _history.last.position) return _history.last;
    if (position < _history.first.position ||
        position > _history.last.position) {
      return null;
    }

    for (var i = 1; i < _history.length; i++) {
      final a = _history[i - 1];
      final b = _history[i];
      if (position == a.position) return a;
      if (position == b.position) return b;
      if (position > a.position && position < b.position) {
        final span = b.position.inMicroseconds - a.position.inMicroseconds;
        if (span <= 0) return b;
        final t = (position.inMicroseconds - a.position.inMicroseconds) / span;
        return SceneCameraSample(
          position: position,
          focal: Offset.lerp(a.focal, b.focal, t)!,
          scale: ui.lerpDouble(a.scale, b.scale, t)!,
          screenScale: ui.lerpDouble(a.screenScale, b.screenScale, t)!,
        );
      }
    }
    return null;
  }

  double _tauMs({
    required double currentMagnitude,
    required double nextMagnitude,
    required bool changingDirection,
  }) {
    if (changingDirection) return 45.0;
    return nextMagnitude > currentMagnitude ? 55.0 : 120.0;
  }

  double _emaAlpha(double dtMs, double tauMs) {
    if (tauMs <= 0) return 1;
    return 1 - math.exp(-dtMs / tauMs);
  }

  double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  static const Duration _resetGap = Duration(milliseconds: 100);
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
