import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;
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

  test('movement magnitude scales with the region hold length', () {
    // 1s ramps each side: a 4s region holds for 2s, a 6s region for 4s.
    ZoomRegion withHold(Duration duration, ZoomMovement movement) =>
        ZoomRegion(
          rect: const Rect.fromLTWH(600, 600, 100, 100),
          startTime: Duration.zero,
          duration: duration,
          zoomLevel: 2,
          enterDuration: const Duration(seconds: 1),
          exitDuration: const Duration(seconds: 1),
          followCursor: false,
          movement: movement,
        );
    const push = ZoomMovement(kind: ZoomMovementKind.pushIn);
    double extraAt(Duration duration, Duration position) {
      final none = t.getTransform(
        position: position,
        zoomRegion: withHold(duration, const ZoomMovement()),
        videoSize: videoSize,
        framing: framing,
      );
      final pushed = t.getTransform(
        position: position,
        zoomRegion: withHold(duration, push),
        videoSize: videoSize,
        framing: framing,
      );
      return scaleX(pushed) / scaleX(none) - 1.0;
    }

    // Sample 1ms before each hold ends so holdProgress ~= 1 on both.
    final short = extraAt(
      const Duration(seconds: 4),
      const Duration(milliseconds: 2999),
    );
    final long = extraAt(
      const Duration(seconds: 6),
      const Duration(milliseconds: 4999),
    );
    expect(long, closeTo(kPushInSubtleExtra, 1e-4));
    expect(short, closeTo(long * (2.0 / kMovementFullHoldSeconds), 1e-4));
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

  test('scaled enter ramp does not start movement before resolved hold', () {
    final withSweep = region(
      movement: const ZoomMovement(kind: ZoomMovementKind.sweep),
    );
    final withoutMovement = region(movement: const ZoomMovement());
    // Raw enter is 1s, but the 1.5x feel scale resolves it to 1.5s. At 1.25s
    // the old hold envelope was already active even though zoom was entering.
    const inResolvedEnter = Duration(milliseconds: 1250);
    final swept = t.getTransform(
      position: inResolvedEnter,
      zoomRegion: withSweep,
      videoSize: videoSize,
      rampDurationScale: 1.5,
      framing: framing,
    );
    final none = t.getTransform(
      position: inResolvedEnter,
      zoomRegion: withoutMovement,
      videoSize: videoSize,
      rampDurationScale: 1.5,
      framing: framing,
    );

    expect(swept.storage, none.storage);
  });

  test('scaled exit starts only after movement reaches full strength', () {
    final withSweep = region(
      movement: const ZoomMovement(kind: ZoomMovementKind.sweep),
    );
    const rampScale = 1.5;
    // Resolved ramps are 1.5s each, so the 4s region's hold is [1.5s, 2.5s].
    // Sampling around 2.5s catches an exit calculation that accidentally uses
    // the raw 1s exit duration (which would put the boundary at 3s).
    final magnitudes = <double>[];
    for (final us in [2499999, 2500000, 2500001]) {
      final transform = t.getTransform(
        position: Duration(microseconds: us),
        zoomRegion: withSweep,
        videoSize: videoSize,
        rampDurationScale: rampScale,
        framing: framing,
      );
      magnitudes.add(transform.storage[2].abs());
    }
    // The resolved hold is 1s, below the full-strength threshold, so the
    // sweep plays at a proportionally reduced angle.
    final holdScale = 1.0 / kMovementFullHoldSeconds;
    final expectedFull =
        2.0 * math.sin(kSweepSubtleDeg * holdScale * math.pi / 180.0);

    expect(magnitudes[1], closeTo(expectedFull, 1e-9));
    expect(magnitudes[0], lessThanOrEqualTo(magnitudes[1]));
    expect(magnitudes[2], lessThanOrEqualTo(magnitudes[1]));
    expect((magnitudes[1] - magnitudes[0]).abs(), lessThan(1e-6));
    // The configured cubic ramp has a small non-zero departure immediately
    // after the boundary; it must still be continuous rather than a yaw step.
    expect((magnitudes[1] - magnitudes[2]).abs(), lessThan(1e-4));
  });

  test('compressed zero-span hold never steps sweep on mid-ramp', () {
    ZoomRegion compressed(ZoomMovement movement) => ZoomRegion(
          rect: const Rect.fromLTWH(600, 600, 100, 100),
          startTime: Duration.zero,
          duration: const Duration(seconds: 1),
          zoomLevel: 2,
          enterDuration: const Duration(milliseconds: 800),
          exitDuration: const Duration(milliseconds: 800),
          followCursor: false,
          movement: movement,
        );
    final withSweep = compressed(
      const ZoomMovement(
        kind: ZoomMovementKind.sweep,
        intensity: ZoomMovementIntensity.dramatic,
      ),
    );
    final withoutMovement = compressed(const ZoomMovement());

    // The former raw-duration envelope jumped at 200ms (raw holdEnd) even
    // though resolved ramps squeeze to 500ms + 500ms and leave no hold.
    for (final us in [199999, 200000, 200001, 499999, 500000, 500001]) {
      final position = Duration(microseconds: us);
      final swept = t.getTransform(
        position: position,
        zoomRegion: withSweep,
        videoSize: videoSize,
        framing: framing,
      );
      final none = t.getTransform(
        position: position,
        zoomRegion: withoutMovement,
        videoSize: videoSize,
        framing: framing,
      );
      expect(swept.storage, none.storage, reason: 'position: ${us}us');
    }
  });

  test('cursor-follow sweep transform crosses canvas center continuously', () {
    final r = region(
      movement: const ZoomMovement(
        kind: ZoomMovementKind.sweep,
        intensity: ZoomMovementIntensity.dramatic,
      ),
      followCursor: true,
    );
    final left = t.getTransform(
      position: midHold,
      zoomRegion: r,
      videoSize: videoSize,
      focalPoint: const Offset(499, 500),
      framing: framing,
    );
    final center = t.getTransform(
      position: midHold,
      zoomRegion: r,
      videoSize: videoSize,
      focalPoint: const Offset(500, 500),
      framing: framing,
    );
    final right = t.getTransform(
      position: midHold,
      zoomRegion: r,
      videoSize: videoSize,
      focalPoint: const Offset(501, 500),
      framing: framing,
    );

    // Matrix4's Y-rotation sine lives in entry 2 after the base scale is
    // composed. The old binary direction changed this entry by ~0.35 across
    // these adjacent focals; a continuous live direction keeps it microscopic.
    expect(center.storage[2], closeTo(0.0, 1e-12));
    expect(left.storage[2], closeTo(-right.storage[2], 1e-12));
    expect((right.storage[2] - left.storage[2]).abs(), lessThan(0.001));
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
