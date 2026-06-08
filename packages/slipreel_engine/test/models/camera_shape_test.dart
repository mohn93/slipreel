import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_shape.dart';

void main() {
  group('CameraShape.pixelAspect', () {
    test('square and circle are 1:1', () {
      expect(CameraShape.square.pixelAspect(1.7777), 1.0);
      expect(CameraShape.circle.pixelAspect(1.7777), 1.0);
    });
    test('horizontal is 16:9, vertical is 9:16', () {
      expect(CameraShape.horizontal.pixelAspect(1.0), closeTo(16 / 9, 1e-9));
      expect(CameraShape.vertical.pixelAspect(1.0), closeTo(9 / 16, 1e-9));
    });
    test('original passes the source aspect through', () {
      expect(CameraShape.original.pixelAspect(1.3333), closeTo(1.3333, 1e-9));
    });
    test('original falls back to 1.0 for a non-finite/zero source aspect', () {
      expect(CameraShape.original.pixelAspect(0), 1.0);
      expect(CameraShape.original.pixelAspect(double.nan), 1.0);
    });
    test('isRound only for circle', () {
      expect(CameraShape.circle.isRound, isTrue);
      expect(CameraShape.square.isRound, isFalse);
    });
  });
}
