import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';

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

    final resolved = OutputCanvasResolver.resolve(
      videoSize: videoSize,
      padding: frame.padding,
      aspect: OutputAspect.auto,
    );
    final contentRect = resolved.videoRect;

    // Create rounded rectangle for the frame
    final rrect = RRect.fromRectAndRadius(
      contentRect,
      Radius.circular(frame.cornerRadius),
    );

    // Inset ring sits between the wallpaper and the video. Cap the
    // requested width at whatever fits inside the smallest padding
    // side — without padding there's nowhere to draw it.
    final insetWidth = _resolveInset(frame.padding);
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

  /// Total canvas size (wallpaper + padding + video), shaped by the
  /// chosen [aspect]. Defaults to [OutputAspect.auto] (canvas matches
  /// the padded inner region's aspect — equal to the video aspect when
  /// padding is zero).
  ///
  /// Padding is uniform now — no aspect-scaling trick. The previous
  /// behavior horizontally aspect-scaled `frame.padding` so the canvas
  /// retained the video aspect; with aspect now an explicit input,
  /// uniform padding is the cleaner model.
  static Size calculateTotalSize({
    required WindowFrame frame,
    required Size videoSize,
    OutputAspect aspect = OutputAspect.auto,
  }) {
    if (frame.name == 'None') {
      return videoSize;
    }
    return OutputCanvasResolver.resolve(
      videoSize: videoSize,
      padding: frame.padding,
      aspect: aspect,
    ).canvasSize;
  }
}
