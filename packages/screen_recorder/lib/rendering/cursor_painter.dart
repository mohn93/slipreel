import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/spring_config.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Inputs for [paintCursorComposed] — every value the unified
/// ripple+glyph composition needs. Pulled out as a value class so the
/// three current cursor painters (export `CursorRenderer`, preview
/// `CursorOverlayPainter`, accumulation `AccumulationCursorPainter`)
/// can build it once per frame and route it to the same code path,
/// rather than each maintaining its own `paintCursorRipple` +
/// `paintCursorGlyphWithPulse` sequence and silently drifting.
///
/// The two-position split is load-bearing: the ripple anchors at
/// [clickPosition] (where the click actually happened) while the glyph
/// follows [cursorPosition] (the live cursor). A single shared
/// "position" was the source of bug #1 in the 2026-05 architecture
/// review — exported MP4s showed the ripple dragging behind the
/// cursor whenever the user clicked-and-moved.
@immutable
class CursorPaintRequest {
  const CursorPaintRequest({
    required this.cursorPosition,
    this.clickPosition,
    this.microsSinceClick,
    this.microsSinceRelease,
    required this.baseDiameter,
    this.style = CursorStyle.modernDark,
    this.state = CursorState.arrow,
    this.clickEffect = CursorClickEffect.none,
    this.clickSpring = ClickSpring.snappy,
    this.shadowIntensity = 0,
  });

  /// Live cursor location for the glyph + press-pulse.
  final Offset cursorPosition;

  /// Where the most recent click landed, in the same coordinate space
  /// as [cursorPosition]. Null when no click has happened yet at this
  /// playhead (and therefore no ripple should be drawn). Distinct from
  /// [cursorPosition] so the ripple can stay pinned to the click site
  /// after the user has moved the mouse away.
  final Offset? clickPosition;

  /// Microseconds since [clickPosition] was recorded; drives both the
  /// ripple's expand/fade animation and the glyph's press-pulse spring.
  /// Null when no click is currently active.
  final int? microsSinceClick;

  /// Microseconds since the most recent button-release. Null while the
  /// button is still held. Used by the press-pulse to decide
  /// release-phase animation; the ripple ignores it.
  final int? microsSinceRelease;

  /// Glyph height in canvas pixels at pulse = 1.0. The press-pulse
  /// scales this; the ripple uses it as the baseline ring diameter.
  final double baseDiameter;

  final CursorStyle style;
  final CursorState state;
  final CursorClickEffect clickEffect;
  final ClickSpring clickSpring;

  /// Soft drop-shadow strength under the glyph, 0..1. 0 disables.
  final double shadowIntensity;
}

/// Single entry point for "draw one cursor stamp" — composes the
/// optional click ripple underneath the glyph (with press-pulse +
/// shadow). Used by every cursor painter so the three rendering paths
/// (live preview, accumulation blur, export) produce the same visual
/// result frame-for-frame.
///
/// Replaces the legacy `paintCursorWithEffects` from
/// `cursor_click_effect.dart`. That wrapper took a single `position`
/// parameter and used it for both ripple and glyph — fine for the
/// non-clicking case but wrong for any click-and-drag, which exported
/// builds were silently shipping.
void paintCursorComposed(Canvas canvas, CursorPaintRequest req) {
  final clickPos = req.clickPosition;
  if (clickPos != null) {
    paintCursorRipple(
      canvas,
      position: clickPos,
      baseDiameter: req.baseDiameter,
      microsSinceClick: req.microsSinceClick,
      effect: req.clickEffect,
    );
  }
  paintCursorGlyphWithPulse(
    canvas,
    position: req.cursorPosition,
    baseDiameter: req.baseDiameter,
    style: req.style,
    microsSinceClick: req.microsSinceClick,
    microsSinceRelease: req.microsSinceRelease,
    clickSpring: req.clickSpring,
    state: req.state,
    shadowIntensity: req.shadowIntensity,
  );
}
