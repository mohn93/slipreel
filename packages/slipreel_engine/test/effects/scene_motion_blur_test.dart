@TestOn('vm')
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:slipreel_engine/effects/scene_motion_blur.dart';

/// Determinism contract: the displayed scene-blur signal must be a pure
/// function of `(position, sampleAt, exposure, maxTranslation)`. Pause
/// vs. play vs. export vs. scrub-then-play must all produce the same
/// signal at the same playhead — anything else is a WYSIWYG break
/// between editor preview and the exported MP4.
///
/// Prior to this refactor, [SceneMotionBlurController] kept an EMA
/// running over its call history (a `smooth:` flag controlled whether
/// the EMA was active). Same `current` sample produced different
/// signals depending on the EMA's accumulated state. These tests pin
/// the no-history, no-EMA contract that replaces it.
void main() {
  test('shared slider curve gives preview and export the same scale', () {
    const master = 0.25;
    const channel = 0.5;
    final previewScale =
        sceneBlurMasterResponse(master) * sceneBlurChannelResponse(channel);

    expect(sceneBlurMasterResponse(master), closeTo(0.0625, 1e-12));
    expect(sceneBlurChannelResponse(channel), closeTo(0.125, 1e-12));
    expect(
      sceneBlurExposureScale(master: master, channel: channel),
      closeTo(previewScale, 1e-12),
    );
    expect(previewScale, closeTo(0.0078125, 1e-12));
  });

  test(
    'production slider range yields a visible but bounded scene shutter',
    () {
      const baseExposureMs = 80.0;
      final commonMs =
          baseExposureMs * sceneBlurExposureScale(master: 0.25, channel: 1.0);
      final maximumMs =
          baseExposureMs * sceneBlurExposureScale(master: 0.5, channel: 1.0);

      expect(commonMs, closeTo(5.0, 1e-12));
      expect(maximumMs, closeTo(40.0, 1e-12));
    },
  );

  // Linear camera pan: focal moves +100 px/s on x, scale held at 1.0.
  // Pure function of t, so two calls at the same t must be identical.
  SceneCameraSample panAt(Duration t) {
    final s = t.inMicroseconds / 1e6;
    return SceneCameraSample(
      position: t,
      focal: Offset(100.0 * s, 0),
      scale: 1.0,
    );
  }

  // Static camera — no motion at all. Signal must report zero.
  SceneCameraSample stillAt(Duration t) =>
      SceneCameraSample(position: t, focal: const Offset(500, 500), scale: 1.0);

  const movementExposure = Duration(milliseconds: 16);
  const zoomExposure = Duration(milliseconds: 16);
  const maxTranslation = 200.0;

  test('compute is a pure function: same inputs → same outputs', () {
    final a = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: panAt,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: maxTranslation,
    );
    final b = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: panAt,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: maxTranslation,
    );

    expect(a.scaleDelta, b.scaleDelta);
    expect(a.translation, b.translation);
  });

  test(
    'order of prior calls does not affect the result (play-from-0 vs scrub-to-t)',
    () {
      // "Played through": compute at every 16 ms tick up to t=500.
      SceneMotionBlurSignal? viaPlayback;
      for (var ms = 0; ms <= 500; ms += 16) {
        viaPlayback = SceneMotionBlurController.compute(
          position: Duration(milliseconds: ms),
          sampleAt: panAt,
          movementExposure: movementExposure,
          zoomExposure: zoomExposure,
          maxTranslation: maxTranslation,
        );
      }

      // "Scrubbed-to": compute once at t=500 with no prior calls.
      final viaScrub = SceneMotionBlurController.compute(
        position: const Duration(milliseconds: 500),
        sampleAt: panAt,
        movementExposure: movementExposure,
        zoomExposure: zoomExposure,
        maxTranslation: maxTranslation,
      );

      // Path-independence is the whole contract: editor preview (which
      // arrives at frame T after many builds) must produce the same
      // blur as the export (which renders frame T fresh).
      expect(viaPlayback!.translation, viaScrub.translation);
      expect(viaPlayback.scaleDelta, viaScrub.scaleDelta);
    },
  );

  test(
    'paused-tick (repeat call at same position) does not drift the signal',
    () {
      // Editor builds re-paint at vsync while the playhead stays
      // pinned. Each paint calls compute. The signal must not drift.
      final first = SceneMotionBlurController.compute(
        position: const Duration(milliseconds: 200),
        sampleAt: panAt,
        movementExposure: movementExposure,
        zoomExposure: zoomExposure,
        maxTranslation: maxTranslation,
      );
      for (var i = 0; i < 30; i++) {
        final repeat = SceneMotionBlurController.compute(
          position: const Duration(milliseconds: 200),
          sampleAt: panAt,
          movementExposure: movementExposure,
          zoomExposure: zoomExposure,
          maxTranslation: maxTranslation,
        );
        expect(repeat.translation, first.translation);
        expect(repeat.scaleDelta, first.scaleDelta);
      }
    },
  );

  test('translation magnitude equals prev.focal − current.focal scaled by '
      'prev.scale × current.screenScale (linear pan, no EMA attenuation)', () {
    // panAt moves the focal at +100 px/s on x. Translation is
    // `(prev.focal − current.focal) × scale`, so for a +x camera
    // motion the smear vector points in −x. Over a 16 ms exposure
    // that's exactly −1.6 px.
    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: panAt,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: maxTranslation,
    );
    expect(signal.translation.dx, closeTo(-1.6, 0.01));
    expect(signal.translation.dy, closeTo(0.0, 0.01));
  });

  test('translation is clamped to maxTranslation magnitude', () {
    SceneCameraSample fastPan(Duration t) {
      final s = t.inMicroseconds / 1e6;
      // 100_000 px/s — over a 16 ms window that's 1600 px raw.
      return SceneCameraSample(
        position: t,
        focal: Offset(100000 * s, 0),
        scale: 1.0,
      );
    }

    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 100),
      sampleAt: fastPan,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: 50.0,
    );
    expect(signal.translation.distance, closeTo(50.0, 0.001));
  });

  test('zero motion → hasMotion is false', () {
    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: stillAt,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: maxTranslation,
    );
    expect(signal.hasMotion, isFalse);
  });

  test('zero exposure → translation is zero and scaleDelta is zero', () {
    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: panAt,
      movementExposure: Duration.zero,
      zoomExposure: Duration.zero,
      maxTranslation: maxTranslation,
    );
    expect(signal.translation, Offset.zero);
    expect(signal.scaleDelta, 0);
  });

  test('scaleDelta reflects zoom motion across the exposure window', () {
    // Linear ramp from 1.0× → 2.0× over 1 second. At t=500 ms the
    // scale is 1.5×; 16 ms earlier (t=484 ms) it was ~1.484×.
    // scaleDelta = 1 − prev.scale / current.scale ≈ 1 − 1.484/1.5 ≈ 0.01067.
    SceneCameraSample rampZoom(Duration t) {
      final s = t.inMicroseconds / 1e6;
      return SceneCameraSample(
        position: t,
        focal: const Offset(500, 500),
        scale: 1.0 + s, // 1.0× → 2.0× over 1 s
      );
    }

    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: rampZoom,
      movementExposure: movementExposure,
      zoomExposure: zoomExposure,
      maxTranslation: maxTranslation,
    );
    expect(signal.scaleDelta, closeTo(0.01067, 0.001));
  });

  test('trajectory samples the real nonlinear camera path at four knots', () {
    SceneCameraSample acceleratingPan(Duration t) {
      final seconds = t.inMicroseconds / 1e6;
      return SceneCameraSample(
        position: t,
        focal: Offset(100 * seconds * seconds, 0),
        scale: 1,
      );
    }

    final signal = SceneMotionBlurController.compute(
      position: const Duration(seconds: 1),
      sampleAt: acceleratingPan,
      movementExposure: const Duration(seconds: 1),
      zoomExposure: Duration.zero,
      maxTranslation: 1000,
    );

    expect(signal.trajectory, hasLength(4));
    expect(signal.trajectory[0].translation.dx, closeTo(-43.75, 1e-9));
    expect(signal.trajectory[1].translation.dx, closeTo(-75, 1e-9));
    expect(signal.trajectory[2].translation.dx, closeTo(-93.75, 1e-9));
    expect(signal.trajectory[3].translation.dx, closeTo(-100, 1e-9));
    expect(signal.translation, signal.trajectory.last.translation);
  });

  test('out-and-back camera path blurs even when endpoints match', () {
    SceneCameraSample loopPan(Duration t) {
      final seconds = t.inMicroseconds / 1e6;
      return SceneCameraSample(
        position: t,
        focal: Offset(math.sin(seconds * math.pi * 2) * 100, 0),
        scale: 1,
      );
    }

    final signal = SceneMotionBlurController.compute(
      position: const Duration(seconds: 1),
      sampleAt: loopPan,
      movementExposure: const Duration(seconds: 1),
      zoomExposure: Duration.zero,
      maxTranslation: 1000,
    );

    expect(signal.translation.distance, lessThan(1e-9));
    expect(signal.trajectory[0].translation.distance, closeTo(100, 1e-9));
    expect(signal.trajectory[2].translation.distance, closeTo(100, 1e-9));
    expect(signal.hasMotion, isTrue);
  });

  test('shared movement/zoom timestamps are sampled only once', () {
    var calls = 0;
    SceneCameraSample counted(Duration t) {
      calls++;
      return SceneCameraSample(
        position: t,
        focal: Offset(t.inMicroseconds.toDouble(), 0),
        scale: 1,
      );
    }

    SceneMotionBlurController.compute(
      position: const Duration(seconds: 1),
      sampleAt: counted,
      movementExposure: const Duration(milliseconds: 40),
      zoomExposure: const Duration(milliseconds: 40),
      maxTranslation: 160,
    );

    expect(calls, 5); // current + four shared shutter knots
  });

  test('projective camera delta detects pure 3D tilt motion', () {
    SceneCameraSample tiltAt(Duration t) {
      final progress =
          t.inMicroseconds / const Duration(seconds: 1).inMicroseconds;
      final transform = Matrix4.identity()
        ..setEntry(3, 2, -1 / 1600)
        ..rotateY(progress * 0.2);
      return SceneCameraSample(
        position: t,
        focal: const Offset(500, 500),
        // Keep the legacy scalar signal deliberately motionless. The full
        // transform must be what activates blur for this case.
        scale: 1,
        transform: transform,
        transformOrigin: const Offset(500, 500),
      );
    }

    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: tiltAt,
      movementExposure: Duration.zero,
      zoomExposure: const Duration(milliseconds: 40),
      maxTranslation: 160,
    );

    expect(signal.scaleDelta, 0);
    expect(signal.translation, Offset.zero);
    expect(signal.projectiveTransform, isNotNull);
    expect(signal.projectiveTransform!.isIdentity, isFalse);
    expect(signal.hasMotion, isTrue);
    expect(
      signal.projectiveTransform!.transformPoint(const Offset(850, 500)),
      isNot(const Offset(850, 500)),
    );
    expect(signal.trajectory, hasLength(4));
    expect(signal.trajectory.take(3), everyElement(isA<SceneMotionBlurKnot>()));
    expect(
      signal.trajectory[1].projectiveTransform!.transformPoint(
        const Offset(850, 500),
      ),
      isNot(const Offset(850, 500)),
    );
  });

  test(
    'projective delta maps current scaled pixels back to their prior pose',
    () {
      final current = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      final mapping = SceneProjectiveTransform.between(
        current: current,
        previous: Matrix4.identity(),
        origin: const Offset(100, 100),
      );

      // Source point (120, 130) appears at (140, 160) after a 2x scale about
      // (100, 100). The current→previous homography must recover its old pixel.
      expect(
        mapping.transformPoint(const Offset(140, 160)),
        const Offset(120, 130),
      );
    },
  );

  test('identical full camera transforms do not create phantom blur', () {
    final transform = Matrix4.identity()
      ..setEntry(3, 2, -1 / 1600)
      ..rotateY(0.1);
    SceneCameraSample fixedTilt(Duration t) => SceneCameraSample(
      position: t,
      focal: const Offset(500, 500),
      scale: 1,
      transform: transform,
      transformOrigin: const Offset(500, 500),
    );

    final signal = SceneMotionBlurController.compute(
      position: const Duration(milliseconds: 500),
      sampleAt: fixedTilt,
      movementExposure: const Duration(milliseconds: 40),
      zoomExposure: const Duration(milliseconds: 40),
      maxTranslation: 160,
    );

    expect(signal.projectiveTransform!.isIdentity, isTrue);
    expect(signal.hasMotion, isFalse);
  });
}
