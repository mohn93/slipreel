import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_snap.dart';

void main() {
  const canvas = Size(800, 450); // canvas aspect 1.7778

  group('cameraHalfExtents', () {
    test('halfW is size/2; halfH scales by canvasAspect/shapeAspect', () {
      final e = cameraHalfExtents(
          size: 0.25, shapeAspect: 1.0, canvasAspect: 800 / 450);
      expect(e.halfW, closeTo(0.125, 1e-9));
      expect(e.halfH, closeTo(0.125 * 800 / 450, 1e-9)); // ≈ 0.2222
    });
  });

  group('clampCameraCenterInView', () {
    test('keeps the bubble fully on canvas', () {
      // halfW 0.125, halfH 0.2222 → X∈[0.125,0.875], Y∈[0.2222,0.7778].
      final c = clampCameraCenterInView(
          centerX: 0.99, centerY: 0.99, halfW: 0.125, halfH: 0.2222);
      expect(c.cx, closeTo(0.875, 1e-9));
      expect(c.cy, closeTo(0.7778, 1e-9));
    });

    test('centers an oversized bubble', () {
      final c = clampCameraCenterInView(
          centerX: 0.9, centerY: 0.1, halfW: 0.6, halfH: 0.6);
      expect(c.cx, 0.5);
      expect(c.cy, 0.5);
    });
  });

  group('cameraSnapAnchors', () {
    test('insets anchor CENTERS so the bubble edge sits at the margin', () {
      final a = cameraSnapAnchors(
          halfW: 0.125, halfH: 0.2, marginX: 0.04, marginY: 0.04);
      expect(a, hasLength(9));
      expect(a.first.dx, closeTo(0.165, 1e-9)); // top-left x = 0.04+0.125
      expect(a.first.dy, closeTo(0.24, 1e-9)); //            y = 0.04+0.2
      expect(a.last.dx, closeTo(0.835, 1e-9)); // bottom-right x = 1-0.04-0.125
      expect(a.last.dy, closeTo(0.76, 1e-9)); //              y = 1-0.04-0.2
      expect(a[4], const Offset(0.5, 0.5)); // center
    });
  });

  group('snapCameraCenter', () {
    test('clamps an out-of-view center fully back into view', () {
      final r = snapCameraCenter(
        centerX: 1.2,
        centerY: 1.2,
        canvasSize: canvas,
        size: 0.25,
        shapeAspect: 1.0,
        thresholdPx: 0, // disable snapping to isolate the clamp
      );
      expect(r.snapped, isFalse);
      expect(r.center.dx, closeTo(0.875, 1e-6)); // 1 - halfW
      expect(r.center.dy, closeTo(0.7778, 1e-3)); // 1 - halfH
    });

    test('snaps to the nearest in-view anchor when close', () {
      // halfH = 0.125*800/450 ≈ 0.2222 → bottom-right anchor ≈ (0.835, 0.7378).
      final r = snapCameraCenter(
        centerX: 0.83,
        centerY: 0.74,
        canvasSize: canvas,
        size: 0.25,
        shapeAspect: 1.0,
      );
      expect(r.snapped, isTrue);
      expect(r.center.dx, closeTo(0.835, 1e-3));
      expect(r.center.dy, closeTo(0.7378, 1e-3));
    });

    test('does not snap when no anchor is within threshold', () {
      final r = snapCameraCenter(
        centerX: 0.5,
        centerY: 0.4,
        canvasSize: canvas,
        size: 0.25,
        shapeAspect: 1.0,
      );
      expect(r.snapped, isFalse);
      expect(r.center.dx, closeTo(0.5, 1e-9));
      expect(r.center.dy, closeTo(0.4, 1e-9)); // in view, unchanged
    });
  });
}
