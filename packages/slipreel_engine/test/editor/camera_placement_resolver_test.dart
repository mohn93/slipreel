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

    test('joinTolerance boundary: 4ms gap (== default tolerance) still glides; '
        '5ms gap does not', () {
      // predecessor ends at 996, active starts at 1000 -> 4ms gap == tolerance.
      final touching = [r(0, 996, 0.2), r(1000, 1000, 0.8)];
      final p = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000), touching,
        glideDuration: const Duration(milliseconds: 400), glideCurve: Curves.linear)!;
      expect(p.centerX, closeTo(0.2, 1e-9)); // glides from predecessor

      final gapped = [r(0, 995, 0.2), r(1000, 1000, 0.8)]; // 5ms gap > 4ms
      final q = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000), gapped,
        glideDuration: const Duration(milliseconds: 400), glideCurve: Curves.linear)!;
      expect(q.centerX, closeTo(0.8, 1e-9)); // no glide, snaps to active
    });

    test('glideDuration <= zero returns static placement (no glide)', () {
      final regions = [r(0, 1000, 0.2), r(1000, 1000, 0.8)];
      final p = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000), regions,
        glideDuration: Duration.zero)!;
      expect(p.centerX, closeTo(0.8, 1e-9));
    });

    test('default glideCurve (easeInOut) eases — early progress is below linear', () {
      // Two touching regions, centerX 0.0 -> 1.0, using the DEFAULT glide
      // duration (350ms) and DEFAULT curve. 100ms in = 0.2857 linear; easeInOut
      // starts slow so the eased centerX must be strictly less than that.
      final regions = [r(0, 1000, 0.0), r(1000, 1000, 1.0)];
      final p = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1100), regions)!; // 100ms into 350ms glide
      expect(p.centerX, greaterThan(0.0));
      expect(p.centerX, lessThan(100 / 350)); // eased < linear in the first half
    });

    test('predecessor is the greatest endTime <= start among 3+ regions', () {
      // A:[0,300) cx0.1 ; B:[300,700) cx0.5 (touches C) ; C:[700,1700) cx0.9
      final regions = [r(0, 300, 0.1), r(300, 400, 0.5), r(700, 1000, 0.9)];
      final p = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 700), regions,
        glideDuration: const Duration(milliseconds: 400), glideCurve: Curves.linear)!;
      expect(p.centerX, closeTo(0.5, 1e-9)); // glides from B (end 700), not A
    });
  });
}
