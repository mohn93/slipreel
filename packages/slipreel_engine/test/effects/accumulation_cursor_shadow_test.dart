@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Records the destination rect of every `drawImageRect`. The cursor shadow
/// is a baked image stamped on the MAIN canvas BEFORE the body stamps, so it
/// is the FIRST drawImageRect; the body's accumulation stamps follow. All
/// other Canvas methods no-op so `paint()` runs to completion.
class _DrawImageRectSpyCanvas implements ui.Canvas {
  final List<Rect> dstRects = [];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    dstRects.add(dst);
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Stationary cursor at (50,50) over the whole window.
CursorRecording _staticRecording() {
  final r = CursorRecording();
  for (var t = 0; t <= 120; t += 1) {
    r.addPosition(
        CursorPosition(x: 50, y: 50, timestampMicros: t * 1000, isClicked: false));
  }
  return r;
}

/// Cursor whose x == timestamp in ms, so the average x over the
/// accumulation window is well below the current (latest) x.
CursorRecording _rampRecording() {
  final r = CursorRecording();
  for (var t = 0; t <= 120; t += 1) {
    r.addPosition(CursorPosition(
        x: t.toDouble(), y: 50, timestampMicros: t * 1000, isClicked: false));
  }
  return r;
}

AccumulationCursorPainter _painter(
        CursorRecording rec, {required double cursorShadow}) =>
    AccumulationCursorPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      videoSize: const Size(200, 200),
      exposureMs: 40,
      sampleCount: 8,
      sizeMultiplier: 1.0,
      devicePixelRatio: 1.0,
      clickEffect: CursorClickEffect.none,
      cursorShadow: cursorShadow,
    );

void main() {
  const size = Size(200, 200);

  test('cursorShadow > 0 adds exactly one stamp (the shadow) over shadow == 0',
      () {
    final off = _DrawImageRectSpyCanvas();
    _painter(_staticRecording(), cursorShadow: 0).paint(off, size);

    final on = _DrawImageRectSpyCanvas();
    _painter(_staticRecording(), cursorShadow: 0.6).paint(on, size);

    expect(off.dstRects, isNotEmpty, reason: 'body stamps must be drawn');
    expect(on.dstRects.length, off.dstRects.length + 1,
        reason: 'the shadow is one extra stamp on top of the body stamps');
  });

  test('shadow is the first stamp and is centred on the window AVERAGE, '
      'not the instantaneous current sample (anti-shiver)', () {
    final on = _DrawImageRectSpyCanvas();
    // x ramps with time; current sample (t=100ms) is x=100, but the window
    // [~60..100]ms averages to ~80. A single-sample shadow would sit at 100.
    _painter(_rampRecording(), cursorShadow: 0.6).paint(on, size);

    // Mapping is identity (videoRect == full canvas, scaleX == 1); the
    // shadow is drawn first, centred at the averaged cursor x (~80).
    final shadowCx = on.dstRects.first.center.dx;
    expect(shadowCx, lessThan(95),
        reason: 'shadow must be averaged, not pinned to the current sample');
    expect(shadowCx, closeTo(80, 12));
  });
}
