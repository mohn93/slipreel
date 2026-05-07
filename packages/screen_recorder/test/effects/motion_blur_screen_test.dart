import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/motion_blur_screen.dart';

void main() {
  group('screenBlurSigma', () {
    test('intensity 0 → zero sigmas regardless of velocity', () {
      final s = screenBlurSigma(
        velocity: const Offset(2000, 2000),
        intensity: 0,
      );
      expect(s, Offset.zero);
    });

    test('zero velocity → zero sigmas', () {
      final s = screenBlurSigma(
        velocity: Offset.zero,
        intensity: 1.0,
      );
      expect(s, Offset.zero);
    });

    test('horizontal pan at max speed, intensity 1 → sigmaX=maxReach, sigmaY=0', () {
      final s = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 1.0,
      );
      expect(s.dx, closeTo(10.0, 1e-6));
      expect(s.dy, closeTo(0, 1e-6));
    });

    test('vertical pan at max speed, intensity 1 → sigmaY=maxReach, sigmaX=0', () {
      final s = screenBlurSigma(
        velocity: const Offset(0, 800),
        intensity: 1.0,
      );
      expect(s.dx, closeTo(0, 1e-6));
      expect(s.dy, closeTo(10.0, 1e-6));
    });

    test('intensity scales sigma linearly at fixed speed', () {
      final half = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 0.5,
      );
      final full = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 1.0,
      );
      expect(half.dx, closeTo(full.dx * 0.5, 1e-6));
    });

    test('speed above reference is clamped', () {
      final cap = screenBlurSigma(
        velocity: const Offset(80000, 0),
        intensity: 1.0,
      );
      expect(cap.dx, closeTo(10.0, 1e-6));
    });

    test('negative velocity components → absolute-value sigmas', () {
      final s = screenBlurSigma(
        velocity: const Offset(-800, -800),
        intensity: 1.0,
      );
      expect(s.dx, closeTo(10.0, 1e-6));
      expect(s.dy, closeTo(10.0, 1e-6));
    });

    test('sub-pixel sigma is snapped to Offset.zero (avoid invisible saveLayer cost)', () {
      // intensity 0.001 × speed 800 / ref 800 × maxReach 10 = 0.01 px
      // — invisible to the eye but a real per-frame saveLayer cost
      // if we pass it to ImageFilter. Helper must snap.
      final s = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 0.001,
      );
      expect(s, Offset.zero);
    });
  });
}
