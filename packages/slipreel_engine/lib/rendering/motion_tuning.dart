import 'package:flutter/foundation.dart';

/// One bag for the editor's motion-feel constants — spring sub-step
/// caps, the bounded-mode "cursor at rest" velocity threshold, the
/// cursor sprite's velocity feedforward strength and fade-band, etc.
///
/// Before P2-8 every one of these lived as a private `static const`
/// inside a different controller file. Tuning the editor's feel meant
/// finding the right file, recompiling, relaunching. This record
/// makes the tuning vocabulary discoverable in one place, lets the
/// values be loaded from JSON or swapped to a named preset at
/// runtime, and gives test code a single seam for asserting that a
/// chosen preset actually affects what it claims to affect.
///
/// Production controllers default to [MotionTuning.defaults], which
/// is the historic hand-tuned set — landing this commit does not
/// change the feel of the editor.
@immutable
class MotionTuning {
  const MotionTuning({
    this.reverseScrubFloor = const Duration(milliseconds: 200),
    this.subStepCapMicros = const Duration(milliseconds: 16),
    this.dtCap = const Duration(milliseconds: 250),
    this.cursorAtRestPxPerSec = 80.0,
    this.cursorVelocityLookback = const Duration(milliseconds: 33),
    this.cursorFeedforwardStrength = 0.5,
    this.cursorFeedforwardFadeStartPxPerSec = 200.0,
    this.cursorFeedforwardFullSpeedPxPerSec = 800.0,
  });

  /// Minimum reverse-scrub jump that resets focal/cursor spring
  /// state. Inputs smaller than this are treated as normal playback
  /// motion. Below the floor the spring's accumulated state stays
  /// useful; above it we'd re-render content the spring never saw.
  final Duration reverseScrubFloor;

  /// Maximum sub-step duration when integrating the focal spring's
  /// semi-implicit Euler. Smaller = stabler at high stiffness but
  /// more compute per frame.
  final Duration subStepCapMicros;

  /// Total per-frame dt cap. Frames longer than this (paint stalls,
  /// hot reload, etc.) collapse to this duration so the integrator
  /// can't bulk-step the spring into ringing.
  final Duration dtCap;

  /// Velocity threshold (px/s) below which the bounded-mode follow
  /// gate considers the cursor "at rest" and releases. Production at
  /// 80 px/s gives ~45 px/s of margin above the noise floor (click
  /// sample injection + screen→video transform jitter + hand tremor).
  final double cursorAtRestPxPerSec;

  /// Backwards window for the cursor's finite-difference scene
  /// velocity estimate. Longer windows smooth more but lag the truth.
  final Duration cursorVelocityLookback;

  /// Peak fraction of the spring's analytical lag (τ) that the
  /// feedforward target compensates for. 1.0 = full cancellation (no
  /// lag); 0.0 = vanilla spring chase.
  final double cursorFeedforwardStrength;

  /// Cursor speed (px/s) at which the feedforward strength is fully
  /// faded off. Below this the feedforward target collapses toward
  /// the raw cursor — important on click landings where the spring's
  /// τ × v lead would yank the sprite past the click site.
  final double cursorFeedforwardFadeStartPxPerSec;

  /// Cursor speed (px/s) at which the feedforward is fully on. Above
  /// this speed [cursorFeedforwardStrength] applies in full.
  final double cursorFeedforwardFullSpeedPxPerSec;

  /// Historic production tuning — what the editor felt like before
  /// P2-8 landed. Every controller defaults here unless the caller
  /// passes an override, so this commit alone is behavior-neutral.
  static const MotionTuning defaults = MotionTuning();

  /// Tighter, more responsive feel. Drops the at-rest threshold so
  /// the gate releases sooner, bumps feedforward closer to full lag
  /// cancellation. Suitable for product demos / tutorial recordings
  /// where viewers expect the camera to keep up with the cursor.
  static const MotionTuning snappy = MotionTuning(
    cursorAtRestPxPerSec: 60.0,
    cursorFeedforwardStrength: 0.75,
  );

  /// Slacker, film-y feel — preserves more spring lag so the cursor
  /// settles in visibly rather than snapping to position. The
  /// vanilla spring chase (strength = 0) is a touch too sluggish; 0.25
  /// keeps the rendered cursor close enough to the raw path that
  /// click landings still read as accurate.
  static const MotionTuning cinematic = MotionTuning(
    cursorFeedforwardStrength: 0.25,
  );

  MotionTuning copyWith({
    Duration? reverseScrubFloor,
    Duration? subStepCapMicros,
    Duration? dtCap,
    double? cursorAtRestPxPerSec,
    Duration? cursorVelocityLookback,
    double? cursorFeedforwardStrength,
    double? cursorFeedforwardFadeStartPxPerSec,
    double? cursorFeedforwardFullSpeedPxPerSec,
  }) {
    return MotionTuning(
      reverseScrubFloor: reverseScrubFloor ?? this.reverseScrubFloor,
      subStepCapMicros: subStepCapMicros ?? this.subStepCapMicros,
      dtCap: dtCap ?? this.dtCap,
      cursorAtRestPxPerSec:
          cursorAtRestPxPerSec ?? this.cursorAtRestPxPerSec,
      cursorVelocityLookback:
          cursorVelocityLookback ?? this.cursorVelocityLookback,
      cursorFeedforwardStrength:
          cursorFeedforwardStrength ?? this.cursorFeedforwardStrength,
      cursorFeedforwardFadeStartPxPerSec: cursorFeedforwardFadeStartPxPerSec ??
          this.cursorFeedforwardFadeStartPxPerSec,
      cursorFeedforwardFullSpeedPxPerSec: cursorFeedforwardFullSpeedPxPerSec ??
          this.cursorFeedforwardFullSpeedPxPerSec,
    );
  }

  Map<String, dynamic> toJson() => {
        'reverseScrubFloorMs': reverseScrubFloor.inMilliseconds,
        'subStepCapMicros': subStepCapMicros.inMicroseconds,
        'dtCapMs': dtCap.inMilliseconds,
        'cursorAtRestPxPerSec': cursorAtRestPxPerSec,
        'cursorVelocityLookbackMs': cursorVelocityLookback.inMilliseconds,
        'cursorFeedforwardStrength': cursorFeedforwardStrength,
        'cursorFeedforwardFadeStartPxPerSec':
            cursorFeedforwardFadeStartPxPerSec,
        'cursorFeedforwardFullSpeedPxPerSec':
            cursorFeedforwardFullSpeedPxPerSec,
      };

  factory MotionTuning.fromJson(Map<String, dynamic> json) {
    const d = MotionTuning.defaults;
    Duration durationFromMs(String key, Duration fallback) {
      final v = json[key];
      if (v is num) return Duration(milliseconds: v.round());
      return fallback;
    }

    Duration durationFromMicros(String key, Duration fallback) {
      final v = json[key];
      if (v is num) return Duration(microseconds: v.round());
      return fallback;
    }

    double doubleOr(String key, double fallback) {
      final v = json[key];
      return v is num ? v.toDouble() : fallback;
    }

    return MotionTuning(
      reverseScrubFloor:
          durationFromMs('reverseScrubFloorMs', d.reverseScrubFloor),
      subStepCapMicros:
          durationFromMicros('subStepCapMicros', d.subStepCapMicros),
      dtCap: durationFromMs('dtCapMs', d.dtCap),
      cursorAtRestPxPerSec:
          doubleOr('cursorAtRestPxPerSec', d.cursorAtRestPxPerSec),
      cursorVelocityLookback: durationFromMs(
        'cursorVelocityLookbackMs',
        d.cursorVelocityLookback,
      ),
      cursorFeedforwardStrength: doubleOr(
        'cursorFeedforwardStrength',
        d.cursorFeedforwardStrength,
      ),
      cursorFeedforwardFadeStartPxPerSec: doubleOr(
        'cursorFeedforwardFadeStartPxPerSec',
        d.cursorFeedforwardFadeStartPxPerSec,
      ),
      cursorFeedforwardFullSpeedPxPerSec: doubleOr(
        'cursorFeedforwardFullSpeedPxPerSec',
        d.cursorFeedforwardFullSpeedPxPerSec,
      ),
    );
  }
}
