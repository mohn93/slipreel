// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'dart:ui' as ui;
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

  static ui.FragmentProgram? _motionBlurProgram;

  /// Pre-loads the motion-blur fragment shader so the cursor painter
  /// can use it on first paint. Call from `main()` before `runApp`.
  /// Idempotent — subsequent calls return the cached program.
  static Future<void> ensureMotionBlurProgramLoaded() async {
    _motionBlurProgram ??= await ui.FragmentProgram.fromAsset(
      'shaders/motion_blur.frag',
    );
  }

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

    // Slider all the way down: cheap direct paint, no shader / pre-bake.
    if (motionBlurIntensity <= 0) {
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

    final samples = computeMotionBlurSamples(
      velocityPxPerSec: velocityPxPerSec,
      sliderIntensity: motionBlurIntensity,
      referenceSpeedPxPerSec: 600,
      maxReachPx: 60,
    );

    // No early-return on samples.count == 1: when intensity > 0 we
    // always route through the shader path so the rendered cursor
    // doesn't visibly toggle between "direct paint" and "shader
    // pass-through" as velocity bobs around the activation threshold.
    // The shader's reach<1 branch produces a pixel-identical result to
    // direct paint, so this is purely a path-consolidation move.

    // Pre-bake the cursor sprite to a ui.Image so the shader (and the
    // multi-stamp fallback) can sample it cheaply. This also lets the
    // shader render a continuous directional smear instead of stacked
    // discrete cursor copies.
    //
    // Sprite buffer is generously sized for the click ripple, which can
    // grow to a few cursor diameters during the press-pulse animation.
    // Trail length in pixels at the current intensity. The output rect
    // for the shader (and the sprite buffer for fallback) must be big
    // enough to contain both the cursor body and the full trail.
    final reach = samples.stepPx.distance * (samples.count - 1);
    final spriteBufferSize =
        (pxDiameter * 4 + reach * 2).ceil().toDouble();
    final spriteBufferCenter =
        Offset(spriteBufferSize / 2, spriteBufferSize / 2);

    final recorder = ui.PictureRecorder();
    final spriteCanvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, spriteBufferSize, spriteBufferSize),
    );
    paintCursorWithEffects(
      spriteCanvas,
      position: spriteBufferCenter,
      baseDiameter: pxDiameter,
      style: style,
      microsSinceClick: dt,
      effect: clickEffect,
    );
    final picture = recorder.endRecording();
    final spriteImage = picture.toImageSync(
      spriteBufferSize.toInt(),
      spriteBufferSize.toInt(),
    );
    picture.dispose();

    try {
      final program = _motionBlurProgram;
      if (program != null) {
        // Shader path: one drawRect with a fragment shader that
        // produces a continuous directional smear.
        final shader = program.fragmentShader();
        final velocity = velocityPxPerSec;
        final speed = velocity.distance;
        // When speed is zero (cursor paused, or below the activation
        // threshold so samples collapsed to count==1) reach is also
        // zero and the shader's reach<1 branch fires before it reads
        // velocityDir. Pass an arbitrary unit vector to avoid NaN
        // showing up in any backend that evaluates the uniform anyway.
        final velocityDir = speed > 0
            ? Offset(velocity.dx / speed, velocity.dy / speed)
            : const Offset(1, 0);

        shader.setImageSampler(0, spriteImage);
        // Uniform layout (declaration order in the .frag file):
        //   uniform vec2  uOutputSize    -> floats 0, 1
        //   uniform vec2  uVelocityDir   -> floats 2, 3
        //   uniform float uReachPx       -> float  4
        shader.setFloat(0, spriteBufferSize);
        shader.setFloat(1, spriteBufferSize);
        shader.setFloat(2, velocityDir.dx);
        shader.setFloat(3, velocityDir.dy);
        shader.setFloat(4, reach);

        // FlutterFragCoord under Skia is the canvas-local fragment
        // position (after the canvas's CTM), NOT local to the rect
        // being drawn. The shader's UV math `fragCoord / uOutputSize`
        // therefore only lands in [0, 1] when the rect's local origin
        // is at the canvas origin. Translate the canvas so the rect's
        // top-left is at (0, 0) and draw at origin — fragCoord then
        // ranges over [0, spriteBufferSize] as the shader assumes.
        // Without this, the cursor only renders correctly when
        // widgetPos happens to land within bufferSize of canvas (0,0)
        // and is invisible everywhere else.
        canvas.save();
        canvas.translate(
          widgetPos.dx - spriteBufferCenter.dx,
          widgetPos.dy - spriteBufferCenter.dy,
        );
        canvas.drawRect(
          Rect.fromLTWH(0, 0, spriteBufferSize, spriteBufferSize),
          Paint()..shader = shader,
        );
        canvas.restore();
      } else {
        // Fallback: pre-baked drawImage multi-stamp. Used only when the
        // shader hasn't loaded yet (briefly at app startup) or when an
        // older Flutter SDK doesn't ship FragmentProgram.fromAsset.
        // Index 0 = oldest tail (lowest alpha, largest negative offset).
        // Index count-1 = head (highest alpha, offset 0). Painting in
        // this order means the head composites on top of the tail.
        for (var i = 0; i < samples.count; i++) {
          final tailIndex = samples.count - 1 - i;
          final dx = samples.stepPx.dx * tailIndex;
          final dy = samples.stepPx.dy * tailIndex;
          canvas.drawImage(
            spriteImage,
            Offset(
              widgetPos.dx + dx - spriteBufferCenter.dx,
              widgetPos.dy + dy - spriteBufferCenter.dy,
            ),
            Paint()..color = Colors.white.withValues(alpha: samples.alphas[i]),
          );
        }
      }
    } finally {
      spriteImage.dispose();
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
