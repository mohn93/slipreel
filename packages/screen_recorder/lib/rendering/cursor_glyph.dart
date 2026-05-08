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

/// Design coordinates for the macOS pointer SVG (vendored from
/// daviddarnes/mac-cursors `default.svg`). Two paths: a white halo
/// drawn first, a black body drawn on top. Vertices listed clockwise
/// starting from the tip. The body's tip at (1.000, 2.814) is the
/// hot-spot — this is what the user clicks on, and what we anchor to
/// the caller's [position] argument.
const double _kBodyHeight = 14.186; // (17.000 - 2.814)
const _kBodyTip = Offset(1.000, 2.814);
const List<Offset> _kBodyVertices = [
  Offset(1.000, 2.814),  // tip
  Offset(9.025, 10.857), // right shoulder
  Offset(5.421, 10.857), // inner shoulder
  Offset(8.196, 16.059), // right-prong outer
  Offset(6.431, 17.000), // right-prong tip
  Offset(3.530, 11.560), // inner notch
  Offset(1.000, 14.002), // left-prong tip
];
const List<Offset> _kHaloVertices = [
  Offset(0.011, 0.407),  // halo tip
  Offset(11.390, 11.815),// halo right shoulder
  Offset(7.058, 11.815), // halo inner shoulder
  Offset(9.626, 16.631), // halo right-prong outer
  Offset(8.011, 17.470), // halo right-prong outer 2
  Offset(6.148, 18.473), // halo right-prong tip
  Offset(3.327, 13.201), // halo inner notch
  Offset(0.011, 16.422), // halo left-prong tip
];

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

  // Scale the macOS-design grid so the BLACK body's height equals
  // [diameter] (matches prior behavior where `diameter` was the
  // arrow's vertical extent). The halo extends slightly outside this
  // box, which is the OS-pointer's actual visual footprint.
  final scale = diameter / _kBodyHeight;
  Path buildPath(List<Offset> verts) {
    final path = Path();
    for (var i = 0; i < verts.length; i++) {
      final v = verts[i];
      final p = Offset(
        position.dx + (v.dx - _kBodyTip.dx) * scale,
        position.dy + (v.dy - _kBodyTip.dy) * scale,
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    return path;
  }

  final bodyPath = buildPath(_kBodyVertices);

  if (style == CursorStyle.classic) {
    // Exact macOS pointer: halo first (white), body second (black).
    // This dual-path approach is what the OS cursor uses — a thin
    // outer "shape" sitting under the inner body — and reproduces the
    // halo crispness that a single centered stroke can't match,
    // especially around the sharp tip.
    //
    // The halo gets a small Gaussian softening (sigma ≈ 4% of body
    // height) so its outer edge reads as a fuzzy glow rather than a
    // crisp polygon — that's the slightly hazy halo effect the modern
    // macOS pointer has when you look closely. Body stays sharp.
    final haloPath = buildPath(_kHaloVertices);
    canvas.drawPath(
      haloPath,
      Paint()
        ..color = Colors.white
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, diameter * 0.04),
    );
    canvas.drawPath(bodyPath, Paint()..color = Colors.black);
    return;
  }

  // Other arrow styles share the macOS body shape but use a single
  // fill+stroke rendering so each style's visual identity (bold,
  // outlined, dark glyph) is preserved.
  final (Color fill, Color outline, double strokePx) = switch (style) {
    CursorStyle.modernDark =>
      (Colors.white, Colors.black, diameter / 24 * 1.4),
    CursorStyle.bold => (Colors.white, Colors.white, 0.0),
    CursorStyle.outlined =>
      (Colors.white, Colors.black, diameter / 24 * 2.4),
    CursorStyle.classic => throw StateError('handled above'),
    CursorStyle.dot => throw StateError('handled above'),
  };

  if (fill != Colors.transparent) {
    canvas.drawPath(bodyPath, Paint()..color = fill);
  }
  if (strokePx > 0) {
    canvas.drawPath(
      bodyPath,
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
