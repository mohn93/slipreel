import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

void main() {
  group('ZoomTransformer', () {
    test('should return identity matrix when no zoom is active', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1), // Before zoom starts
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      expect(matrix, Matrix4.identity());
    });

    test('should calculate zoom transform at peak', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(200, 150, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 3), // At 0.5 progress (peak)
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // At peak, should have maximum zoom
      expect(matrix, isNot(Matrix4.identity()));

      // Scale component should reflect zoom level
      final scale = matrix.getMaxScaleOnAxis();
      expect(scale, greaterThan(1.0));
    });

    test('should apply ease-in-out curve', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(200, 150, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrixStart = transformer.getTransform(
        position: const Duration(milliseconds: 100),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      final matrixMid = transformer.getTransform(
        position: const Duration(seconds: 1),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // Scale should be less at start than at middle (ease-in-out)
      expect(
        matrixStart.getMaxScaleOnAxis(),
        lessThan(matrixMid.getMaxScaleOnAxis()),
      );
    });

    test('focal point at peak zoom maps to viewport center', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(150, 150, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      const videoSize = Size(800, 600);
      const focal = Offset(200, 200); // somewhere away from center

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1), // peak
        zoomRegion: zoomRegion,
        videoSize: videoSize,
        focalPoint: focal,
      );

      // Apply matrix to focal point in center-relative coords; result must
      // be the origin (= viewport center under alignment.center).
      final focalCenterRel = focal -
          Offset(videoSize.width / 2, videoSize.height / 2);
      final v = matrix.transform3(
          vector.Vector3(focalCenterRel.dx, focalCenterRel.dy, 0));
      expect(v.x, closeTo(0, 0.001));
      expect(v.y, closeTo(0, 0.001));
    });

    test('three-phase curve holds at full zoom between enter and exit', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 6),
        zoomLevel: 2.0,
        enterDuration: const Duration(milliseconds: 500),
        exitDuration: const Duration(milliseconds: 500),
      );
      const videoSize = Size(800, 600);

      double zoomAt(Duration t) => transformer
          .getTransform(
            position: t,
            zoomRegion: zoomRegion,
            videoSize: videoSize,
          )
          .getMaxScaleOnAxis();

      // Mid-enter: somewhere between 1× and 2×.
      final midEnter = zoomAt(const Duration(milliseconds: 250));
      expect(midEnter, greaterThan(1.0));
      expect(midEnter, lessThan(2.0));

      // After enter, in the hold region: should be exactly 2×.
      expect(zoomAt(const Duration(seconds: 1)), closeTo(2.0, 0.001));
      expect(zoomAt(const Duration(seconds: 3)), closeTo(2.0, 0.001));
      expect(zoomAt(const Duration(seconds: 5)), closeTo(2.0, 0.001));

      // Mid-exit: between 2× and 1×.
      final midExit = zoomAt(const Duration(milliseconds: 5750));
      expect(midExit, greaterThan(1.0));
      expect(midExit, lessThan(2.0));
    });

    test('zoom factor scales enter+exit when total ramp exceeds duration',
        () {
      final transformer = ZoomTransformer();
      // Region is 200ms but enter+exit asks for 1s — has to be squeezed.
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(milliseconds: 200),
        zoomLevel: 2.0,
        enterDuration: const Duration(milliseconds: 500),
        exitDuration: const Duration(milliseconds: 500),
      );
      // Should still produce a valid zoom factor between 1 and 2 across
      // the region without crashing or going out of range.
      for (var t = 0; t <= 200; t += 25) {
        final s = transformer
            .getTransform(
              position: Duration(milliseconds: t),
              zoomRegion: zoomRegion,
              videoSize: const Size(800, 600),
            )
            .getMaxScaleOnAxis();
        expect(s, greaterThanOrEqualTo(1.0));
        expect(s, lessThanOrEqualTo(2.0001));
      }
    });

    test('focal point near edge clamps so visible area stays in bounds', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      const videoSize = Size(800, 600);
      // Focal at the very top-left corner — clamp must pull it inward to
      // keep the (zoomed) visible window inside the frame.
      const focal = Offset(0, 0);

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1),
        zoomRegion: zoomRegion,
        videoSize: videoSize,
        focalPoint: focal,
      );

      // After transform, the visible window's top-left in source coords
      // should be (0, 0), not negative — i.e. we don't try to display
      // outside the source. Equivalently, the source point (0,0) should
      // map to the top-left corner of the viewport, not beyond.
      final v = matrix.transform3(
          vector.Vector3(-videoSize.width / 2, -videoSize.height / 2, 0));
      // Top-left of the viewport in center-relative coords is exactly that.
      expect(v.x, closeTo(-videoSize.width / 2, 0.5));
      expect(v.y, closeTo(-videoSize.height / 2, 0.5));
    });
  });
}
