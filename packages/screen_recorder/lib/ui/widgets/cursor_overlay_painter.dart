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
/// [motionBlurIntensity] is > 0 and the cursor moved during the virtual
/// shutter window, the sprite is stamped along the cursor's actual
/// recorded polyline to produce a path-aware motion-blur trail.
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
  /// resolution and stamp draws look stepped on Retina displays.
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

    // Path-aware trail: list of polyline points (in widget pixels)
    // tracing the cursor's actual recorded motion across the exposure
    // window, with the head anchored to widgetPos. Returns null when
    // there's no blur to render — slider at 0, no displacement, lookback
    // before the recording start, OR a recording-sample gap that would
    // cause cursorAt to fabricate a phantom path through unknown ground.
    final polyline = _trailPolylineForBlur(
      widgetPos: widgetPos,
      scaleX: scaleX,
      scaleY: scaleY,
    );

    final stamps = polyline == null
        ? const <MotionBlurStamp>[]
        : sampleMotionBlurStamps(polyline: polyline);

    // Direct paint when there's no blur to render (slider 0, sub-pixel
    // displacement, sample gap, etc.). This branch also keeps the
    // cursor sharp under an active zoom: the stamp/bake path
    // rasterizes the sprite to a ui.Image first, and that image gets
    // upscaled by any wrapping Transform.scale; direct vector commands
    // re-execute at the destination resolution.
    if (stamps.length < 2) {
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
    // cursor stamps) rather than baked into the sprite, so the ring
    // stays anchored to the click point instead of smearing along the
    // motion path.
    if (rippleWidgetPos != null) {
      paintCursorRipple(
        canvas,
        position: rippleWidgetPos,
        baseDiameter: pxDiameter,
        microsSinceClick: dt,
        effect: clickEffect,
      );
    }

    // Bake one cursor sprite (with press-pulse) into a ui.Image so
    // the multi-stamp loop only re-rasterizes vectors once per frame.
    //
    // Buffer-size budget: the macOS-shape glyph extends at most ~1.27
    // × pxDiameter from the tip in any direction (body height + halo
    // overshoot); the drop shadow extends another ~0.5 × pxDiameter
    // below. 4 × pxDiameter centred on the tip covers all of those
    // without clipping.
    final spriteBufferSize = (pxDiameter * 4).ceil().toDouble();
    final spriteBufferCenter =
        Offset(spriteBufferSize / 2, spriteBufferSize / 2);
    // Oversample the bake by devicePixelRatio so the texture has
    // enough texels for FilterQuality.high to land a unique value per
    // output device pixel — without this, retina displays show
    // 2-px-wide stepped edges along the trail.
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
      final spriteSrcRect = Rect.fromLTWH(
        0,
        0,
        spriteBufferPixelSize.toDouble(),
        spriteBufferPixelSize.toDouble(),
      );
      // Draw tail-first so the head composites on top. stamps[0] is
      // the dimmest tail (alpha = 1/count); stamps.last is the
      // opaque head (alpha = 1.0) at widgetPos.
      for (final s in stamps) {
        canvas.drawImageRect(
          spriteImage,
          spriteSrcRect,
          Rect.fromLTWH(
            s.position.dx - spriteBufferCenter.dx,
            s.position.dy - spriteBufferCenter.dy,
            spriteBufferSize,
            spriteBufferSize,
          ),
          Paint()
            ..color = Colors.white.withValues(alpha: s.alpha)
            ..filterQuality = FilterQuality.high,
        );
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

  /// Reject the trail when any pair of consecutive recording samples
  /// that overlaps the exposure window is more than this far apart.
  ///
  /// macOS records cursor samples at ~60 Hz (≈16 ms apart). Real
  /// recordings see frame jitter up to ~30 ms. Anything past 50 ms is
  /// a hiccup — cursor disappeared (focus change, app switch, hidden-
  /// cursor toggle) — and `cursorAt`'s linear interpolation across
  /// that interval fabricates a path through unknown ground. Drawing
  /// stamps along that fabricated path is exactly the "trail in
  /// places the cursor wasn't" artifact, so we drop the trail entirely
  /// and let the cursor render sharp.
  static const int _maxSampleGapMicros = 50000;

  /// Returns the cursor's recorded polyline across the virtual shutter
  /// window in widget pixels, with the HEAD point anchored at
  /// [widgetPos]. Every stamp drawn along this polyline lands on a
  /// piecewise-linear segment between two real recorded samples (or one
  /// real + one interpolated endpoint), so the trail can never extend
  /// to a position the cursor wasn't actually at.
  ///
  /// Returns `null` when:
  /// - the slider is at 0,
  /// - the exposure lookback falls before the start of the recording,
  /// - the recording has fewer than two samples, or
  /// - any pair of consecutive recording samples that overlaps the
  ///   exposure window is more than [_maxSampleGapMicros] apart (the
  ///   gap-based phantom-path guard).
  ///
  /// Anchoring the head at [widgetPos] means the bright head stamp
  /// covers the visible (parent-smoothed) cursor position, even when
  /// the parent's smoothing leads/lags the raw recording slightly.
  List<Offset>? _trailPolylineForBlur({
    required Offset widgetPos,
    required double scaleX,
    required double scaleY,
  }) {
    if (motionBlurIntensity <= 0) return null;
    final exposureSec = motionBlurIntensity * _maxExposureSeconds;
    if (exposureSec <= 0) return null;
    final exposureMicros = (exposureSec * 1e6).round();
    final tEnd = position.inMicroseconds;
    final tStart = tEnd - exposureMicros;
    if (tStart < 0) return null;

    final raw = cursorRecording.positions;
    if (raw.length < 2) return null;

    // Reject the trail whenever a pair of consecutive recording
    // samples that overlaps [tStart, tEnd] is wider than the
    // expected cadence. Use the RAW recording's timestamps here, not
    // the polyline's — interpolated endpoints carry the requested
    // time, not the underlying gap.
    for (var i = 1; i < raw.length; i++) {
      final prevT = raw[i - 1].timestampMicros;
      final curT = raw[i].timestampMicros;
      if (curT <= tStart) continue;
      if (prevT >= tEnd) break;
      if (curT - prevT > _maxSampleGapMicros) return null;
    }

    final endSample = cursorAt(cursorRecording, position);
    final startSample = cursorAt(
      cursorRecording,
      Duration(microseconds: tStart),
    );
    if (endSample == null || startSample == null) return null;

    // Point sequence in time order: interpolated start + every recorded
    // sample strictly inside the window + interpolated end.
    final pts = <CursorPosition>[
      startSample,
      for (final p in raw)
        if (p.timestampMicros > tStart && p.timestampMicros < tEnd) p,
      endSample,
    ];

    // Anchor the polyline so the head (last point) coincides with
    // widgetPos. dxOffset/dyOffset is the constant shift applied to
    // every recorded video-coord point so the head video-coord maps
    // exactly to widgetPos.
    final dxOffset = widgetPos.dx - endSample.x * scaleX;
    final dyOffset = widgetPos.dy - endSample.y * scaleY;
    return [
      for (final p in pts)
        Offset(p.x * scaleX + dxOffset, p.y * scaleY + dyOffset),
    ];
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
