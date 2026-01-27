import 'package:flutter/material.dart';
import 'package:screen_recorder/models/trim_selection.dart';
import 'timeline_painter.dart';

enum _DragTarget { none, playhead, startHandle, endHandle }

/// Timeline widget for video playback control
class TimelineWidget extends StatefulWidget {
  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onPositionChanged;
  final TrimSelection? trimSelection;
  final ValueChanged<TrimSelection>? onTrimChanged;
  final double height;

  const TimelineWidget({
    super.key,
    required this.duration,
    required this.position,
    required this.onPositionChanged,
    this.trimSelection,
    this.onTrimChanged,
    this.height = 80,
  });

  @override
  State<TimelineWidget> createState() => _TimelineWidgetState();
}

class _TimelineWidgetState extends State<TimelineWidget> {
  _DragTarget _dragTarget = _DragTarget.none;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapDown: (details) {
            _handleDragStart(details.localPosition, constraints.maxWidth);
            _handleDrag(details.localPosition, constraints.maxWidth);
          },
          onHorizontalDragStart: (details) {
            _handleDragStart(details.localPosition, constraints.maxWidth);
          },
          onHorizontalDragUpdate: (details) {
            _handleDrag(details.localPosition, constraints.maxWidth);
          },
          onHorizontalDragEnd: (_) {
            setState(() {
              _dragTarget = _DragTarget.none;
            });
          },
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: const Color(0xFF2B2B3D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: CustomPaint(
              painter: TimelinePainter(
                duration: widget.duration,
                position: widget.position,
                trimSelection: widget.trimSelection,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  void _handleDragStart(Offset localPosition, double width) {
    const hitRadius = 20.0;

    // Check if tapping near trim handles
    if (widget.trimSelection != null && widget.onTrimChanged != null) {
      final startX = (widget.trimSelection!.start.inMicroseconds /
                     widget.duration.inMicroseconds) * width;
      final endX = (widget.trimSelection!.end.inMicroseconds /
                   widget.duration.inMicroseconds) * width;

      if ((localPosition.dx - startX).abs() < hitRadius) {
        setState(() {
          _dragTarget = _DragTarget.startHandle;
        });
        return;
      }

      if ((localPosition.dx - endX).abs() < hitRadius) {
        setState(() {
          _dragTarget = _DragTarget.endHandle;
        });
        return;
      }
    }

    // Default to playhead dragging
    setState(() {
      _dragTarget = _DragTarget.playhead;
    });
  }

  void _handleDrag(Offset localPosition, double width) {
    final progress = (localPosition.dx / width).clamp(0.0, 1.0);
    final newPosition = Duration(
      microseconds: (widget.duration.inMicroseconds * progress).round(),
    );

    switch (_dragTarget) {
      case _DragTarget.playhead:
        widget.onPositionChanged(newPosition);
        break;
      case _DragTarget.startHandle:
        if (widget.trimSelection != null && widget.onTrimChanged != null) {
          final newTrim = TrimSelection(
            start: newPosition,
            end: widget.trimSelection!.end,
            videoDuration: widget.duration,
          );
          widget.onTrimChanged!(newTrim);
        }
        break;
      case _DragTarget.endHandle:
        if (widget.trimSelection != null && widget.onTrimChanged != null) {
          final newTrim = TrimSelection(
            start: widget.trimSelection!.start,
            end: newPosition,
            videoDuration: widget.duration,
          );
          widget.onTrimChanged!(newTrim);
        }
        break;
      case _DragTarget.none:
        break;
    }
  }
}
