import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Light bright-edge area waveform colour (matches the locked design).
const Color _kWaveColor = Color(0xFFEAF1FF);
const double _kFillAlpha = 0.30; // bottom-edge fill alpha
const double _kStrokeAlpha = 0.45; // top stroke alpha
const double _kMaxHeightFactor = 0.6; // peaks reach 60% of slice height
const double _kStrokeWidth = 1.25;

/// Maps normalized samples (0..1) to canvas points. y grows downward, so a
/// louder sample yields a SMALLER y (drawn higher). Returns empty for <2
/// samples (a spline needs at least two points).
List<Offset> waveformPoints(
  List<double> samples,
  Size size,
  double maxHeightFactor,
) {
  if (samples.length < 2 || size.width <= 0 || size.height <= 0) {
    return const [];
  }
  final maxH = size.height * maxHeightFactor;
  final last = samples.length - 1;
  final pts = <Offset>[];
  for (var i = 0; i < samples.length; i++) {
    final x = i / last * size.width;
    final h = samples[i].clamp(0.0, 1.0) * maxH;
    pts.add(Offset(x, size.height - h));
  }
  return pts;
}

/// Smooth Catmull-Rom spline through [pts] (open curve). Empty path for <2.
Path buildSmoothPath(List<Offset> pts) {
  final path = Path();
  if (pts.length < 2) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = i == 0 ? pts[i] : pts[i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
    final c1 = Offset(
      p1.dx + (p2.dx - p0.dx) / 6.0,
      p1.dy + (p2.dy - p0.dy) / 6.0,
    );
    final c2 = Offset(
      p2.dx - (p3.dx - p1.dx) / 6.0,
      p2.dy - (p3.dy - p1.dy) / 6.0,
    );
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path;
}

/// Draws a subtle bottom-anchored area waveform with a soft gradient fill and
/// a thin bright top stroke. Dimming/fade is handled by the caller's
/// AnimatedOpacity, so this painter always paints at its configured alpha.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({required this.samples});

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = waveformPoints(samples, size, _kMaxHeightFactor);
    if (pts.isEmpty) return;

    final line = buildSmoothPath(pts);
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fill = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, size.height), // bottom: solid-ish
        Offset(0, 0), // top: transparent
        [
          _kWaveColor.withValues(alpha: _kFillAlpha),
          _kWaveColor.withValues(alpha: 0.0),
        ],
        const [0.0, 0.8],
      );
    canvas.drawPath(area, fill);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kStrokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = _kWaveColor.withValues(alpha: _kStrokeAlpha);
    canvas.drawPath(line, stroke);
  }

  @override
  bool shouldRepaint(WaveformPainter old) {
    // SliceBar rebuilds every frame during the selection glow and hands a
    // freshly-allocated sub-range list each time, so identity always differs.
    // Compare by content (cheap for a per-slice array) so we only repaint the
    // spline when the samples actually change.
    if (identical(old.samples, samples)) return false;
    if (old.samples.length != samples.length) return true;
    for (var i = 0; i < samples.length; i++) {
      if (old.samples[i] != samples[i]) return true;
    }
    return false;
  }
}
