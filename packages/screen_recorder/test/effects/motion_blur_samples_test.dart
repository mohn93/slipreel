import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/motion_blur_samples.dart';

void main() {
  group('computeMotionBlurSamples', () {
    test('slider 0 → single stamp regardless of velocity', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(5000, 0),
        sliderIntensity: 0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 1);
      expect(s.stepPx, Offset.zero);
      expect(s.alphas, [closeTo(1.0, 1e-9)]);
    });

    test('velocity below 1 px/s → single stamp regardless of slider', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(0.4, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 1);
      expect(s.stepPx, Offset.zero);
    });

    test('effective intensity below 0.05 → single stamp', () {
      // slider 0.1, speed = 800, ref 2000 → effective = 0.04
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(800, 0),
        sliderIntensity: 0.1,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 1);
    });

    test('horizontal velocity at max speed, slider 1 → 8 stamps along -x', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 8);
      expect(s.stepPx.dx, lessThan(0));
      expect(s.stepPx.dy, closeTo(0, 1e-9));
      // (count - 1) steps span maxReachPx exactly at max effective
      expect(s.stepPx.dx * (s.count - 1), closeTo(-12.0, 1e-6));
    });

    test('alphas sum to 1.0', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      final sum = s.alphas.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-9));
    });

    test('alphas are monotonically increasing (tail dim → head bright)', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      for (var i = 1; i < s.alphas.length; i++) {
        expect(s.alphas[i], greaterThan(s.alphas[i - 1]));
      }
    });

    test('supersonic velocity is clamped — no >maxStamps stamps, no >maxReach offset', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(20000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, lessThanOrEqualTo(8));
      expect(s.stepPx.dx.abs() * (s.count - 1), lessThanOrEqualTo(12.0 + 1e-6));
    });

    test('45-degree velocity → step direction is exactly -v_hat', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(1500, 1500), // |v| ≈ 2121
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      // step direction should be (-1/√2, -1/√2)
      final mag = s.stepPx.distance;
      expect(s.stepPx.dx / mag, closeTo(-1 / 1.41421356, 1e-3));
      expect(s.stepPx.dy / mag, closeTo(-1 / 1.41421356, 1e-3));
    });

    test('count grows with effective intensity (1 + round((max-1) * eff))', () {
      // effective = 0.5 → count = 1 + round(7 * 0.5) = 1 + 4 = 5  (sliderIntensity 0.5 at max ref speed)
      final mid = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 0.5,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(mid.count, 5);
    });
  });
}
