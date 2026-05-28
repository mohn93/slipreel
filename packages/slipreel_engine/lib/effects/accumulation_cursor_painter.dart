import 'dart:ui' as ui;
import 'dart:ui' show BlendMode, Canvas, Color, FilterQuality, Offset, Paint, Rect, Size;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';

/// Renders the cursor with **temporal accumulation** motion blur — the
/// approach Screen Studio and cinematic renderers use.
///
/// For each output frame at time T, the painter takes [sampleCount]
/// equally-spaced sub-frame timestamps across the exposure window
/// `[T - exposureMs, T]`, looks up the cursor position at each, and
/// stamps the pre-baked cursor sprite at every position with
/// `1 / sampleCount` alpha. Stationary cursors integrate back to
/// alpha = 1.0 (all stamps land at the same place); moving cursors
/// spread their stamps out along the **actual recorded path**, giving
/// a smear that curves with the path and tapers naturally on
/// acceleration / deceleration without any explicit velocity ramps.
///
/// This replaces the chord-stretched single sprite ("fake" smear)
/// produced by [CursorOverlayPainter]'s motion-blur path. Both are
/// kept in the codebase during the prototype so the playground can
/// A/B compare.
class AccumulationCursorPainter extends CustomPainter {
  AccumulationCursorPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    this.exposureMs = 40.0,
    this.sampleCount = 8,
    this.sizeMultiplier = 1.0,
    this.style = CursorStyle.classic,
    this.cursorState = CursorState.arrow,
    this.devicePixelRatio = 2.0,
    this.currentFocalVideo,
    this.currentScale = 1.0,
    this.focalAt,
    this.scaleAt,
    this.videoRect,
    this.typeChangeBlurSigmaPx = 0.0,
    this.typeChangeBlurHalfWidthMs,
    this.postProcess = CursorPostProcess.none,
    this.clickEffect = CursorClickEffect.ripple,
    this.clickSpring = ClickSpring.snappy,
  });

  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final double exposureMs;
  final int sampleCount;
  final double sizeMultiplier;
  final CursorStyle style;

  /// Fallback cursor state used when a sub-frame sample is missing.
  /// Each individual stamp's sprite is normally chosen from the
  /// per-sub-frame sample's [CursorPosition.state], so transitions like
  /// arrow→I-beam are crossfaded across the accumulation window for
  /// free. This is only consulted if the recording has no sample at all
  /// at the sub-frame's time (typically only on the very first sub-frame
  /// of a recording).
  final CursorState cursorState;
  final double devicePixelRatio;

  /// Current camera focal in video coords. Pair with [currentScale]
  /// and the two callbacks below to enable camera-aware sub-frame
  /// positioning — each stamp lands where the cursor *visually*
  /// was at that sub-frame time, given the camera state at that
  /// time. When null, stamps land at the cursor's raw video
  /// position (legacy behaviour; correct when there's no zoom).
  final Offset? currentFocalVideo;

  /// Current camera scale (zoom factor at the painted frame).
  final double currentScale;

  /// Camera focal lookup at arbitrary sub-frame times (video coords).
  final Offset Function(Duration)? focalAt;

  /// Camera scale lookup at arbitrary sub-frame times.
  final double Function(Duration)? scaleAt;

  /// Where the video occupies the painter's canvas. Defaults to the
  /// whole canvas, which matches the legacy expectation that the
  /// CustomPaint is sized to videoSize. Callers that wrap a larger
  /// canvas (e.g. PlaybackCanvas, which sizes the cursor layer to
  /// totalSize so the cursor can extend onto the wallpaper padding
  /// outside the framed video) pass an explicit rect — the painter
  /// then maps recorded cursor positions into this rect and lets the
  /// isolating saveLayer cover the full canvas, so stamps that land
  /// in the padding area aren't clipped by the video boundary.
  final Rect? videoRect;

  /// Peak Gaussian σ (in widget pixels) applied to stamps that land
  /// *at* a cursor-type-change boundary (e.g. arrow→I-beam). Stamps far
  /// from any boundary use σ = 0 (sharp). Between, σ ramps quadratically
  /// to zero at ±[typeChangeBlurHalfWidthMs]. Set to 0 to disable the
  /// effect entirely. ~4px is a reasonable "vanish into a soft glow and
  /// re-condense" starting point; ~8–12px makes the cursor's silhouette
  /// fully dissolve mid-transition.
  final double typeChangeBlurSigmaPx;

  /// Half-width (ms) of the type-change blur bump. σ is at peak when a
  /// stamp's time exactly matches a type-change boundary and tapers to
  /// 0 at ±this distance. When null, defaults to [exposureMs] so the
  /// blur naturally spans the accumulation window — wide enough that
  /// neighbouring sub-frames see it, narrow enough that stamps well
  /// before/after the transition stay sharp.
  final double? typeChangeBlurHalfWidthMs;

  /// Per-project cursor filters (end-freeze, despike, state-debounce).
  /// Applied to every sub-frame sample lookup so the smear matches the
  /// filtered path the user is editing against.
  final CursorPostProcess postProcess;

  /// Click-feedback ring style. The ripple is drawn UNDER the cursor
  /// stamps so the cursor renders on top of the expanding ring, and it
  /// is anchored to the cursor position **at the click moment** — not
  /// to the live cursor — so the ring reads as "a click happened here"
  /// rather than "the cursor is dragging a ring around". The
  /// pre-accumulation playback path uses [CursorOverlayPainter] which
  /// already paints this same ring; surfacing it here keeps the live
  /// preview consistent regardless of which blur mode is active.
  final CursorClickEffect clickEffect;

  /// Spring tuning for the press-pulse — drives how fast the cursor
  /// glyph shrinks on click and how it bounces back on release. Each
  /// sub-frame stamp gets its own pulse multiplier sampled from this
  /// spring at the stamp's recorded timestamp, so the press animation
  /// plays through the motion trail rather than being lost the moment
  /// the recording sees a click. Defaults to [ClickSpring.snappy].
  final ClickSpring clickSpring;

  @override
  void paint(Canvas canvas, Size size) {
    if (cursorRecording.positions.isEmpty) return;
    if (sampleCount <= 0) return;

    final mapping = videoRect ?? (Offset.zero & size);
    final scaleX = mapping.width / videoSize.width;
    final scaleY = mapping.height / videoSize.height;
    final pxDiameter =
        kCursorBaseDiameter * sizeMultiplier * (scaleX + scaleY) / 2;

    // Buffer is sized to leave ~2 cursor-widths of padding around the
    // glyph (halo / shadow / any overshoot from state glyphs).
    final spriteBufferSize = (pxDiameter * 4).ceil().toDouble();
    final spriteCenter = Offset(spriteBufferSize / 2, spriteBufferSize / 2);
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final spritePxSize = (spriteBufferSize * dpr).ceil();

    // Sprite cache is keyed by state too, so a single paint can stamp
    // multiple types (arrow, I-beam, hand) without re-baking when the
    // cursor type changes inside the accumulation window. We touch each
    // distinct state we end up using; the cache evicts unused entries.
    ui.Image spriteFor(CursorState state) => _spriteCache.get(
          pxDiameter: pxDiameter,
          dpr: dpr,
          style: style,
          state: state,
          bufferPx: spritePxSize,
          bufferLogical: spriteBufferSize,
          spriteCenter: spriteCenter,
        );

    final exposureMicros = (exposureMs * 1000).round();
    // Sub-frame interval. sampleCount=1 → just the current frame.
    final dtMicros =
        sampleCount <= 1 ? 0 : (exposureMicros ~/ (sampleCount - 1));
    // Each stamp contributes 1/N to the accumulated alpha via BlendMode.plus
    // inside an isolated saveLayer (see below). A stationary cursor's N
    // stamps land at the same pixel and add to alpha = 1.0 exactly. A
    // moving cursor smears its stamps along the recorded path, so each
    // pixel only accumulates the stamps that landed there — producing a
    // trail that fades naturally at the ends. Default srcOver compositing
    // would converge to alpha ≈ 1−(1−1/N)^N ≈ 0.64 for a stationary
    // cursor (never reaches 1), which read as a permanently translucent
    // cursor at large sizes.
    final alphaPerStamp = 1.0 / sampleCount;

    final srcRect = Rect.fromLTWH(
      0,
      0,
      spritePxSize.toDouble(),
      spritePxSize.toDouble(),
    );

    // Camera-aware sub-frame positioning is active only when all of
    // currentFocalVideo / focalAt / scaleAt are provided. Otherwise
    // we fall back to the legacy "stamp at the cursor's raw video
    // position" behaviour, which is correct when there's no zoom
    // transform applied above the painter.
    final cameraAware = currentFocalVideo != null &&
        focalAt != null &&
        scaleAt != null &&
        currentScale > 0;
    final fNow = currentFocalVideo ?? Offset.zero;
    final sNow = currentScale;

    // Collect cursor-type-change boundaries within the accumulation
    // window plus a half-width margin on each side. A "boundary" is the
    // timestamp of any recorded sample whose state differs from its
    // predecessor. Stamps near a boundary get a Gaussian blur that
    // ramps to 0 at ±halfWidth, producing the "vanish into a soft glow
    // and re-condense as the new type" feel.
    final halfWidthMs = typeChangeBlurHalfWidthMs ?? exposureMs;
    final halfWidthMicros = (halfWidthMs * 1000).round();
    final windowStartMicros =
        position.inMicroseconds - exposureMicros - halfWidthMicros;
    final windowEndMicros = position.inMicroseconds + halfWidthMicros;
    final changeBoundariesMicros = <int>[];
    if (typeChangeBlurSigmaPx > 0 && halfWidthMicros > 0) {
      final samples = cursorRecording.positions;
      for (var i = 1; i < samples.length; i++) {
        final ts = samples[i].timestampMicros;
        if (ts < windowStartMicros) continue;
        if (ts > windowEndMicros) break;
        if (samples[i].state != samples[i - 1].state) {
          // When state-debounce is active, only honor boundaries where
          // the *filtered* state actually changes — phantom boundaries
          // from sub-window flaps would otherwise blur the cursor on
          // transitions the user told us to ignore.
          if (postProcess.optimizeChanges) {
            final before = cursorAtFiltered(
              cursorRecording,
              Duration(microseconds: ts - 1),
              postProcess,
            );
            final after = cursorAtFiltered(
              cursorRecording,
              Duration(microseconds: ts + 1),
              postProcess,
            );
            if (before != null && after != null &&
                before.state == after.state) {
              continue;
            }
          }
          changeBoundariesMicros.add(ts);
        }
      }
    }

    // Click ripple — drawn BEFORE the accumulation saveLayer so it
    // lives on the main canvas (normal srcOver, full alpha) and the
    // cursor stamps render on top. The ripple is anchored to the
    // cursor position at the click moment; live cursor motion does
    // not drag it around.
    if (clickEffect != CursorClickEffect.none) {
      final clickEvent = mostRecentClickEvent(
        cursorRecording,
        position.inMicroseconds,
      );
      if (clickEvent != null) {
        final dt = position.inMicroseconds - clickEvent.timestampMicros;
        if (dt >= 0) {
          final ripplePos = Offset(
            mapping.left + clickEvent.screenPos.dx * scaleX,
            mapping.top + clickEvent.screenPos.dy * scaleY,
          );
          paintCursorRipple(
            canvas,
            position: ripplePos,
            baseDiameter: pxDiameter,
            microsSinceClick: dt,
            effect: clickEffect,
          );
        }
      }
    }

    // Isolate the stamp accumulation onto its own offscreen layer.
    // Inside, stamps are composited additively (plus) so 1/N alphas
    // sum to 1.0. Outside, the finished layer composites onto the
    // scene with normal srcOver — the cursor doesn't brighten the
    // wallpaper around it the way a raw plus blend would.
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );

    for (var i = 0; i < sampleCount; i++) {
      final t = position.inMicroseconds - i * dtMicros;
      if (t < 0) continue;
      final sample = cursorAtFiltered(
        cursorRecording,
        Duration(microseconds: t),
        postProcess,
      );
      if (sample == null) continue;

      // Per-sub-frame state — this is what makes arrow→I-beam
      // crossfade for free: stamps before the change use the OLD
      // sprite, stamps after use the NEW one, and they sum via plus
      // blending inside the saveLayer.
      final stampState = sample.state;
      final stampSprite = spriteFor(stampState);

      // Per-sub-frame blur σ. Quadratic bump centered on the nearest
      // type-change boundary inside the window: σ = σMax * (1 - d/h)²
      // where d = |t - tChange|, h = halfWidthMicros. 0 when there is
      // no boundary within reach, σMax when t exactly hits the change.
      double sigma = 0.0;
      if (changeBoundariesMicros.isNotEmpty && typeChangeBlurSigmaPx > 0) {
        var minDist = halfWidthMicros + 1;
        for (final tc in changeBoundariesMicros) {
          final d = (t - tc).abs();
          if (d < minDist) minDist = d;
        }
        if (minDist <= halfWidthMicros) {
          final n = 1.0 - minDist / halfWidthMicros;
          sigma = typeChangeBlurSigmaPx * n * n;
        }
      }

      // Where should this stamp land in the painter's widget coords?
      // - Legacy: cursor's raw video position. Correct when nothing
      //   above the painter is transforming.
      // - Camera-aware: solve for the widget_pos that, after the
      //   parent's current Transform (alignment=center, scale=sNow,
      //   focal=fNow), produces the viewport position where the
      //   cursor *visually* was at sub-frame time t — given the
      //   camera state at t. Result:
      //     widget_pos = fNow + (S_i / sNow) * (cursor_i - F_i)
      Offset cursorVideo;
      if (cameraAware) {
        final ti = Duration(microseconds: t);
        final fI = focalAt!(ti);
        final sI = scaleAt!(ti);
        final s = sNow == 0 ? 1.0 : sI / sNow;
        cursorVideo = fNow +
            Offset(
              (sample.x - fI.dx) * s,
              (sample.y - fI.dy) * s,
            );
      } else {
        cursorVideo = Offset(sample.x.toDouble(), sample.y.toDouble());
      }

      // Map video-coord into painter coords. When videoRect is the
      // full canvas (legacy callers), mapping.topLeft is Offset.zero
      // and this collapses to the prior `cursorVideo * scale` form.
      // When the canvas is larger (e.g. totalSize with effPadding
      // around the video), the offset shifts the stamp onto the
      // correct position over the wallpaper padding.
      final widgetPos = Offset(
        mapping.left + cursorVideo.dx * scaleX,
        mapping.top + cursorVideo.dy * scaleY,
      );
      final stampPaint = Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: alphaPerStamp)
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.high;
      if (sigma > 0.01) {
        stampPaint.imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
        );
      }

      // Press-pulse: cached sprites are baked at base diameter (pulse =
      // 1.0) since the cache key omits press-pulse phase — including
      // it would miss every frame and re-rasterize the sprite, defeating
      // the cache. Instead, apply the per-stamp pulse as a scale on the
      // destination rect. Each sub-frame sample's t looks up the click
      // state at that exact moment, so the press animation actually
      // plays through the motion trail (stamps recorded before the
      // click stay full-size; stamps after it shrink). Bug #4 from the
      // 2026-05 architecture review.
      final stampDt = microsSinceClick(cursorRecording, t);
      final stampDtRelease = microsSinceRelease(cursorRecording, t);
      final pulse = pressPulseMultiplier(
        microsSinceClick: stampDt,
        microsSinceRelease: stampDtRelease,
        spring: clickSpring,
      );
      final scaledBuffer = spriteBufferSize * pulse;
      final pulseInset = (spriteBufferSize - scaledBuffer) / 2;
      canvas.drawImageRect(
        stampSprite,
        srcRect,
        Rect.fromLTWH(
          widgetPos.dx - spriteCenter.dx + pulseInset,
          widgetPos.dy - spriteCenter.dy + pulseInset,
          scaledBuffer,
          scaledBuffer,
        ),
        stampPaint,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AccumulationCursorPainter old) {
    return old.cursorRecording != cursorRecording ||
        old.position != position ||
        old.videoSize != videoSize ||
        old.exposureMs != exposureMs ||
        old.sampleCount != sampleCount ||
        old.sizeMultiplier != sizeMultiplier ||
        old.style != style ||
        old.cursorState != cursorState ||
        old.devicePixelRatio != devicePixelRatio ||
        old.currentFocalVideo != currentFocalVideo ||
        old.currentScale != currentScale ||
        old.focalAt != focalAt ||
        old.scaleAt != scaleAt ||
        old.videoRect != videoRect ||
        old.typeChangeBlurSigmaPx != typeChangeBlurSigmaPx ||
        old.typeChangeBlurHalfWidthMs != typeChangeBlurHalfWidthMs ||
        old.postProcess != postProcess ||
        old.clickEffect != clickEffect ||
        old.clickSpring != clickSpring;
  }
}

/// Process-wide LRU cache for baked cursor sprites. Each sprite shape
/// is a pure function of (diameter, dpr, style, state) — none of which
/// change frame-to-frame in typical playback — so we bake once and
/// reuse. A single paint can request *multiple* states (during a type
/// crossfade, the accumulation window holds both the OLD and NEW
/// sprites simultaneously), so this is a small map rather than a
/// single slot. Without the cache the painter would call
/// `picture.toImageSync` on every video tick, stalling the UI thread.
class _SpriteCache {
  static const int _capacity = 6;
  final Map<_SpriteKey, ui.Image> _entries =
      <_SpriteKey, ui.Image>{}; // insertion-order LRU

  ui.Image get({
    required double pxDiameter,
    required double dpr,
    required CursorStyle style,
    required CursorState state,
    required int bufferPx,
    required double bufferLogical,
    required Offset spriteCenter,
  }) {
    final key = _SpriteKey(pxDiameter, dpr, style, state, bufferPx);
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
    paintCursorGlyphWithPulse(
      c,
      position: spriteCenter,
      baseDiameter: pxDiameter,
      style: style,
      microsSinceClick: null,
      state: state,
    );
    final pic = recorder.endRecording();
    final image = pic.toImageSync(bufferPx, bufferPx);
    pic.dispose();
    _entries[key] = image;
    while (_entries.length > _capacity) {
      final first = _entries.keys.first;
      _entries.remove(first)?.dispose();
    }
    return image;
  }
}

@immutable
class _SpriteKey {
  const _SpriteKey(
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
      other is _SpriteKey &&
      other.pxDiameter == pxDiameter &&
      other.dpr == dpr &&
      other.style == style &&
      other.state == state &&
      other.bufferPx == bufferPx;

  @override
  int get hashCode => Object.hash(pxDiameter, dpr, style, state, bufferPx);
}

final _spriteCache = _SpriteCache();

/// Which cursor motion-blur pipeline to use.
enum CursorBlurMode {
  /// Production path: chord-stretched single sprite produced by the
  /// motion-blur fragment program. Fast but the smear runs in a
  /// straight line along the chord regardless of the actual cursor
  /// path, and the velocity gate is a brittle smoothstep ramp.
  shader,

  /// Cinematic accumulation: cursor sprite stamped at sub-frame
  /// positions across the exposure window with 1/N alpha each.
  /// Smear follows the actual recorded path; no velocity ramps,
  /// no chord extrapolation.
  accumulation,
}
