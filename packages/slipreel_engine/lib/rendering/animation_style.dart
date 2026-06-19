import 'package:flutter/animation.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';

/// Screen-level animation style picked from the Animation tab. Drives
/// the zoom-level tween that runs when a region's zoom magnitude
/// changes mid-flight (and could later drive the in/out ramps too).
enum ScreenAnimationStyle {
  focused,
  smooth,
  studioSoft,
  studioSnappy,
}

extension ScreenAnimationStyleData on ScreenAnimationStyle {
  String get label => switch (this) {
        ScreenAnimationStyle.focused => 'Focused',
        ScreenAnimationStyle.smooth => 'Smooth',
        ScreenAnimationStyle.studioSoft => 'Studio Soft',
        ScreenAnimationStyle.studioSnappy => 'Studio Snappy',
      };

  /// Whether this preset is a hidden experimental option excluded from
  /// the normal selectable picker set.
  bool get experimental => switch (this) {
        ScreenAnimationStyle.focused || ScreenAnimationStyle.smooth => false,
        ScreenAnimationStyle.studioSoft ||
        ScreenAnimationStyle.studioSnappy =>
          true,
      };

  String get description => switch (this) {
        ScreenAnimationStyle.focused =>
          'Animation stabilizes quickly making it easier to follow '
              'and read the content',
        ScreenAnimationStyle.smooth =>
          'Animation is more fluid. Great for more creative content '
              'not focused on reading',
        ScreenAnimationStyle.studioSoft =>
          'Experimental: a soft, film-like push with eased ends',
        ScreenAnimationStyle.studioSnappy =>
          'Experimental: a quick, decisive push that steadies fast',
      };

  /// Tween duration applied to live zoom-level changes (e.g., when the
  /// user nudges the badge). Focused snaps in faster; Smooth lingers.
  Duration get badgeDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 150),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 520),
        ScreenAnimationStyle.studioSoft => const Duration(milliseconds: 520),
        ScreenAnimationStyle.studioSnappy => const Duration(milliseconds: 260),
      };

  Curve get badgeCurve => switch (this) {
        ScreenAnimationStyle.focused => Curves.easeOutCubic,
        ScreenAnimationStyle.smooth => Curves.easeInOutCubic,
        ScreenAnimationStyle.studioSoft => Curves.easeInOutCubic,
        ScreenAnimationStyle.studioSnappy => Curves.easeOutCubic,
      };

  /// Curve used for the zoom region's enter/exit ramps. Focused
  /// front-loads the motion so the camera reaches the target quickly
  /// and steadies; Smooth eases on both ends for a film-like push.
  Curve get rampCurve => switch (this) {
        // Focused = the quick, decisive Studio Snappy push (#7).
        ScreenAnimationStyle.focused => const Cubic(0.4, 0.0, 0.2, 1.0),
        // Smooth = the tuned Studio Soft feel (#7): ease-out — quick off
        // the line, decelerating into the destination with a soft landing.
        ScreenAnimationStyle.smooth => const Cubic(0.22, 0.61, 0.35, 1.0),
        ScreenAnimationStyle.studioSoft => const Cubic(0.22, 0.61, 0.35, 1.0),
        ScreenAnimationStyle.studioSnappy => const Cubic(0.4, 0.0, 0.2, 1.0),
      };

  /// Multiplier on a zoom region's enter/exit ramp DURATION. >1 = slower,
  /// more cinematic push; <1 = quicker snap. The feel's most perceptible
  /// lever on modest zooms (curve shape alone is nearly invisible).
  double get rampDurationScale => switch (this) {
        // Focused = quick snap; Smooth = slow cinematic glide (#7).
        ScreenAnimationStyle.focused => 0.55,
        ScreenAnimationStyle.smooth => 1.4,
        ScreenAnimationStyle.studioSoft => 1.4,
        ScreenAnimationStyle.studioSnappy => 0.55,
      };

  /// Curve used for the picker's hover-driven demo circle.
  Curve get previewCurve => switch (this) {
        ScreenAnimationStyle.focused => Curves.easeOutCubic,
        ScreenAnimationStyle.smooth => Curves.easeOutCubic,
        ScreenAnimationStyle.studioSoft => Curves.easeInOutCubic,
        ScreenAnimationStyle.studioSnappy => Curves.easeOutCubic,
      };

  /// One forward-and-back cycle for the demo. Longer for Smooth so the
  /// difference vs. Focused is visible.
  Duration get previewDuration => switch (this) {
        ScreenAnimationStyle.focused => const Duration(milliseconds: 700),
        ScreenAnimationStyle.smooth => const Duration(milliseconds: 1300),
        ScreenAnimationStyle.studioSoft => const Duration(milliseconds: 1100),
        ScreenAnimationStyle.studioSnappy => const Duration(milliseconds: 800),
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
  studioSoft,
  studioSnappy,
}

extension CursorAnimationStyleData on CursorAnimationStyle {
  String get label => switch (this) {
        CursorAnimationStyle.smooth => 'Smooth',
        CursorAnimationStyle.medium => 'Medium',
        CursorAnimationStyle.rapid => 'Rapid',
        CursorAnimationStyle.none => 'None',
        CursorAnimationStyle.studioSoft => 'Studio Soft',
        CursorAnimationStyle.studioSnappy => 'Studio Snappy',
      };

  /// Whether this preset is a hidden experimental option excluded from
  /// the normal selectable picker set.
  bool get experimental => switch (this) {
        CursorAnimationStyle.smooth ||
        CursorAnimationStyle.medium ||
        CursorAnimationStyle.rapid ||
        CursorAnimationStyle.none =>
          false,
        CursorAnimationStyle.studioSoft ||
        CursorAnimationStyle.studioSnappy =>
          true,
      };

  /// Lerp factor passed to [ZoomFocalController.update]. 1.0 = no
  /// smoothing (focal snaps to the cursor every frame).
  double get smoothing => switch (this) {
        CursorAnimationStyle.smooth => 0.09,
        CursorAnimationStyle.medium => 0.18,
        CursorAnimationStyle.rapid => 0.40,
        CursorAnimationStyle.none => 1.0,
        CursorAnimationStyle.studioSoft => 0.09,
        CursorAnimationStyle.studioSnappy => 0.22,
      };

  /// Curve used for the picker's hover demo.
  Curve get previewCurve => switch (this) {
        CursorAnimationStyle.smooth => Curves.easeOutSine,
        CursorAnimationStyle.medium => Curves.easeOutCubic,
        CursorAnimationStyle.rapid => Curves.easeOutQuint,
        CursorAnimationStyle.none => Curves.linear,
        CursorAnimationStyle.studioSoft => Curves.easeOutCubic,
        CursorAnimationStyle.studioSnappy => Curves.easeOutQuint,
      };

  Duration get previewDuration => switch (this) {
        CursorAnimationStyle.smooth => const Duration(milliseconds: 1400),
        CursorAnimationStyle.medium => const Duration(milliseconds: 800),
        CursorAnimationStyle.rapid => const Duration(milliseconds: 350),
        CursorAnimationStyle.none => const Duration(milliseconds: 80),
        CursorAnimationStyle.studioSoft => const Duration(milliseconds: 1000),
        CursorAnimationStyle.studioSnappy => const Duration(milliseconds: 600),
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
        CursorAnimationStyle.studioSoft =>
          (window: const Duration(milliseconds: 300), curve: Curves.easeOutCubic),
        CursorAnimationStyle.studioSnappy =>
          (window: const Duration(milliseconds: 140), curve: Curves.easeOutCubic),
      };

  /// Spring parameters that drive the cursor's motion chase. Stiffness
  /// is tuned so each preset's perceived "settle time" is similar to
  /// the legacy FIR's: Smooth chases lazily, Rapid is nearly instant,
  /// None snaps. All presets default to critical damping (ratio = 1.0)
  /// — no overshoot. Dragging the Springs section sliders in the
  /// cursor tab switches the config to a custom spring that overrides
  /// these.
  MotionSpring get motionSpring => switch (this) {
        // Baked from the tuned Studio Soft feel (#7): a lazier chase.
        CursorAnimationStyle.smooth =>
          const MotionSpring(stiffness: 160, damping: 1.0),
        CursorAnimationStyle.medium =>
          const MotionSpring(stiffness: 380, damping: 1.0),
        CursorAnimationStyle.rapid =>
          const MotionSpring(stiffness: 900, damping: 1.0),
        CursorAnimationStyle.none => MotionSpring.snap,
        CursorAnimationStyle.studioSoft =>
          const MotionSpring(stiffness: 160, damping: 1.0),
        CursorAnimationStyle.studioSnappy =>
          const MotionSpring(stiffness: 520, damping: 1.0),
      };
}
