import 'package:flutter/material.dart';
import 'package:screen_recorder/models/trim_selection.dart';

/// Custom painter for timeline visualization
class TimelinePainter extends CustomPainter {
  final Duration duration;
  final Duration position;
  final TrimSelection? trimSelection;

  TimelinePainter({
    required this.duration,
    required this.position,
    this.trimSelection,
  });

  double get progress {
    if (duration.inMicroseconds == 0) return 0.0;
    return position.inMicroseconds / duration.inMicroseconds;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final progressValue = progress.clamp(0.0, 1.0);

    // Draw trim selection background if present
    if (trimSelection != null && duration.inMicroseconds > 0) {
      final startX = (trimSelection!.start.inMicroseconds / duration.inMicroseconds) * size.width;
      final endX = (trimSelection!.end.inMicroseconds / duration.inMicroseconds) * size.width;

      final trimPaint = Paint()
        ..color = const Color(0xFF6C63FF).withOpacity(0.2)
        ..style = PaintingStyle.fill;

      canvas.drawRect(
        Rect.fromLTWH(startX, 0, endX - startX, size.height),
        trimPaint,
      );
    }

    // Draw background track
    final backgroundPaint = Paint()
      ..color = const Color(0xFF1E1E2E)
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 2, size.width, 4),
        const Radius.circular(2),
      ),
      backgroundPaint,
    );

    // Draw progress track
    final progressPaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 2, size.width * progressValue, 4),
        const Radius.circular(2),
      ),
      progressPaint,
    );

    // Draw playhead
    final playheadX = size.width * progressValue;
    final playheadPaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      Offset(playheadX, size.height / 2),
      8,
      playheadPaint,
    );

    // Draw playhead line
    final linePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      linePaint,
    );

    // Draw trim handles if present
    if (trimSelection != null && duration.inMicroseconds > 0) {
      final startX = (trimSelection!.start.inMicroseconds / duration.inMicroseconds) * size.width;
      final endX = (trimSelection!.end.inMicroseconds / duration.inMicroseconds) * size.width;

      _drawTrimHandle(canvas, size, startX);
      _drawTrimHandle(canvas, size, endX);
    }
  }

  void _drawTrimHandle(Canvas canvas, Size size, double x) {
    final handlePaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.fill;

    final handleRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(x - 4, 0, 8, size.height),
      const Radius.circular(4),
    );

    canvas.drawRRect(handleRect, handlePaint);

    // Draw grip lines
    final gripPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1;

    canvas.drawLine(
      Offset(x - 1, size.height * 0.3),
      Offset(x - 1, size.height * 0.7),
      gripPaint,
    );

    canvas.drawLine(
      Offset(x + 1, size.height * 0.3),
      Offset(x + 1, size.height * 0.7),
      gripPaint,
    );
  }

  @override
  bool shouldRepaint(TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.position != position ||
        oldDelegate.trimSelection != trimSelection;
  }
}
