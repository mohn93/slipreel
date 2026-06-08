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
    test('keeps the bubble fully on canvas with edge padding (margin 0.06)', () {
      // halfW 0.125, halfH 0.2222 → X∈[0.185,0.815], Y∈[0.2822,0.7178].
      final c = clampCameraCenterInView(
          centerX: 0.99, centerY: 0.99, halfW: 0.125, halfH: 0.2222);
      expect(c.cx, closeTo(1 - 0.06 - 0.125, 1e-9)); // 0.815
      expect(c.cy, closeTo(1 - 0.06 - 0.2222, 1e-9)); // 0.7178
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
    test('clamps an out-of-view center fully back into view (with padding)', () {
      final r = snapCameraCenter(
        centerX: 1.2,
        centerY: 1.2,
        canvasSize: canvas,
        size: 0.25,
        shapeAspect: 1.0,
        thresholdPx: 0, // disable snapping to isolate the clamp
      );
      expect(r.snapped, isFalse);
      expect(r.center.dx, closeTo(1 - 0.06 - 0.125, 1e-6)); // 0.815
      expect(r.center.dy, closeTo(1 - 0.06 - 0.2222, 1e-3)); // 0.7178
    });

    test('snaps to the nearest in-view anchor when close', () {
      // margin 0.06, halfH ≈ 0.2222 → bottom-right anchor ≈ (0.815, 0.7178).
      final r = snapCameraCenter(
        centerX: 0.81,
        centerY: 0.72,
        canvasSize: canvas,
        size: 0.25,
        shapeAspect: 1.0,
      );
      expect(r.snapped, isTrue);
      expect(r.center.dx, closeTo(0.815, 1e-3));
      expect(r.center.dy, closeTo(1 - 0.06 - 0.2222, 1e-3));
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

  group('cameraPixelBox', () {
    test('clamps the box inside the edge margin', () {
      const canvas = Size(1000, 500);
      // size 0.2 over width 1000 => w=200; square shape => h=200
      final box = cameraPixelBox(
        centerX: 1.0, centerY: 1.0, size: 0.2,
        canvasSize: canvas, shapeAspect: 1.0,
      );
      // pad = 0.06*1000=60 (x), 0.06*500=30 (y); hiX = 1000-100-60=840
      expect(box.width, closeTo(200, 1e-6));
      expect(box.height, closeTo(200, 1e-6));
      expect(box.center.dx, closeTo(840, 1e-6)); // clamped to hiX
      expect(box.center.dy, closeTo(500 - 100 - 30, 1e-6)); // hiY=370
    });

    test('centers the box when it is larger than the padded canvas', () {
      const canvas = Size(400, 400);
      // size 1.0 => w=400 == canvas width; loX(=200+24=224) > hiX(=400-200-24=176)
      final box = cameraPixelBox(
        centerX: 0.1, centerY: 0.1, size: 1.0,
        canvasSize: canvas, shapeAspect: 1.0,
      );
      expect(box.center.dx, closeTo(200, 1e-6));
      expect(box.center.dy, closeTo(200, 1e-6));
    });
  });
}
