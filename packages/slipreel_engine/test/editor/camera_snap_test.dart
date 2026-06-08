import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_snap.dart';

void main() {
  const canvas = Size(800, 450);

  group('cameraSnapAnchors', () {
    test('produces the 9 standard anchors with the default margin', () {
      final a = cameraSnapAnchors();
      expect(a, hasLength(9));
      expect(a, contains(const Offset(0.05, 0.05))); // top-left corner
      expect(a, contains(const Offset(0.95, 0.95))); // bottom-right corner
      expect(a, contains(const Offset(0.5, 0.5))); // center
      expect(a, contains(const Offset(0.5, 0.05))); // top edge midpoint
    });
  });

  group('snapCameraCenter', () {
    test('snaps to the nearest anchor when within threshold', () {
      // Just off the bottom-right corner anchor (0.95, 0.95).
      final r = snapCameraCenter(centerX: 0.94, centerY: 0.94, canvasSize: canvas);
      expect(r.snapped, isTrue);
      expect(r.center.dx, closeTo(0.95, 1e-9));
      expect(r.center.dy, closeTo(0.95, 1e-9));
    });

    test('does not snap when no anchor is within threshold', () {
      // (0.5, 0.3): nearest anchor is center (0.5,0.5) at 0.2*450 = 90px > 24px.
      final r = snapCameraCenter(centerX: 0.5, centerY: 0.3, canvasSize: canvas);
      expect(r.snapped, isFalse);
      expect(r.center, const Offset(0.5, 0.3));
    });

    test('snaps to dead center near the middle', () {
      // (0.51,0.5) → center: 0.01*800 = 8px < 24px.
      final r = snapCameraCenter(centerX: 0.51, centerY: 0.5, canvasSize: canvas);
      expect(r.snapped, isTrue);
      expect(r.center, const Offset(0.5, 0.5));
    });

    test('threshold is measured in pixels (respects canvas dimensions)', () {
      // Same normalized point (0.54, 0.95) relative to the bottom-center anchor
      // (0.50, 0.95): the only difference is canvas width.
      // dx = 0.04 → 32px on a 800px canvas (> 24, no snap), 16px on a 400px
      // canvas (< 24, snaps). dy = 0 (exactly on the anchor row).
      final wide = snapCameraCenter(
          centerX: 0.54, centerY: 0.95, canvasSize: const Size(800, 450));
      expect(wide.snapped, isFalse, reason: '32px is beyond the 24px threshold');

      final narrow = snapCameraCenter(
          centerX: 0.54, centerY: 0.95, canvasSize: const Size(400, 450));
      expect(narrow.snapped, isTrue, reason: '16px is within the 24px threshold');
      expect(narrow.center, const Offset(0.5, 0.95));
    });
  });
}
