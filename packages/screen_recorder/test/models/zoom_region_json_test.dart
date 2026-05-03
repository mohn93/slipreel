import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';

void main() {
  group('ZoomRegion JSON roundtrip', () {
    test('round-trips a fully-populated region', () {
      // Set every field to a non-default value so a missed field would
      // fail the equality check rather than coincidentally matching.
      final original = ZoomRegion(
        rect: const Rect.fromLTWH(120, 30, 800, 600),
        startTime: const Duration(milliseconds: 1234),
        duration: const Duration(milliseconds: 5678),
        zoomLevel: 3.5,
        enterDuration: const Duration(milliseconds: 250),
        exitDuration: const Duration(milliseconds: 450),
        rampCurveOverride:
            const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.7, y2: 0.9),
        followCursor: false,
        followMode: FollowMode.predictive,
        deadzoneRatio: 0.42,
        followDuration: const Duration(milliseconds: 600),
        followCurve:
            const CubicBezierCurve(x1: 0.0, y1: 1.0, x2: 1.0, y2: 0.0),
        predictiveWindow: const Duration(milliseconds: 2200),
      );

      final restored = ZoomRegion.fromJson(original.toJson());

      expect(restored, original);
    });

    test('round-trips a minimal region without curve overrides', () {
      final original = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      );

      final restored = ZoomRegion.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.rampCurveOverride, isNull);
      expect(restored.followCurve, isNull);
    });

    test('rejects unknown FollowMode names', () {
      // Forward-compat guard: an older build encountering a future
      // mode should fail loudly rather than silently fall back to
      // bounded and confuse the user.
      final json = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      ).toJson();
      json['followMode'] = 'cinematic'; // not a real mode

      expect(
        () => ZoomRegion.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing optional fields populate with defaults', () {
      // Older project files predate fields like predictiveWindow.
      // They should load with sensible defaults, not throw.
      final json = {
        'rect': {'left': 0.0, 'top': 0.0, 'width': 100.0, 'height': 100.0},
        'startTimeMicros': 0,
        'durationMicros': 1000000,
        'zoomLevel': 2.0,
        // No followMode, followDuration, deadzoneRatio, etc.
      };

      final restored = ZoomRegion.fromJson(json);
      expect(restored.followMode, FollowMode.bounded);
      expect(restored.deadzoneRatio, 0.3);
      expect(restored.followDuration, const Duration(milliseconds: 400));
      expect(restored.predictiveWindow, const Duration(milliseconds: 1500));
      expect(restored.followCursor, true);
    });
  });
}
