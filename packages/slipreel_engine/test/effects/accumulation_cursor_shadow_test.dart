@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Records every `saveLayer(bounds, paint)` so we can detect the blurred
/// drop-shadow layer and where it was centred. All other Canvas methods
/// no-op so `paint()` runs to completion.
class _SaveLayerSpyCanvas implements ui.Canvas {
  final List<({Rect? bounds, Paint paint})> saveLayers = [];

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    saveLayers.add((bounds: bounds, paint: paint));
  }

  /// The blurred layer is the drop shadow (the accumulation layer uses a
  /// plain Paint with no imageFilter).
  Iterable<({Rect? bounds, Paint paint})> get blurredLayers =>
      saveLayers.where((e) => e.paint.imageFilter != null);

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
      cursorShadow: cursorShadow,
    );

void main() {
  const size = Size(200, 200);

  test('cursorShadow == 0 draws no blurred shadow layer', () {
    final canvas = _SaveLayerSpyCanvas();
    _painter(_staticRecording(), cursorShadow: 0).paint(canvas, size);
    expect(canvas.blurredLayers, isEmpty);
  });

  test('cursorShadow > 0 draws exactly one blurred drop-shadow layer', () {
    final canvas = _SaveLayerSpyCanvas();
    _painter(_staticRecording(), cursorShadow: 0.6).paint(canvas, size);
    expect(canvas.blurredLayers.length, 1);
  });

  test(
      'shadow is centred on the AVERAGE of the accumulation window, not the '
      'instantaneous current sample (anti-shiver)', () {
    final canvas = _SaveLayerSpyCanvas();
    // x ramps with time; current sample (t=100ms) is x=100, but the window
    // [~60..100]ms averages to ~80. A single-sample shadow would sit at 100.
    _painter(_rampRecording(), cursorShadow: 0.6).paint(canvas, size);
    final shadow = canvas.blurredLayers.single;
    final cx = shadow.bounds!.center.dx;
    // Mapping is identity (videoRect == full canvas, scaleX == 1), so the
    // shadow x equals the averaged cursor x. Must be the window average
    // (~80), clearly NOT the current sample (100).
    expect(cx, lessThan(95),
        reason: 'shadow should be averaged, not pinned to the current sample');
    expect(cx, closeTo(80, 10));
  });
}
