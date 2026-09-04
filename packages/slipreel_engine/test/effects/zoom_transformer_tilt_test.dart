import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/animation.dart' show Cubic;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

void main() {
  final t = ZoomTransformer();
  const videoSize = Size(1000, 1000);
  final framing = ZoomFraming.identity(videoSize);

  ({double pitch, double yaw}) orientation(Matrix4 matrix) => (
    yaw: math.atan2(matrix.entry(0, 2), matrix.entry(2, 2)),
    pitch: math.atan2(
      -matrix.entry(1, 2),
      math.sqrt(
        matrix.entry(0, 2) * matrix.entry(0, 2) +
            matrix.entry(2, 2) * matrix.entry(2, 2),
      ),
    ),
  );

  void expectIdentity(Matrix4 matrix) {
    expect(matrix.storage, orderedEquals(Matrix4.identity().storage));
  }

  ZoomRegion region({required Tilt3D tilt, bool followCursor = true}) =>
      ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2,
        enterDuration: Duration.zero,
        exitDuration: Duration.zero,
        followCursor: followCursor,
        tilt: tilt,
      );

  // Mid-hold so z == zoomLevel (progress == 1).
  const pos = Duration(seconds: 1);

  test('flat tilt is byte-identical to a region with no tilt config', () {
    final flat = t.getTransform(
      position: pos,
      zoomRegion: region(tilt: const Tilt3D()),
      videoSize: videoSize,
      focalPoint: const Offset(650, 650),
      framing: framing,
    );
    // Perspective row must be identity (no setEntry(3,2)).
    expect(flat.entry(3, 2), 0.0);
    expect(flat.entry(3, 3), 1.0);
  });

  test('3D tilt sets a non-zero perspective entry and rotation', () {
    final tilted = t.getTransform(
      position: pos,
      zoomRegion: region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
      videoSize: videoSize,
      focalPoint: const Offset(650, 650),
      framing: framing,
    );
    expect(tilted.entry(3, 2), isNot(0.0));
  });

  test('manual placement (followCursor:false) also tilts', () {
    final tilted = t.getTransform(
      position: pos,
      zoomRegion: region(
        tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
        followCursor: false,
      ),
      videoSize: videoSize,
      framing: framing,
    );
    expect(tilted.entry(3, 2), isNot(0.0));
  });

  test('resolution-independence: a focal point projects to the same '
      'normalized screen position at 1080p and 4K', () {
    // 2x canvas == 4K of the same scene. Same normalized focal, same tilt.
    final f1 = ZoomFraming.identity(const Size(1920, 1080));
    final f2 = ZoomFraming.identity(const Size(3840, 2160));
    final r = region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    final m1 = t.getTransform(
      position: pos,
      zoomRegion: r,
      videoSize: const Size(1920, 1080),
      focalPoint: const Offset(1400, 800),
      framing: f1,
    );
    final m2 = t.getTransform(
      position: pos,
      zoomRegion: r,
      videoSize: const Size(3840, 2160),
      focalPoint: const Offset(2800, 1600),
      framing: f2,
    );
    // perspective entry scales by 1/2 between the two resolutions.
    expect(m1.entry(3, 2), closeTo(m2.entry(3, 2) * 2, 1e-9));
  });

  group('follow-camera ramp direction', () {
    ZoomRegion rampRegion({
      Tilt3D tilt = const Tilt3D(),
      ZoomMovement movement = const ZoomMovement(),
    }) => ZoomRegion(
      rect: const Rect.fromLTWH(600, 400, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2,
      enterDuration: const Duration(milliseconds: 500),
      exitDuration: const Duration(milliseconds: 500),
      followCursor: true,
      tilt: tilt,
      movement: movement,
    );

    double yawRadians(Matrix4 matrix) => orientation(matrix).yaw;

    test('zoom-out tilt uses one full time-based orientation envelope', () {
      final matrix = t.getTransform(
        position: const Duration(milliseconds: 1750),
        zoomRegion: rampRegion(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        videoSize: videoSize,
        // The controller has recentered a settled normalized x=0.8 focal to
        // x=0.4 at the halfway point of the exit ramp.
        focalPoint: const Offset(700, 500),
        framing: framing,
      );

      // 4deg * settledDirection(0.8) * exitGate(0.5)=0.8deg. The return
      // begins immediately and is already mostly flat by the ramp midpoint.
      expect(yawRadians(matrix).abs(), closeTo(0.8 * math.pi / 180, 1e-3));
    });

    test('zoom-out Sweep keeps its direction while fading once', () {
      final matrix = t.getTransform(
        position: const Duration(milliseconds: 1750),
        zoomRegion: rampRegion(
          movement: const ZoomMovement(kind: ZoomMovementKind.sweep),
        ),
        videoSize: videoSize,
        focalPoint: const Offset(700, 500),
        framing: framing,
      );

      // smoothstep(0.8)=0.896; 5deg * 0.896 * exitGate(0.5)=1.12deg, then
      // scaled by the 1s hold (below the full-strength threshold).
      final holdScale = 1.0 / kMovementFullHoldSeconds;
      expect(
        yawRadians(matrix).abs(),
        closeTo(1.12 * holdScale * math.pi / 180, 1.2e-3 * holdScale),
      );
    });

    test('manual placement direction is not ramp-compensated', () {
      final matrix = t.getTransform(
        position: const Duration(milliseconds: 1750),
        zoomRegion: rampRegion(
          tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
        ).copyWith(followCursor: false),
        videoSize: videoSize,
        focalPoint: const Offset(700, 500),
        framing: framing,
      );

      // normalized x=0.4 remains literal: 4deg * 0.4 * 0.25 = 0.4deg.
      expect(yawRadians(matrix).abs(), closeTo(0.4 * math.pi / 180, 5e-4));
    });

    test('orientation progress is monotonic with zero-velocity endpoints', () {
      final samples = <double>[
        for (var i = 0; i <= 100; i++)
          ZoomTransformer.orientationRampProgress(i / 100.0),
      ];

      expect(samples.first, 0.0);
      expect(samples.last, 1.0);
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i], greaterThan(samples[i - 1]));
      }
      expect(ZoomTransformer.orientationRampProgress(0.5), 0.5);
      expect(samples[1] - samples[0], lessThan(0.001));
      expect(samples[100] - samples[99], lessThan(0.001));
    });

    test('orientation exit unwinds immediately then decelerates into flat', () {
      final samples = <double>[
        for (var i = 0; i <= 10; i++)
          ZoomTransformer.orientationExitGate(i / 10.0),
      ];

      expect(samples.first, 1.0);
      expect(samples.last, 0.0);
      final angularSteps = <double>[
        for (var i = 1; i < samples.length; i++) samples[i - 1] - samples[i],
      ];
      for (var i = 1; i < angularSteps.length; i++) {
        expect(angularSteps[i], lessThan(angularSteps[i - 1]));
      }
      // There is no initial plateau and no residual angle left for the region
      // boundary to clear on the following frame.
      expect(angularSteps.first, greaterThan(0.15));
      expect(angularSteps.last, lessThan(0.02));
    });

    test('Smooth scale curve cannot concentrate the 3D unwind', () {
      const smoothCurve = Cubic(0.65, 0.0, 0.35, 1.0);
      final r = rampRegion(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
      const exitProgress = 0.25;
      final scaleGate = 1.0 - smoothCurve.transform(exitProgress);
      final matrix = t.getTransform(
        position: const Duration(milliseconds: 1625),
        zoomRegion: r,
        videoSize: videoSize,
        // Match the controller's lock-step recentering so direction recovery
        // resolves the settled normalized x=0.8 focal.
        focalPoint: Offset(500 + 400 * scaleGate, 500),
        rampCurve: smoothCurve,
        framing: framing,
      );
      final expectedGate = ZoomTransformer.orientationExitGate(exitProgress);

      expect(
        yawRadians(matrix).abs(),
        closeTo(4.0 * 0.8 * expectedGate * math.pi / 180, 5e-4),
      );
    });
  });

  group('exit boundary regression', () {
    const smoothCurve = Cubic(0.65, 0.0, 0.35, 1.0);
    const rampDurationScale = 1.7;
    const frameCount = 51; // Approximately 60 fps across the scaled 850 ms.

    ZoomRegion exitRegion({
      required bool followCursor,
      Tilt3D tilt = const Tilt3D(),
      ZoomMovement movement = const ZoomMovement(),
      Duration duration = const Duration(milliseconds: 2800),
    }) => ZoomRegion(
      rect: const Rect.fromLTWH(800, 800, 100, 100),
      startTime: Duration.zero,
      duration: duration,
      zoomLevel: 1.5,
      enterDuration: const Duration(milliseconds: 500),
      exitDuration: const Duration(milliseconds: 500),
      followCursor: followCursor,
      tilt: tilt,
      movement: movement,
    );

    List<({double pitch, double yaw})> sampleExit({
      required ZoomRegion region,
      required Offset Function(double exitProgress) focalAt,
      Offset? Function(double exitProgress)? exitOrientationFocalAt,
    }) {
      final ramps = region.resolvedRampsUs(rampDurationScale);
      final endUs = region.endTime.inMicroseconds;
      final exitStartUs = endUs - ramps.exitUs;
      return <({double pitch, double yaw})>[
        for (var i = 0; i <= frameCount; i++)
          orientation(
            t.getTransform(
              position: Duration(
                microseconds:
                    exitStartUs + (ramps.exitUs * i / frameCount).round(),
              ),
              zoomRegion: region,
              videoSize: videoSize,
              focalPoint: focalAt(i / frameCount),
              exitOrientationFocalPoint: exitOrientationFocalAt?.call(
                i / frameCount,
              ),
              rampCurve: smoothCurve,
              rampDurationScale: rampDurationScale,
              framing: framing,
            ),
          ),
      ];
    }

    void expectDeceleratingReturn(List<double> signedAngles) {
      final angles = signedAngles.map((angle) => angle.abs()).toList();
      expect(angles.first, greaterThan(0.01));
      expect(angles.last, 0.0);

      for (var i = 1; i < angles.length; i++) {
        expect(
          angles[i],
          lessThan(angles[i - 1]),
          reason: 'orientation must unwind on every sampled preview frame',
        );
      }

      final drops = <double>[
        for (var i = 1; i < angles.length; i++) angles[i - 1] - angles[i],
      ];
      expect(
        drops.first,
        greaterThan(0.001),
        reason: 'the exit must not hold its settled angle on the first frame',
      );
      for (var i = 1; i < drops.length; i++) {
        expect(
          drops[i],
          lessThan(drops[i - 1] + 1e-12),
          reason: 'angular motion must decelerate instead of snapping late',
        );
      }
      expect(
        angles[angles.length - 2],
        lessThan(0.01 * math.pi / 180.0),
        reason: 'the last visible frame must be within 0.01° of flat',
      );
    }

    test('bottom-right Tilt3D + push-in unwinds both axes every frame and '
        'hands off to identity', () {
      final region = exitRegion(
        followCursor: false,
        tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
        movement: const ZoomMovement(
          kind: ZoomMovementKind.pushIn,
          intensity: ZoomMovementIntensity.dramatic,
        ),
      );
      final samples = sampleExit(
        region: region,
        focalAt: (_) => const Offset(900, 900),
      );

      expectDeceleratingReturn([for (final s in samples) s.yaw]);
      expectDeceleratingReturn([for (final s in samples) s.pitch]);

      expectIdentity(
        t.getTransform(
          position: region.endTime,
          zoomRegion: region,
          videoSize: videoSize,
          focalPoint: const Offset(900, 900),
          rampCurve: smoothCurve,
          rampDurationScale: rampDurationScale,
          framing: framing,
        ),
      );
      expectIdentity(
        t.getTransform(
          position: region.endTime + const Duration(microseconds: 1),
          zoomRegion: region,
          videoSize: videoSize,
          focalPoint: const Offset(900, 900),
          rampCurve: smoothCurve,
          rampDurationScale: rampDurationScale,
          framing: framing,
        ),
      );
    });

    test(
      'cursor-follow Tilt3D + Sweep remains monotonic while focal recenters',
      () {
        final region = exitRegion(
          followCursor: true,
          tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
          movement: const ZoomMovement(
            kind: ZoomMovementKind.sweep,
            intensity: ZoomMovementIntensity.dramatic,
          ),
        );
        const settledFocal = Offset(900, 900);
        const settledOffset = Offset(400, 400);
        final samples = sampleExit(
          region: region,
          // Mirrors an edge-follow exit's back-loaded radial return. This is
          // deliberately NOT proportional to the zoom scale gate: attempting
          // to recover direction by dividing this focal by that gate caused
          // the follow-only late tilt correction reported in production.
          focalAt: (exitProgress) {
            final scaleGate = 1.0 - smoothCurve.transform(exitProgress);
            final backloaded = math.pow(scaleGate, 0.76).toDouble();
            return const Offset(500, 500) + settledOffset * backloaded;
          },
          exitOrientationFocalAt: (_) => settledFocal,
        );

        expectDeceleratingReturn([for (final s in samples) s.yaw]);
        expectDeceleratingReturn([for (final s in samples) s.pitch]);
      },
    );

    test('scaled ramp begins orientation return at the resolved exit edge', () {
      final region = exitRegion(
        followCursor: false,
        tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
      );
      final ramps = region.resolvedRampsUs(rampDurationScale);
      final exitStart = Duration(
        microseconds: region.endTime.inMicroseconds - ramps.exitUs,
      );

      ({double pitch, double yaw}) at(Duration position) => orientation(
        t.getTransform(
          position: position,
          zoomRegion: region,
          videoSize: videoSize,
          focalPoint: const Offset(900, 900),
          rampCurve: smoothCurve,
          rampDurationScale: rampDurationScale,
          framing: framing,
        ),
      );

      final before = at(exitStart - const Duration(microseconds: 1));
      final edge = at(exitStart);
      final firstFrame = at(exitStart + const Duration(microseconds: 16667));

      expect(edge.yaw, closeTo(before.yaw, 1e-8));
      expect(edge.pitch, closeTo(before.pitch, 1e-8));
      expect(firstFrame.yaw.abs(), lessThan(edge.yaw.abs()));
      expect(firstFrame.pitch.abs(), lessThan(edge.pitch.abs()));
      expect(ramps.exitUs, 850000);
    });

    test(
      'compressed enter/exit ramps still reach identity at a short edge',
      () {
        final region = exitRegion(
          followCursor: false,
          tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
          movement: const ZoomMovement(kind: ZoomMovementKind.sweep),
          duration: const Duration(milliseconds: 200),
        );
        final ramps = region.resolvedRampsUs(rampDurationScale);
        expect(ramps.enterUs + ramps.exitUs, region.duration.inMicroseconds);

        final justBeforeEnd = t.getTransform(
          position: region.endTime - const Duration(microseconds: 1),
          zoomRegion: region,
          videoSize: videoSize,
          focalPoint: const Offset(900, 900),
          rampCurve: smoothCurve,
          rampDurationScale: rampDurationScale,
          framing: framing,
        );
        final atEnd = t.getTransform(
          position: region.endTime,
          zoomRegion: region,
          videoSize: videoSize,
          focalPoint: const Offset(900, 900),
          rampCurve: smoothCurve,
          rampDurationScale: rampDurationScale,
          framing: framing,
        );

        final lastOrientation = orientation(justBeforeEnd);
        expect(lastOrientation.yaw.abs(), lessThan(1e-8));
        expect(lastOrientation.pitch.abs(), lessThan(1e-8));
        expectIdentity(atEnd);
      },
    );
  });

  group('combined yaw cap', () {
    const deg2rad = math.pi / 180.0;
    // Manual placement (static direction, no focal-ramp compensation), long
    // enough that the movement hold-length scaling is at full strength.
    ZoomRegion manual({required Tilt3D tilt, required ZoomMovement movement}) =>
        ZoomRegion(
          rect: const Rect.fromLTWH(900, 450, 100, 100),
          startTime: Duration.zero,
          duration: const Duration(seconds: 4),
          zoomLevel: 2,
          enterDuration: Duration.zero,
          exitDuration: Duration.zero,
          followCursor: false,
          tilt: tilt,
          movement: movement,
        );
    // Right at the end of the hold so the sweep envelope is ~1.
    const nearEnd = Duration(milliseconds: 3999);
    // Right-edge focal: nx == 1 so auto tilt Y and sweep both reach max.
    const edgeFocal = Offset(1000, 500);

    double yawOf(ZoomRegion r) => orientation(
          t.getTransform(
            position: nearEnd,
            zoomRegion: r,
            videoSize: videoSize,
            focalPoint: edgeFocal,
            framing: framing,
          ),
        ).yaw.abs();

    test('dramatic tilt plus dramatic sweep is capped', () {
      // Guard: the cap only matters if the presets can exceed it.
      expect(
        kTiltDramaticMaxDeg + kSweepDramaticDeg,
        greaterThan(kMaxCombinedYawDeg),
      );
      final yaw = yawOf(
        manual(
          tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
          movement: const ZoomMovement(
            kind: ZoomMovementKind.sweep,
            intensity: ZoomMovementIntensity.dramatic,
          ),
        ),
      );
      expect(yaw, closeTo(kMaxCombinedYawDeg * deg2rad, 1e-4));
    });

    test('subtle tilt plus subtle sweep is below the cap and adds up', () {
      expect(
        kTiltSubtleMaxDeg + kSweepSubtleDeg,
        lessThan(kMaxCombinedYawDeg),
      );
      final yaw = yawOf(
        manual(
          tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
          movement: const ZoomMovement(kind: ZoomMovementKind.sweep),
        ),
      );
      expect(
        yaw,
        closeTo((kTiltSubtleMaxDeg + kSweepSubtleDeg) * deg2rad, 1e-4),
      );
    });

    test('a manual angle above the cap is never reduced by the cap', () {
      final yaw = yawOf(
        manual(
          tilt: const Tilt3D(style: ZoomTiltStyle.dramatic, manualAngleY: 20),
          movement: const ZoomMovement(
            kind: ZoomMovementKind.sweep,
            intensity: ZoomMovementIntensity.dramatic,
          ),
        ),
      );
      expect(yaw, closeTo(20 * deg2rad, 1e-4));
    });
  });

  group('orientation focal', () {
    const deg2rad = math.pi / 180.0;
    final follow = region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));

    test('drives the tilt direction instead of the live focal', () {
      final live = t.getTransform(
        position: pos,
        zoomRegion: follow,
        videoSize: videoSize,
        focalPoint: const Offset(500, 500),
        framing: framing,
      );
      expect(orientation(live).yaw.abs(), lessThan(1e-9));

      final smoothed = t.getTransform(
        position: pos,
        zoomRegion: follow,
        videoSize: videoSize,
        focalPoint: const Offset(500, 500),
        orientationFocalPoint: const Offset(1000, 500),
        framing: framing,
      );
      expect(
        orientation(smoothed).yaw.abs(),
        closeTo(kTiltSubtleMaxDeg * deg2rad, 1e-6),
      );
    });

    test('exit orientation focal still takes precedence', () {
      final right = t.getTransform(
        position: pos,
        zoomRegion: follow,
        videoSize: videoSize,
        focalPoint: const Offset(500, 500),
        orientationFocalPoint: const Offset(1000, 500),
        framing: framing,
      );
      final exitLeft = t.getTransform(
        position: pos,
        zoomRegion: follow,
        videoSize: videoSize,
        focalPoint: const Offset(500, 500),
        orientationFocalPoint: const Offset(1000, 500),
        exitOrientationFocalPoint: const Offset(0, 500),
        framing: framing,
      );
      expect(
        orientation(exitLeft).yaw,
        closeTo(-orientation(right).yaw, 1e-9),
      );
    });
  });
}
