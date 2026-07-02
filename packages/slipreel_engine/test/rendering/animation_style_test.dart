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
}
