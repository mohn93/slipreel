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
}
