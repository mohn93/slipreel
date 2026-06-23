import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/rendering/caption_renderer.dart';

/// Canvas-fixed caption overlay for the editor preview. Delegates to the same
/// [CaptionRenderer] the export uses, so preview matches the rendered video.
class CaptionOverlay extends StatelessWidget {
  const CaptionOverlay({
    super.key,
    required this.position,
    required this.canvasSize,
    required this.segments,
    required this.style,
  });

  final Duration position;
  final Size canvasSize;
  final List<CaptionSegment> segments;
  final CaptionStyle style;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
          size: canvasSize,
          painter: _CaptionPainter(position, canvasSize, segments, style),
        ),
      );
}

class _CaptionPainter extends CustomPainter {
  _CaptionPainter(this.position, this.canvasSize, this.segments, this.style);

  final Duration position;
  final Size canvasSize;
  final List<CaptionSegment> segments;
  final CaptionStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    CaptionRenderer.paint(canvas, size, position, segments, style);
  }

  @override
  bool shouldRepaint(_CaptionPainter old) =>
      old.position != position ||
      old.canvasSize != canvasSize ||
      old.style != style ||
      !identical(old.segments, segments);
}
