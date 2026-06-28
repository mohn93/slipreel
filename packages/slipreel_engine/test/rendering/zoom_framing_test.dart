import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  const videoSize = Size(1170, 2532);

  group('identity framing == today\'s ZoomTransformer math', () {
    final f = ZoomFraming.identity(videoSize);
    test('clampFocal delegates to clampFocalToBounds', () {
      for (final z in [1.0, 1.5, 2.5, 5.0]) {
        for (final p in [const Offset(0, 0), const Offset(1170, 2532),
            const Offset(585, 1266), const Offset(50, 2400)]) {
          expect(f.clampFocal(p, z),
              ZoomTransformer.clampFocalToBounds(p, videoSize, z));
        }
      }
    });
    test('clampFocalRadial delegates to clampFocalToBoundsRadial', () {
      for (final z in [1.5, 2.5]) {
        const p = Offset(50, 2400);
        expect(f.clampFocalRadial(p, z),
            ZoomTransformer.clampFocalToBoundsRadial(p, videoSize, z));
      }
    });
    test('centerOffset == clampFocalToBounds(focal) - videoCenter', () {
      const p = Offset(50, 2400);
      const z = 2.0;
      final expected = ZoomTransformer.clampFocalToBounds(p, videoSize, z) -
          Offset(videoSize.width / 2, videoSize.height / 2);
      final actual = f.centerOffset(p, z);
      expect(actual.dx, closeTo(expected.dx, 1e-9));
      expect(actual.dy, closeTo(expected.dy, 1e-9));
    });
  });

  group('device framing maps + clamps in canvas space', () {
    // Video drawn into a cutout offset (100,120) and ~1:1 inside a larger
    // padded canvas (1400x2900). Cutout size 1200x2596 (slight scale).
    const canvasSize = Size(1400, 2900);
    final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
    final f = ZoomFraming.device(
        videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);

    test('toCanvas/fromCanvas round-trip is identity', () {
      const p = Offset(300, 800);
      final back = f.debugFromCanvas(f.debugToCanvas(p));
      expect(back.dx, closeTo(p.dx, 1e-6));
      expect(back.dy, closeTo(p.dy, 1e-6));
    });

    test('an edge video focal clamps to the PADDED CANVAS, not the video', () {
      // Cursor at the right screen edge.
      const edge = Offset(1170, 1266);
      const z = 2.0;
      // Canvas-space clamp: map -> clamp to canvasSize -> map back.
      final canvasFocal = f.debugToCanvas(edge);
      final canvasClamped =
          ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
      final expected = f.debugFromCanvas(canvasClamped);
      final actual = f.clampFocal(edge, z);
      expect(actual.dx, closeTo(expected.dx, 1e-6));
      expect(actual.dy, closeTo(expected.dy, 1e-6));
      // And it must differ from the (wrong) video-bounds clamp at the edge.
      expect((actual - ZoomTransformer.clampFocalToBounds(edge, videoSize, z))
          .distance, greaterThan(1.0));
    });

    test('centerOffset = toCanvas(canvasClamp(focal)) - canvasCenter', () {
      const p = Offset(900, 2000);
      const z = 2.5;
      final canvasFocal = f.debugToCanvas(p);
      final canvasClamped =
          ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
      final expected =
          canvasClamped - Offset(canvasSize.width / 2, canvasSize.height / 2);
      final actual = f.centerOffset(p, z);
      expect(actual.dx, closeTo(expected.dx, 1e-6));
      expect(actual.dy, closeTo(expected.dy, 1e-6));
    });
  });

  group('centerOffsetInPlace (no clamp)', () {
    test('identity flavor: (f - videoCenter) * (1 - 1/z)', () {
      final f = ZoomFraming.identity(videoSize);
      final testCases = [
        (const Offset(585, 1266), 1.5),
        (const Offset(0, 0), 2.0),
        (const Offset(1170, 2532), 3.0),
        (const Offset(50, 2400), 5.0),
      ];
      for (final (focal, z) in testCases) {
        final videoCenter = Offset(videoSize.width / 2, videoSize.height / 2);
        final expected = (focal - videoCenter) * (1.0 - 1.0 / z);
        final actual = f.centerOffsetInPlace(focal, z);
        expect(actual.dx, closeTo(expected.dx, 1e-6),
            reason: 'dx mismatch for focal=$focal, z=$z');
        expect(actual.dy, closeTo(expected.dy, 1e-6),
            reason: 'dy mismatch for focal=$focal, z=$z');
      }
    });

    test('device flavor: (toCanvas(f) - canvasCenter) * (1 - 1/z)', () {
      const canvasSize = Size(1400, 2900);
      final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
      final f = ZoomFraming.device(
          videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);

      final testCases = [
        (const Offset(585, 1266), 1.5),
        (const Offset(0, 0), 2.0),
        (const Offset(1170, 2532), 3.0),
        (const Offset(900, 2000), 5.0),
      ];
      for (final (focal, z) in testCases) {
        final canvasFocal = f.debugToCanvas(focal);
        final canvasCenter = Offset(canvasSize.width / 2, canvasSize.height / 2);
        final expected = (canvasFocal - canvasCenter) * (1.0 - 1.0 / z);
        final actual = f.centerOffsetInPlace(focal, z);
        expect(actual.dx, closeTo(expected.dx, 1e-6),
            reason: 'dx mismatch for focal=$focal, z=$z');
        expect(actual.dy, closeTo(expected.dy, 1e-6),
            reason: 'dy mismatch for focal=$focal, z=$z');
      }
    });

    test('centered focal returns Offset.zero', () {
      final f = ZoomFraming.identity(videoSize);
      final videoCenter = Offset(videoSize.width / 2, videoSize.height / 2);
      for (final z in [1.5, 2.0, 3.0, 5.0]) {
        final actual = f.centerOffsetInPlace(videoCenter, z);
        expect(actual.dx, closeTo(0.0, 1e-9),
            reason: 'dx should be 0 for centered focal, z=$z');
        expect(actual.dy, closeTo(0.0, 1e-9),
            reason: 'dy should be 0 for centered focal, z=$z');
      }
    });

    test('viewport at offset stays within canvas bounds (void-free property)',
        () {
      const canvasSize = Size(1400, 2900);
      final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
      final f = ZoomFraming.device(
          videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);

      const epsilon = 1e-6;
      final canvasCenter = Offset(canvasSize.width / 2, canvasSize.height / 2);

      // Test near-edge focals with multiple zoom levels
      final nearEdgeFocals = [
        const Offset(10, 10),
        const Offset(1160, 10),
        const Offset(10, 2520),
        const Offset(1160, 2520),
        const Offset(585, 100),
        const Offset(585, 2400),
        const Offset(50, 1266),
        const Offset(1150, 1266),
      ];

      for (final focal in nearEdgeFocals) {
        for (final z in [1.5, 2.0, 3.0, 5.0]) {
          final offset = f.centerOffsetInPlace(focal, z);
          final c = canvasCenter + offset;
          final halfViewportWidth = canvasSize.width / (2 * z);
          final halfViewportHeight = canvasSize.height / (2 * z);

          final minX = c.dx - halfViewportWidth;
          final maxX = c.dx + halfViewportWidth;
          final minY = c.dy - halfViewportHeight;
          final maxY = c.dy + halfViewportHeight;

          expect(minX, greaterThanOrEqualTo(-epsilon),
              reason:
                  'viewport left edge out of bounds: focal=$focal, z=$z, minX=$minX');
          expect(maxX, lessThanOrEqualTo(canvasSize.width + epsilon),
              reason:
                  'viewport right edge out of bounds: focal=$focal, z=$z, maxX=$maxX');
          expect(minY, greaterThanOrEqualTo(-epsilon),
              reason:
                  'viewport top edge out of bounds: focal=$focal, z=$z, minY=$minY');
          expect(maxY, lessThanOrEqualTo(canvasSize.height + epsilon),
              reason:
                  'viewport bottom edge out of bounds: focal=$focal, z=$z, maxY=$maxY');
        }
      }
    });
  });
}
