import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/motion_blur_samples.dart';

void main() {
  group('sampleMotionBlurStamps', () {
    test('< 2 polyline points → empty (no blur)', () {
      expect(sampleMotionBlurStamps(polyline: const []), isEmpty);
      expect(
          sampleMotionBlurStamps(polyline: const [Offset(1, 2)]), isEmpty);
    });

    test('zero-length polyline (all coincident) → empty', () {
      final s = sampleMotionBlurStamps(polyline: const [
        Offset(10, 20),
        Offset(10, 20),
        Offset(10, 20),
      ]);
      expect(s, isEmpty);
    });

    test('sub-pixel polyline collapses to empty (no fake trail)', () {
      final s = sampleMotionBlurStamps(polyline: const [
        Offset(0, 0),
        Offset(0.4, 0),
      ]);
      expect(s, isEmpty);
    });

    test('30 px straight polyline → 16 stamps spanning the full reach',
        () {
      final s = sampleMotionBlurStamps(polyline: const [
        Offset(0, 0),
        Offset(30, 0),
      ]);
      // round(30/2) + 1 = 16
      expect(s.length, 16);
      expect(s.first.position.dx, closeTo(0, 1e-9));
      expect(s.last.position.dx, closeTo(30, 1e-9));
    });

    test('alphas — head at 1.0, tail at 1/count, monotonically increasing',
        () {
      final s = sampleMotionBlurStamps(polyline: const [
        Offset(0, 0),
        Offset(60, 0),
      ]);
      expect(s.last.alpha, closeTo(1.0, 1e-9));
      expect(s.first.alpha, closeTo(1.0 / s.length, 1e-9));
      for (var i = 1; i < s.length; i++) {
        expect(s[i].alpha, greaterThan(s[i - 1].alpha));
      }
    });

    test('count caps at maxStamps; head + tail still exact', () {
      final s = sampleMotionBlurStamps(polyline: const [
        Offset(0, 0),
        Offset(500, 0),
      ]);
      expect(s.length, 40);
      expect(s.first.position.dx, closeTo(0, 1e-6));
      expect(s.last.position.dx, closeTo(500, 1e-6));
    });

    test(
        'curved (L-shape) polyline → mid-arc stamp lands ON the path, '
        'not on the chord', () {
      // (0,0) → (50,0) → (50,50). Total arc = 100. Mid-arc = 50,
      // which is exactly at the corner (50, 0) — NOT at the chord
      // midpoint (25, 25).
      final s = sampleMotionBlurStamps(
        polyline: const [
          Offset(0, 0),
          Offset(50, 0),
          Offset(50, 50),
        ],
        maxStamps: 11,
      );
      expect(s.length, 11);
      // i=5 is at arc-length s = 0.5 * 100 = 50 → corner.
      expect(s[5].position.dx, closeTo(50, 1e-6));
      expect(s[5].position.dy, closeTo(0, 1e-6));
    });

    test('45-degree polyline → mid-arc stamp lies on the diagonal', () {
      final s = sampleMotionBlurStamps(
        polyline: const [Offset(0, 0), Offset(40, 40)],
        maxStamps: 5,
      );
      expect(s.length, 5);
      expect(s[2].position.dx, closeTo(20, 1e-3));
      expect(s[2].position.dy, closeTo(20, 1e-3));
    });

    test('polyline endpoints map to stamps[0] and stamps.last exactly', () {
      final s = sampleMotionBlurStamps(polyline: const [
        Offset(7, 11),
        Offset(13, 17),
        Offset(53, 19),
      ]);
      expect(s.first.position.dx, closeTo(7, 1e-6));
      expect(s.first.position.dy, closeTo(11, 1e-6));
      expect(s.last.position.dx, closeTo(53, 1e-6));
      expect(s.last.position.dy, closeTo(19, 1e-6));
    });
  });
}
