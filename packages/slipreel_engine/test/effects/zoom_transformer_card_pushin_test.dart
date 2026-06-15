import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';

void main() {
  // Canvas 400×320, video 320×240 centered → padding 40 each side.
  const canvas = Size(400, 320);
  const videoRect = Rect.fromLTWH(40, 40, 320, 240);
  const cornerRadius = 12.0;

  group('resolveCardPushIn', () {
    test('floorFraction 1.0 ⇒ card never grows (fixed-frame degenerate)', () {
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 4.0,
        paddingFloorFraction: 1.0,
      );
      expect(r.zCard, closeTo(1.0, 1e-9));
      expect(r.cardRect, videoRect);
      expect(r.cornerRadius, closeTo(cornerRadius, 1e-9));
    });

    test('low zoom below zCardMax ⇒ card scales by the full zoom', () {
      // zCardMax(x) = (400 - 0.4*(400-320))/320 = (400-32)/320 = 1.15
      // zCardMax(y) = (320 - 0.4*(320-240))/240 = (320-32)/240 = 1.20
      // zCardMax = min = 1.15. zoom 1.10 < 1.15 ⇒ zCard == 1.10.
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 1.10,
        paddingFloorFraction: 0.4,
      );
      expect(r.zCard, closeTo(1.10, 1e-9));
      expect(r.cardRect.center, const Offset(200, 160));
      expect(r.cardRect.width, closeTo(320 * 1.10, 1e-6));
      expect(r.cornerRadius, closeTo(cornerRadius * 1.10, 1e-6));
    });

    test('high zoom clamps card scale to zCardMax; padding holds at floor', () {
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 4.0,
        paddingFloorFraction: 0.4,
      );
      expect(r.zCard, closeTo(1.15, 1e-6));
      final padX = (canvas.width - r.cardRect.width) / 2;
      expect(padX, closeTo(0.4 * 40, 1e-6)); // 16
      expect(r.cardRect.width, lessThanOrEqualTo(canvas.width - 2 * 16 + 1e-6));
    });

    test('zoom 1.0 ⇒ zCard 1.0, cardRect == videoRect', () {
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 1.0,
        paddingFloorFraction: 0.4,
      );
      expect(r.zCard, closeTo(1.0, 1e-9));
      expect(r.cardRect, videoRect);
    });
  });
}
