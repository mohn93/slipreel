import 'package:flutter/painting.dart';

/// Result of [computeMotionBlurSamples]: how many stamps to draw, the
/// per-stamp offset (so consecutive stamps step backwards along the
/// motion vector), and the alpha to assign each stamp. Tail at index
/// 0 (dimmest), head at index [count] - 1 (brightest, offset 0).
class MotionBlurSamples {
  const MotionBlurSamples({
    required this.count,
    required this.stepPx,
    required this.alphas,
  });

  final int count;
  final Offset stepPx;
  final List<double> alphas;
}

/// Single-stamp result reused for the no-blur short-circuit so callers
/// can branch on `samples.count == 1`.
const _noBlur = MotionBlurSamples(
  count: 1,
  stepPx: Offset.zero,
  alphas: [1.0],
);

/// Tunables on the no-blur shortcut. A blur strength below 0.05
/// renders identically to no blur to the eye, so we skip the
/// saveLayer + multi-stamp loop for it.
const _kEffectiveCutoff = 0.05;

/// Velocities slower than this don't produce visible directional
/// blur. Below it we report no blur regardless of slider value.
const _kMinSpeedPxPerSec = 1.0;

/// Returns the per-stamp parameters for cursor motion blur.
///
/// `effective = sliderIntensity × clamp(|v| / referenceSpeed, 0, 1)`.
/// Count grows from 1 at effective=0 to [maxStamps] at effective=1.
/// Step magnitude grows from 0 to `maxReachPx / (count - 1)`.
/// Alphas linearly taper from 1/Σ at the tail to count/Σ at the head
/// (Σ = N(N+1)/2), then are normalized so the alpha sum is 1.0.
MotionBlurSamples computeMotionBlurSamples({
  required Offset velocityPxPerSec,
  required double sliderIntensity,
  required double referenceSpeedPxPerSec,
  required double maxReachPx,
  int maxStamps = 8,
}) {
  if (sliderIntensity <= 0) return _noBlur;
  final speed = velocityPxPerSec.distance;
  if (speed < _kMinSpeedPxPerSec) return _noBlur;

  final effective =
      (sliderIntensity * speed / referenceSpeedPxPerSec).clamp(0.0, 1.0);
  if (effective < _kEffectiveCutoff) return _noBlur;

  final count = 1 + ((maxStamps - 1) * effective).round();
  // round() may collapse small effective values just above _kEffectiveCutoff to 0;
  // this guard catches the gap between _kEffectiveCutoff (0.05) and 1.0/(maxStamps-1) ~0.143
  if (count <= 1) return _noBlur;

  final reach = effective * maxReachPx;
  final stepMag = reach / (count - 1);
  final invSpeed = 1.0 / speed;
  final stepPx = Offset(
    -velocityPxPerSec.dx * invSpeed * stepMag,
    -velocityPxPerSec.dy * invSpeed * stepMag,
  );

  final sumWeights = count * (count + 1) / 2.0;
  final alphas = List<double>.generate(
    count,
    (i) => (i + 1) / sumWeights,
    growable: false,
  );

  return MotionBlurSamples(
    count: count,
    stepPx: stepPx,
    alphas: alphas,
  );
}
