import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';

ZoomRegion _z({Duration? predictiveWindow}) => ZoomRegion(
      rect: const Rect.fromLTRB(0, 0, 0, 0),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2.0,
      predictiveWindow: predictiveWindow,
    );

void main() {
  group('predictiveWindow lead time clamp', () {
    test('predictiveWindow (lead time) defaults to 150ms', () {
      expect(_z().predictiveWindow, const Duration(milliseconds: 150));
    });

    test('predictiveWindow clamps above 250ms down to 250ms', () {
      expect(
        _z(predictiveWindow: const Duration(milliseconds: 1500)).predictiveWindow,
        const Duration(milliseconds: 250),
      );
    });

    test('predictiveWindow clamps below 80ms up to 80ms', () {
      expect(
        _z(predictiveWindow: const Duration(milliseconds: 10)).predictiveWindow,
        const Duration(milliseconds: 80),
      );
    });

    test('predictiveWindow in range is preserved', () {
      expect(
        _z(predictiveWindow: const Duration(milliseconds: 150)).predictiveWindow,
        const Duration(milliseconds: 150),
      );
    });
  });


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

    test('isActive is a half-open interval [start, end)', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
      );
      // endTime == 5s.
      // Active exactly at the start edge.
      expect(region.isActive(const Duration(seconds: 2)), true);
      // Active just before the end edge.
      expect(
        region.isActive(const Duration(seconds: 5) - const Duration(microseconds: 1)),
        true,
      );
      // Inactive exactly at the end edge (half-open).
      expect(region.isActive(const Duration(seconds: 5)), false);
    });

    test('activeAt covers the closed end edge with earlier-wins at shared edges',
        () {
      // A and B abut at t=2s. activeAt must report A for everything inside
      // A (including exactly endTime=2s), and B for the body of B.
      final a = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      final b = ZoomRegion(
        rect: const Rect.fromLTWH(200, 200, 100, 100),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      // Just before the seam → A.
      expect(
        ZoomRegion.activeAt(
            const Duration(seconds: 2) - const Duration(microseconds: 1),
            [a, b]),
        same(a),
      );
      // At the shared edge → A wins via loop order (closed end-edge match).
      expect(ZoomRegion.activeAt(const Duration(seconds: 2), [a, b]), same(a));
      // Just past the seam → B (A.isActive false, A.endTime != position).
      expect(
        ZoomRegion.activeAt(
            const Duration(seconds: 2) + const Duration(microseconds: 1),
            [a, b]),
        same(b),
      );
      // At B's end (closed) → B.
      expect(ZoomRegion.activeAt(const Duration(seconds: 4), [a, b]), same(b));
      // Beyond everything → null.
      expect(
        ZoomRegion.activeAt(const Duration(seconds: 5), [a, b]),
        isNull,
      );
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

  // Manual placement may position the focal over the composed canvas's
  // padding/bezel — i.e. the focal center may legitimately fall OUTSIDE
  // [0, videoSize]. The picker is the clamp authority (keeps the viewport
  // in-canvas); manual commit/preview therefore build the region with
  // `videoBounds: null` so `_constrainRect` does NOT pull the focal back
  // onto the screen. Follow-cursor and other construction keep passing
  // `videoBounds` and still clamp. These tests lock that contract.
  group('manual-placement focal clamp relaxation', () {
    const videoSize = Size(1920, 1080);
    // A focal whose CENTER sits in the padding above-left of the video
    // (negative coords) — only reachable when the zoom frames the padded
    // composed canvas.
    final paddingFocal = Rect.fromCenter(
      center: const Offset(-160, -90),
      width: videoSize.width / 2,
      height: videoSize.height / 2,
    );

    test('manual placement with videoBounds: null keeps a padding focal', () {
      final region = ZoomRegion(
        rect: paddingFocal,
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
        followCursor: false,
        // No video clamp — the picker already constrained the viewport.
        videoBounds: null,
      );
      // The focal center is preserved verbatim (not pulled to [0,0]).
      expect(region.rect.center, const Offset(-160, -90));
    });

    test('copyWith for a manual commit (videoBounds: null) keeps the focal',
        () {
      final base = ZoomRegion(
        rect: Rect.fromCenter(
          center: const Offset(960, 540),
          width: 100,
          height: 100,
        ),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
        followCursor: false,
        videoBounds: videoSize,
      );
      // Mirrors playback_screen's _onPlacementCommit: pin manual + no clamp.
      final committed = base.copyWith(
        rect: paddingFocal,
        followCursor: false,
        videoBounds: null,
      );
      expect(committed.rect.center, const Offset(-160, -90));
      expect(committed.followCursor, isFalse);

      // And the padding focal survives serialization unchanged.
      final restored = ZoomRegion.fromJson(committed.toJson());
      expect(restored.rect.center, const Offset(-160, -90));
    });

    test('follow-cursor construction still clamps the focal to video bounds',
        () {
      final region = ZoomRegion(
        rect: paddingFocal,
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
        followCursor: true,
        // Other construction keeps passing videoBounds → _constrainRect pulls
        // the rect back so it stays inside [0, videoSize].
        videoBounds: videoSize,
      );
      expect(region.rect.left, greaterThanOrEqualTo(0));
      expect(region.rect.top, greaterThanOrEqualTo(0));
      expect(region.rect.right, lessThanOrEqualTo(videoSize.width));
      expect(region.rect.bottom, lessThanOrEqualTo(videoSize.height));
    });
  });
}
