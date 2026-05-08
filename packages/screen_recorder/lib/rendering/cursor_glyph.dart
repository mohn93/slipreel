import 'package:flutter/material.dart';

/// Built-in synthetic-cursor styles. The recorder no longer bakes the
/// OS pointer into video frames, so the editor and exporter both
/// render the cursor at playback/encode time using one of these
/// presets, plus the user's chosen size multiplier.
enum CursorStyle {
  classic,
  modernDark,
  dot,
  bold,
  outlined,
}

/// Default arrow height in video pixels at size = 1.0. Picked to be
/// noticeable on Retina recordings without dwarfing the screen
/// content; the inspector slider scales this up or down.
const double kCursorBaseDiameter = 32;

/// Draws a synthetic cursor onto [canvas] at [position] with the given
/// [style]. For arrow styles the tip of the arrow lands on [position]
/// (matching the OS hot-spot), so the recorded cursor coordinates can
/// be passed in unchanged. For the [CursorStyle.dot] style the circle
/// is centered on [position] instead.
void paintCursorGlyph(
  Canvas canvas, {
  required Offset position,
  required double diameter,
  required CursorStyle style,
}) {
  if (style == CursorStyle.dot) {
    canvas.drawCircle(
      position,
      diameter / 2,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.drawCircle(
      position,
      diameter / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black.withValues(alpha: 0.6)
        ..strokeWidth = diameter / 24 * 1.0,
    );
    return;
  }

  // Arrow shape — the macOS pointer polygon. Vertices follow a 10×16
  // design grid, going clockwise from the top-left tip:
  //   (0,0) tip → (10,10) right shoulder → (6,10) inner shoulder →
  //   (9,15) right-prong corner → (6,16) right-prong tip →
  //   (4,11) inner crease → (0,14) left-prong tip → close.
  // The tip sits at (0, 0) of the bounding box, so [position] is the
  // arrow's tip — matches the OS hot-spot exactly.
  final h = diameter;
  final w = diameter * 10 / 16;
  final ox = position.dx;
  final oy = position.dy;
  final path = Path()
    ..moveTo(ox + 0,           oy + 0)
    ..lineTo(ox + w,           oy + h * 10 / 16)
    ..lineTo(ox + w *  6 / 10, oy + h * 10 / 16)
    ..lineTo(ox + w *  9 / 10, oy + h * 15 / 16)
    ..lineTo(ox + w *  6 / 10, oy + h)
    ..lineTo(ox + w *  4 / 10, oy + h * 11 / 16)
    ..lineTo(ox + 0,           oy + h * 14 / 16)
    ..close();

  final (Color fill, Color outline, double strokePx) = switch (style) {
    // Classic: matches the modern macOS pointer — black fill with a
    // thin white halo. The halo (achieved via a centered stroke) is
    // what makes the cursor visible against any background.
    CursorStyle.classic =>
      (Colors.black, Colors.white, diameter / 24 * 1.6),
    CursorStyle.modernDark =>
      (Colors.white, Colors.black, diameter / 24 * 1.4),
    CursorStyle.bold => (Colors.white, Colors.white, 0.0),
    CursorStyle.outlined =>
      (Colors.white, Colors.black, diameter / 24 * 2.4),
    CursorStyle.dot => (Colors.white, Colors.white, 0.0),
  };

  if (fill != Colors.transparent) {
    canvas.drawPath(path, Paint()..color = fill);
  }
  if (strokePx > 0) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = outline
        ..strokeWidth = strokePx
        ..strokeJoin = StrokeJoin.round,
    );
  }
}

extension CursorStyleLabel on CursorStyle {
  String get label => switch (this) {
        CursorStyle.classic => 'Classic',
        CursorStyle.modernDark => 'Modern Dark',
        CursorStyle.dot => 'Dot',
        CursorStyle.bold => 'Bold',
        CursorStyle.outlined => 'Outlined',
      };
}
