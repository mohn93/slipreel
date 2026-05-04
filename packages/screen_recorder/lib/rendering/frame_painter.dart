import 'package:flutter/material.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/rendering/wallpaper.dart';

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

    // Inset ring sits between the wallpaper and the video. Cap the
    // requested width at whatever fits inside the smallest padding
    // side — without padding there's nowhere to draw it.
    final insetWidth = _resolveInset(p);
    final insetRRect = insetWidth > 0
        ? RRect.fromRectAndRadius(
            contentRect.inflate(insetWidth),
            // Keep the curve concentric with the video's corners by
            // matching the inflate amount, so the ring's outer edge
            // doesn't kink at the corners.
            Radius.circular(frame.cornerRadius + insetWidth),
          )
        : null;
    final shadowSourceRRect = insetRRect ?? rrect;

    // 1. Draw shadow (if shadowBlur > 0). Cast off the OUTER edge so
    // the shadow conforms to the inset ring when present, the video
    // when not.
    if (frame.shadowBlur > 0) {
      final shadowPaint = Paint()
        ..color = frame.shadowColor
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, frame.shadowBlur);

      final shadowRRect = shadowSourceRRect.shift(frame.shadowOffset);
      canvas.drawRRect(shadowRRect, shadowPaint);
    }

    // 2. Draw the inset ring. Drawn as a solid filled rounded rect
    // larger than the video; the video is painted on top by the
    // compositor, so only the ring portion is visible.
    if (insetRRect != null) {
      final insetColor = _resolveInsetColor();
      if (insetColor != null) {
        canvas.drawRRect(insetRRect, Paint()..color = insetColor);
      }
    }

    // 3. Draw background (if backgroundColor is not null and has opacity)
    if (frame.backgroundColor != null && frame.backgroundColor!.a > 0) {
      final backgroundPaint = Paint()
        ..color = frame.backgroundColor!
        ..style = PaintingStyle.fill;

      canvas.drawRRect(rrect, backgroundPaint);
    }

    // 4. Draw border (if borderWidth > 0 and borderColor is not null)
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

  double _resolveInset(EdgeInsets effective) {
    if (frame.inset <= 0) return 0;
    final maxInset = [
      effective.left,
      effective.right,
      effective.top,
      effective.bottom,
    ].reduce((a, b) => a < b ? a : b);
    if (maxInset <= 0) return 0;
    return frame.inset > maxInset ? maxInset : frame.inset;
  }

  /// Color of the inset ring: a lightened, slightly desaturated
  /// version of the wallpaper's primary color so the rim "reflects"
  /// the background but reads as a highlight, not a competing tint.
  /// Returns null when there's no wallpaper to derive from.
  Color? _resolveInsetColor() {
    final cat = frame.wallpaperCategory;
    if (cat == null) return null;
    final base = wallpaperRepresentativeColor(cat, frame.wallpaperIndex);
    final hsl = HSLColor.fromColor(base);
    return hsl
        .withLightness((hsl.lightness + 0.25).clamp(0.0, 0.92))
        .withSaturation((hsl.saturation * 0.7).clamp(0.0, 1.0))
        .toColor();
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
