// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'package:flutter/material.dart';
import '../../effects/motion_blur_samples.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_click_effect.dart';
import '../../rendering/cursor_geometry.dart';
import '../../rendering/cursor_glyph.dart';

/// Paints the recorded cursor on top of the video at the player's current
/// position. Takes a pre-computed [screenPos] (in screen-space pixels)
/// so the parent can apply motion smoothing via a CursorMotionController
/// — the painter itself stays stateless. Click events are still looked
/// up against [cursorRecording] for the press-pulse + ripple.
///
/// The glyph + click effects are drawn via [paintCursorWithEffects] so
/// the preview and the exported video stay visually consistent. When
/// [motionBlurIntensity] is > 0 and [velocityPxPerSec] is non-trivial,
/// the sprite is stamped multiple times along `−v̂` to produce a
/// directional motion-blur trail.
class CursorOverlayPainter extends CustomPainter {
  final CursorRecording cursorRecording;
  final Duration position;
  final Offset screenPos;
  final Size videoSize;
  final Size screenSize;
  final double sizeMultiplier;
  final CursorStyle style;
  final CursorClickEffect clickEffect;
  final Offset velocityPxPerSec;
  final double motionBlurIntensity;

  CursorOverlayPainter({
    required this.cursorRecording,
    required this.position,
    required this.screenPos,
    required this.videoSize,
    required this.screenSize,
    this.sizeMultiplier = 1.0,
    this.style = CursorStyle.modernDark,
    this.clickEffect = CursorClickEffect.ripple,
    this.velocityPxPerSec = Offset.zero,
    this.motionBlurIntensity = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final inVideo = screenToVideoSpace(
      screenPos: screenPos,
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

    final samples = computeMotionBlurSamples(
      velocityPxPerSec: velocityPxPerSec,
      sliderIntensity: motionBlurIntensity,
      referenceSpeedPxPerSec: 1000,
      maxReachPx: 16,
    );

    if (samples.count == 1) {
      paintCursorWithEffects(
        canvas,
        position: widgetPos,
        baseDiameter: pxDiameter,
        style: style,
        microsSinceClick: dt,
        effect: clickEffect,
      );
      return;
    }

    // Pad bounds by max stamp reach so stamps near canvas edges
    // aren't clipped by the layer rect.
    final reach = samples.stepPx.distance * (samples.count - 1);
    final stampBounds = Rect.fromCircle(
      center: widgetPos,
      radius: pxDiameter * 1.5 + reach,
    );

    // Index 0 = oldest tail (lowest alpha, largest negative offset).
    // Index count-1 = head (highest alpha, offset 0).
    for (var i = 0; i < samples.count; i++) {
      final tailIndex = samples.count - 1 - i;
      final dx = samples.stepPx.dx * tailIndex;
      final dy = samples.stepPx.dy * tailIndex;
      canvas.saveLayer(
        stampBounds,
        Paint()..color = Colors.white.withValues(alpha: samples.alphas[i]),
      );
      canvas.translate(dx, dy);
      // widgetPos is absolute; combined with the translate above it lands
      // the stamp at widgetPos + (dx, dy). Each saveLayer/restore pair
      // also pushes/pops the transform stack, so adjacent stamps' translates
      // don't compound.
      paintCursorWithEffects(
        canvas,
        position: widgetPos,
        baseDiameter: pxDiameter,
        style: style,
        microsSinceClick: dt,
        effect: clickEffect,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CursorOverlayPainter old) {
    return old.position != position ||
        old.screenPos != screenPos ||
        old.cursorRecording != cursorRecording ||
        old.videoSize != videoSize ||
        old.screenSize != screenSize ||
        old.sizeMultiplier != sizeMultiplier ||
        old.style != style ||
        old.clickEffect != clickEffect ||
        old.velocityPxPerSec != velocityPxPerSec ||
        old.motionBlurIntensity != motionBlurIntensity;
  }
}
