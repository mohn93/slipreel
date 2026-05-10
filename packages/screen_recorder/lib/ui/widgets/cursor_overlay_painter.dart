// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'dart:math' as math;
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
/// [motionBlurIntensity] is > 0 and the cursor moved during the virtual
/// shutter window, the cursor sprite is smeared along the chord of its
/// recorded path to produce a motion-blur trail. A pre-pass over the raw
/// recording rejects the trail when sample density inside the window is
/// too sparse to reconstruct the cursor's actual motion (cursorAt would
/// otherwise fabricate a phantom path through unknown ground).
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
  /// resolution and the shader's image sampler produces visibly
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

    // Trail vector: the cursor's recorded chord across the virtual
    // shutter window in widget pixels, capped at [_maxTrailPx]. Returns
    // [Offset.zero] for "no blur to render" (slider 0, no displacement,
    // recording too sparse, lookback before recording start, etc.).
    //
    // The path-aware gap rejection is what lets us trust the chord:
    // when the recording has dense samples covering the entire window,
    // the chord is anchored to ground the cursor actually crossed, so
    // the smear can't extend to positions the cursor wasn't at. When
    // any consecutive-sample interval that overlaps the window exceeds
    // [_maxSampleGapMicros], cursorAt's interpolation across that gap
    // would fabricate a phantom path — we drop the trail entirely
    // rather than smear through unknown ground.
    final trailVector = _trailVectorForBlur(
      scaleX: scaleX,
      scaleY: scaleY,
    );

    // Slider all the way down (or recording too sparse / no displacement
    // during the exposure): cheap direct paint, no shader / pre-bake.
    // This branch also keeps the cursor sharp under an active zoom
    // transform — the bake/shader path rasterizes the sprite to a
    // ui.Image, and a wrapping Transform.scale upscales that bitmap
    // (jaggy edges) instead of re-executing the vector commands.
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

    // Math collapsed to "no blur" (sub-pixel chord). Direct paint.
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
    // motion vector.
    if (rippleWidgetPos != null) {
      paintCursorRipple(
        canvas,
        position: rippleWidgetPos,
        baseDiameter: pxDiameter,
        microsSinceClick: dt,
        effect: clickEffect,
      );
    }

    // Pre-bake just the cursor body (with press-pulse) to a ui.Image so
    // the shader can sample it cheaply, and so the fallback path's
    // multi-stamp loop only re-rasterizes vectors once per frame.
    //
    // Buffer-size budget per side from the cursor's tip (which sits at
    // the buffer's center): the macOS-shape glyph extends at most ~1.27
    // × pxDiameter from the tip in any direction (body height + halo
    // overshoot); the drop shadow extends another ~0.5 × pxDiameter
    // below at full intensity (offset + 3σ blur); the trail reaches
    // `reach` pixels in the velocity direction. 4 × pxDiameter centred
    // on the tip covers all of those without clipping, even at the
    // inspector slider's maxima.
    final reach = samples.stepPx.distance * (samples.count - 1);
    final spriteBufferSize =
        (pxDiameter * 4 + reach * 2).ceil().toDouble();
    final spriteBufferCenter =
        Offset(spriteBufferSize / 2, spriteBufferSize / 2);
    // Oversample the bake by devicePixelRatio so the texture has
    // enough texels for the shader's bilinear sampling to land a
    // unique value per output device pixel. Without this the bake is
    // at logical resolution; on a 2× retina display the shader sees
    // half the texels it needs and produces stepped edges.
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
        final trailLen = trailVector.distance;
        final trailDir = trailLen > 0
            ? Offset(trailVector.dx / trailLen, trailVector.dy / trailLen)
            : const Offset(1, 0);

        shader.setImageSampler(0, spriteImage);
        shader.setFloat(0, spriteBufferSize);
        shader.setFloat(1, spriteBufferSize);
        shader.setFloat(2, trailDir.dx);
        shader.setFloat(3, trailDir.dy);
        shader.setFloat(4, reach);
        shader.setFloat(5, spriteBufferPixelSize.toDouble());
        shader.setFloat(6, spriteBufferPixelSize.toDouble());

        // FlutterFragCoord is canvas-local under Skia. Translate the
        // canvas so the rect's top-left is at (0, 0), draw at origin.
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
        // Fallback: pre-baked drawImage multi-stamp. Used only when
        // the shader hasn't loaded yet (briefly at app startup) or
        // when a Flutter SDK without FragmentProgram.fromAsset runs
        // this code (older test harnesses).
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
  /// lookback; slider scales it linearly from 0 to this maximum.
  static const double _maxExposureSeconds = 0.05;

  /// Reject the trail when any pair of consecutive recording samples
  /// that overlaps the exposure window is more than this far apart.
  ///
  /// macOS records cursor samples at ~60 Hz (≈16 ms apart). Real
  /// recordings see frame jitter up to ~30 ms. Anything past 50 ms
  /// is a hiccup — cursor disappeared (focus change, app switch,
  /// hidden-cursor toggle) — and `cursorAt`'s linear interpolation
  /// across that gap fabricates a path through unknown ground.
  /// Drawing a smear along that fabricated path is exactly the
  /// "trail in places the cursor wasn't" artifact, so we drop the
  /// trail entirely and let the cursor render sharp.
  static const int _maxSampleGapMicros = 50000;

  /// Above this per-pair displacement (in video pixels), the post-idle
  /// warp check kicks in. Real fast cursor motion can hit 200 px in a
  /// single 16-ms sample interval, so this is intentionally just above
  /// slow-to-moderate motion — the displacement alone isn't suspicious,
  /// only its combination with a long preceding-pair gap.
  static const double _largePairDispPx = 100.0;

  /// If a "fast" sample-pair's IMMEDIATELY PRECEDING pair has a gap
  /// of at least this many micros, the fast pair is treated as a
  /// system warp (focus change / app switch / cursor teleport)
  /// rather than real human motion. The signature: cursor sat idle
  /// for ≥80 ms and then "moved" >100 px between two samples that
  /// happen to be close together in time. Real flicks have small
  /// preceding gaps (because they're sustained dense motion); only
  /// system warps land an isolated burst right after a long idle.
  static const int _postIdleThresholdMicros = 80000;

  /// Hard cap on the rendered trail length in widget pixels.
  ///
  /// Even when the recording is dense and gap-rejection passes, a
  /// genuinely fast flick can produce a chord longer than what reads
  /// as "natural blur" — the smear extends most of the way across the
  /// frame. Capping the visible trail at [_maxTrailPx] turns those
  /// extreme cases into a fixed-length blur in the motion direction
  /// rather than a screen-spanning streak.
  static const double _maxTrailPx = 300.0;

  /// Trail vector for the shader/fallback in widget pixels: direction
  /// is the chord between `cursorAt(T)` and `cursorAt(T − exposure)`,
  /// magnitude is min(chord length, [_maxTrailPx]).
  ///
  /// Returns [Offset.zero] when there's no blur to render — the slider
  /// is at 0, the lookback falls before the recording start, the
  /// recording is too sparse for cursorAt to interpolate without
  /// fabricating a phantom path, or the chord is sub-pixel.
  Offset _trailVectorForBlur({required double scaleX, required double scaleY}) {
    if (motionBlurIntensity <= 0) return Offset.zero;
    final exposureSec = motionBlurIntensity * _maxExposureSeconds;
    if (exposureSec <= 0) return Offset.zero;
    final exposureMicros = (exposureSec * 1e6).round();
    final tEnd = position.inMicroseconds;
    final tStart = tEnd - exposureMicros;
    if (tStart < 0) return Offset.zero;

    final raw = cursorRecording.positions;
    if (raw.length < 2) return Offset.zero;

    // Walk the consecutive sample pairs that overlap [tStart, tEnd]
    // and reject the trail when either:
    //   (a) the pair's TIME gap exceeds [_maxSampleGapMicros] — the
    //       cursor disappeared from event capture, and cursorAt's
    //       linear interpolation across that interval fabricates
    //       a phantom path through unknown ground; or
    //   (b) the pair's POSITION displacement exceeds
    //       [_largePairDispPx] AND the immediately preceding pair
    //       had a gap of ≥[_postIdleThresholdMicros] — the cursor
    //       sat idle then "warped" to a new position in a single
    //       sample interval. That's a system action (focus change,
    //       app switch, cursor reposition) rather than real human
    //       motion; cursorAt would interpolate across the warp
    //       pair the same way a long time-gap would, just at
    //       finer time resolution. Drawing a smear through those
    //       interpolated positions is the "trail in places the
    //       cursor wasn't" artifact.
    for (var i = 1; i < raw.length; i++) {
      final prevT = raw[i - 1].timestampMicros;
      final curT = raw[i].timestampMicros;
      if (curT <= tStart) continue;
      if (prevT >= tEnd) break;
      if (curT - prevT > _maxSampleGapMicros) return Offset.zero;

      final dxPair = raw[i].x - raw[i - 1].x;
      final dyPair = raw[i].y - raw[i - 1].y;
      if (dxPair * dxPair + dyPair * dyPair >
              _largePairDispPx * _largePairDispPx &&
          i >= 2) {
        final prevPairGap = prevT - raw[i - 2].timestampMicros;
        if (prevPairGap >= _postIdleThresholdMicros) return Offset.zero;
      }
    }

    final currentSample = cursorAt(cursorRecording, position);
    final prevSample =
        cursorAt(cursorRecording, Duration(microseconds: tStart));
    if (currentSample == null || prevSample == null) return Offset.zero;

    // Chord in video pixels, then convert to widget pixels.
    final dxVideo = currentSample.x - prevSample.x;
    final dyVideo = currentSample.y - prevSample.y;
    final dxWidget = dxVideo * scaleX;
    final dyWidget = dyVideo * scaleY;
    final lenWidget = math.sqrt(dxWidget * dxWidget + dyWidget * dyWidget);

    if (lenWidget < 1) return Offset.zero;

    // Cap the rendered trail length but keep direction intact.
    if (lenWidget > _maxTrailPx) {
      final scale = _maxTrailPx / lenWidget;
      return Offset(dxWidget * scale, dyWidget * scale);
    }
    return Offset(dxWidget, dyWidget);
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
