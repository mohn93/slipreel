// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'package:flutter/material.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_click_effect.dart';
import '../../rendering/cursor_geometry.dart';
import '../../rendering/cursor_glyph.dart';

/// Paints the recorded cursor on top of the video at the player's current
/// position. Reads positions from [CursorRecording] using the shared
/// [cursorAt] geometry helper, so its math matches the export-time
/// renderer; the actual glyph + click effects are drawn via
/// [paintCursorWithEffects] so the preview and the exported video stay
/// visually consistent.
class CursorOverlayPainter extends CustomPainter {
  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final Size screenSize;
  final double sizeMultiplier;
  final CursorStyle style;
  final CursorClickEffect clickEffect;

  CursorOverlayPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    required this.screenSize,
    this.sizeMultiplier = 1.0,
    this.style = CursorStyle.modernDark,
    this.clickEffect = CursorClickEffect.ripple,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pos = cursorAt(cursorRecording, position);
    if (pos == null) return;

    final inVideo = screenToVideoSpace(
      screenPos: Offset(pos.x, pos.y),
      screenSize: screenSize,
      videoSize: videoSize,
    );
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;
    final widgetPos = Offset(inVideo.dx * scaleX, inVideo.dy * scaleY);

    // Diameter scales with the widget→video ratio so the cursor stays
    // visually proportional even when the preview is rendered at a
    // size other than the native video size.
    final pxDiameter =
        kCursorBaseDiameter * sizeMultiplier * (scaleX + scaleY) / 2;

    final dt =
        microsSinceClick(cursorRecording, position.inMicroseconds);

    paintCursorWithEffects(
      canvas,
      position: widgetPos,
      baseDiameter: pxDiameter,
      style: style,
      microsSinceClick: dt,
      effect: clickEffect,
    );
  }

  @override
  bool shouldRepaint(covariant CursorOverlayPainter old) {
    return old.position != position ||
        old.cursorRecording != cursorRecording ||
        old.videoSize != videoSize ||
        old.screenSize != screenSize ||
        old.sizeMultiplier != sizeMultiplier ||
        old.style != style ||
        old.clickEffect != clickEffect;
  }
}
