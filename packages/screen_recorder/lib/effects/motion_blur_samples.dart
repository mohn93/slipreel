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
/// **Path-displacement model.** The caller passes in [trailVectorPx]:
/// the cursor's actual recorded displacement (`cursorAt(T) −
/// cursorAt(T − exposure)`) over the virtual shutter window. The
/// trail's direction is that vector's direction; the trail's length
/// is that vector's magnitude. Slider/exposure logic lives at the
/// call site so this function stays a pure "displacement → render
/// parameters" mapping.
///
/// Why displacement, not `velocity × exposure`? Velocity at T is
/// instantaneous (sampled over a short lookback). When the cursor
/// suddenly accelerates, instantaneous velocity is much higher than
/// the average velocity over the exposure window, and `v × t`
/// overshoots the cursor's actual displacement — the trail extends
/// over ground the cursor never crossed. Sampling the recording at
/// both ends of the exposure window gives the actual chord, so the
/// trail can never be longer than where the cursor really was.
///
/// Stamp count is sized to the reach (~1 stamp per 2 px so
/// consecutive stamps overlap on a typical cursor body), capped at
/// [maxStamps] so the fallback path's per-frame work stays bounded.
/// Alphas linearly taper from `1/count` at the tail to `1.0` at the
/// head — not normalized to sum-to-1, so overlapping stamps leave
/// the head opaque (cursor stays sharp) and only the trailing region
/// shows the dim tail.
///
/// Sub-pixel trail vectors collapse to count = 1 and the shader's
/// reach &lt; 1 branch produces the sharp cursor.
MotionBlurSamples computeMotionBlurSamples({
  required Offset trailVectorPx,
  int maxStamps = 40,
}) {
  final length = trailVectorPx.distance;
  // Defensive: zero-length trail would divide by zero in the stepPx
  // computation below. A stationary cursor (no displacement during
  // exposure) correctly renders no blur anyway.
  if (length <= 0) return _noBlur;

  // Stamp count grows with reach (~1 stamp per 2 px so consecutive
  // stamps overlap on a 32-px cursor body), capped at maxStamps so
  // a long-reach trail doesn't burn frames on the fallback's
  // discrete-stamp path. The shader uses fixed kSamples internally
  // and isn't affected by this clamp.
  final count = ((length / 2).round() + 1).clamp(1, maxStamps);
  if (count <= 1) return _noBlur;

  final stepMag = length / (count - 1);
  final invLen = 1.0 / length;
  // Stamps step BACKWARD along the trail direction (head at the
  // current position, tail at where the cursor was at T - exposure).
  final stepPx = Offset(
    -trailVectorPx.dx * invLen * stepMag,
    -trailVectorPx.dy * invLen * stepMag,
  );

  // Raw linear taper. Head (i=count-1) gets 1.0, tail (i=0) gets 1/count.
  // Not normalized to sum=1: with overlapping stamps the head paints
  // opaque over the tail so the rendered cursor stays sharp.
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
