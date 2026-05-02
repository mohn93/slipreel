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

    final p = effectivePadding(frame.padding, videoSize);

    // Calculate the rect for the video content within the frame
    final contentRect = Rect.fromLTWH(
      p.left,
      p.top,
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
  /// Padding is aspect-scaled (X scaled by video aspect ratio) so the
  /// canvas keeps the video's aspect — without this, sliding the
  /// padding control would change the framedVideo's aspect, the outer
  /// FittedBox would re-fit it to the available area, and the user
  /// sees the entire composition (wallpaper + video) visibly resize.
  /// If the frame is 'None', returns the video size unchanged.
  static Size calculateTotalSize({
    required WindowFrame frame,
    required Size videoSize,
  }) {
    if (frame.name == 'None') {
      return videoSize;
    }
    final p = effectivePadding(frame.padding, videoSize);
    return Size(
      videoSize.width + p.left + p.right,
      videoSize.height + p.top + p.bottom,
    );
  }

  /// Aspect-scaled padding used by [calculateTotalSize] and [paint].
  /// Stored padding is treated as the vertical (top/bottom) value;
  /// horizontal padding is scaled by the video's aspect ratio so the
  /// resulting canvas matches the video's aspect.
  static EdgeInsets effectivePadding(
    EdgeInsets base,
    Size videoSize,
  ) {
    if (videoSize.height <= 0) return base;
    final aspect = videoSize.width / videoSize.height;
    return EdgeInsets.only(
      left: base.left * aspect,
      right: base.right * aspect,
      top: base.top,
      bottom: base.bottom,
    );
  }
}
