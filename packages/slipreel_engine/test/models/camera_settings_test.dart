import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';

void main() {
  group('CameraSettings', () {
    test('defaults match the locked brainstorming decisions', () {
      const s = CameraSettings();
      expect(s.enabled, isTrue);
      expect(s.shape, CameraShape.circle);
      expect(s.roundness, 1.0);
      expect(s.mirror, isTrue); // mirror default ON
      expect(s.borderWidth, 0.0);
      expect(s.borderColor, 0xFFFFFFFF);
      expect(s.shadow, isTrue);
      expect(s.opacity, 1.0);
    });

    test('json round-trips', () {
      const s = CameraSettings(
        enabled: false,
        shape: CameraShape.horizontal,
        roundness: 0.3,
        mirror: false,
        borderWidth: 4,
        borderColor: 0xFF112233,
        shadow: false,
        opacity: 0.8,
      );
      expect(CameraSettings.fromJson(s.toJson()), s);
    });

    test('fromJson tolerates missing keys (falls back to defaults)', () {
      final s = CameraSettings.fromJson(const {});
      expect(s, const CameraSettings());
    });

    test('fromJson clamps out-of-range numerics and unknown shape', () {
      final s = CameraSettings.fromJson(const {
        'shape': 'not-a-shape',
        'roundness': 5.0,
        'opacity': -1.0,
        'borderWidth': -3.0,
      });
      expect(s.shape, CameraShape.circle); // fallback
      expect(s.roundness, 1.0);
      expect(s.opacity, 0.0);
      expect(s.borderWidth, 0.0);
    });

    test('copyWith replaces only named fields', () {
      const s = CameraSettings();
      expect(s.copyWith(mirror: false).mirror, isFalse);
      expect(s.copyWith(mirror: false).shape, CameraShape.circle);
    });

    test('equality and hashCode by value', () {
      const a = CameraSettings(opacity: 0.5);
      const b = CameraSettings(opacity: 0.5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const CameraSettings(opacity: 0.6), isFalse);
    });
  });
}
