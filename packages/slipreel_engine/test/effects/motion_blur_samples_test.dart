import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/motion_blur_samples.dart';

void main() {
  group('computeMotionBlurSamples', () {
    test('zero trail vector → single stamp (stationary cursor or slider 0)',
        () {
      final s = computeMotionBlurSamples(trailVectorPx: Offset.zero);
      expect(s.count, 1);
      expect(s.stepPx, Offset.zero);
      expect(s.alphas, [closeTo(1.0, 1e-9)]);
    });

    test('sub-pixel trail collapses to a single stamp (no fake trail)', () {
      // 0.4 px displacement rounds to 0 stamp steps → count = 1.
      final s = computeMotionBlurSamples(
        trailVectorPx: const Offset(0.4, 0),
      );
      expect(s.count, 1);
    });

    test('low-but-nonzero trail still produces blur (no manual cutoff)', () {
      // 25 px trail → ~13 stamps.
      final s = computeMotionBlurSamples(
        trailVectorPx: const Offset(25, 0),
      );
      expect(s.count, greaterThan(1));
      expect(s.stepPx.dx, lessThan(0));
    });

    test('reach equals the trail vector\'s magnitude (path-displacement model)',
        () {
      // 30 px trail along +x. (count - 1) × stepMag must span exactly 30 px.
      final s = computeMotionBlurSamples(
        trailVectorPx: const Offset(30, 0),
      );
      expect(s.stepPx.dx, lessThan(0));
      expect(s.stepPx.dy, closeTo(0, 1e-9));
      expect(s.stepPx.dx * (s.count - 1), closeTo(-30.0, 1e-6));
    });

    test('alphas — head is 1.0, tail is 1/count, linear taper', () {
      final s = computeMotionBlurSamples(
        trailVectorPx: const Offset(60, 0),
      );
      expect(s.alphas.last, closeTo(1.0, 1e-9));
      expect(s.alphas.first, closeTo(1.0 / s.count, 1e-9));
    });

    test('alphas are monotonically increasing (tail dim → head bright)', () {
      final s = computeMotionBlurSamples(
        trailVectorPx: const Offset(60, 0),
      );
      for (var i = 1; i < s.alphas.length; i++) {
        expect(s.alphas[i], greaterThan(s.alphas[i - 1]));
      }
    });

    test(
        'long trail vector extends reach linearly with magnitude — no upper '
        'cap, matches the cursor\'s actual motion', () {
      // Doubling the trail vector doubles the reach.
      final at30 = computeMotionBlurSamples(
        trailVectorPx: const Offset(30, 0),
      );
      final at60 = computeMotionBlurSamples(
        trailVectorPx: const Offset(60, 0),
      );
      final reachAt30 = at30.stepPx.dx.abs() * (at30.count - 1);
      final reachAt60 = at60.stepPx.dx.abs() * (at60.count - 1);
      expect(reachAt60 / reachAt30, closeTo(2.0, 0.05),
          reason: '2× trail magnitude = 2× reach');
    });

    test('45-degree trail vector → step direction is exactly -trail_hat', () {
      final s = computeMotionBlurSamples(
        trailVectorPx: const Offset(40, 40),
      );
      final mag = s.stepPx.distance;
      expect(s.stepPx.dx / mag, closeTo(-1 / 1.41421356, 1e-3));
      expect(s.stepPx.dy / mag, closeTo(-1 / 1.41421356, 1e-3));
    });

    test('count is sized to reach (~1 stamp per 2 px), capped at maxStamps', () {
      // 18 px trail → count = round(9) + 1 = 10
      final mid = computeMotionBlurSamples(
        trailVectorPx: const Offset(18, 0),
      );
      expect(mid.count, 10);

      // 500 px trail would round to 251 stamps; capped at 40.
      final huge = computeMotionBlurSamples(
        trailVectorPx: const Offset(500, 0),
      );
      expect(huge.count, 40);
      // Reach is preserved end-to-end even when count is clamped.
      expect(huge.stepPx.dx.abs() * (huge.count - 1), closeTo(500.0, 1e-6));
    });
  });
}
