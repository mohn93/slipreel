import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/ema_velocity_filter.dart';

void main() {
  group('EmaVelocityFilter', () {
    test('first call returns the raw value (cold-start, no ramp from zero)',
        () {
      final f = EmaVelocityFilter();
      final out = f.filter(
        const Offset(500, 0),
        const Duration(milliseconds: 16),
      );
      expect(out, const Offset(500, 0));
    });

    test('second call dampens toward raw — output between previous and raw',
        () {
      final f = EmaVelocityFilter();
      // Seed at 0.
      f.filter(Offset.zero, const Duration(milliseconds: 0));
      // Step input to 1000 px/s 16ms later.
      final out = f.filter(
        const Offset(1000, 0),
        const Duration(milliseconds: 16),
      );
      // EMA must produce a value strictly between the previous (0) and
      // the new raw (1000). With τ=100ms and Δt=16ms this is ~148 px/s,
      // but assert the bracket rather than the exact value to keep this
      // robust against τ tuning.
      expect(out.dx, greaterThan(0));
      expect(out.dx, lessThan(1000));
      expect(out.dy, closeTo(0, 1e-9));
    });

    test('repeated step settles toward steady-state value (~63% within τ)',
        () {
      final f = EmaVelocityFilter();
      f.filter(Offset.zero, const Duration(milliseconds: 0));
      // Apply a constant 1000 px/s input over many small steps.
      // After ~τ (100ms) of integration the output should be near
      // (1 - 1/e) ≈ 63% of the target.
      Offset out = Offset.zero;
      for (var t = 16; t <= 96; t += 16) {
        out = f.filter(const Offset(1000, 0), Duration(milliseconds: t));
      }
      // 96ms of integration → 1 - exp(-0.96) ≈ 0.617. Allow generous
      // tolerance for the discrete-vs-continuous gap.
      expect(out.dx, greaterThan(500));
      expect(out.dx, lessThan(750));
    });

    test('backward position re-seeds (no negative-Δt blowup)', () {
      final f = EmaVelocityFilter();
      f.filter(const Offset(100, 0), const Duration(milliseconds: 100));
      // Scrub backward — the filter must NOT integrate against a
      // negative Δt. Re-seeding to the new raw is the right behavior:
      // the user just jumped to a new playback location.
      final out = f.filter(
        const Offset(-500, 0),
        const Duration(milliseconds: 50),
      );
      expect(out, const Offset(-500, 0));
    });

    test('large gap (> 500ms) re-seeds — stale prev is too old to blend', () {
      final f = EmaVelocityFilter();
      f.filter(const Offset(100, 0), const Duration(milliseconds: 0));
      // 600ms gap — beyond the filter's _maxGap. The previous sample
      // is too stale to be a valid base for EMA, so re-seed.
      final out = f.filter(
        const Offset(800, 0),
        const Duration(milliseconds: 600),
      );
      expect(out, const Offset(800, 0));
    });

    test('reset clears state — first call after reset returns raw', () {
      final f = EmaVelocityFilter();
      f.filter(const Offset(100, 0), const Duration(milliseconds: 0));
      f.filter(const Offset(200, 0), const Duration(milliseconds: 16));
      f.reset();
      final out = f.filter(
        const Offset(900, 0),
        const Duration(milliseconds: 32),
      );
      expect(out, const Offset(900, 0));
    });

    test('output is finite and non-NaN under tiny Δt (1µs)', () {
      // A 1µs gap produces a near-zero alpha; output should be very
      // close to the previous smoothed value, never NaN/Inf.
      final f = EmaVelocityFilter();
      f.filter(const Offset(500, 0), const Duration(microseconds: 0));
      final out = f.filter(
        const Offset(0, 0),
        const Duration(microseconds: 1),
      );
      expect(out.dx.isFinite, isTrue);
      expect(out.dy.isFinite, isTrue);
      // Should still be very close to 500 (barely any integration).
      expect(out.dx, closeTo(500, 1));
    });

    test('two-axis input — both axes are smoothed independently', () {
      final f = EmaVelocityFilter();
      f.filter(Offset.zero, const Duration(milliseconds: 0));
      final out = f.filter(
        const Offset(800, 600),
        const Duration(milliseconds: 16),
      );
      // Both axes attenuate by the same alpha — ratio is preserved.
      expect(out.dx / out.dy, closeTo(800 / 600, 1e-9));
      // Magnitude is dampened from 1000 (raw) down to less than 1000.
      final mag = math.sqrt(out.dx * out.dx + out.dy * out.dy);
      expect(mag, lessThan(1000));
      expect(mag, greaterThan(0));
    });
  });
}
