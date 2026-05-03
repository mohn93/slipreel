import 'package:flutter/material.dart';

import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';

/// Dev HUD painter overlaid on the playback canvas. Renders the recorded
/// cursor trail, the raw cursor at the current playhead, and the
/// smoothed zoom focal point so we can visually confirm the focal is
/// tracking the cursor as expected. Toggled by the dev "show zoom debug"
/// flag in playback_screen.
class ZoomFocalDebugPainter extends CustomPainter {
  ZoomFocalDebugPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    required this.smoothedFocal,
  });

  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final Offset? smoothedFocal;

  @override
  void paint(Canvas canvas, Size size) {
    final raw = cursorAt(cursorRecording, position);
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;

    // Trail: render every recorded cursor sample as a small dot, colored
    // by time (early=blue → late=red). Lets you see whether the saved
    // cursor path roughly matches the path you actually moved during
    // recording. If the trail looks completely different, the native
    // transform is producing wrong coordinates.
    final all = cursorRecording.positions;
    if (all.length > 1) {
      final n = all.length;
      final dotPaint = Paint();
      for (var i = 0; i < n; i++) {
        final p = all[i];
        final t = i / (n - 1);
        // HSL: 220° (blue) → 0° (red). Saturation 0.9, lightness 0.5.
        final hue = 220.0 * (1 - t);
        dotPaint.color = HSLColor.fromAHSL(0.6, hue, 0.9, 0.55).toColor();
        canvas.drawCircle(
            Offset(p.x * scaleX, p.y * scaleY), 2, dotPaint);
      }
    }

    if (raw != null) {
      final p = Offset(raw.x * scaleX, raw.y * scaleY);
      // Raw cursor: small filled cyan dot with black outline.
      canvas.drawCircle(p, 6,
          Paint()..color = const Color(0xCC00E5FF));
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.black87,
      );
    }

    if (smoothedFocal != null) {
      final f = Offset(smoothedFocal!.dx * scaleX, smoothedFocal!.dy * scaleY);
      // Smoothed focal: hollow yellow ring + crosshair.
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFC107);
      canvas.drawCircle(f, 14, ringPaint);
      canvas.drawLine(Offset(f.dx - 18, f.dy), Offset(f.dx + 18, f.dy), ringPaint);
      canvas.drawLine(Offset(f.dx, f.dy - 18), Offset(f.dx, f.dy + 18), ringPaint);
    }

    // Text readout — top-left of the video.
    final readout = StringBuffer();
    readout.writeln('samples: ${cursorRecording.count}');
    if (raw == null) {
      readout.writeln('cursor: <none at this time>');
    } else {
      readout.writeln('cursor: ${raw.x.toStringAsFixed(0)}, ${raw.y.toStringAsFixed(0)} px');
    }
    if (smoothedFocal != null) {
      readout.writeln(
          'focal:  ${smoothedFocal!.dx.toStringAsFixed(0)}, ${smoothedFocal!.dy.toStringAsFixed(0)} px');
    } else {
      readout.writeln('focal:  <no active zoom>');
    }
    if (cursorRecording.positions.isNotEmpty) {
      final xs = cursorRecording.positions.map((p) => p.x);
      final ys = cursorRecording.positions.map((p) => p.y);
      readout.writeln(
          'x rng:  ${xs.reduce((a, b) => a < b ? a : b).toStringAsFixed(0)} … ${xs.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)}');
      readout.writeln(
          'y rng:  ${ys.reduce((a, b) => a < b ? a : b).toStringAsFixed(0)} … ${ys.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)}');
    }
    readout.write('video:  ${videoSize.width.toStringAsFixed(0)} × ${videoSize.height.toStringAsFixed(0)}');
    final tp = TextPainter(
      text: TextSpan(
        text: readout.toString(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
          shadows: [
            Shadow(color: Colors.black, blurRadius: 4),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = 6.0;
    final bg = Rect.fromLTWH(8, 8, tp.width + pad * 2, tp.height + pad * 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      Paint()..color = const Color(0xAA000000),
    );
    tp.paint(canvas, Offset(bg.left + pad, bg.top + pad));
  }

  @override
  bool shouldRepaint(ZoomFocalDebugPainter old) =>
      old.position != position ||
      old.cursorRecording != cursorRecording ||
      old.videoSize != videoSize ||
      old.smoothedFocal != smoothedFocal;
}
