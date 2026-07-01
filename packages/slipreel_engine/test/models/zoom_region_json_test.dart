import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';

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
        manualPanBackload: 0.76,
        followCursor: false,
        followMode: FollowMode.predictive,
        deadzoneRatio: 0.42,
        followDuration: const Duration(milliseconds: 600),
        predictiveWindow: const Duration(milliseconds: 200),
      );

      final restored = ZoomRegion.fromJson(original.toJson());

      expect(restored, original);
    });

    test('round-trips a minimal region without ramp curve override', () {
      final original = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      );

      final restored = ZoomRegion.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.rampCurveOverride, isNull);
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
      // Default bumped from 0.3 → 0.8 alongside the slider cap going
      // from 1.0 → 1.5 — "the camera holds unless the cursor really
      // wanders" is the new out-of-the-box feel.
      expect(restored.deadzoneRatio, 0.8);
      // Default catch-up spring settle time: 400 → 700 → 850 ms. Below
      // ~750 ms the camera hugs the raw cursor path and the follow reads as
      // rigidly linear; 850 ms smooths the corners into a curve.
      expect(restored.followDuration, const Duration(milliseconds: 850));
      expect(restored.predictiveWindow, const Duration(milliseconds: 150));
      expect(restored.followCursor, true);
    });

    test('legacy followSmoothing / followCurve keys load without error', () {
      // Earlier builds wrote a `followSmoothing` slider value and an
      // optional `followCurve` bezier into the JSON. Both knobs were
      // dropped when the focal controller switched to a critically-
      // damped spring; old sidecar files must still load. fromJson
      // simply does not consult those keys — Dart map lookups for
      // absent keys return null and are otherwise inert.
      final json = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      ).toJson();
      json['followSmoothing'] = 0.42;
      json['followCurve'] = const CubicBezierCurve(
              x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4)
          .toJson();

      expect(() => ZoomRegion.fromJson(json), returnsNormally);
    });
  });
}
