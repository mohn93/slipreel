import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

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
        child: CustomPaint(
          painter: TimeRulerPainter(
            duration: duration,
            pixelsPerSecond: pixelsPerSecond,
          ),
        ),
      ),
    );
  }
}

class TimeRulerPainter extends CustomPainter {
  TimeRulerPainter({
    required this.duration,
    required this.pixelsPerSecond,
  });

  final Duration duration;
  final double pixelsPerSecond;

  /// Target spacing between MAJOR (labeled) ticks in pixels. The
  /// step is chosen so adjacent labels sit at roughly this distance.
  /// As pps grows (timeline zoom-in), the in-seconds step shrinks
  /// → more labels appear smoothly without snapping.
  static const double _targetMajorPx = 90;

  /// Number of minor (unlabeled) dots between two major dots. 5 keeps
  /// the visual rhythm clean for the 1-2-5 nice-numbers family: a 1s
  /// major step gives 200 ms minors, a 5s major gives 1s minors, etc.
  static const int _minorDivisions = 5;

  /// Below this px gap, minor dots are skipped — they'd clump into a
  /// fuzzy line instead of reading as distinct dots.
  static const double _minMinorSpacingPx = 9;

  static const double _majorDotRadius = 2.0;
  static const double _minorDotRadius = 0.9;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration.inMicroseconds <= 0 || pixelsPerSecond <= 0) return;
    final totalSec = duration.inMicroseconds / 1e6;

    // Labels are always whole seconds — never fractional — so the
    // major step is floored at 1 s. Beyond that, the 1-2-5 family
    // still picks 2 / 5 / 10 / 20 / 50 / … as you zoom out. Minor
    // dots are free to go sub-second below the major cap so a denser
    // grid still appears at high zoom.
    final majorStep =
        math.max(1.0, _niceStep(_targetMajorPx / pixelsPerSecond));
    final minorStep = majorStep / _minorDivisions;
    final minorPx = minorStep * pixelsPerSecond;
    final showMinor = minorPx >= _minMinorSpacingPx;

    // Dot row sits at the very bottom of the (now compact) ruler so
    // the labels + dots group reads as a single unit hugging the lane
    // below, not floating in the middle of an empty strip.
    final dotCy = size.height - 2.5;

    final majorPaint = Paint()
      ..color = tickColor
      ..style = PaintingStyle.fill;
    final minorPaint = Paint()
      ..color = tickColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    const labelStyle = TextStyle(
      color: labelColor,
      fontSize: 11,
      height: 1.0,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    // ── Minor dots ──
    // Painted first so any pixel overlap with a major dot is hidden
    // beneath the larger major dot drawn after.
    if (showMinor) {
      double s = 0;
      // Snap the first sample to a minorStep grid anchored at 0 to
      // avoid float creep adding/dropping a tail dot during zoom.
      while (s <= totalSec + 1e-6) {
        final x = s * pixelsPerSecond;
        if (x > size.width + 1) break;
        canvas.drawCircle(Offset(x, dotCy), _minorDotRadius, minorPaint);
        s += minorStep;
      }
    }

    // ── Major dots + labels ──
    double s = 0;
    while (s <= totalSec + 1e-6) {
      final x = s * pixelsPerSecond;
      if (x > size.width + 1) break;

      canvas.drawCircle(Offset(x, dotCy), _majorDotRadius, majorPaint);

      final tp = TextPainter(
        text: TextSpan(text: _formatLabel(s), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final tx = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
      // Label sits flush at the top of the compact bar; dot rides
      // just below it. Together they form a tight pair.
      tp.paint(canvas, Offset(tx, 0));

      s += majorStep;
    }
  }

  /// Pick a "nice" step from the 1-2-5 family scaled by powers of 10.
  /// Same algorithm chart/plot libraries use for axis ticks — produces
  /// smoothly-densifying labels as the input shrinks, with no jarring
  /// 1→0.5 (×0.5) jumps in the visible step sequence.
  static double _niceStep(double rough) {
    if (rough <= 0) return 1;
    final exp = (math.log(rough) / math.ln10).floor();
    final magnitude = math.pow(10.0, exp).toDouble();
    final normalized = rough / magnitude;
    if (normalized <= 1) return magnitude;
    if (normalized <= 2) return 2 * magnitude;
    if (normalized <= 5) return 5 * magnitude;
    return 10 * magnitude;
  }

  /// Always "M:SS" — integer seconds, never fractional. Major step is
  /// floored at 1 s upstream so the rounded value can't collide with
  /// its neighbour.
  static String _formatLabel(double secs) {
    final s = secs.round();
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(TimeRulerPainter old) =>
      old.duration != duration ||
      old.pixelsPerSecond != pixelsPerSecond;
}
