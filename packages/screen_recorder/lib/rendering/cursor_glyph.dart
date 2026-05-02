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

  // Arrow shape — same proportions as the inspector preview tile.
  final h = diameter;
  final w = diameter * 20 / 24;
  // Tip lives at (0.15w, 0.05h) inside the bounding box; anchor the
  // box so that point lands on [position].
  final ox = position.dx - w * 0.15;
  final oy = position.dy - h * 0.05;
  final path = Path()
    ..moveTo(ox + w * 0.15, oy + h * 0.05)
    ..lineTo(ox + w * 0.85, oy + h * 0.55)
    ..lineTo(ox + w * 0.55, oy + h * 0.6)
    ..lineTo(ox + w * 0.7, oy + h * 0.92)
    ..lineTo(ox + w * 0.55, oy + h * 0.96)
    ..lineTo(ox + w * 0.4, oy + h * 0.66)
    ..lineTo(ox + w * 0.15, oy + h * 0.85)
    ..close();

  final (Color fill, Color outline, double strokePx) = switch (style) {
    CursorStyle.classic =>
      (Colors.transparent, Colors.white, diameter / 24 * 1.4),
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
