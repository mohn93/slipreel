import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';

void main() {
  CameraRegion r(int startMs, int durMs, double cx) => CameraRegion(
        startTime: Duration(milliseconds: startMs),
        duration: Duration(milliseconds: durMs),
        centerX: cx,
        centerY: 0.8,
        size: 0.22,
      );

  group('CameraPlacementResolver', () {
    test('gap = hidden (null)', () {
      final regions = [r(0, 1000, 0.2)];
      expect(
        CameraPlacementResolver.placementAt(
            const Duration(milliseconds: 1500), regions),
        isNull,
      );
    });

    test('inside an isolated region = static placement', () {
      final regions = [r(0, 1000, 0.2)];
      final p = CameraPlacementResolver.placementAt(
          const Duration(milliseconds: 500), regions)!;
      expect(p.centerX, 0.2);
      expect(p.size, 0.22);
    });

    test('two touching regions glide from predecessor to current', () {
      final regions = [r(0, 1000, 0.2), r(1000, 1000, 0.8)];
      const glide = Duration(milliseconds: 400);

      final atStart = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000),
        regions,
        glideDuration: glide,
        glideCurve: Curves.linear,
      )!;
      expect(atStart.centerX, closeTo(0.2, 1e-9));

      final mid = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1200),
        regions,
        glideDuration: glide,
        glideCurve: Curves.linear,
      )!;
      expect(mid.centerX, closeTo(0.5, 1e-9));

      final after = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1600),
        regions,
        glideDuration: glide,
        glideCurve: Curves.linear,
      )!;
      expect(after.centerX, closeTo(0.8, 1e-9));
    });

    test('non-touching predecessor (gap before) does not glide', () {
      final regions = [r(0, 800, 0.2), r(1000, 1000, 0.8)];
      final p = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000),
        regions,
        glideDuration: const Duration(milliseconds: 400),
      )!;
      expect(p.centerX, closeTo(0.8, 1e-9));
    });
  });
}
