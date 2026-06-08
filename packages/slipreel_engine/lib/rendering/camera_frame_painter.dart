import 'dart:ui' as ui;
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/camera_settings.dart';

/// Paints the camera bubble onto [canvas] at [pixelBox], pixel-for-pixel with
/// the editor preview (`CameraBubble` + `AnimatedCameraBubble`): opacity ->
/// shadow -> shape-clipped, cover-cropped, optionally mirrored image -> border,
/// with the show/hide reveal applied (fade + blur + slide). Canvas-space only;
/// the caller positions it (unzoomed) on the final composited frame.
class CameraFramePainter {
  /// [opacity] is the project's static opacity; [reveal] (0..1, default 1) is
  /// the vanish/appear progress — at reveal < 1 the bubble fades, blurs, and
  /// slides down exactly like `AnimatedCameraBubble` in the preview.
  static void paint(
    ui.Canvas canvas, {
    required ui.Image image,
    required Rect pixelBox,
    required CameraSettings settings,
    required double originalAspect,
    required double opacity,
    double reveal = 1.0,
  }) {
    final r = reveal.clamp(0.0, 1.0);
    final hidden = 1.0 - r;
    final effOpacity = (opacity * r).clamp(0.0, 1.0);
    if (effOpacity <= 0) return;
    // Vanish/appear: the bubble slides down and blurs out as it hides
    // (reveal == 1 → no slide/blur, identical to the steady-state render).
    final slideY = hidden * 20.0;
    final blurSigma = hidden * 12.0;
    final isRound = settings.shape.isRound;
    final radius = isRound
        ? pixelBox.shortestSide / 2
        : settings.roundness.clamp(0.0, 1.0) * (pixelBox.shortestSide / 2);
    final rrect = RRect.fromRectAndRadius(pixelBox, Radius.circular(radius));

    final layerPaint = Paint()..color = Color.fromRGBO(0, 0, 0, effOpacity);
    if (blurSigma > 0.01) {
      layerPaint.imageFilter =
          ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);
    }
    canvas.saveLayer(
        pixelBox.shift(Offset(0, slideY)).inflate(40 + blurSigma * 3),
        layerPaint);
    canvas.translate(0, slideY);

    if (settings.shadow) {
      final sigma = _blurRadiusToSigma(18.0);
      final shadowPaint = Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma);
      final shifted = rrect.shift(const Offset(0, 6));
      if (isRound) {
        canvas.drawOval(shifted.outerRect, shadowPaint);
      } else {
        canvas.drawRRect(shifted, shadowPaint);
      }
    }

    canvas.save();
    if (isRound) {
      canvas.clipPath(Path()..addOval(pixelBox));
    } else {
      canvas.clipRRect(rrect);
    }
    final src = _coverSrcRect(image, pixelBox);
    if (settings.mirror) {
      canvas.save();
      canvas.translate(pixelBox.center.dx, 0);
      canvas.scale(-1, 1);
      canvas.translate(-pixelBox.center.dx, 0);
    }
    canvas.drawImageRect(
        image, src, pixelBox, Paint()..filterQuality = FilterQuality.medium);
    if (settings.mirror) canvas.restore();
    canvas.restore(); // clip

    if (settings.borderWidth > 0) {
      // Flutter's default border is inside the edge: deflate by half stroke.
      final inset = settings.borderWidth / 2;
      final bp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = settings.borderWidth
        ..color = Color(settings.borderColor);
      if (isRound) {
        canvas.drawOval(pixelBox.deflate(inset), bp);
      } else {
        canvas.drawRRect(rrect.deflate(inset), bp);
      }
    }

    canvas.restore(); // opacity layer
  }

  // BoxFit.cover source crop: largest centered sub-rect of [image] matching the
  // destination box's aspect.
  static Rect _coverSrcRect(ui.Image image, Rect dst) {
    final iw = image.width.toDouble(), ih = image.height.toDouble();
    final dstAspect = dst.width / dst.height;
    double sw, sh;
    if (dstAspect > iw / ih) {
      sw = iw;
      sh = iw / dstAspect;
    } else {
      sh = ih;
      sw = ih * dstAspect;
    }
    return Rect.fromCenter(center: Offset(iw / 2, ih / 2), width: sw, height: sh);
  }

  static double _blurRadiusToSigma(double radius) => radius * 0.57735 + 0.5;
}
