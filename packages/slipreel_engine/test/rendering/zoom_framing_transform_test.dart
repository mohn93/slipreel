// Integration test: device ZoomFraming produces matching preview/export
// focal + transform geometry.
//
// Proves two invariants for the device framing path:
//
//  1. The matrix produced by ZoomTransformer.getTransform(framing: device)
//     translates by `-z * framing.centerOffset(edgeFocal, z)` (the canvas-
//     space centering), confirming the device path routes through canvas
//     space rather than raw video space.
//
//  2. The device clamp differs from the video-bounds clamp for an edge focal,
//     i.e. framing.clampFocal(edge, z) != ZoomTransformer.clampFocalToBounds(
//     edge, videoSize, z) — proving the device path clamps in canvas space
//     and preserves the bezel padding.

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  // iPhone 14-ish recording in a device bezel: the video occupies a sub-rect
  // of a larger canvas, offset + slightly scaled.
  const videoSize = Size(1170, 2532);
  const videoRect = Rect.fromLTWH(100, 120, 1200, 2596);
  const canvasSize = Size(1400, 2900);

  final deviceFraming = ZoomFraming.device(
    videoSize: videoSize,
    videoRect: videoRect,
    canvasSize: canvasSize,
  );

  // Edge focal in source-video coords: near the right/bottom corner.
  const edgeFocal = Offset(1100, 2400);
  const zoomLevel = 2.0;

  // A mid-hold zoom region so the active z == zoomLevel (no ramp easing).
  final region = ZoomRegion(
    rect: Rect.fromLTWH(0, 0, videoSize.width, videoSize.height),
    startTime: Duration.zero,
    duration: const Duration(seconds: 10),
    zoomLevel: zoomLevel,
    enterDuration: Duration.zero,
    exitDuration: Duration.zero,
    followCursor: false,
  );
  // Probe at a time well inside the hold (no ramp): z == zoomLevel exactly.
  const probeTime = Duration(seconds: 5);

  group('ZoomFraming device-path transform parity', () {
    test('getTransform translation equals -z * centerOffset for device framing',
        () {
      final transformer = ZoomTransformer();
      final matrix = transformer.getTransform(
        position: probeTime,
        zoomRegion: region,
        videoSize: videoSize,
        focalPoint: edgeFocal,
        framing: deviceFraming,
      );

      // The zoom matrix is scale(z) * translate(-z*c) where c is the
      // canvas-space center-offset of the clamped focal. Column-major
      // Matrix4: translation is at indices [12], [13].
      final tx = matrix.storage[12];
      final ty = matrix.storage[13];

      final centerOff = deviceFraming.centerOffset(edgeFocal, zoomLevel);
      final expectedTx = -zoomLevel * centerOff.dx;
      final expectedTy = -zoomLevel * centerOff.dy;

      expect(
        tx,
        closeTo(expectedTx, 0.5),
        reason:
            'matrix tx must equal -z * centerOffset.dx for device framing',
      );
      expect(
        ty,
        closeTo(expectedTy, 0.5),
        reason:
            'matrix ty must equal -z * centerOffset.dy for device framing',
      );
    });

    test('device clamp differs from video-bounds clamp for an edge focal', () {
      // Device framing clamps in canvas space, so the padded margins are
      // preserved. The plain video-bounds clamp ignores the bezel padding and
      // lets the viewport crowd the raw video edge. For an edge focal the two
      // must disagree — that disagreement is the whole point of device framing.
      final deviceClamped = deviceFraming.clampFocal(edgeFocal, zoomLevel);
      final videoClamped = ZoomTransformer.clampFocalToBounds(
        edgeFocal,
        videoSize,
        zoomLevel,
      );

      expect(
        (deviceClamped - videoClamped).distance,
        greaterThan(1.0),
        reason:
            'device clamp must differ from video-bounds clamp for an edge '
            'focal — proves clamping is in canvas space (padding preserved)',
      );
    });

    test('identity framing clamp matches ZoomTransformer.clampFocalToBounds',
        () {
      // Non-device path must stay byte-identical: identity framing delegates
      // directly to ZoomTransformer.clampFocalToBounds.
      final identityFraming = ZoomFraming.identity(videoSize);
      const inBoundsFocal = Offset(800, 1200); // well inside video bounds

      final identityClamped = identityFraming.clampFocal(
        inBoundsFocal,
        zoomLevel,
      );
      final directClamped = ZoomTransformer.clampFocalToBounds(
        inBoundsFocal,
        videoSize,
        zoomLevel,
      );

      expect(
        identityClamped,
        equals(directClamped),
        reason:
            'identity framing must delegate to clampFocalToBounds exactly',
      );
    });
  });
}
