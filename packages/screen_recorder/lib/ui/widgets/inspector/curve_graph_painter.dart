import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart'
    show kInspectorAccent, kInspectorBorder;

/// Visible y range for the bezier graph. x always spans [0, 1] (CSS
/// cubic-bezier domain). y can sit outside [0, 1] when the user
/// authors overshoot or anticipation, so the graph extends a bit
/// above and below the unit square to keep those handles in view.
const double kCurveGraphYMin = -0.25;
const double kCurveGraphYMax = 1.25;

/// Aspect ratio of the graph drawing area: width / height. With y
/// spanning 1.5 units and x spanning 1 unit, a 1:1 pixel mapping
/// gives the graph a 1:1.5 aspect ratio — taller than wide.
const double kCurveGraphAspect = 1.0 / (kCurveGraphYMax - kCurveGraphYMin);

/// Renders the bezier graph: an outer canvas spanning x∈[0,1] and
/// y∈[kCurveGraphYMin, kCurveGraphYMax], with the unit square
/// highlighted as a faint inner box (so the user always knows where
/// y=0 / y=1 are even after dragging into the overshoot zone).
/// Plus the curve sampled at ~64 points, tangent guide lines from
/// (0,0)→handle1 and (1,1)→handle2, the two draggable handles, and
/// an animated demo dot whose horizontal position is `progress` (0–1).
class CurveGraphPainter extends CustomPainter {
  CurveGraphPainter({
    required this.curve,
    required this.demoProgress,
    required this.draggingHandle,
  });

  final CubicBezierCurve curve;

  /// 0–1 — current x-coord of the demo dot. The dot's y is the curve
  /// evaluated at this x.
  final double demoProgress;

  /// 0 = none, 1 = handle 1, 2 = handle 2. Drives a glow on the active
  /// handle so users see what they're dragging.
  final int draggingHandle;

  @override
  void paint(Canvas canvas, Size size) {
    Offset toScreen(double x, double y) {
      final ny = (kCurveGraphYMax - y) / (kCurveGraphYMax - kCurveGraphYMin);
      return Offset(x * size.width, ny * size.height);
    }

    // Outer frame around the entire visible coordinate range.
    final outerPaint = Paint()
      ..color = kInspectorBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      outerPaint,
    );

    // Quartile gridlines inside the unit square.
    final unitTop = toScreen(0, 1).dy;
    final unitBottom = toScreen(0, 0).dy;
    final unitHeight = unitBottom - unitTop;
    final faintGrid = Paint()
      ..color = kInspectorBorder.withValues(alpha: 0.3);
    for (var i = 1; i < 4; i++) {
      final dx = size.width * i / 4;
      final dy = unitTop + unitHeight * i / 4;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), faintGrid);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), faintGrid);
    }

    // Highlight the unit square — y=0 and y=1 baselines — so the user
    // can read the overshoot region against a clear landmark.
    final unitFramePaint = Paint()
      ..color = kInspectorBorder.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, unitTop), Offset(size.width, unitTop), unitFramePaint);
    canvas.drawLine(
      Offset(0, unitBottom), Offset(size.width, unitBottom), unitFramePaint);

    // Tangent guide lines.
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    canvas.drawLine(toScreen(0, 0), toScreen(curve.x1, curve.y1), guidePaint);
    canvas.drawLine(toScreen(1, 1), toScreen(curve.x2, curve.y2), guidePaint);

    // Curve path — sample 64 points using the Flutter Cubic.
    final cubic = Cubic(curve.x1, curve.y1, curve.x2, curve.y2);
    final path = Path()..moveTo(toScreen(0, 0).dx, toScreen(0, 0).dy);
    const samples = 64;
    for (var i = 1; i <= samples; i++) {
      final tx = i / samples;
      final ty = cubic.transform(tx);
      final p = toScreen(tx, ty);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = kInspectorAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Handles.
    void handle(int idx, double x, double y) {
      final p = toScreen(x, y);
      final glowing = draggingHandle == idx;
      if (glowing) {
        canvas.drawCircle(
          p,
          12,
          Paint()..color = kInspectorAccent.withValues(alpha: 0.25),
        );
      }
      canvas.drawCircle(p, 6, Paint()..color = kInspectorAccent);
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white.withValues(alpha: 0.85)
          ..strokeWidth = 1.4,
      );
    }

    handle(1, curve.x1, curve.y1);
    handle(2, curve.x2, curve.y2);

    // Demo dot.
    final dx = demoProgress.clamp(0.0, 1.0);
    final dy = cubic.transform(dx);
    final dot = toScreen(dx, dy);
    canvas.drawCircle(dot, 4.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CurveGraphPainter old) =>
      old.curve != curve ||
      old.demoProgress != demoProgress ||
      old.draggingHandle != draggingHandle;
}
