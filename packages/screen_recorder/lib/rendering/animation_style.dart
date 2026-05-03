import 'package:flutter/animation.dart';

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
}
