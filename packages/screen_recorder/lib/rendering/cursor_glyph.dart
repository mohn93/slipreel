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

  // Arrow shape — the classic macOS pointer polygon. Vertices follow a
  // 12×18 design grid, going clockwise from the top-left tip:
  //   (0,0) tip → (12,11) right shoulder → (7,11) inner shoulder →
  //   (10,17) right-prong corner → (7,18) right-prong tip →
  //   (4,12) inner crease → (0,16) left-prong tip → close.
  // The tip sits at (0, 0) of the bounding box, so [position] is the
  // arrow's tip (matches the OS hot-spot exactly).
  final h = diameter;
  final w = diameter * 12 / 18;
  final ox = position.dx;
  final oy = position.dy;
  final path = Path()
    ..moveTo(ox + 0,           oy + 0)
    ..lineTo(ox + w,           oy + h * 11 / 18)
    ..lineTo(ox + w *  7 / 12, oy + h * 11 / 18)
    ..lineTo(ox + w * 10 / 12, oy + h * 17 / 18)
    ..lineTo(ox + w *  7 / 12, oy + h)
    ..lineTo(ox + w *  4 / 12, oy + h * 12 / 18)
    ..lineTo(ox + 0,           oy + h * 16 / 18)
    ..close();

  final (Color fill, Color outline, double strokePx) = switch (style) {
    // Classic: matches the macOS pointer — white fill, hairline
    // black stroke. The thin stroke and rounded join make the shape
    // read as the OS pointer at any size.
    CursorStyle.classic =>
      (Colors.white, Colors.black, diameter / 24 * 1.0),
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
