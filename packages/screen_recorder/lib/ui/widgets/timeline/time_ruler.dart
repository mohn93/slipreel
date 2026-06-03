import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

String _formatSecondsLabel(double secs) {
  final s = secs.round();
  final m = s ~/ 60;
  final sec = s % 60;
  return '$m:${sec.toString().padLeft(2, '0')}';
}

class TimeRuler extends StatelessWidget {
  const TimeRuler({
    super.key,
    required this.duration,
    required this.pixelsPerSecond,
    required this.contentWidth,
    required this.onSeek,
  });

  final Duration duration;
  final double pixelsPerSecond;
  final double contentWidth;
  final ValueChanged<Duration> onSeek;

  void _seek(Offset local) {
    // Clamp the gesture x to [0, contentWidth] so out-of-range drag
    // events (post-scroll-wrap, possible during fast drags) don't
    // produce negative or beyond-duration seek targets.
    final x = local.dx.clamp(0.0, contentWidth);
    onSeek(xToTime(x, pixelsPerSecond));
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _seek(d.localPosition),
        onHorizontalDragStart: (d) => _seek(d.localPosition),
        onHorizontalDragUpdate: (d) => _seek(d.localPosition),
        child: CustomPaint(painter: TimeRulerPainter(duration: duration)),
      ),
    );
  }
}

class TimeRulerPainter extends CustomPainter {
  TimeRulerPainter({required this.duration});

  final Duration duration;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration.inMicroseconds <= 0) return;
    final totalSec = duration.inMicroseconds / 1e6;
    final step = _chooseStep(totalSec, size.width);
    final tickPaint = Paint()..color = tickColor;
    final labelStyle = const TextStyle(
      color: labelColor,
      fontSize: 11,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    double s = 0;
    while (s <= totalSec + 0.0001) {
      final x = (s / totalSec) * size.width;

      // Tick mark just below labels.
      canvas.drawLine(
        Offset(x, size.height - 4),
        Offset(x, size.height),
        tickPaint,
      );

      // Label centered horizontally on the tick.
      final tp = TextPainter(
        text: TextSpan(text: _formatSecondsLabel(s), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final tx = (x - tp.width / 2)
          .clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(tx, 1));

      s += step;
    }
  }

  static double _chooseStep(double seconds, double width) {
    if (seconds <= 0 || width <= 0) return 1;
    const targetLabels = 7;
    final rough = seconds / targetLabels;
    const candidates = [
      0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0
    ];
    for (final c in candidates) {
      if (rough <= c) return c;
    }
    return 600.0;
  }

  @override
  bool shouldRepaint(TimeRulerPainter old) => old.duration != duration;
}
