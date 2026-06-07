import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_seed.dart';

void main() {
  group('cameraSeedRegion', () {
    test('spans the whole video at the self-view position', () {
      final r = cameraSeedRegion(
        videoDuration: const Duration(seconds: 12),
        selfViewX: 0.82,
        selfViewY: 0.78,
      );
      expect(r.startTime, Duration.zero);
      expect(r.duration, const Duration(seconds: 12));
      expect(r.centerX, 0.82);
      expect(r.centerY, 0.78);
      expect(r.size, 0.22);
    });

    test('clamps an off-canvas self-view center into the unit square', () {
      final r = cameraSeedRegion(
        videoDuration: const Duration(seconds: 1),
        selfViewX: 1.4,
        selfViewY: -0.3,
      );
      expect(r.centerX, 1.0);
      expect(r.centerY, 0.0);
    });

    test('honors a custom width fraction', () {
      final r = cameraSeedRegion(
        videoDuration: const Duration(seconds: 1),
        selfViewX: 0.5,
        selfViewY: 0.5,
        widthFraction: 0.3,
      );
      expect(r.size, 0.3);
    });
  });
}
