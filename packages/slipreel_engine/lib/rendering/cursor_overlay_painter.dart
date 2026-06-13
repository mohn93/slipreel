// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Color, FilterQuality, Offset, Paint, Rect, Size;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../../effects/motion_blur_samples.dart';
import '../../effects/motion_blur_tuning.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_click_effect.dart';
import '../../rendering/cursor_geometry.dart';
import '../../rendering/cursor_glyph.dart';
import '../../rendering/spring_config.dart';

// `cursorAt` (the time-based recording lookup with linear interp) lives
// in cursor_geometry.dart and is already imported above via the
// rendering/cursor_geometry export chain.

/// Paints the recorded cursor on top of the video at the player's current
/// position. Takes a pre-computed [screenPos] (in screen-space pixels)
/// so the parent can apply motion smoothing via a CursorMotionController
/// — the painter itself stays stateless. Click events are still looked
/// up against [cursorRecording] for the press-pulse + ripple.
///
/// The glyph + click effects are drawn via [paintCursorComposed] so
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
  /// Spring controlling the press-pulse size animation. Tuned in the
  /// Springs section of the cursor tab; default is snappy / critically
  /// damped so the press reads as instant.
  final ClickSpring clickSpring;
  /// Live-tunable knobs for the motion-blur path. Defaults match the
  /// values previously hardcoded as `static const` on this class.
  final MotionBlurTuning tuning;
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
    this.clickSpring = ClickSpring.snappy,
    this.tuning = MotionBlurTuning.defaults,
    this.devicePixelRatio = 1.0,
  });

  static ui.FragmentProgram? _motionBlurProgram;

  /// Pre-loads the motion-blur fragment shader so the cursor painter
  /// can use it on first paint. Call from `main()` before `runApp`.
  /// Idempotent — subsequent calls return the cached program.
  static Future<void> ensureMotionBlurProgramLoaded() async {
    // Asset is declared in slipreel_engine/pubspec.yaml. From a
    // depending app the path resolves through the package prefix;
    // from inside the engine's own tests it resolves bare. Try the
    // depending-app path first; fall back for tests.
    if (_motionBlurProgram != null) return;
    try {
      _motionBlurProgram = await ui.FragmentProgram.fromAsset(
        'packages/slipreel_engine/shaders/motion_blur.frag',
      );
    } catch (_) {
      _motionBlurProgram = await ui.FragmentProgram.fromAsset(
        'shaders/motion_blur.frag',
      );
    }
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
    // Release time drives the press-pulse's release-out phase. Until
    // the button releases, the press pulse holds the cursor at the
    // pressed scale so a long click reads as a press for as long as
    // the user holds it (instead of bouncing back after 250ms).
    final dtRelease =
        microsSinceRelease(cursorRecording, position.inMicroseconds);

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

    // Pre-bake just the cursor body to a ui.Image so the shader can
    // sample it cheaply and the fallback path only re-rasterizes
    // vectors once. The bake is now BARE (no press-pulse, no drop
    // shadow) so it can be cached across frames — the press-pulse is
    // applied as a destination-rect scale at stamp time, and the
    // shadow is drawn separately. Without this split the bake would
    // change every frame the press-pulse animates and the cache would
    // miss continuously (bug #9 / P1-4 phase C).
    //
    // Buffer-size budget per side from the cursor's tip (which sits at
    // the buffer's center): the macOS-shape glyph extends at most ~1.27
    // × pxDiameter from the tip in any direction (body height + halo
    // overshoot); the trail reaches `reach` pixels in the velocity
    // direction. 4 × pxDiameter centred on the tip covers all of
    // those without clipping, even at the inspector slider's maxima.
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

    // Press-pulse is applied per stamp at draw time so the bake stays
    // cacheable (sprite cache key omits press-pulse phase by design).
    final pulse = pressPulseMultiplier(
      microsSinceClick: dt,
      microsSinceRelease: dtRelease,
      spring: clickSpring,
    );

    final spriteImage = _overlaySpriteCache.get(
      pxDiameter: pxDiameter,
      dpr: dpr,
      style: style,
      state: cursorState,
      bufferPx: spriteBufferPixelSize,
      bufferLogical: spriteBufferSize,
      spriteCenter: spriteBufferCenter,
    );

    try {
      // Drop shadow goes UNDER the smeared sprite so the smear's
      // alpha doesn't darken it. Scales with the pulse so a held
      // click visibly shrinks the shadow alongside the body.
      if (cursorShadow > 0) {
        paintCursorShadow(
          canvas,
          position: widgetPos,
          diameter: pxDiameter * pulse,
          style: style,
          state: cursorState,
          intensity: cursorShadow,
        );
      }

      final program = _motionBlurProgram;
      if (program != null) {
        // Shader path: one drawRect with a fragment shader that
        // produces a continuous directional smear.
        final shader = program.fragmentShader();
        final trailLen = trailVector.distance;
        final trailDir = trailLen > 0
            ? Offset(trailVector.dx / trailLen, trailVector.dy / trailLen)
            : const Offset(1, 0);

        // Pulse scales the rect uniformly so a held click visibly shrinks the
        // smear too. m11: uOutputSize MUST match the destination rect
        // (scaledSize), not the unscaled buffer — otherwise during a press-
        // pulse the shader normalizes fragCoord against the wrong size and only
        // samples the top-left `pulse` fraction of the sprite, clipping the
        // centered cursor off-center. The trail reach scales by the same pulse
        // so it stays proportional to the shrunk body. Both are no-ops at
        // pulse == 1.
        final scaledSize = spriteBufferSize * pulse;
        final pulseInset = (spriteBufferSize - scaledSize) / 2;

        shader.setImageSampler(0, spriteImage);
        shader.setFloat(0, scaledSize);
        shader.setFloat(1, scaledSize);
        shader.setFloat(2, trailDir.dx);
        shader.setFloat(3, trailDir.dy);
        shader.setFloat(4, reach * pulse);
        shader.setFloat(5, spriteBufferPixelSize.toDouble());
        shader.setFloat(6, spriteBufferPixelSize.toDouble());

        // FlutterFragCoord is canvas-local under Skia. Translate the
        // canvas so the rect's top-left is at (0, 0), draw at origin.
        canvas.save();
        canvas.translate(
          widgetPos.dx - spriteBufferCenter.dx + pulseInset,
          widgetPos.dy - spriteBufferCenter.dy + pulseInset,
        );
        canvas.drawRect(
          Rect.fromLTWH(0, 0, scaledSize, scaledSize),
          Paint()..shader = shader,
        );
        canvas.restore();
      } else {
        // Fallback: pre-baked drawImage multi-stamp. Used only when
        // the shader hasn't loaded yet (briefly at app startup) or
        // when a Flutter SDK without FragmentProgram.fromAsset runs
        // this code (older test harnesses). The last (head) stamp's
        // alpha is 1.0, so the cursor body stays opaque without an
        // additional sharp paint.
        final spriteSrcRect = Rect.fromLTWH(
          0,
          0,
          spriteBufferPixelSize.toDouble(),
          spriteBufferPixelSize.toDouble(),
        );
        final scaledSize = spriteBufferSize * pulse;
        final pulseInset = (spriteBufferSize - scaledSize) / 2;
        for (var i = 0; i < samples.count; i++) {
          final tailIndex = samples.count - 1 - i;
          final dx = samples.stepPx.dx * tailIndex;
          final dy = samples.stepPx.dy * tailIndex;
          canvas.drawImageRect(
            spriteImage,
            spriteSrcRect,
            Rect.fromLTWH(
              widgetPos.dx + dx - spriteBufferCenter.dx + pulseInset,
              widgetPos.dy + dy - spriteBufferCenter.dy + pulseInset,
              scaledSize,
              scaledSize,
            ),
            Paint()
              ..color = const Color(0xFFFFFFFF).withValues(alpha: samples.alphas[i])
              ..filterQuality = FilterQuality.high,
          );
        }
      }
    } finally {
      // No spriteImage.dispose() — the cache owns it. Disposing
      // would invalidate the next frame's lookup.
    }
  }

  /// Trail vector for the shader/fallback in widget pixels: direction
  /// is the chord between `cursorAt(T)` and `cursorAt(T − exposure)`,
  /// magnitude is min(chord length, recent-velocity × exposure,
  /// [tuning.maxTrailPx]) further multiplied by the velocity-trigger
  /// smoothstep ramp from [tuning.vTriggerLowPxPerSec] to
  /// [tuning.vTriggerHighPxPerSec]. The trail taper and the trigger
  /// ramp use separate lookback windows ([tuning.velocityLookbackMs]
  /// and [tuning.gateLookbackMs]) so the gate can respond to current
  /// speed while the taper still smooths jitter.
  ///
  /// Returns [Offset.zero] when there's no blur to render — the slider
  /// is at 0, the lookback falls before the recording start, the
  /// recording is too sparse for cursorAt to interpolate without
  /// fabricating a phantom path, or the chord is sub-pixel.
  Offset _trailVectorForBlur({required double scaleX, required double scaleY}) {
    // [motionBlurIntensity] is the on/off gate; the actual exposure
    // window comes from [tuning.maxExposureMs]. The parent screen
    // synchronises maxExposureMs to the general slider's value
    // (intensity × default-max), so dragging the general slider also
    // visibly drags the "Max exposure" advanced knob — there's no
    // hidden multiplier left inside the painter.
    if (motionBlurIntensity <= 0) return Offset.zero;
    final exposureSec = tuning.maxExposureMs / 1000.0;
    if (exposureSec <= 0) return Offset.zero;
    final exposureMicros = (exposureSec * 1e6).round();
    final tEnd = position.inMicroseconds;
    final tStart = tEnd - exposureMicros;
    if (tStart < 0) return Offset.zero;

    final raw = cursorRecording.positions;
    if (raw.length < 2) return Offset.zero;
    final maxSampleGapMicros = (tuning.maxSampleGapMs * 1000).round();
    final largePairDispPx = tuning.largePairDispPx;
    final postIdleThresholdMicros =
        (tuning.postIdleThresholdMs * 1000).round();

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
      if (curT - prevT > maxSampleGapMicros) return Offset.zero;

      final dxPair = raw[i].x - raw[i - 1].x;
      final dyPair = raw[i].y - raw[i - 1].y;
      if (dxPair * dxPair + dyPair * dyPair >
              largePairDispPx * largePairDispPx &&
          i >= 2) {
        final prevPairGap = prevT - raw[i - 2].timestampMicros;
        if (prevPairGap >= postIdleThresholdMicros) return Offset.zero;
      }
    }

    final currentSample = cursorAt(cursorRecording, position);
    final prevSample =
        cursorAt(cursorRecording, Duration(microseconds: tStart));
    if (currentSample == null || prevSample == null) return Offset.zero;

    // Chord in video pixels, then convert to widget pixels. Direction
    // of the trail is the chord direction — that's the cursor's
    // actual recorded path, so the smear runs along ground the
    // cursor crossed.
    final dxVideo = currentSample.x - prevSample.x;
    final dyVideo = currentSample.y - prevSample.y;
    final dxWidget = dxVideo * scaleX;
    final dyWidget = dyVideo * scaleY;
    final chordLen = math.sqrt(dxWidget * dxWidget + dyWidget * dyWidget);

    if (chordLen < 1) return Offset.zero;

    // Velocity-tapered length: cap the trail at the distance the
    // cursor would cover at its CURRENT (most-recent-frame) velocity
    // over the exposure window. This shortens the trail during
    // deceleration so the smear tracks where the cursor is now,
    // instead of dragging the chord all the way back to where the
    // cursor was when it was still moving fast. During acceleration
    // the chord is the smaller of the two (cursor only just started
    // moving), so the chord wins — no overshoot. At constant
    // velocity the two values are equal, so the cap is a no-op.
    //
    // Velocity-trigger ramp: below [_vTriggerLowPxPerSec] no blur
    // draws at all (the eye doesn't expect blur on motion slow
    // enough to clearly track). Between low and high, the trail
    // length is multiplied by a smoothstep so the blur fades in
    // instead of popping on/off.
    // Trail taper uses [velocityLookbackMs] — a longer window
    // smooths jitter out of the decel-tail cap. The trigger ramp
    // uses [gateLookbackMs] — a short window so the gate opens
    // immediately when motion starts and closes only after motion
    // has actually stopped (instead of riding the long-window
    // average through the tail of every move).
    final velocityLookbackMicros = (tuning.velocityLookbackMs * 1000).round();
    final vLookback = position.inMicroseconds - velocityLookbackMicros;
    final lookbackSample = vLookback >= 0
        ? cursorAt(cursorRecording, Duration(microseconds: vLookback))
        : null;
    double effectiveLen = chordLen;
    if (lookbackSample != null) {
      final vDxVideo = currentSample.x - lookbackSample.x;
      final vDyVideo = currentSample.y - lookbackSample.y;
      final vDxWidget = vDxVideo * scaleX;
      final vDyWidget = vDyVideo * scaleY;
      final lookbackSec = velocityLookbackMicros / 1e6;
      final vRecentMag =
          math.sqrt(vDxWidget * vDxWidget + vDyWidget * vDyWidget) /
              lookbackSec;
      final vTLen = vRecentMag * exposureSec;
      if (vTLen < effectiveLen) effectiveLen = vTLen;
    }

    final gateLookbackMicros = (tuning.gateLookbackMs * 1000).round();
    final gateLookback = position.inMicroseconds - gateLookbackMicros;
    final gateSample = gateLookback >= 0
        ? cursorAt(cursorRecording, Duration(microseconds: gateLookback))
        : null;
    double triggerRamp = 1.0;
    if (gateSample != null && gateLookbackMicros > 0) {
      final gDxVideo = currentSample.x - gateSample.x;
      final gDyVideo = currentSample.y - gateSample.y;
      final gDxWidget = gDxVideo * scaleX;
      final gDyWidget = gDyVideo * scaleY;
      final gateSec = gateLookbackMicros / 1e6;
      final vGateMag =
          math.sqrt(gDxWidget * gDxWidget + gDyWidget * gDyWidget) / gateSec;

      final triggerSpan =
          (tuning.vTriggerHighPxPerSec - tuning.vTriggerLowPxPerSec)
              .abs();
      // If the user squashes low ≈ high, fall back to a hard
      // threshold (no ramp band) instead of dividing by zero.
      final triggerT = triggerSpan < 1
          ? (vGateMag >= tuning.vTriggerHighPxPerSec ? 1.0 : 0.0)
          : ((vGateMag - tuning.vTriggerLowPxPerSec) / triggerSpan)
              .clamp(0.0, 1.0);
      // Smoothstep: 3t² - 2t³. Hermite interpolation, zero
      // derivative at both ends — no visible kink at threshold
      // boundaries while the ramp is active.
      triggerRamp = triggerT * triggerT * (3 - 2 * triggerT);
    }
    if (triggerRamp <= 0) return Offset.zero;
    effectiveLen *= triggerRamp;

    if (effectiveLen < 1) return Offset.zero;

    // Hard cap on absolute pixels regardless of source.
    if (effectiveLen > tuning.maxTrailPx) effectiveLen = tuning.maxTrailPx;

    // Project the cap (effectiveLen) onto the chord direction.
    final scale = effectiveLen / chordLen;
    return Offset(dxWidget * scale, dyWidget * scale);
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
        old.clickSpring != clickSpring ||
        old.tuning != tuning ||
        old.devicePixelRatio != devicePixelRatio;
  }
}

/// Cache of pre-baked, bare cursor sprites keyed by the inputs that
/// can change frame-to-frame (diameter, dpr, style, state, bufferPx).
/// Each baked sprite is the cursor body alone — no press-pulse, no
/// drop shadow — so the cache key needn't include the press-pulse
/// phase (which would re-bake every frame) or the shadow knob (which
/// the painter applies separately at draw time). Without this cache,
/// the motion-blur branch called `picture.toImageSync` on every
/// frame the cursor was moving, stalling the UI thread on each tick
/// (bug #9 from the 2026-05 architecture review).
class _OverlaySpriteCache {
  static const int _capacity = 8;
  final Map<_OverlaySpriteKey, ui.Image> _entries =
      <_OverlaySpriteKey, ui.Image>{}; // insertion-order LRU

  ui.Image get({
    required double pxDiameter,
    required double dpr,
    required CursorStyle style,
    required CursorState state,
    required int bufferPx,
    required double bufferLogical,
    required Offset spriteCenter,
  }) {
    final key = _OverlaySpriteKey(pxDiameter, dpr, style, state, bufferPx);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit; // touch (move to end)
      return hit;
    }
    final recorder = ui.PictureRecorder();
    final c = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, bufferPx.toDouble(), bufferPx.toDouble()),
    );
    c.scale(dpr);
    paintCursorGlyph(
      c,
      position: spriteCenter,
      diameter: pxDiameter,
      style: style,
      state: state,
    );
    final pic = recorder.endRecording();
    final image = pic.toImageSync(bufferPx, bufferPx);
    pic.dispose();
    _entries[key] = image;
    while (_entries.length > _capacity) {
      final firstKey = _entries.keys.first;
      _entries.remove(firstKey)?.dispose();
    }
    return image;
  }
}

@immutable
class _OverlaySpriteKey {
  const _OverlaySpriteKey(
    this.pxDiameter,
    this.dpr,
    this.style,
    this.state,
    this.bufferPx,
  );
  final double pxDiameter;
  final double dpr;
  final CursorStyle style;
  final CursorState state;
  final int bufferPx;

  @override
  bool operator ==(Object other) =>
      other is _OverlaySpriteKey &&
      other.pxDiameter == pxDiameter &&
      other.dpr == dpr &&
      other.style == style &&
      other.state == state &&
      other.bufferPx == bufferPx;

  @override
  int get hashCode => Object.hash(pxDiameter, dpr, style, state, bufferPx);
}

final _overlaySpriteCache = _OverlaySpriteCache();
