import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';

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
  });

  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final double exposureMs;
  final int sampleCount;
  final double sizeMultiplier;
  final CursorStyle style;
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

  @override
  void paint(Canvas canvas, Size size) {
    if (cursorRecording.positions.isEmpty) return;
    if (sampleCount <= 0) return;

    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;
    final pxDiameter =
        kCursorBaseDiameter * sizeMultiplier * (scaleX + scaleY) / 2;

    // Buffer is sized to leave ~2 cursor-widths of padding around the
    // glyph (halo / shadow / any overshoot from state glyphs).
    final spriteBufferSize = (pxDiameter * 4).ceil().toDouble();
    final spriteCenter = Offset(spriteBufferSize / 2, spriteBufferSize / 2);
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final spritePxSize = (spriteBufferSize * dpr).ceil();

    final spriteImage = _spriteCache.get(
      pxDiameter: pxDiameter,
      dpr: dpr,
      style: style,
      state: cursorState,
      bufferPx: spritePxSize,
      bufferLogical: spriteBufferSize,
      spriteCenter: spriteCenter,
    );

    final exposureMicros = (exposureMs * 1000).round();
    // Sub-frame interval. sampleCount=1 → just the current frame.
    final dtMicros =
        sampleCount <= 1 ? 0 : (exposureMicros ~/ (sampleCount - 1));
    // Even alpha-weighted integration: every substep contributes
    // 1/N. A stationary cursor's stamps stack and sum to alpha = 1.
    // A moving cursor smears with peak per-position alpha = 1/N.
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

    for (var i = 0; i < sampleCount; i++) {
      final t = position.inMicroseconds - i * dtMicros;
      if (t < 0) continue;
      final sample = cursorAt(cursorRecording, Duration(microseconds: t));
      if (sample == null) continue;

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

      final widgetPos =
          Offset(cursorVideo.dx * scaleX, cursorVideo.dy * scaleY);
      canvas.drawImageRect(
        spriteImage,
        srcRect,
        Rect.fromLTWH(
          widgetPos.dx - spriteCenter.dx,
          widgetPos.dy - spriteCenter.dy,
          spriteBufferSize,
          spriteBufferSize,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: alphaPerStamp)
          ..filterQuality = FilterQuality.high,
      );
    }
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
        old.scaleAt != scaleAt;
  }
}

/// Process-wide singleton cache for the baked cursor sprite. The sprite
/// shape is a pure function of (diameter, dpr, style, state) — none of
/// which change frame-to-frame in typical playback — so we bake once
/// and reuse for every paint until one of those changes. Without this
/// cache the painter was calling `picture.toImageSync` on every video
/// tick (60 Hz), which stalls the UI thread.
class _SpriteCache {
  ui.Image? _image;
  double? _diameter;
  double? _dpr;
  CursorStyle? _style;
  CursorState? _state;
  int? _bufferPx;

  ui.Image get({
    required double pxDiameter,
    required double dpr,
    required CursorStyle style,
    required CursorState state,
    required int bufferPx,
    required double bufferLogical,
    required Offset spriteCenter,
  }) {
    final hit = _image != null &&
        _diameter == pxDiameter &&
        _dpr == dpr &&
        _style == style &&
        _state == state &&
        _bufferPx == bufferPx;
    if (hit) return _image!;
    _image?.dispose();
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
    _image = pic.toImageSync(bufferPx, bufferPx);
    pic.dispose();
    _diameter = pxDiameter;
    _dpr = dpr;
    _style = style;
    _state = state;
    _bufferPx = bufferPx;
    return _image!;
  }
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
