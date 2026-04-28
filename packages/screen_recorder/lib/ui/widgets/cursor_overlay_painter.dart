// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'package:flutter/material.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_geometry.dart';

/// Paints the recorded cursor on top of the video at the player's current
/// position. Reads positions from [CursorRecording] using the shared
/// [cursorAt] geometry helper, so its math matches the export-time renderer.
class CursorOverlayPainter extends CustomPainter {
  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final Size screenSize;

  CursorOverlayPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pos = cursorAt(cursorRecording, position);
    if (pos == null) return;

    // Map screen-space cursor coords to widget-space (size).
    final inVideo = screenToVideoSpace(
      screenPos: Offset(pos.x, pos.y),
      screenSize: screenSize,
      videoSize: videoSize,
    );
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;
    final widgetPos = Offset(inVideo.dx * scaleX, inVideo.dy * scaleY);

    final paint = Paint()
      ..color = pos.isClicked ? Colors.yellowAccent : Colors.white
      ..style = PaintingStyle.fill;

    // Simple cursor: 8px filled circle. Final visuals can be a sprite later;
    // the geometry math is what matters for spec correctness.
    canvas.drawCircle(widgetPos, 8, paint);
    canvas.drawCircle(
      widgetPos,
      8,
      Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CursorOverlayPainter old) {
    return old.position != position ||
        old.cursorRecording != cursorRecording ||
        old.videoSize != videoSize ||
        old.screenSize != screenSize;
  }
}
