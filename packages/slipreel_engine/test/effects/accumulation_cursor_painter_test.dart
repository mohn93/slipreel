import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Recording canvas that captures the destination rect of every
/// drawImageRect call. Other methods no-op so paint() runs through.
class _StampSizingCanvas implements ui.Canvas {
  final List<Rect> stampDstRects = [];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    stampDstRects.add(dst);
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

CursorRecording _staticRecording({required bool withClick}) {
  // Stationary cursor at (50, 50) for the entire window. The painter's
  // accumulation window is 40 ms by default and ends at the painter's
  // `position`. Samples cover that whole window + a margin so the
  // sub-frame lookups always hit data.
  final r = CursorRecording();
  for (var t = 0; t <= 120; t += 5) {
    final clicked = withClick && t >= 60; // click fires at t = 60ms
    r.addPosition(
      CursorPosition(
        x: 50,
        y: 50,
        timestampMicros: t * 1000,
        isClicked: clicked,
      ),
    );
  }
  return r;
}

CursorRecording _jitterRecording() {
  final r = CursorRecording();
  for (var i = 0; i <= 120; i++) {
    r.addPosition(
      CursorPosition(
        x: i * 4.0,
        y: 100.0 + (i.isEven ? 12.0 : -12.0),
        timestampMicros: i * 16667,
        isClicked: false,
      ),
    );
  }
  return r;
}

void main() {
  group('AccumulationCursorPainter press-pulse', () {
    test('with a click event mid-window, at least one stamp is smaller than '
        'the equivalent stamp from a recording with no click events '
        '(bug #4: press-pulse must reach the cached sprite path)', () {
      const painterSize = Size(200, 200);

      final noClickPainter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: false),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        exposureMs: 40,
        sampleCount: 8,
        sizeMultiplier: 1.0,
        devicePixelRatio: 1.0,
      );

      final clickPainter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: true),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        exposureMs: 40,
        sampleCount: 8,
        sizeMultiplier: 1.0,
        devicePixelRatio: 1.0,
      );

      final noClickCanvas = _StampSizingCanvas();
      noClickPainter.paint(noClickCanvas, painterSize);

      final clickCanvas = _StampSizingCanvas();
      clickPainter.paint(clickCanvas, painterSize);

      expect(
        noClickCanvas.stampDstRects,
        isNotEmpty,
        reason: 'Painter must draw stamps for the trail',
      );
      expect(clickCanvas.stampDstRects, isNotEmpty);

      // Without a click, every stamp uses the full sprite buffer size.
      final baselineWidth = noClickCanvas.stampDstRects.first.width;
      for (final rect in noClickCanvas.stampDstRects) {
        expect(
          rect.width,
          closeTo(baselineWidth, 0.001),
          reason: 'No click → no press-pulse → all stamps at baseline size',
        );
      }

      // With a click at t=60ms and painter position at t=100ms, the
      // sub-frame stamps after t=60ms see microsSinceClick > 0 and
      // must shrink. At least one stamp must come out smaller than
      // the no-click baseline.
      final smallestShrunken = clickCanvas.stampDstRects
          .map((r) => r.width)
          .reduce((a, b) => a < b ? a : b);
      expect(
        smallestShrunken,
        lessThan(baselineWidth),
        reason:
            'After a click, at least the post-click sub-frame stamps '
            'must scale below the no-click baseline',
      );
    });

    test('every stamp stays at baseline size when no click ever happens '
        '(regression guard: no spurious shrink)', () {
      const painterSize = Size(200, 200);
      final painter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: false),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        exposureMs: 40,
        sampleCount: 8,
        sizeMultiplier: 1.0,
        devicePixelRatio: 1.0,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(canvas.stampDstRects, isNotEmpty);
      final widths = canvas.stampDstRects.map((r) => r.width).toSet();
      expect(
        widths.length,
        1,
        reason:
            'All stamp dst widths should be identical when no '
            'click event triggers the press-pulse',
      );
    });
  });

  group('AccumulationCursorPainter smoothed path', () {
    test('zero exposure lands every stamp on the spring-smoothed cursor', () {
      const painterSize = Size(600, 300);
      const smoothed = Offset(321.25, 88.5);
      final painter = AccumulationCursorPainter(
        cursorRecording: _jitterRecording(),
        position: const Duration(milliseconds: 700),
        videoSize: painterSize,
        currentScreenPos: smoothed,
        pathSmoothingSigma: const Duration(milliseconds: 80),
        exposureMs: 0,
        sampleCount: 8,
        devicePixelRatio: 1,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(canvas.stampDstRects, hasLength(8));
      for (final stamp in canvas.stampDstRects) {
        expect(stamp.center.dx, closeTo(smoothed.dx, 1e-6));
        expect(stamp.center.dy, closeTo(smoothed.dy, 1e-6));
      }
    });

    test('sub-frame stamps sample the geometrically averaged line', () {
      const painterSize = Size(600, 300);
      final painter = AccumulationCursorPainter(
        cursorRecording: _jitterRecording(),
        position: const Duration(milliseconds: 700),
        videoSize: painterSize,
        pathSmoothingSigma: const Duration(milliseconds: 80),
        exposureMs: 0,
        sampleCount: 1,
        devicePixelRatio: 1,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(canvas.stampDstRects, hasLength(1));
      expect(
        (canvas.stampDstRects.single.center.dy - 100).abs(),
        lessThan(4.8),
        reason:
            'the production painter must not reproduce the raw ±12px '
            'capture zigzag',
      );
    });
  });
}
