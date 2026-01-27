import 'package:flutter/material.dart';

/// Custom painter for timeline visualization
class TimelinePainter extends CustomPainter {
  final Duration duration;
  final Duration position;

  TimelinePainter({
    required this.duration,
    required this.position,
  });

  double get progress {
    if (duration.inMicroseconds == 0) return 0.0;
    return position.inMicroseconds / duration.inMicroseconds;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final progressValue = progress.clamp(0.0, 1.0);

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
  }

  @override
  bool shouldRepaint(TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.position != position;
  }
}
