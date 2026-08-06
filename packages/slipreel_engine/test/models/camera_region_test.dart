import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';

void main() {
  group('CameraRegion', () {
    CameraRegion region() => CameraRegion(
          startTime: const Duration(seconds: 1),
          duration: const Duration(seconds: 2),
          centerX: 0.8,
          centerY: 0.75,
          size: 0.22,
        );

    test('endTime is start + duration', () {
      expect(region().endTime, const Duration(seconds: 3));
    });

    test('isActive is half-open [start, end)', () {
      final r = region();
      expect(r.isActive(const Duration(seconds: 1)), isTrue);
      expect(r.isActive(const Duration(milliseconds: 2999)), isTrue);
      expect(r.isActive(const Duration(seconds: 3)), isFalse); // end excluded
      expect(r.isActive(const Duration(milliseconds: 999)), isFalse);
    });

    test('constructor clamps placement into the unit square and size > 0', () {
      final r = CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        centerX: 1.5,
        centerY: -0.2,
        size: 5.0,
      );
      expect(r.centerX, 1.0);
      expect(r.centerY, 0.0);
      expect(r.size, 1.0); // size clamps to (0, 1]
    });

    test('json round-trips', () {
      final r = region();
      expect(CameraRegion.fromJson(r.toJson()), r);
    });

    test('copyWith replaces only named fields', () {
      final r = region();
      expect(r.copyWith(centerX: 0.1).centerX, 0.1);
      expect(r.copyWith(centerX: 0.1).size, 0.22);
    });

    test('equality and hashCode by value', () {
      expect(region(), region());
      expect(region().hashCode, region().hashCode);
      expect(region() == region().copyWith(size: 0.3), isFalse);
    });

    test('transient id: unique per construction, preserved by copyWith, '
        'excluded from == and json', () {
      final r = region();
      expect(r.id, isNot(region().id));
      expect(r.copyWith(size: 0.3).id, r.id);
      expect(region(), region()); // fresh ids don't break value equality
      expect(r.toJson().containsKey('id'), isFalse);
    });
  });
}
