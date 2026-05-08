import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';
import 'cursor_glyph.dart';

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

/// Total length of the always-on press pulse — long enough to read but
/// short enough to feel snappy.
const int _pressDurationMicros = 250000;

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

/// Always-on press-pulse multiplier: cursor shrinks slightly, overshoots
/// past 1.0, and settles back. Returns 1.0 outside the animation window.
double pressPulseMultiplier(int microsSinceClick) {
  if (microsSinceClick < 0 || microsSinceClick >= _pressDurationMicros) {
    return 1.0;
  }
  final t = microsSinceClick / _pressDurationMicros;
  // Damped sine: dip first, slight overshoot, return to 1. Amplitude
  // tuned so the dip lands around 0.88 and the bounce around 1.04.
  return 1.0 -
      0.18 *
          math.sin(2 * math.pi * t) *
          math.exp(-1.8 * t);
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

/// Paints the cursor glyph at [position] with the always-on press-pulse
/// applied (cursor briefly shrinks then bounces on click). No ripple —
/// callers that want the ring underneath should call [paintCursorRipple]
/// before this.
void paintCursorGlyphWithPulse(
  Canvas canvas, {
  required Offset position,
  required double baseDiameter,
  required CursorStyle style,
  required int? microsSinceClick,
  CursorState state = CursorState.arrow,
}) {
  final pulse = microsSinceClick == null
      ? 1.0
      : pressPulseMultiplier(microsSinceClick);
  paintCursorGlyph(
    canvas,
    position: position,
    diameter: baseDiameter * pulse,
    style: style,
    state: state,
  );
}

/// Convenience wrapper: ripple underneath, glyph (with pulse) on top.
/// Use this on rendering paths that don't apply motion blur.
void paintCursorWithEffects(
  Canvas canvas, {
  required Offset position,
  required double baseDiameter,
  required CursorStyle style,
  required int? microsSinceClick,
  CursorClickEffect effect = CursorClickEffect.none,
  CursorState state = CursorState.arrow,
}) {
  paintCursorRipple(
    canvas,
    position: position,
    baseDiameter: baseDiameter,
    microsSinceClick: microsSinceClick,
    effect: effect,
  );
  paintCursorGlyphWithPulse(
    canvas,
    position: position,
    baseDiameter: baseDiameter,
    style: style,
    microsSinceClick: microsSinceClick,
    state: state,
  );
}
