import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Recording canvas that captures the destination rect of every
/// drawImageRect call. Other methods no-op so paint() runs through.
class _StampSizingCanvas implements ui.Canvas {
  final List<Rect> stampDstRects = [];
  final List<bool> stampHasImageFilter = [];
  final List<Rect?> saveLayerBounds = [];
  final List<double> saveLayerAlphas = [];
  final List<bool> saveLayerHasImageFilter = [];
  final List<Offset> scales = [];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    stampDstRects.add(dst);
    stampHasImageFilter.add(paint.imageFilter != null);
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    saveLayerBounds.add(bounds);
    saveLayerAlphas.add(paint.color.a);
    saveLayerHasImageFilter.add(paint.imageFilter != null);
  }

  @override
  void scale(double sx, [double? sy]) {
    scales.add(Offset(sx, sy ?? sx));
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
  group('AccumulationCursorPainter zero-exposure fast path', () {
    test('zero exposure draws exactly ONE stamp regardless of sampleCount', () {
      // With the blur slider at 0 the exposure window collapses: all N
      // sub-frame stamps land on the same visual time, same sample,
      // same position. Drawing N coincident 1/N-alpha stamps through
      // the additive layer is 32x the necessary work AND accumulates
      // up to N/2 levels of 8-bit rounding error versus a single stamp
      // at alpha 1.0.
      const painterSize = Size(200, 200);
      final painter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: false),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        exposureMs: 0,
        sampleCount: 32,
        sizeMultiplier: 1.0,
        devicePixelRatio: 1.0,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(
        canvas.stampDstRects.length,
        1,
        reason:
            'zero exposure must degenerate to a single sharp '
            'stamp, not N coincident ones',
      );
    });

    test('sampleCount 1 also draws exactly one stamp', () {
      const painterSize = Size(200, 200);
      final painter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: false),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        exposureMs: 40,
        sampleCount: 1,
        sizeMultiplier: 1.0,
        devicePixelRatio: 1.0,
      );
      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);
      expect(canvas.stampDstRects.length, 1);
    });
  });

  group('AccumulationCursorPainter layer bounds', () {
    test('idle transition fades and blurs the whole cursor composition', () {
      const painterSize = Size(200, 200);
      final painter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: false),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        exposureMs: 0,
        sampleCount: 1,
        visibilityReveal: 0.5,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(canvas.saveLayerAlphas.first, closeTo(0.5, 0.001));
      expect(canvas.saveLayerHasImageFilter.first, isTrue);
      expect(canvas.scales.single.dx, closeTo(1.14, 0.001));
      expect(canvas.scales.single.dy, closeTo(1.14, 0.001));
      expect(canvas.stampDstRects, isNotEmpty);
    });

    test('fully hidden idle cursor skips painting', () {
      const painterSize = Size(200, 200);
      final painter = AccumulationCursorPainter(
        cursorRecording: _staticRecording(withClick: false),
        position: const Duration(milliseconds: 100),
        videoSize: painterSize,
        visibilityReveal: 0,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(canvas.saveLayerBounds, isEmpty);
      expect(canvas.stampDstRects, isEmpty);
    });

    test('accumulation saveLayer covers the full canvas (measured-faster '
        'than trail bounds under the software rasterizer)', () {
      // A trail-bounded layer was tried and benchmarked ~2x slower
      // end-to-end (see the comment at the saveLayer call site). This
      // pins the deliberate full-canvas choice so a future
      // "optimization" re-attempt starts from the measurement, not the
      // intuition.
      const painterSize = Size(2000, 2000);
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

      expect(canvas.saveLayerBounds, hasLength(1));
      expect(
        canvas.saveLayerBounds.single,
        const Rect.fromLTWH(0, 0, 2000, 2000),
      );
    });
  });

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

      // Zero exposure collapses to a single stamp (fast path) — the
      // point of this test is WHERE it lands, not how many there are.
      expect(canvas.stampDstRects, hasLength(1));
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

    test('historical stamps use actual spring history, not current lag', () {
      const painterSize = Size(600, 300);
      final painter = AccumulationCursorPainter(
        cursorRecording: _jitterRecording(),
        position: const Duration(milliseconds: 700),
        videoSize: painterSize,
        currentScreenPos: const Offset(320, 100),
        screenPositionAt: (t) => t == const Duration(milliseconds: 600)
            ? const Offset(140, 90)
            : null,
        exposureMs: 100,
        sampleCount: 2,
        devicePixelRatio: 1,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(canvas.stampDstRects, hasLength(2));
      expect(canvas.stampDstRects[0].center, const Offset(320, 100));
      expect(canvas.stampDstRects[1].center, const Offset(140, 90));
    });

    test('cursor delay shifts the press pulse with the path', () {
      const painterSize = Size(200, 200);
      final rec = _staticRecording(withClick: true); // press at 60ms

      List<double> widthsAt(int visualMs) {
        final painter = AccumulationCursorPainter(
          cursorRecording: rec,
          position: Duration(milliseconds: visualMs),
          videoSize: painterSize,
          cursorDelay: const Duration(milliseconds: 50),
          exposureMs: 0,
          sampleCount: 2,
          devicePixelRatio: 1,
        );
        final canvas = _StampSizingCanvas();
        painter.paint(canvas, painterSize);
        return canvas.stampDstRects.map((r) => r.width).toList();
      }

      final beforeDelayedPress = widthsAt(100); // query=50ms
      final afterDelayedPress = widthsAt(120); // query=70ms
      expect(beforeDelayedPress.toSet(), hasLength(1));
      expect(
        afterDelayedPress.reduce((a, b) => a < b ? a : b),
        lessThan(beforeDelayedPress.first),
      );
    });

    test('exposure is wall-time scaled and clipped at a hard cut', () {
      const painterSize = Size(600, 300);
      final queried = <Duration>[];
      final activeClip = ClipSlice(
        cutStart: const Duration(milliseconds: 550),
        cutEnd: const Duration(seconds: 2),
        playbackSpeed: 2,
      );
      final painter = AccumulationCursorPainter(
        cursorRecording: _jitterRecording(),
        position: const Duration(milliseconds: 700),
        videoSize: painterSize,
        activeClip: activeClip,
        clips: [activeClip],
        screenPositionAt: (t) {
          queried.add(t);
          return const Offset(100, 100);
        },
        exposureMs: 100,
        sampleCount: 2,
        devicePixelRatio: 1,
      );

      final canvas = _StampSizingCanvas();
      painter.paint(canvas, painterSize);

      expect(queried, [
        const Duration(milliseconds: 700),
        const Duration(milliseconds: 550),
      ]);
      expect(canvas.stampDstRects, hasLength(2));
    });

    test('exposure traverses a contiguous mixed-speed boundary', () {
      const painterSize = Size(600, 300);
      final queried = <Duration>[];
      final clips = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 600),
          playbackSpeed: 1,
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 600),
          cutEnd: const Duration(seconds: 2),
          playbackSpeed: 2,
        ),
      ];
      final painter = AccumulationCursorPainter(
        cursorRecording: _jitterRecording(),
        position: const Duration(milliseconds: 650),
        videoSize: painterSize,
        activeClip: clips.last,
        clips: clips,
        screenPositionAt: (t) {
          queried.add(t);
          return const Offset(100, 100);
        },
        exposureMs: 100,
        sampleCount: 2,
        devicePixelRatio: 1,
      );

      painter.paint(_StampSizingCanvas(), painterSize);

      expect(queried.first, const Duration(milliseconds: 650));
      expect(queried.last.inMicroseconds, 525000);
    });

    test('delay and smoothing stay continuous across an ordinary split', () {
      const painterSize = Size(600, 300);
      final recording = _jitterRecording();
      final split = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 600),
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 600),
          cutEnd: const Duration(seconds: 2),
        ),
      ];
      final whole = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 2)),
      ];

      Offset centerFor(List<ClipSlice> clips) {
        final painter = AccumulationCursorPainter(
          cursorRecording: recording,
          position: const Duration(milliseconds: 600),
          videoSize: painterSize,
          clips: clips,
          activeClip: clips.last,
          cursorDelay: const Duration(milliseconds: 80),
          pathSmoothingSigma: const Duration(milliseconds: 80),
          exposureMs: 0,
          sampleCount: 1,
          devicePixelRatio: 1,
        );
        final canvas = _StampSizingCanvas();
        painter.paint(canvas, painterSize);
        return canvas.stampDstRects.single.center;
      }

      expect((centerFor(split) - centerFor(whole)).distance, lessThan(1e-9));
    });

    test('recording mutation invalidates a paused painter', () {
      final recording = _staticRecording(withClick: false);
      final oldPainter = AccumulationCursorPainter(
        cursorRecording: recording,
        position: const Duration(milliseconds: 100),
        videoSize: const Size(200, 200),
      );
      recording.addPosition(
        CursorPosition(x: 80, y: 80, timestampMicros: 130000, isClicked: false),
      );
      final newPainter = AccumulationCursorPainter(
        cursorRecording: recording,
        position: const Duration(milliseconds: 100),
        videoSize: const Size(200, 200),
      );

      expect(newPainter.shouldRepaint(oldPainter), isTrue);
    });

    test('type-transition blur sees across a contiguous split', () {
      const painterSize = Size(600, 300);
      final recording = CursorRecording()
        ..addPosition(
          CursorPosition(
            x: 100,
            y: 100,
            timestampMicros: 0,
            state: CursorState.arrow,
          ),
        )
        ..addPosition(
          CursorPosition(
            x: 100,
            y: 100,
            timestampMicros: 620000,
            state: CursorState.iBeam,
          ),
        )
        ..addPosition(
          CursorPosition(
            x: 100,
            y: 100,
            timestampMicros: 1000000,
            state: CursorState.iBeam,
          ),
        );
      final split = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(milliseconds: 600),
        ),
        ClipSlice(
          cutStart: const Duration(milliseconds: 600),
          cutEnd: const Duration(seconds: 1),
        ),
      ];
      final whole = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 1)),
      ];

      List<bool> filtersFor(List<ClipSlice> clips) {
        final painter = AccumulationCursorPainter(
          cursorRecording: recording,
          position: const Duration(milliseconds: 600),
          videoSize: painterSize,
          clips: clips,
          activeClip: clips.last,
          exposureMs: 0,
          sampleCount: 1,
          devicePixelRatio: 1,
          typeChangeBlurSigmaPx: 8,
          typeChangeBlurHalfWidthMs: 40,
          clickEffect: CursorClickEffect.none,
        );
        final canvas = _StampSizingCanvas();
        painter.paint(canvas, painterSize);
        return canvas.stampHasImageFilter;
      }

      final splitFilters = filtersFor(split);
      final wholeFilters = filtersFor(whole);
      expect(splitFilters, wholeFilters);
      expect(splitFilters, contains(isTrue));
    });
  });
}
