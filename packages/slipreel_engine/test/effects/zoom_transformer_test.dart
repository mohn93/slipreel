import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';
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

  group('ZoomTransformer.clampFocalToBoundsRadial', () {
    const videoSize = Size(1920, 1080);
    const centre = Offset(960, 540);

    test('returns the video center when the box has collapsed (z <= 1)', () {
      expect(
          ZoomTransformer.clampFocalToBoundsRadial(
              const Offset(400, 600), videoSize, 1.0),
          centre);
    });

    test('leaves an in-box point unchanged (no-op)', () {
      // At z=2 the box half-extents are (480, 270); (900, 520) is inside.
      const p = Offset(900, 520);
      final out = ZoomTransformer.clampFocalToBoundsRadial(p, videoSize, 2.0);
      expect((out - p).distance, lessThan(1e-9));
    });

    test('an out-of-box off-center point is scaled onto the box, staying '
        'collinear with the center', () {
      // z=1.1 → box half-extents ((W/2)(1-1/1.1), …) ≈ (87.3, 49.1). The
      // straight ray center→(400,600) far exceeds that, so it gets scaled
      // back to the box boundary along the SAME ray.
      const target = Offset(400, 600);
      final out =
          ZoomTransformer.clampFocalToBoundsRadial(target, videoSize, 1.1);
      // Collinear: cross product of (target-centre) and (out-centre) ≈ 0.
      final d1 = target - centre;
      final d2 = out - centre;
      expect((d1.dx * d2.dy - d1.dy * d2.dx).abs(), lessThan(1e-6));
      // On the boundary: the per-axis clamp at the same z is now a no-op.
      final reclamped =
          ZoomTransformer.clampFocalToBounds(out, videoSize, 1.1);
      expect((reclamped - out).distance, lessThan(1e-6));
    });

    test('a zero-offset axis is unconstrained (point moves only along the '
        'nonzero axis)', () {
      // Pure-horizontal offset: y stays at center, x scales to the x bound.
      const target = Offset(0, 540); // far left, vertically centered
      final out =
          ZoomTransformer.clampFocalToBoundsRadial(target, videoSize, 1.5);
      expect(out.dy, closeTo(540, 1e-9));
      // x bound at z=1.5 is halfW = (W/2)(1-1/1.5) = 320 left of center.
      expect(out.dx, closeTo(960 - 320, 1e-6));
    });
  });

  group('ZoomTransformer with ZoomFraming', () {
    final t = ZoomTransformer();
    final region = ZoomRegion(
      startTime: Duration.zero,
      duration: const Duration(seconds: 3),
      rect: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
      zoomLevel: 2.0,
      enterDuration: const Duration(milliseconds: 1),
      exitDuration: const Duration(milliseconds: 1),
    );
    const videoSize = Size(1170, 2532);
    // Mid-hold so z == zoomLevel (2.0).
    const pos = Duration(milliseconds: 1500);

    test('framing:null is identical to legacy getTransform', () {
      final a = t.getTransform(
          position: pos, zoomRegion: region, videoSize: videoSize,
          focalPoint: const Offset(900, 1800));
      final b = t.getTransform(
          position: pos, zoomRegion: region, videoSize: videoSize,
          focalPoint: const Offset(900, 1800),
          framing: ZoomFraming.identity(videoSize));
      expect(a.storage, b.storage);
    });

    test('device framing translates by canvas centerOffset', () {
      const canvasSize = Size(1400, 2900);
      final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
      final framing = ZoomFraming.device(
          videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);
      const focal = Offset(1170, 1266); // right edge
      // `region` here is a follow-cursor region (followCursor defaults to
      // true), so the transform still center-and-clamps via centerOffset.
      final m = t.getTransform(
          position: pos, zoomRegion: region, videoSize: videoSize,
          focalPoint: focal, framing: framing);
      final z = m.storage[0];
      final pcr = framing.centerOffset(focal, z);
      // matrix = translate(-z*pcr) * scale(z): storage[12]/[13] hold translation.
      expect(m.storage[12], closeTo(-z * pcr.dx, 1e-6));
      expect(m.storage[13], closeTo(-z * pcr.dy, 1e-6));
    });
  });

  group('ZoomTransformer manual magnify-in-place', () {
    final t = ZoomTransformer();
    const videoSize = Size(1170, 2532);
    final centre = Offset(videoSize.width / 2, videoSize.height / 2);

    // A MANUAL placement (followCursor:false) with an edge-hugging rect.center.
    ZoomRegion manualAt(Offset rectCenter, double zoomLevel) => ZoomRegion(
          rect: Rect.fromCenter(center: rectCenter, width: 0, height: 0),
          startTime: Duration.zero,
          duration: const Duration(seconds: 3),
          zoomLevel: zoomLevel,
          enterDuration: const Duration(milliseconds: 1),
          exitDuration: const Duration(milliseconds: 1),
          followCursor: false,
        );

    // Mid-hold so z == zoomLevel.
    const hold = Duration(milliseconds: 1500);

    // Map a source-video point through the transform into center-relative
    // viewport coordinates (the space `alignment: Alignment.center` operates
    // in). The transform consumes center-relative inputs, so subtract the
    // center first.
    Offset onScreen(Matrix4 m, Offset videoPoint) {
      final rel = videoPoint - centre;
      final v = m.transform3(vector.Vector3(rel.dx, rel.dy, 0));
      return Offset(v.x, v.y);
    }

    test('CORE REGRESSION GUARD: an edge placement lands at the same '
        'on-screen position for zoomLevel 5 and zoomLevel 2', () {
      // ~6% from the top — the exact edge-placement case the spec measured as
      // drifting hundreds of px between 5x and 2x under center-and-clamp.
      const placement = Offset(585, 160); // horizontally centered, near top

      final m5 = t.getTransform(
        position: hold,
        zoomRegion: manualAt(placement, 5.0),
        videoSize: videoSize,
        focalPoint: placement,
      );
      final m2 = t.getTransform(
        position: hold,
        zoomRegion: manualAt(placement, 2.0),
        videoSize: videoSize,
        focalPoint: placement,
      );

      final at5 = onScreen(m5, placement);
      final at2 = onScreen(m2, placement);

      // Magnify-in-place keeps the placed point at the exact SAME frame
      // fraction at every zoom level. This assertion FAILS on main (where
      // center-and-clamp re-frames the placement by a zoom-dependent margin).
      expect(at2.dx, closeTo(at5.dx, 1e-6));
      expect(at2.dy, closeTo(at5.dy, 1e-6));
    });

    test('a centered manual placement stays at the viewport center at all '
        'zoom levels', () {
      for (final z in <double>[1.5, 2.0, 3.0, 5.0]) {
        final m = t.getTransform(
          position: hold,
          zoomRegion: manualAt(centre, z),
          videoSize: videoSize,
          focalPoint: centre,
        );
        final at = onScreen(m, centre);
        expect(at.dx, closeTo(0, 1e-6),
            reason: 'centered placement must stay centered at z=$z');
        expect(at.dy, closeTo(0, 1e-6),
            reason: 'centered placement must stay centered at z=$z');
      }
    });

    test('manual placement translation matches centerOffsetInPlace (not the '
        'clamped centerOffset)', () {
      const placement = Offset(585, 160);
      final framing = ZoomFraming.identity(videoSize);
      final m = t.getTransform(
        position: hold,
        zoomRegion: manualAt(placement, 5.0),
        videoSize: videoSize,
        focalPoint: placement,
        framing: framing,
      );
      final z = m.storage[0];
      final pcr = framing.centerOffsetInPlace(placement, z);
      expect(m.storage[12], closeTo(-z * pcr.dx, 1e-6));
      expect(m.storage[13], closeTo(-z * pcr.dy, 1e-6));
    });
  });
}
