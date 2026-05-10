// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../../effects/motion_blur_samples.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_click_effect.dart';
import '../../rendering/cursor_geometry.dart';
import '../../rendering/cursor_glyph.dart';

// `cursorAt` (the time-based recording lookup with linear interp) lives
// in cursor_geometry.dart and is already imported above via the
// rendering/cursor_geometry export chain.

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
  final CursorState cursorState;
  final double cursorShadow;
  /// Device pixel ratio of the surface this painter renders into.
  /// The motion-blur path bakes the cursor to a `ui.Image`; without
  /// oversampling by [devicePixelRatio] the bake ends up at logical
  /// resolution and the shader's image sampler (which uses NEAREST
  /// by default in Flutter's FragmentShader) produces visibly
  /// stepped texel-doubling along the trail on Retina displays.
  /// 1.0 is a safe fallback (export pipeline / non-retina screens).
  final double devicePixelRatio;

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
    this.cursorState = CursorState.arrow,
    this.cursorShadow = 0,
    this.devicePixelRatio = 1.0,
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

    // Trail vector = cursor's actual recorded displacement over the
    // virtual shutter window. Sampling the raw recording at both
    // ends of the exposure means the trail length never exceeds the
    // cursor's real path — even on sudden accelerations where the
    // instantaneous velocity is much higher than the average over
    // the window.
    final trailVector = _trailVectorForBlur(
      scaleX: scaleX,
      scaleY: scaleY,
    );

    // Slider all the way down (or no recorded displacement during
    // the exposure): cheap direct paint, no shader / pre-bake.
    // Ripple drawn first (anchored at click point), cursor on top
    // (at the live position).
    if (motionBlurIntensity <= 0 || trailVector.distance < 1) {
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
        state: cursorState,
        shadowIntensity: cursorShadow,
      );
      return;
    }

    final samples = computeMotionBlurSamples(
      trailVectorPx: trailVector,
    );

    // When the math collapsed to "no blur" (cursor stopped, or the
    // effective intensity rounds down to a single stamp), bail to
    // direct paint. The shader path bakes the cursor into a ui.Image
    // first; the bake is pixel-identical to direct paint at the
    // canvas, but once an active zoom region wraps this widget in a
    // Transform.scale, the layer sampler upscales the baked bitmap
    // (jaggy edges) while vector commands re-execute at the
    // destination resolution (crisp). The threshold-toggle concern
    // only matters during actual motion; below the activation speed
    // there's no blur to draw anyway, so the path switch is invisible.
    if (samples.count == 1) {
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
        state: cursorState,
        shadowIntensity: cursorShadow,
      );
      return;
    }

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
    // height plus halo overshoot); the drop shadow extends another
    // ~0.5 × pxDiameter below at full intensity (offset + 3σ blur);
    // the trail reaches `reach` pixels in the velocity direction.
    // 4 × pxDiameter centred on the tip covers all of those without
    // clipping, even at the inspector slider's maxima.
    final reach = samples.stepPx.distance * (samples.count - 1);
    final spriteBufferSize =
        (pxDiameter * 4 + reach * 2).ceil().toDouble();
    final spriteBufferCenter =
        Offset(spriteBufferSize / 2, spriteBufferSize / 2);
    // Oversample the bake by devicePixelRatio so the texture has
    // enough texels for the shader's nearest-filter sampling to land
    // a unique value per output device pixel. Without this the bake
    // is at logical resolution; on a 2× retina display the shader
    // sees half the texels it needs and produces 2-px-wide stepped
    // edges along the trail.
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final spriteBufferPixelSize = (spriteBufferSize * dpr).ceil();

    final recorder = ui.PictureRecorder();
    final spriteCanvas = Canvas(
      recorder,
      Rect.fromLTWH(
        0,
        0,
        spriteBufferPixelSize.toDouble(),
        spriteBufferPixelSize.toDouble(),
      ),
    );
    // Scale the recording so cursor commands issued in logical
    // coordinates rasterize into the dpr-scaled buffer at high res.
    spriteCanvas.scale(dpr);
    paintCursorGlyphWithPulse(
      spriteCanvas,
      position: spriteBufferCenter,
      baseDiameter: pxDiameter,
      style: style,
      microsSinceClick: dt,
      state: cursorState,
      shadowIntensity: cursorShadow,
    );
    final picture = recorder.endRecording();
    final spriteImage = picture.toImageSync(
      spriteBufferPixelSize,
      spriteBufferPixelSize,
    );
    picture.dispose();

    try {
      final program = _motionBlurProgram;
      if (program != null) {
        // Shader path: one drawRect with a fragment shader that
        // produces a continuous directional smear.
        final shader = program.fragmentShader();
        // Trail direction is the unit vector along the recorded
        // displacement. When length is zero the count==1 short-circuit
        // above already returned, so this division is safe — but pass
        // an arbitrary unit vector if it ever becomes zero so any
        // backend that evaluates the uniform doesn't see NaN.
        final trailLen = trailVector.distance;
        final trailDir = trailLen > 0
            ? Offset(trailVector.dx / trailLen, trailVector.dy / trailLen)
            : const Offset(1, 0);

        shader.setImageSampler(0, spriteImage);
        // Uniform layout (declaration order in the .frag file):
        //   uniform vec2  uOutputSize    -> floats 0, 1
        //   uniform vec2  uVelocityDir   -> floats 2, 3
        //   uniform float uReachPx       -> float  4
        //   uniform vec2  uSpriteSize    -> floats 5, 6
        shader.setFloat(0, spriteBufferSize);
        shader.setFloat(1, spriteBufferSize);
        shader.setFloat(2, trailDir.dx);
        shader.setFloat(3, trailDir.dy);
        shader.setFloat(4, reach);
        // Sprite is dpr-oversampled — the shader's bilinear math
        // needs the texture's actual texel count, not the canvas-
        // logical buffer size.
        shader.setFloat(5, spriteBufferPixelSize.toDouble());
        shader.setFloat(6, spriteBufferPixelSize.toDouble());

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
        // drawImageRect maps the dpr-scaled bake (src) onto the
        // logical-sized destination, with FilterQuality.high so the
        // downsample/upsample doesn't show as nearest-neighbor blocks.
        final spriteSrcRect = Rect.fromLTWH(
          0,
          0,
          spriteBufferPixelSize.toDouble(),
          spriteBufferPixelSize.toDouble(),
        );
        for (var i = 0; i < samples.count; i++) {
          final tailIndex = samples.count - 1 - i;
          final dx = samples.stepPx.dx * tailIndex;
          final dy = samples.stepPx.dy * tailIndex;
          canvas.drawImageRect(
            spriteImage,
            spriteSrcRect,
            Rect.fromLTWH(
              widgetPos.dx + dx - spriteBufferCenter.dx,
              widgetPos.dy + dy - spriteBufferCenter.dy,
              spriteBufferSize,
              spriteBufferSize,
            ),
            Paint()
              ..color = Colors.white.withValues(alpha: samples.alphas[i])
              ..filterQuality = FilterQuality.high,
          );
        }
      }
    } finally {
      spriteImage.dispose();
    }
  }

  /// Virtual shutter window at slider=1.0. ~1.5× the velocity sampling
  /// lookback (33 ms in [CursorMotionController]); slider scales it
  /// linearly from 0 to this maximum. Tuning this changes how
  /// dramatic the trail is at any given speed.
  static const double _maxExposureSeconds = 0.05;

  /// Upper bound on the chord between `cursorAt(T)` and
  /// `cursorAt(T − exposure)` before we treat the result as a
  /// teleport instead of a trail.
  ///
  /// Sustained cursor motion at 6000 px/s for the full 50 ms exposure
  /// covers ~300 px — already an extreme flick. A chord longer than
  /// that means the recording has a sample gap (cursor toggled out
  /// and back, app focus change, etc.) and `cursorAt`'s linear
  /// interpolation has fabricated a path through points the cursor
  /// never actually crossed. Drawing a smear there is exactly the
  /// "trail in places the cursor wasn't" artifact, so we drop the
  /// trail entirely for that frame and let the cursor render sharp.
  static const double _maxTrailPx = 300.0;

  /// Cursor's actual recorded displacement vector over the virtual
  /// shutter window — the trail's direction and length come from this.
  ///
  /// Sampling the raw recording at both [position] and
  /// [position] − exposure means the trail can never be longer than
  /// the cursor's real path, even when the cursor suddenly accelerates.
  /// Using `velocity × exposure` instead would overshoot in those
  /// cases (instantaneous velocity at T is much higher than the
  /// average over the exposure window) and the trail would extend
  /// over ground the cursor never crossed.
  ///
  /// Returns `Offset.zero` when the slider is at 0, the lookback
  /// falls before the start of the recording, or either sample is
  /// null. Either condition routes the painter to the direct-paint
  /// no-blur branch.
  Offset _trailVectorForBlur({required double scaleX, required double scaleY}) {
    if (motionBlurIntensity <= 0) return Offset.zero;
    final exposureSec = motionBlurIntensity * _maxExposureSeconds;
    if (exposureSec <= 0) return Offset.zero;
    final exposureMicros = (exposureSec * 1e6).round();
    final lookback = position.inMicroseconds - exposureMicros;
    if (lookback < 0) return Offset.zero;

    final currentSample = cursorAt(cursorRecording, position);
    final prevSample =
        cursorAt(cursorRecording, Duration(microseconds: lookback));
    if (currentSample == null || prevSample == null) return Offset.zero;

    final dxVideo = currentSample.x - prevSample.x;
    final dyVideo = currentSample.y - prevSample.y;
    // Teleport guard: if the chord exceeds what real cursor motion
    // can cover during the exposure, the recording has a gap and
    // cursorAt has linearly interpolated a path the cursor never
    // actually traced. Drop the trail rather than smearing through
    // those phantom positions.
    if (dxVideo * dxVideo + dyVideo * dyVideo >
        _maxTrailPx * _maxTrailPx) {
      return Offset.zero;
    }

    // Recording stores video-pixel coordinates. Scale to widget pixels
    // so the trail vector matches the units the shader/painter use
    // when drawing into the canvas (= scaleX/Y times video coords).
    return Offset(dxVideo * scaleX, dyVideo * scaleY);
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
        old.motionBlurIntensity != motionBlurIntensity ||
        old.cursorState != cursorState ||
        old.cursorShadow != cursorShadow ||
        old.devicePixelRatio != devicePixelRatio;
  }
}
