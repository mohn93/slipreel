/// Knobs for the cursor motion-blur path.
///
/// The painter takes one of these instead of reading hardcoded
/// constants so the UI can expose them as live-tunable sliders for
/// debugging visual issues. Defaults match the values that ship in
/// production — once a value lands somewhere good for everyone, it
/// can be promoted back to a `static const` in the painter and
/// removed from this class.
class MotionBlurTuning {
  const MotionBlurTuning({
    this.maxExposureMs = 50.0,
    this.maxTrailPx = 150.0,
    this.vTriggerLowPxPerSec = 500.0,
    this.vTriggerHighPxPerSec = 1500.0,
    this.velocityLookbackMs = 16.667,
    this.maxSampleGapMs = 50.0,
    this.largePairDispPx = 100.0,
    this.postIdleThresholdMs = 80.0,
  });

  /// Virtual shutter window in milliseconds at the user-facing slider
  /// at 1.0. The painter scales this linearly by the slider value.
  /// Bigger = more dramatic blur on the same motion.
  final double maxExposureMs;

  /// Hard cap on the rendered trail length in widget pixels.
  final double maxTrailPx;

  /// Velocity below which no motion blur draws at all (px/s).
  final double vTriggerLowPxPerSec;

  /// Velocity at which the trigger ramp reaches full strength (px/s).
  /// Between low and high the trail length is multiplied by a
  /// smoothstep so the blur fades in instead of popping on/off.
  final double vTriggerHighPxPerSec;

  /// Lookback for the "instantaneous" velocity used to taper the trail
  /// during deceleration AND to drive the trigger ramp (ms). One
  /// 60-Hz frame ≈ 16.67 ms.
  final double velocityLookbackMs;

  /// Reject the trail when any pair of consecutive recording samples
  /// that overlaps the exposure window is more than this far apart in
  /// time (ms). Catches recording hiccups where cursorAt would
  /// linearly interpolate across an unknown gap.
  final double maxSampleGapMs;

  /// Above this per-pair displacement (in video pixels), the post-idle
  /// warp check kicks in.
  final double largePairDispPx;

  /// If a "fast" sample-pair's IMMEDIATELY PRECEDING pair has a gap
  /// of at least this many ms, the fast pair is treated as a system
  /// warp (focus change / app switch / cursor teleport) rather than
  /// real motion.
  final double postIdleThresholdMs;

  static const MotionBlurTuning defaults = MotionBlurTuning();

  MotionBlurTuning copyWith({
    double? maxExposureMs,
    double? maxTrailPx,
    double? vTriggerLowPxPerSec,
    double? vTriggerHighPxPerSec,
    double? velocityLookbackMs,
    double? maxSampleGapMs,
    double? largePairDispPx,
    double? postIdleThresholdMs,
  }) {
    return MotionBlurTuning(
      maxExposureMs: maxExposureMs ?? this.maxExposureMs,
      maxTrailPx: maxTrailPx ?? this.maxTrailPx,
      vTriggerLowPxPerSec: vTriggerLowPxPerSec ?? this.vTriggerLowPxPerSec,
      vTriggerHighPxPerSec: vTriggerHighPxPerSec ?? this.vTriggerHighPxPerSec,
      velocityLookbackMs: velocityLookbackMs ?? this.velocityLookbackMs,
      maxSampleGapMs: maxSampleGapMs ?? this.maxSampleGapMs,
      largePairDispPx: largePairDispPx ?? this.largePairDispPx,
      postIdleThresholdMs: postIdleThresholdMs ?? this.postIdleThresholdMs,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! MotionBlurTuning) return false;
    return maxExposureMs == other.maxExposureMs &&
        maxTrailPx == other.maxTrailPx &&
        vTriggerLowPxPerSec == other.vTriggerLowPxPerSec &&
        vTriggerHighPxPerSec == other.vTriggerHighPxPerSec &&
        velocityLookbackMs == other.velocityLookbackMs &&
        maxSampleGapMs == other.maxSampleGapMs &&
        largePairDispPx == other.largePairDispPx &&
        postIdleThresholdMs == other.postIdleThresholdMs;
  }

  @override
  int get hashCode => Object.hash(
        maxExposureMs,
        maxTrailPx,
        vTriggerLowPxPerSec,
        vTriggerHighPxPerSec,
        velocityLookbackMs,
        maxSampleGapMs,
        largePairDispPx,
        postIdleThresholdMs,
      );
}
