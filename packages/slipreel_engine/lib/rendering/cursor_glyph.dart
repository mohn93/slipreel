import 'dart:math' as math;
import 'dart:ui' show Canvas, Color, Offset, Paint, PaintingStyle, Path, StrokeJoin;

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'cursor_state_glyphs.dart';

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
///
/// When [state] is anything other than [CursorState.arrow], the
/// rendering swaps the styled arrow for the matching state glyph
/// (I-beam, pointing hand, resize, etc.) — that's the live OS
/// pointer the recorder captured. The user's [style] selection only
/// affects the arrow form; once macOS switches the pointer to a
/// hand or I-beam the styled-arrow distinction no longer applies
/// (macOS itself swaps the cursor wholesale, it doesn't stylise the
/// resize glyph). [CursorStyle.dot] is the one exception: it's the
/// "minimal abstract" style and stays a circle regardless of state.
void paintCursorGlyph(
  Canvas canvas, {
  required Offset position,
  required double diameter,
  required CursorStyle style,
  CursorState state = CursorState.arrow,
}) {
  // State-specific glyphs apply to every arrow style: hovering over
  // a link in the recording shows a pointing hand, hovering over a
  // text field shows an I-beam, etc., regardless of whether the
  // user picked Classic, Modern Dark, Bold, or Outlined.
  if (style != CursorStyle.dot && state != CursorState.arrow) {
    paintStateGlyph(
      canvas,
      state: state,
      position: position,
      diameter: diameter,
    );
    return;
  }
  if (style == CursorStyle.dot) {
    canvas.drawCircle(
      position,
      diameter / 2,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85),
    );
    canvas.drawCircle(
      position,
      diameter / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xFF000000).withValues(alpha: 0.6)
        ..strokeWidth = diameter / 24 * 1.0,
    );
    return;
  }

  // Scale the macOS-design grid so the BLACK body's height equals
  // [diameter] (matches prior behavior where `diameter` was the
  // arrow's vertical extent). The halo extends slightly outside this
  // box, which is the OS-pointer's actual visual footprint.
  final scale = diameter / _kBodyHeight;
  // Corner radius in canvas pixels. Small enough that the tip and
  // prong points still read as sharp at a glance, but large enough
  // to remove the visible polygon edges on closer inspection.
  final cornerRadius = diameter * 0.05;

  Offset toCanvas(Offset v) => Offset(
        position.dx + (v.dx - _kBodyTip.dx) * scale,
        position.dy + (v.dy - _kBodyTip.dy) * scale,
      );

  // Build a closed path through [verts] with each corner rounded by
  // [cornerRadius] using a quadratic Bezier through the vertex. The
  // radius is auto-clamped to half the shorter adjacent edge so two
  // close corners don't crash into each other.
  Path buildRoundedPath(List<Offset> verts) {
    final pts = [for (final v in verts) toCanvas(v)];
    final path = Path();
    final n = pts.length;
    for (var i = 0; i < n; i++) {
      final prev = pts[(i - 1 + n) % n];
      final curr = pts[i];
      final next = pts[(i + 1) % n];
      final inLen = (curr - prev).distance;
      final outLen = (next - curr).distance;
      final r = math.min(cornerRadius, math.min(inLen, outLen) * 0.5);
      final inDir = (curr - prev) / inLen;
      final outDir = (next - curr) / outLen;
      final entry = curr - inDir * r;
      final exit = curr + outDir * r;
      if (i == 0) {
        path.moveTo(entry.dx, entry.dy);
      } else {
        path.lineTo(entry.dx, entry.dy);
      }
      path.quadraticBezierTo(curr.dx, curr.dy, exit.dx, exit.dy);
    }
    path.close();
    return path;
  }

  final bodyPath = buildRoundedPath(_kBodyVertices);

  if (style == CursorStyle.classic) {
    // Exact macOS pointer: halo first (white), body second (black).
    // This dual-path approach is what the OS cursor uses — a thin
    // outer "shape" sitting under the inner body — and reproduces the
    // halo crispness that a single centered stroke can't match,
    // especially around the sharp tip. Both paths get the same
    // corner-radius rounding so the halo stays parallel to the body.
    final haloPath = buildRoundedPath(_kHaloVertices);
    canvas.drawPath(haloPath, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawPath(bodyPath, Paint()..color = const Color(0xFF000000));
    return;
  }

  // Other arrow styles share the macOS body shape but use a single
  // fill+stroke rendering so each style's visual identity (bold,
  // outlined, dark glyph) is preserved.
  const white = Color(0xFFFFFFFF);
  const black = Color(0xFF000000);
  final (Color fill, Color outline, double strokePx) = switch (style) {
    CursorStyle.modernDark =>
      (white, black, diameter / 24 * 1.4),
    CursorStyle.bold => (white, white, 0.0),
    CursorStyle.outlined =>
      (white, black, diameter / 24 * 2.4),
    CursorStyle.classic => throw StateError('handled above'),
    CursorStyle.dot => throw StateError('handled above'),
  };

  if (fill != const Color(0x00000000)) {
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
