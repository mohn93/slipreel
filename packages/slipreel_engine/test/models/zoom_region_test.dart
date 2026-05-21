import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';

void main() {
  group('ZoomRegion', () {
    test('should create zoom region with valid rect and timing', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
      );

      expect(region.rect, const Rect.fromLTWH(100, 100, 200, 150));
      expect(region.startTime, const Duration(seconds: 2));
      expect(region.duration, const Duration(seconds: 3));
      expect(region.endTime, const Duration(seconds: 5));
      expect(region.zoomLevel, 2.0);
    });

    test('should check if position is within zoom region', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
      );

      expect(region.isActive(const Duration(seconds: 1)), false);
      expect(region.isActive(const Duration(seconds: 3)), true);
      expect(region.isActive(const Duration(seconds: 6)), false);
    });

    test('should calculate progress within zoom region', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 4),
        zoomLevel: 2.0,
      );

      expect(region.getProgress(const Duration(seconds: 2)), 0.0);
      expect(region.getProgress(const Duration(seconds: 4)), 0.5);
      expect(region.getProgress(const Duration(seconds: 6)), 1.0);
    });

    test('should constrain to video bounds', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(-10, -10, 1000, 1000),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
        videoBounds: const Size(800, 600),
      );

      expect(region.rect.left, greaterThanOrEqualTo(0));
      expect(region.rect.top, greaterThanOrEqualTo(0));
      expect(region.rect.right, lessThanOrEqualTo(800));
      expect(region.rect.bottom, lessThanOrEqualTo(600));
    });

    test('should clamp zoom level between 1.0 and 5.0', () {
      final region1 = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 0.5, // Too low
      );

      final region2 = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 10.0, // Too high
      );

      expect(region1.zoomLevel, 1.0);
      expect(region2.zoomLevel, 5.0);
    });
  });

  group('ZoomRegion.rampCurveOverride', () {
    test('defaults to null', () {
      final z = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      expect(z.rampCurveOverride, isNull);
    });

    test('copyWith sets and clears override', () {
      final z = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      const override = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      final z2 = z.copyWith(rampCurveOverride: override);
      expect(z2.rampCurveOverride, override);

      // copyWith with explicit null: use the sentinel-style overload to
      // distinguish "leave as-is" from "clear".
      final z3 = z2.copyWith(clearRampCurveOverride: true);
      expect(z3.rampCurveOverride, isNull);
    });
  });
}
