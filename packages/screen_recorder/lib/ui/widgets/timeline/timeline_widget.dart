import 'package:flutter/material.dart';
import 'timeline_painter.dart';

/// Timeline widget for video playback control
class TimelineWidget extends StatelessWidget {
  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onPositionChanged;
  final double height;

  const TimelineWidget({
    super.key,
    required this.duration,
    required this.position,
    required this.onPositionChanged,
    this.height = 80,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapDown: (details) {
            _handleTap(details.localPosition, constraints.maxWidth);
          },
          onHorizontalDragUpdate: (details) {
            _handleTap(details.localPosition, constraints.maxWidth);
          },
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF2B2B3D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: CustomPaint(
              painter: TimelinePainter(
                duration: duration,
                position: position,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  void _handleTap(Offset localPosition, double width) {
    final progress = (localPosition.dx / width).clamp(0.0, 1.0);
    final newPosition = Duration(
      microseconds: (duration.inMicroseconds * progress).round(),
    );
    onPositionChanged(newPosition);
  }
}
