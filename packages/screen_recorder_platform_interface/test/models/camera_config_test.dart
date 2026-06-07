import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/camera_config.dart';

void main() {
  group('CameraConfig', () {
    test('json round-trips', () {
      const c = CameraConfig(deviceUid: 'cam-uid-1', deviceLabel: 'FaceTime HD');
      final back = CameraConfig.fromJson(c.toJson());
      expect(back, c);
    });

    test('equality and hashCode by value', () {
      const a = CameraConfig(deviceUid: 'u', deviceLabel: 'L');
      const b = CameraConfig(deviceUid: 'u', deviceLabel: 'L');
      const d = CameraConfig(deviceUid: 'u', deviceLabel: 'OTHER');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == d, isFalse);
    });

    test('CameraMenuResult parses a config payload', () {
      final r = CameraMenuResult.fromJson({
        'cancelled': false,
        'config': {'deviceUid': 'u', 'deviceLabel': 'L'},
      });
      expect(r.cancelled, isFalse);
      expect(r.config, const CameraConfig(deviceUid: 'u', deviceLabel: 'L'));
    });

    test('CameraMenuResult parses a null config (don\'t record)', () {
      final r = CameraMenuResult.fromJson({'cancelled': false, 'config': null});
      expect(r.cancelled, isFalse);
      expect(r.config, isNull);
    });
  });
}
