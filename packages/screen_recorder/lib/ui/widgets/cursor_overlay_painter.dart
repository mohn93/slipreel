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

    // The ripple ring's animation timing comes from the most recent
    // click event, but its on-screen anchor is the cursor position AT
    // THE TIME OF THE CLICK — not the live cursor. Without this the
    // ring would track the cursor as the user moves the mouse mid-
    // ripple, which makes it read as "the cursor is dragging the
    // ring around" instead of "a click happened at this spot".
    final clickEvent =
        mostRecentClickEvent(cursorRecording, position.inMicroseconds);
    final int? dt;
    final Offset? rippleWidgetPos;
    if (clickEvent == null) {
      dt = null;
      rippleWidgetPos = null;
    } else {
      final delta = position.inMicroseconds - clickEvent.timestampMicros;
      dt = delta < 0 ? null : delta;
      final clickInVideo = screenToVideoSpace(
        screenPos: clickEvent.screenPos,
        screenSize: screenSize,
        videoSize: videoSize,
      );
      rippleWidgetPos =
          Offset(clickInVideo.dx * scaleX, clickInVideo.dy * scaleY);
    }

    // Slider all the way down: cheap direct paint, no shader / pre-bake.
    // Ripple drawn first (anchored at click point), cursor on top
    // (at the live position).
    if (motionBlurIntensity <= 0) {
      if (rippleWidgetPos != null) {
        paintCursorRipple(
          canvas,
          position: rippleWidgetPos,
          baseDiameter: pxDiameter,
          microsSinceClick: dt,
          effect: clickEffect,
        );
      }
      paintCursorGlyphWithPulse(
        canvas,
        position: widgetPos,
        baseDiameter: pxDiameter,
        style: style,
        microsSinceClick: dt,
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

    // The click ripple is rendered DIRECTLY on the canvas (below the
    // shader output) rather than baked into the sprite, so the ring
    // stays anchored to the click point instead of smearing along the
    // velocity vector. Anchored at [rippleWidgetPos] (the cursor
    // position when the click happened), not at the live cursor.
    if (rippleWidgetPos != null) {
      paintCursorRipple(
        canvas,
        position: rippleWidgetPos,
        baseDiameter: pxDiameter,
        microsSinceClick: dt,
        effect: clickEffect,
      );
    }

    // Pre-bake just the cursor body (with press-pulse) to a ui.Image
    // so the shader can sample it cheaply. This also lets the shader
    // render a continuous directional smear instead of stacked
    // discrete cursor copies.
    //
    // Buffer-size budget per side from the cursor's tip (which sits
    // at the buffer's center): the macOS-shape glyph extends at most
    // ~1.27 × pxDiameter from the tip in any direction (the body
    // height plus halo overshoot), and the trail reaches `reach`
    // pixels in the velocity direction. Use 1.5 × pxDiameter for the
    // glyph budget so the round-joined halo and sub-pixel rendering
    // never clip against the buffer edge.
    final reach = samples.stepPx.distance * (samples.count - 1);
    final spriteBufferSize =
        (pxDiameter * 3 + reach * 2).ceil().toDouble();
    final spriteBufferCenter =
        Offset(spriteBufferSize / 2, spriteBufferSize / 2);

    final recorder = ui.PictureRecorder();
    final spriteCanvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, spriteBufferSize, spriteBufferSize),
    );
    paintCursorGlyphWithPulse(
      spriteCanvas,
      position: spriteBufferCenter,
      baseDiameter: pxDiameter,
      style: style,
      microsSinceClick: dt,
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
