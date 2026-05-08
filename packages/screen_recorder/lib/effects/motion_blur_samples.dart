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

/// Returns the per-stamp parameters for cursor motion blur.
///
/// `effective = sliderIntensity × clamp(|v| / referenceSpeed, 0, 1)`.
/// Count grows from 1 at effective=0 to [maxStamps] at effective=1.
/// Step magnitude grows from 0 to `maxReachPx / (count - 1)`.
/// Alphas linearly taper from `1/count` at the tail to `1.0` at the head.
/// Not normalized to sum-to-1: with overlapping stamps (typical for
/// blurred cursors) the head paints opaque over the tail so the cursor
/// stays sharp; only the trailing region shows the dim tail.
///
/// No manual cutoffs on [sliderIntensity] or speed beyond zero — the
/// natural rounding of `count` collapses sub-pixel-blur cases to count=1
/// (no blur), and the shader's reach&lt;1 short-circuit makes that path
/// pixel-identical to a sharp cursor. Removing the explicit cutoffs is
/// what makes the slider feel responsive across its full 0..1 range
/// instead of having a dead zone at the bottom for slow motion.
MotionBlurSamples computeMotionBlurSamples({
  required Offset velocityPxPerSec,
  required double sliderIntensity,
  required double referenceSpeedPxPerSec,
  required double maxReachPx,
  int maxStamps = 40,
}) {
  if (sliderIntensity <= 0) return _noBlur;
  final speed = velocityPxPerSec.distance;
  // Defensive: speed=0 would divide by zero in the stepPx computation
  // below. A truly stationary cursor should produce no blur anyway, so
  // this is the only "minimum speed" guard we need.
  if (speed <= 0) return _noBlur;

  final effective =
      (sliderIntensity * speed / referenceSpeedPxPerSec).clamp(0.0, 1.0);
  final count = 1 + ((maxStamps - 1) * effective).round();
  // Natural cutoff: when effective is small enough that `round` collapses
  // (maxStamps - 1) × effective to 0, count is 1 and there's no trail to
  // sample. For maxStamps=40 this kicks in below effective ≈ 0.013, where
  // the corresponding reach is also sub-pixel so a trail wouldn't be
  // visible anyway.
  if (count <= 1) return _noBlur;

  final reach = effective * maxReachPx;
  final stepMag = reach / (count - 1);
  final invSpeed = 1.0 / speed;
  final stepPx = Offset(
    -velocityPxPerSec.dx * invSpeed * stepMag,
    -velocityPxPerSec.dy * invSpeed * stepMag,
  );

  // Raw linear taper. Head (i=count-1) gets 1.0, tail (i=0) gets 1/count.
  // Not normalized to sum=1: when stamps overlap (e.g. low-velocity, small
  // step) the head paints opaque over the tail, leaving a sharp cursor
  // with a faint trail rather than a washed-out blur. Sum-to-1 alphas
  // looked physically correct only when stamps don't overlap.
  final alphas = List<double>.generate(
    count,
    (i) => (i + 1) / count,
    growable: false,
  );

  return MotionBlurSamples(
    count: count,
    stepPx: stepPx,
    alphas: alphas,
  );
}
