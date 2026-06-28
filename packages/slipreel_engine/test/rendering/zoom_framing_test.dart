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

  group('identity-reduction guard: device(videoRect=(0,0,W,H), canvas=(W,H)) '
      '== identity', () {
    // This is the safety property that makes "always device-style framing" safe:
    // when there is no padding and no bezel (video fills the canvas 1:1), the
    // device flavor must be byte-identical to the legacy identity flavor across
    // every public method and every zoom level, for both a centered focal and an
    // edge focal. If this ever drifts, zero-padding non-device recordings would
    // silently change their zoom transform.
    final identity = ZoomFraming.identity(videoSize);
    final deviceReduced = ZoomFraming.device(
      videoSize: videoSize,
      videoRect: Rect.fromLTWH(0, 0, videoSize.width, videoSize.height),
      canvasSize: videoSize,
    );

    const epsilon = 1e-9;
    final focals = <(String, Offset)>[
      ('centered', Offset(videoSize.width / 2, videoSize.height / 2)),
      ('edge', const Offset(1170, 1266)),
    ];

    for (final (label, focal) in focals) {
      for (final z in [1.5, 2.0, 3.0, 5.0]) {
        test('clampFocal matches identity ($label focal, z=$z)', () {
          final a = identity.clampFocal(focal, z);
          final b = deviceReduced.clampFocal(focal, z);
          expect(b.dx, closeTo(a.dx, epsilon));
          expect(b.dy, closeTo(a.dy, epsilon));
        });
        test('clampFocalRadial matches identity ($label focal, z=$z)', () {
          final a = identity.clampFocalRadial(focal, z);
          final b = deviceReduced.clampFocalRadial(focal, z);
          expect(b.dx, closeTo(a.dx, epsilon));
          expect(b.dy, closeTo(a.dy, epsilon));
        });
        test('centerOffset matches identity ($label focal, z=$z)', () {
          final a = identity.centerOffset(focal, z);
          final b = deviceReduced.centerOffset(focal, z);
          expect(b.dx, closeTo(a.dx, epsilon));
          expect(b.dy, closeTo(a.dy, epsilon));
        });
        test('centerOffsetInPlace matches identity ($label focal, z=$z)', () {
          final a = identity.centerOffsetInPlace(focal, z);
          final b = deviceReduced.centerOffsetInPlace(focal, z);
          expect(b.dx, closeTo(a.dx, epsilon));
          expect(b.dy, closeTo(a.dy, epsilon));
        });
      }
    }
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
      final back = f.fromCanvas(f.toCanvas(p));
      expect(back.dx, closeTo(p.dx, 1e-6));
      expect(back.dy, closeTo(p.dy, 1e-6));
    });

    test('an edge video focal clamps to the PADDED CANVAS, not the video', () {
      // Cursor at the right screen edge.
      const edge = Offset(1170, 1266);
      const z = 2.0;
      // Canvas-space clamp: map -> clamp to canvasSize -> map back.
      final canvasFocal = f.toCanvas(edge);
      final canvasClamped =
          ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
      final expected = f.fromCanvas(canvasClamped);
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
      final canvasFocal = f.toCanvas(p);
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
        final canvasFocal = f.toCanvas(focal);
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

    test('identity corner focals: viewport in bounds AND bound is tight', () {
      // Identity framing: canvas == videoSize, so a corner focal IS at the
      // canvas edge. This makes the magnify-in-place scaling exactly what
      // keeps the viewport in bounds (no padding slack), so the test can
      // discriminate the real formula from a zero-offset stub.
      const canvasSize = Size(1920, 1080);
      final f = ZoomFraming.identity(canvasSize);
      final canvasCenter = Offset(canvasSize.width / 2, canvasSize.height / 2);
      const epsilon = 1e-6;

      for (final focal in [const Offset(0, 0), const Offset(1920, 1080)]) {
        for (final z in [1.5, 2.0, 3.0, 5.0]) {
          final offset = f.centerOffsetInPlace(focal, z);
          final c = canvasCenter + offset;
          final halfW = canvasSize.width / (2 * z);
          final halfH = canvasSize.height / (2 * z);

          final minX = c.dx - halfW;
          final maxX = c.dx + halfW;
          final minY = c.dy - halfH;
          final maxY = c.dy + halfH;

          // In-bounds.
          expect(minX, greaterThanOrEqualTo(-epsilon),
              reason: 'left edge out of bounds: focal=$focal, z=$z, minX=$minX');
          expect(maxX, lessThanOrEqualTo(canvasSize.width + epsilon),
              reason:
                  'right edge out of bounds: focal=$focal, z=$z, maxX=$maxX');
          expect(minY, greaterThanOrEqualTo(-epsilon),
              reason: 'top edge out of bounds: focal=$focal, z=$z, minY=$minY');
          expect(maxY, lessThanOrEqualTo(canvasSize.height + epsilon),
              reason:
                  'bottom edge out of bounds: focal=$focal, z=$z, maxY=$maxY');

          // Tight bound: the viewport must hug the corner the focal sits at.
          // A zero-offset stub would leave the near edge at w/2 - w/(2z) > 0,
          // failing these. ~1px tolerance.
          if (focal == const Offset(0, 0)) {
            expect(minX, closeTo(0.0, 1.0),
                reason: 'left edge not tight for (0,0): z=$z, minX=$minX');
            expect(minY, closeTo(0.0, 1.0),
                reason: 'top edge not tight for (0,0): z=$z, minY=$minY');
          } else {
            expect(maxX, closeTo(canvasSize.width, 1.0),
                reason: 'right edge not tight for corner: z=$z, maxX=$maxX');
            expect(maxY, closeTo(canvasSize.height, 1.0),
                reason: 'bottom edge not tight for corner: z=$z, maxY=$maxY');
          }
        }
      }
    });
  });

  group('manual viewport API (picker geometry)', () {
    const canvasSize = Size(1400, 2900);
    final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
    final f = ZoomFraming.device(
        videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);
    final canvasCenter = Offset(canvasSize.width / 2, canvasSize.height / 2);

    test('manualViewportRect center == canvasCenter + centerOffsetInPlace, '
        'size == canvas / z', () {
      const focal = Offset(900, 2000);
      const z = 2.5;
      final rect = f.manualViewportRect(focal, z);
      final expectedCenter = canvasCenter + f.centerOffsetInPlace(focal, z);
      expect(rect.center.dx, closeTo(expectedCenter.dx, 1e-6));
      expect(rect.center.dy, closeTo(expectedCenter.dy, 1e-6));
      expect(rect.width, closeTo(canvasSize.width / z, 1e-6));
      expect(rect.height, closeTo(canvasSize.height / z, 1e-6));
    });

    test('manualFocalForViewportCenter inverts manualViewportRect.center', () {
      // In-band focals (the inverse must round-trip exactly).
      final focals = [
        const Offset(585, 1266),
        const Offset(300, 800),
        const Offset(900, 2000),
      ];
      for (final focal in focals) {
        for (final z in [1.5, 2.0, 3.0, 5.0]) {
          final vc = f.manualViewportRect(focal, z).center;
          final back = f.manualFocalForViewportCenter(vc, z);
          expect(back.dx, closeTo(focal.dx, 1e-6),
              reason: 'dx round-trip failed for focal=$focal, z=$z');
          expect(back.dy, closeTo(focal.dy, 1e-6),
              reason: 'dy round-trip failed for focal=$focal, z=$z');
        }
      }
    });

    test('clampManualViewportCenter keeps the box inside the canvas', () {
      for (final z in [1.5, 2.0, 3.0, 5.0]) {
        final halfW = canvasSize.width / (2 * z);
        final halfH = canvasSize.height / (2 * z);
        // Push far past the top-left corner.
        final clamped =
            f.clampManualViewportCenter(const Offset(-9999, -9999), z);
        expect(clamped.dx, closeTo(halfW, 1e-6));
        expect(clamped.dy, closeTo(halfH, 1e-6));
        // Push far past the bottom-right corner.
        final clamped2 =
            f.clampManualViewportCenter(const Offset(99999, 99999), z);
        expect(clamped2.dx, closeTo(canvasSize.width - halfW, 1e-6));
        expect(clamped2.dy, closeTo(canvasSize.height - halfH, 1e-6));
      }
    });

    test('z==1 guard: manualFocalForViewportCenter returns canvas-center focal',
        () {
      final back = f.manualFocalForViewportCenter(const Offset(10, 20), 1.0);
      final expected = f.fromCanvas(canvasCenter);
      expect(back.dx, closeTo(expected.dx, 1e-6));
      expect(back.dy, closeTo(expected.dy, 1e-6));
    });
  });
}
