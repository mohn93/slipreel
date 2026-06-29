@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Records every `saveLayer` paint so we can detect the blurred drop-shadow
/// layer. All other Canvas methods no-op so `paint()` runs to completion.
class _SaveLayerSpyCanvas implements ui.Canvas {
  final List<Paint> saveLayerPaints = [];

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    saveLayerPaints.add(paint);
  }

  int get blurredLayerCount =>
      saveLayerPaints.where((p) => p.imageFilter != null).length;

  @override
  noSuchMethod(Invocation invocation) => null;
}

CursorRecording _staticRecording() {
  final r = CursorRecording();
  for (var t = 0; t <= 120; t += 5) {
    r.addPosition(CursorPosition(
      x: 50,
      y: 50,
      timestampMicros: t * 1000,
      isClicked: false,
    ));
  }
  return r;
}

AccumulationCursorPainter _painter({required double cursorShadow}) =>
    AccumulationCursorPainter(
      cursorRecording: _staticRecording(),
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
    _painter(cursorShadow: 0).paint(canvas, size);
    expect(canvas.blurredLayerCount, 0);
  });

  test('cursorShadow > 0 draws a blurred drop-shadow layer under the cursor',
      () {
    final canvas = _SaveLayerSpyCanvas();
    _painter(cursorShadow: 0.6).paint(canvas, size);
    // paintCursorShadow pushes exactly one saveLayer carrying a blur
    // ImageFilter; the accumulation layer itself uses a plain Paint().
    expect(canvas.blurredLayerCount, greaterThanOrEqualTo(1));
  });
}
