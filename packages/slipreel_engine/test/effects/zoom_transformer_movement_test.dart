import 'dart:ui' show Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  final t = ZoomTransformer();
  const videoSize = Size(1000, 1000);
  final framing = ZoomFraming.identity(videoSize);

  ZoomRegion region({
    required ZoomMovement movement,
    bool followCursor = false,
  }) =>
      ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 4),
        zoomLevel: 2,
        // 1s enter + 1s exit => hold window is [1s, 3s].
        enterDuration: const Duration(seconds: 1),
        exitDuration: const Duration(seconds: 1),
        followCursor: followCursor,
        movement: movement,
      );

  // A frame in the middle of the hold (holdProgress ~= 0.5, ramp fully in).
  const midHold = Duration(milliseconds: 2000);

  // The scale factor a matrix applies along X (row-major storage index 0).
  double scaleX(m) => m.storage[0].abs();

  test('none movement is byte-identical to a region without movement', () {
    final none = t.getTransform(
      position: midHold,
      zoomRegion: region(movement: const ZoomMovement()),
      videoSize: videoSize,
      framing: framing,
    );
    final bare = t.getTransform(
      position: midHold,
      zoomRegion: ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 4),
        zoomLevel: 2,
        enterDuration: const Duration(seconds: 1),
        exitDuration: const Duration(seconds: 1),
        followCursor: false,
      ),
      videoSize: videoSize,
      framing: framing,
    );
    expect(none.storage, bare.storage);
  });

  test('push-in enlarges the effective scale versus none', () {
    final withPush = t.getTransform(
      position: midHold,
      zoomRegion:
          region(movement: const ZoomMovement(kind: ZoomMovementKind.pushIn)),
      videoSize: videoSize,
      framing: framing,
    );
    final none = t.getTransform(
      position: midHold,
      zoomRegion: region(movement: const ZoomMovement()),
      videoSize: videoSize,
      framing: framing,
    );
    expect(scaleX(withPush), greaterThan(scaleX(none)));
  });

  test('movement is gated out during the enter ramp', () {
    // 500ms is inside the enter ramp => rampGate < 1 and holdProgress 0.
    const inRamp = Duration(milliseconds: 500);
    final withPush = t.getTransform(
      position: inRamp,
      zoomRegion:
          region(movement: const ZoomMovement(kind: ZoomMovementKind.pushIn)),
      videoSize: videoSize,
      framing: framing,
    );
    final none = t.getTransform(
      position: inRamp,
      zoomRegion: region(movement: const ZoomMovement()),
      videoSize: videoSize,
      framing: framing,
    );
    expect(scaleX(withPush), closeTo(scaleX(none), 1e-9));
  });

  test('getTransform is deterministic — same position, same matrix, '
      'regardless of call order (preview == export)', () {
    final r =
        region(movement: const ZoomMovement(kind: ZoomMovementKind.sweep));
    Object call(Duration p) => t
        .getTransform(
          position: p,
          zoomRegion: r,
          videoSize: videoSize,
          framing: framing,
        )
        .storage;
    // Sample forward, then the same positions in reverse.
    final fwd = [for (final ms in [1200, 1800, 2400]) call(Duration(milliseconds: ms))];
    final rev = [for (final ms in [2400, 1800, 1200]) call(Duration(milliseconds: ms))];
    expect(fwd[0], rev[2]);
    expect(fwd[1], rev[1]);
    expect(fwd[2], rev[0]);
  });
}
