import 'package:flutter/animation.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';

/// Screen-level animation style picked from the Animation tab. Drives
/// the zoom-level tween that runs when a region's zoom magnitude
/// changes mid-flight (and could later drive the in/out ramps too).
enum ScreenAnimationStyle {
  focused,
  smooth,
}

extension ScreenAnimationStyleData on ScreenAnimationStyle {
  String get label => switch (this) {
        ScreenAnimationStyle.focused => 'Focused',
        ScreenAnimationStyle.smooth => 'Smooth',
      };

  String get description => switch (this) {
        ScreenAnimationStyle.focused =>
          'Animation stabilizes quickly making it easier to follow '
              'and read the content',
        ScreenAnimationStyle.smooth =>
          'Animation is more fluid. Great for more creative content '
              'not focused on reading',
      };

  /// Tween duration applied to live zoom-level changes (e.g., when the
  /// user nudges the badge). Focused snaps in faster; Smooth lingers.
  Duration get badgeDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 140),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 600),
      };

  Curve get badgeCurve => switch (this) {
        ScreenAnimationStyle.focused => Curves.easeOutCubic,
        ScreenAnimationStyle.smooth => Curves.easeInOutCubic,
      };

  /// Curve used for the zoom region's enter/exit ramps. The two presets
  /// have OPPOSITE shapes so they read differently at a glance:
  /// Focused accelerates instantly and settles hard (snaps and locks);
  /// Smooth is a pronounced ease-in-out — the camera visibly gathers
  /// momentum, glides, and soft-lands (the film push).
  Curve get rampCurve => switch (this) {
        ScreenAnimationStyle.focused => const Cubic(0.2, 0.0, 0.0, 1.0),
        ScreenAnimationStyle.smooth => const Cubic(0.65, 0.0, 0.35, 1.0),
      };

  /// Multiplier on a zoom region's enter/exit ramp DURATION. >1 = slower,
  /// more cinematic push; <1 = quicker snap. The feel's most perceptible
  /// lever on modest zooms (curve shape alone is nearly invisible).
  double get rampDurationScale => switch (this) {
        // ≥3× spread: ≈250 ms vs ≈850 ms on a default 500 ms ramp.
        ScreenAnimationStyle.focused => 0.5,
        ScreenAnimationStyle.smooth => 1.7,
      };

  /// The picker's hover demo runs the REAL ramp curve so the tile
  /// honestly previews the feel it selects.
  Curve get previewCurve => rampCurve;

  Duration get previewDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 600),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 1500),
      };
}

/// How the rendered cursor chases the recorded path. Each preset is a
/// spring chase with its own character: stiffness (how hard it pulls),
/// damping ratio (Smooth is slightly underdamped for a floaty, organic
/// feel), and velocity-feedforward strength (how much of the spring's
/// phase lag is cancelled while the cursor is moving — see
/// [CursorMotionController]). The camera focal chases the rendered
/// sprite, so the preset shapes the camera feel too.
enum CursorAnimationStyle {
  smooth,
  medium,
  rapid,
  none,
}

extension CursorAnimationStyleData on CursorAnimationStyle {
  String get label => switch (this) {
        CursorAnimationStyle.smooth => 'Smooth',
        CursorAnimationStyle.medium => 'Medium',
        CursorAnimationStyle.rapid => 'Rapid',
        CursorAnimationStyle.none => 'None',
      };

  /// Curve used for the picker's hover demo. Smooth uses an overshooting
  /// curve so the demo shows the underdamped float; Rapid reads as an
  /// immediate lock.
  Curve get previewCurve => switch (this) {
        CursorAnimationStyle.smooth => Curves.easeOutBack,
        CursorAnimationStyle.medium => Curves.easeOutCubic,
        CursorAnimationStyle.rapid => Curves.easeOutQuint,
        CursorAnimationStyle.none => Curves.linear,
      };

  Duration get previewDuration => switch (this) {
        CursorAnimationStyle.smooth => const Duration(milliseconds: 1600),
        CursorAnimationStyle.medium => const Duration(milliseconds: 800),
        CursorAnimationStyle.rapid => const Duration(milliseconds: 250),
        CursorAnimationStyle.none => const Duration(milliseconds: 80),
      };

  /// Re-tuning table: maps each preset to its FIR (window, curve) pair.
  /// Retained only so legacy JSON projects round-trip — the active
  /// motion path no longer uses FIR. New projects use [motionSpring].
  ({Duration window, Curve curve}) get fir => switch (this) {
        CursorAnimationStyle.smooth =>
          (window: const Duration(milliseconds: 450), curve: Curves.easeOutCubic),
        CursorAnimationStyle.medium =>
          (window: const Duration(milliseconds: 180), curve: Curves.easeOutCubic),
        CursorAnimationStyle.rapid =>
          (window: const Duration(milliseconds: 65), curve: Curves.easeOutCubic),
        CursorAnimationStyle.none =>
          (window: Duration.zero, curve: Curves.linear),
      };

  /// Spring parameters that drive the cursor's motion chase. Each
  /// preset has a distinct character, not just a different settle
  /// time: Smooth is soft AND slightly underdamped (floaty arcs, a
  /// whisper of overshoot at stops); Medium is the balanced critically-
  /// damped reference; Rapid is a stiff, near-locked track; None
  /// snaps to the raw recorded grid. Paired with [feedforwardStrength]
  /// so the soft presets keep more of their natural trail.
  MotionSpring get motionSpring => switch (this) {
        CursorAnimationStyle.smooth =>
          const MotionSpring(stiffness: 90, damping: 0.8),
        CursorAnimationStyle.medium =>
          const MotionSpring(stiffness: 380, damping: 1.0),
        CursorAnimationStyle.rapid =>
          const MotionSpring(stiffness: 1400, damping: 1.0),
        CursorAnimationStyle.none => MotionSpring.snap,
      };

  /// Fraction of the spring's analytical phase lag (τ = 2ζ/ωₙ) that the
  /// velocity feedforward cancels while the cursor is moving (see
  /// [CursorMotionController]). Per-preset so the presets stay
  /// CONTRASTED: full-strength feedforward makes every spring sit on
  /// the raw path during motion, erasing the differences between them.
  /// Smooth keeps most of its lag (floaty trail); Rapid cancels almost
  /// all of it (locked). None bypasses the spring entirely — 0.0 here
  /// is never read, defined for completeness.
  double get feedforwardStrength => switch (this) {
        CursorAnimationStyle.smooth => 0.25,
        CursorAnimationStyle.medium => 0.5,
        CursorAnimationStyle.rapid => 0.85,
        CursorAnimationStyle.none => 0.0,
      };
}
