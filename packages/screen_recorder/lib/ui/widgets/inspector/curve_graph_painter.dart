import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart'
    show kInspectorAccent, kInspectorBorder;

/// Renders the bezier graph: axes box, the curve sampled at ~64 points,
/// tangent guide lines from (0,0)→handle1 and (1,1)→handle2, the two
/// draggable handles, and (optionally) an animated demo dot whose
/// horizontal position is `progress` (0–1).
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
    // Axes box.
    final box = Rect.fromLTWH(0, 0, size.width, size.height);
    final axesPaint = Paint()
      ..color = kInspectorBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(box, axesPaint);

    // Light grid (quartiles).
    for (var i = 1; i < 4; i++) {
      final dx = size.width * i / 4;
      final dy = size.height * i / 4;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height),
          Paint()..color = kInspectorBorder.withValues(alpha: 0.3));
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy),
          Paint()..color = kInspectorBorder.withValues(alpha: 0.3));
    }

    Offset toScreen(double x, double y) {
      return Offset(x * size.width, (1 - y) * size.height);
    }

    // Tangent guide lines.
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    canvas.drawLine(toScreen(0, 0), toScreen(curve.x1, curve.y1), guidePaint);
    canvas.drawLine(toScreen(1, 1), toScreen(curve.x2, curve.y2), guidePaint);

    // Curve path — sample 64 points using the Flutter Cubic.
    final cubic = Cubic(curve.x1, curve.y1, curve.x2, curve.y2);
    final path = Path()..moveTo(0, size.height);
    const samples = 64;
    for (var i = 1; i <= samples; i++) {
      final tx = i / samples;
      final ty = cubic.transform(tx);
      path.lineTo(tx * size.width, (1 - ty) * size.height);
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
