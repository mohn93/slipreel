import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';
import 'cursor_glyph.dart';
import 'spring_config.dart';

/// Visual click-feedback options shown by the inspector's *Click effect*
/// picker. The press-pulse (size shrink-then-overshoot animation) plays
/// regardless of choice — these values control whether an additional
/// expanding ring is drawn underneath the cursor.
enum CursorClickEffect {
  none,
  ripple,
}

extension CursorClickEffectLabel on CursorClickEffect {
  String get label => switch (this) {
        CursorClickEffect.none => 'None',
        CursorClickEffect.ripple => 'Ripple',
      };
}

/// The cursor's scale factor while the mouse button is held. Below 1.0
/// so the click reads as a press; tuned to match macOS's own subtle
/// shrink. Press and release durations come from the spring's
/// settling time — there are no fixed timing constants any more.
const double _heldMultiplier = 0.86;

/// Total length of the ripple expansion+fade.
const int _rippleDurationMicros = 350000;

/// One click event: when it happened (false→true transition) and where
/// the cursor was at that moment in screen-space. Returned by
/// [mostRecentClickEvent] so the renderer can pin the ripple to the
/// click site even after the cursor has moved on.
class CursorClickEvent {
  final int timestampMicros;
  final Offset screenPos;
  const CursorClickEvent({
    required this.timestampMicros,
    required this.screenPos,
  });
}

/// Returns the most recent false→true click transition at or before
/// [timestampMicros], or null if no click has happened yet. Walks the
/// recording from the start once per call — recordings are small
/// enough that this isn't worth caching today.
CursorClickEvent? mostRecentClickEvent(
  CursorRecording recording,
  int timestampMicros,
) {
  final positions = recording.positions;
  if (positions.isEmpty) return null;
  bool? prevClicked;
  CursorClickEvent? mostRecent;
  for (final p in positions) {
    if (p.timestampMicros > timestampMicros) break;
    if (prevClicked == false && p.isClicked) {
      mostRecent = CursorClickEvent(
        timestampMicros: p.timestampMicros,
        screenPos: Offset(p.x, p.y),
      );
    }
    prevClicked = p.isClicked;
  }
  return mostRecent;
}

/// Microseconds since the most recent click event, or null if no click
/// has happened yet at [timestampMicros].
int? microsSinceClick(
  CursorRecording recording,
  int timestampMicros,
) {
  final ev = mostRecentClickEvent(recording, timestampMicros);
  if (ev == null) return null;
  final delta = timestampMicros - ev.timestampMicros;
  return delta < 0 ? null : delta;
}

/// Microseconds since the most recent button-release event (true→false
/// transition), or null if no release has happened yet at
/// [timestampMicros]. Walks the recording from the start once per
/// call; recordings are small enough this isn't worth caching.
int? microsSinceRelease(
  CursorRecording recording,
  int timestampMicros,
) {
  final positions = recording.positions;
  if (positions.isEmpty) return null;
  bool? prevClicked;
  int? lastReleaseMicros;
  for (final p in positions) {
    if (p.timestampMicros > timestampMicros) break;
    if (prevClicked == true && !p.isClicked) {
      lastReleaseMicros = p.timestampMicros;
    }
    prevClicked = p.isClicked;
  }
  if (lastReleaseMicros == null) return null;
  final delta = timestampMicros - lastReleaseMicros;
  return delta < 0 ? null : delta;
}

/// Press-pulse multiplier, evaluated in closed form from a single
/// [SpringSimulation] re-targeted on each button event. The cursor
/// shrinks toward [_heldMultiplier] while the button is down (so a
/// long click stays visibly pressed for as long as the user holds it)
/// and chases back to 1.0 after release. With the default `snappy`
/// spring the press and release both settle in ~150–200 ms; dropping
/// the damping ratio below 1.0 introduces bounce on release.
///
/// Closed-form means: no per-frame state, deterministic at any
/// playhead position, scrub-friendly.
///
/// [microsSinceClick]   — time since the most recent press-down event,
///                        or null if none has happened. Larger values
///                        are older.
/// [microsSinceRelease] — time since the most recent release event, or
///                        null if the button has never been released
///                        since recording start. Treated as "still
///                        held" when greater than [microsSinceClick].
/// [spring]             — tuning. [ClickSpring.snappy] by default.
double pressPulseMultiplier({
  required int? microsSinceClick,
  required int? microsSinceRelease,
  ClickSpring spring = ClickSpring.snappy,
}) {
  if (microsSinceClick == null || microsSinceClick < 0) return 1.0;

  final desc = spring.toDescription();
  final stillHeld = microsSinceRelease == null ||
      microsSinceRelease > microsSinceClick;

  if (stillHeld) {
    // Press phase. Spring starts at rest at 1.0, targets _heldMultiplier.
    final t = microsSinceClick / 1e6;
    final sim = SpringSimulation(desc, 1.0, _heldMultiplier, 0.0);
    return sim.x(t);
  }

  // Release phase. We need the spring's state at the moment of
  // release to start the release simulation from. Evaluate the press
  // spring at the hold duration to get (size, velocity) at release,
  // then run a release spring from that state toward 1.0.
  final holdT = (microsSinceClick - microsSinceRelease) / 1e6;
  final pressSim = SpringSimulation(desc, 1.0, _heldMultiplier, 0.0);
  final sizeAtRelease = pressSim.x(holdT);
  final velAtRelease = pressSim.dx(holdT);

  final releaseT = microsSinceRelease / 1e6;
  final releaseSim =
      SpringSimulation(desc, sizeAtRelease, 1.0, velAtRelease);
  return releaseSim.x(releaseT);
}

/// State for the expanding ripple ring at a given moment, or null when
/// the ripple is not active.
class RippleState {
  final double radius;
  final double opacity;
  final double strokeWidth;
  const RippleState({
    required this.radius,
    required this.opacity,
    required this.strokeWidth,
  });
}

/// Compute the current ripple geometry for a click event that occurred
/// [microsSinceClick] microseconds ago, given the cursor's [baseDiameter]
/// in canvas pixels. Returns null when the ripple has finished or was
/// never started.
RippleState? rippleAt(
  int microsSinceClick,
  double baseDiameter,
) {
  if (microsSinceClick < 0 || microsSinceClick >= _rippleDurationMicros) {
    return null;
  }
  final t = microsSinceClick / _rippleDurationMicros;
  // Cubic ease-out so the ring moves quickly at first and slows.
  final eased = 1 - math.pow(1 - t, 3).toDouble();
  return RippleState(
    radius: baseDiameter * (0.5 + eased * 2.0),
    opacity: 0.6 * (1 - t),
    strokeWidth: 3.0 * (1 - t * 0.7),
  );
}

/// Paints just the click ripple ring (or no-ops if no ripple is
/// active). Split out from the glyph painter so the motion-blur path
/// can render the ripple directly on the canvas — keeping the ring
/// tied to the click point — while pre-baking only the cursor body
/// into the sprite that gets smeared along the velocity vector.
void paintCursorRipple(
  Canvas canvas, {
  required Offset position,
  required double baseDiameter,
  required int? microsSinceClick,
  CursorClickEffect effect = CursorClickEffect.none,
}) {
  if (effect != CursorClickEffect.ripple || microsSinceClick == null) return;
  final ripple = rippleAt(microsSinceClick, baseDiameter);
  if (ripple == null) return;
  canvas.drawCircle(
    position,
    ripple.radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withValues(alpha: ripple.opacity)
      ..strokeWidth = ripple.strokeWidth,
  );
}

/// Paints the cursor glyph at [position] with the press-pulse applied
/// (cursor shrinks while held, snaps back with a small bounce on
/// release). No ripple — callers that want the ring underneath should
/// call [paintCursorRipple] before this.
void paintCursorGlyphWithPulse(
  Canvas canvas, {
  required Offset position,
  required double baseDiameter,
  required CursorStyle style,
  required int? microsSinceClick,
  int? microsSinceRelease,
  ClickSpring clickSpring = ClickSpring.snappy,
  CursorState state = CursorState.arrow,
  double shadowIntensity = 0,
}) {
  final pulse = pressPulseMultiplier(
    microsSinceClick: microsSinceClick,
    microsSinceRelease: microsSinceRelease,
    spring: clickSpring,
  );
  final effectiveDiameter = baseDiameter * pulse;
  if (shadowIntensity > 0) {
    _paintCursorShadow(
      canvas,
      position: position,
      diameter: effectiveDiameter,
      style: style,
      state: state,
      intensity: shadowIntensity,
    );
  }
  paintCursorGlyph(
    canvas,
    position: position,
    diameter: effectiveDiameter,
    style: style,
    state: state,
  );
}

/// Renders a soft drop shadow under the cursor by re-drawing the
/// glyph onto a Gaussian-blurred + black-tinted layer, offset slightly
/// down. Works uniformly for every cursor type (arrow, dot, I-beam,
/// pointing-hand, resize, etc.) — we just delegate to [paintCursorGlyph]
/// inside the layer, so whatever shape the foreground draws becomes
/// the shadow's silhouette.
///
/// Parameters scale with [intensity] (0..1) so a single user-facing
/// slider drives offset, blur radius, and opacity together. The base
/// constants are tuned for the macOS cursor's typical drop-shadow
/// look (subtle, mostly downward, narrow halo).
void _paintCursorShadow(
  Canvas canvas, {
  required Offset position,
  required double diameter,
  required CursorStyle style,
  required CursorState state,
  required double intensity,
}) {
  final blurSigma = diameter * 0.10 * intensity + 1.0;
  final offsetY = diameter * 0.08 * intensity;
  final opacity = (0.55 * intensity).clamp(0.0, 0.7);

  // The layer's bounds need to cover the cursor body + the blur's
  // tail. A square of side ~3× diameter centred on [position] is
  // generous enough for every glyph (the largest, the macOS arrow
  // halo, runs ~1.3× diameter from the tip). null bounds would also
  // work but force Skia into a slow path.
  final layerBounds = Rect.fromCenter(
    center: position + Offset(0, offsetY),
    width: diameter * 3,
    height: diameter * 3,
  );

  canvas.save();
  canvas.translate(0, offsetY);
  canvas.saveLayer(
    layerBounds,
    Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
      )
      ..colorFilter = ColorFilter.mode(
        Color.fromRGBO(0, 0, 0, opacity),
        BlendMode.srcIn,
      ),
  );
  paintCursorGlyph(
    canvas,
    position: position,
    diameter: diameter,
    style: style,
    state: state,
  );
  canvas.restore();
  canvas.restore();
}

