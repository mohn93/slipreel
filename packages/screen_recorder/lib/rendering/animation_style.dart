import 'package:flutter/animation.dart';
import 'package:screen_recorder/rendering/spring_config.dart';

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
        ScreenAnimationStyle.focused => const Duration(milliseconds: 150),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 350),
      };

  Curve get badgeCurve => switch (this) {
        ScreenAnimationStyle.focused => Curves.easeOutCubic,
        ScreenAnimationStyle.smooth => Curves.easeInOutCubic,
      };

  /// Curve used for the zoom region's enter/exit ramps. Focused
  /// front-loads the motion so the camera reaches the target quickly
  /// and steadies; Smooth eases on both ends for a film-like push.
  Curve get rampCurve => switch (this) {
        ScreenAnimationStyle.focused => Curves.easeOutCubic,
        ScreenAnimationStyle.smooth => Curves.easeInOutCubic,
      };

  /// Curve used for the picker's hover-driven demo circle.
  Curve get previewCurve => switch (this) {
        ScreenAnimationStyle.focused => Curves.easeOutCubic,
        ScreenAnimationStyle.smooth => Curves.easeInOutSine,
      };

  /// One forward-and-back cycle for the demo. Longer for Smooth so the
  /// difference vs. Focused is visible.
  Duration get previewDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 700),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 1300),
      };
}

/// How aggressively the cursor-follow zoom focal point chases the
/// recorded cursor. Mapped to [ZoomFocalController.update]'s
/// `smoothing` factor — values closer to 1.0 mean less lag.
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

  /// Lerp factor passed to [ZoomFocalController.update]. 1.0 = no
  /// smoothing (focal snaps to the cursor every frame).
  double get smoothing => switch (this) {
        CursorAnimationStyle.smooth => 0.08,
        CursorAnimationStyle.medium => 0.18,
        CursorAnimationStyle.rapid => 0.40,
        CursorAnimationStyle.none => 1.0,
      };

  /// Curve used for the picker's hover demo.
  Curve get previewCurve => switch (this) {
        CursorAnimationStyle.smooth => Curves.easeOutSine,
        CursorAnimationStyle.medium => Curves.easeOutCubic,
        CursorAnimationStyle.rapid => Curves.easeOutQuint,
        CursorAnimationStyle.none => Curves.linear,
      };

  Duration get previewDuration => switch (this) {
        CursorAnimationStyle.smooth => const Duration(milliseconds: 1400),
        CursorAnimationStyle.medium => const Duration(milliseconds: 800),
        CursorAnimationStyle.rapid => const Duration(milliseconds: 350),
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

  /// Spring parameters that drive the cursor's motion chase. Stiffness
  /// is tuned so each preset's perceived "settle time" is similar to
  /// the legacy FIR's: Smooth chases lazily, Rapid is nearly instant,
  /// None snaps. All presets default to critical damping (ratio = 1.0)
  /// — no overshoot. Dragging the Springs section sliders in the
  /// cursor tab switches the config to a custom spring that overrides
  /// these.
  MotionSpring get motionSpring => switch (this) {
        CursorAnimationStyle.smooth =>
          const MotionSpring(stiffness: 180, damping: 1.0),
        CursorAnimationStyle.medium =>
          const MotionSpring(stiffness: 380, damping: 1.0),
        CursorAnimationStyle.rapid =>
          const MotionSpring(stiffness: 900, damping: 1.0),
        CursorAnimationStyle.none => MotionSpring.snap,
      };
}
