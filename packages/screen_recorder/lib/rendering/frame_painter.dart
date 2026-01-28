import 'package:flutter/material.dart';
import 'package:screen_recorder/models/window_frame.dart';

/// A custom painter that renders window frames around video content.
///
/// This painter draws shadows, backgrounds, and borders with rounded corners
/// to create professional-looking frames. It's designed to be hardware-accelerated
/// and efficient, repainting only when the frame or video size changes.
class FramePainter extends CustomPainter {
  /// The frame style to render
  final WindowFrame frame;

  /// The size of the video content (without frame)
  final Size videoSize;

  const FramePainter({
    required this.frame,
    required this.videoSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Skip rendering if frame is 'None'
    if (frame.name == 'None') {
      return;
    }

    // Calculate the rect for the video content within the frame
    final contentRect = Rect.fromLTWH(
      frame.padding.left,
      frame.padding.top,
      videoSize.width,
      videoSize.height,
    );

    // Create rounded rectangle for the frame
    final rrect = RRect.fromRectAndRadius(
      contentRect,
      Radius.circular(frame.cornerRadius),
    );

    // 1. Draw shadow (if shadowBlur > 0)
    if (frame.shadowBlur > 0) {
      final shadowPaint = Paint()
        ..color = frame.shadowColor
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, frame.shadowBlur);

      // Offset the shadow by the specified amount
      final shadowRect = contentRect.shift(frame.shadowOffset);
      final shadowRRect = RRect.fromRectAndRadius(
        shadowRect,
        Radius.circular(frame.cornerRadius),
      );

      canvas.drawRRect(shadowRRect, shadowPaint);
    }

    // 2. Draw background (if backgroundColor is not null and has opacity)
    if (frame.backgroundColor != null && frame.backgroundColor!.a > 0) {
      final backgroundPaint = Paint()
        ..color = frame.backgroundColor!
        ..style = PaintingStyle.fill;

      canvas.drawRRect(rrect, backgroundPaint);
    }

    // 3. Draw border (if borderWidth > 0 and borderColor is not null)
    if (frame.borderWidth > 0 &&
        frame.borderColor != null &&
        frame.borderColor!.a > 0) {
      final borderPaint = Paint()
        ..color = frame.borderColor!
        ..style = PaintingStyle.stroke
        ..strokeWidth = frame.borderWidth;

      canvas.drawRRect(rrect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant FramePainter oldDelegate) {
    // Repaint if frame or video size changes
    return oldDelegate.frame != frame || oldDelegate.videoSize != videoSize;
  }

  /// Calculates the total size needed for the frame including padding.
  ///
  /// Returns the size of the canvas needed to render the video content
  /// with the frame padding applied. If the frame is 'None', returns
  /// the video size unchanged.
  static Size calculateTotalSize({
    required WindowFrame frame,
    required Size videoSize,
  }) {
    if (frame.name == 'None') {
      return videoSize;
    }

    return Size(
      videoSize.width + frame.padding.left + frame.padding.right,
      videoSize.height + frame.padding.top + frame.padding.bottom,
    );
  }
}
