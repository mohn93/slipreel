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

  @override
  void paint(Canvas canvas, Size size) {
    if (cursorRecording.positions.isEmpty) return;
    if (sampleCount <= 0) return;

    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;
    final pxDiameter =
        kCursorBaseDiameter * sizeMultiplier * (scaleX + scaleY) / 2;

    // Bake the cursor sprite once per paint. Buffer is sized to leave
    // ~2 cursor-widths of padding around the glyph (halo / shadow /
    // any overshoot from state glyphs).
    final spriteBufferSize = (pxDiameter * 4).ceil().toDouble();
    final spriteCenter = Offset(spriteBufferSize / 2, spriteBufferSize / 2);
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final spritePxSize = (spriteBufferSize * dpr).ceil();

    final recorder = ui.PictureRecorder();
    final spriteCanvas = Canvas(
      recorder,
      Rect.fromLTWH(
        0,
        0,
        spritePxSize.toDouble(),
        spritePxSize.toDouble(),
      ),
    );
    spriteCanvas.scale(dpr);
    paintCursorGlyphWithPulse(
      spriteCanvas,
      position: spriteCenter,
      baseDiameter: pxDiameter,
      style: style,
      microsSinceClick: null,
      state: cursorState,
    );
    final picture = recorder.endRecording();
    final spriteImage = picture.toImageSync(spritePxSize, spritePxSize);
    picture.dispose();

    try {
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

      for (var i = 0; i < sampleCount; i++) {
        final t = position.inMicroseconds - i * dtMicros;
        if (t < 0) continue;
        final sample = cursorAt(cursorRecording, Duration(microseconds: t));
        if (sample == null) continue;

        final widgetPos = Offset(sample.x * scaleX, sample.y * scaleY);
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
    } finally {
      spriteImage.dispose();
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
        old.devicePixelRatio != devicePixelRatio;
  }
}
