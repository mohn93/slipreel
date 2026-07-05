import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';

void main() {
  group('CursorAnimationStyle presets', () {
    // Analytical phase lag of each preset's spring: τ = 2ζ·√(m/k).
    double tau(CursorAnimationStyle s) {
      final spring = s.motionSpring;
      return 2.0 *
          spring.damping *
          math.sqrt(spring.mass / spring.stiffness);
    }

    // What the viewer actually sees during motion: the feedforward
    // cancels `feedforwardStrength` of τ, leaving τ·(1−ff).
    double visibleLagMs(CursorAnimationStyle s) =>
        tau(s) * (1.0 - s.feedforwardStrength) * 1000.0;

    test('Medium is the unchanged reference (380 / 1.0 / 0.5)', () {
      final m = CursorAnimationStyle.medium;
      expect(m.motionSpring.stiffness, 380);
      expect(m.motionSpring.damping, 1.0);
      expect(m.feedforwardStrength, 0.5);
    });

    test('only Smooth is underdamped (the floaty character)', () {
      expect(CursorAnimationStyle.smooth.motionSpring.damping, lessThan(1.0));
      expect(CursorAnimationStyle.medium.motionSpring.damping, 1.0);
      expect(CursorAnimationStyle.rapid.motionSpring.damping, 1.0);
    });

    test('feedforward strength is monotone: smooth < medium < rapid', () {
      expect(CursorAnimationStyle.smooth.feedforwardStrength,
          lessThan(CursorAnimationStyle.medium.feedforwardStrength));
      expect(CursorAnimationStyle.medium.feedforwardStrength,
          lessThan(CursorAnimationStyle.rapid.feedforwardStrength));
    });

    test('adjacent presets differ by ≥40 ms of visible lag '
        '(the perceptibility floor this redesign exists to enforce)', () {
      final smooth = visibleLagMs(CursorAnimationStyle.smooth);
      final medium = visibleLagMs(CursorAnimationStyle.medium);
      final rapid = visibleLagMs(CursorAnimationStyle.rapid);
      expect(smooth - medium, greaterThanOrEqualTo(40.0),
          reason: 'Smooth must visibly trail Medium');
      expect(medium - rapid, greaterThanOrEqualTo(40.0),
          reason: 'Medium must visibly trail Rapid');
      expect(rapid, lessThan(15.0),
          reason: 'Rapid should read as locked to the real path');
    });

    test('None stays the raw-grid snap', () {
      expect(CursorAnimationStyle.none.motionSpring.isSnap, isTrue);
      expect(CursorAnimationStyle.none.feedforwardStrength, 0.0);
    });

    test('config exposes the preset feedforward strength', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.rapid);
      expect(cfg.feedforwardStrength,
          CursorAnimationStyle.rapid.feedforwardStrength);
    });
  });

  group('ScreenAnimationStyle presets', () {
    test('ramp duration spread is ≥3× (Focused snaps, Smooth glides)', () {
      final f = ScreenAnimationStyle.focused.rampDurationScale;
      final s = ScreenAnimationStyle.smooth.rampDurationScale;
      expect(s / f, greaterThanOrEqualTo(3.0));
      expect(f, lessThan(1.0), reason: 'Focused quickens the ramp');
      expect(s, greaterThan(1.0), reason: 'Smooth stretches the ramp');
    });

    test('curve shapes are opposite: Focused starts fast, Smooth winds up',
        () {
      // A quarter of the way through the ramp, Focused (fast-out) must be
      // far ahead of Smooth (pronounced ease-in start). This is the
      // perceptible signature of the two feels.
      final focusedAtQuarter =
          ScreenAnimationStyle.focused.rampCurve.transform(0.25);
      final smoothAtQuarter =
          ScreenAnimationStyle.smooth.rampCurve.transform(0.25);
      expect(focusedAtQuarter, greaterThan(smoothAtQuarter + 0.15));
    });

    test('badge tween: Focused snaps (<200 ms), Smooth lingers (>500 ms)',
        () {
      expect(ScreenAnimationStyle.focused.badgeDuration.inMilliseconds,
          lessThan(200));
      expect(ScreenAnimationStyle.smooth.badgeDuration.inMilliseconds,
          greaterThan(500));
    });

    test('picker demo mirrors the real ramp curve (honest preview)', () {
      for (final s in ScreenAnimationStyle.values) {
        expect(s.previewCurve, s.rampCurve);
      }
      expect(
          ScreenAnimationStyle.smooth.previewDuration >
              ScreenAnimationStyle.focused.previewDuration,
          isTrue);
    });
  });
}
