import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';

void main() {
  // A focal sitting right-of-center (positive nx) so auto directions resolve.
  const focalRight = Offset(0.5, 0.0);

  ZoomMovementSample resolve(
    ZoomMovement m, {
    double holdProgress = 1.0,
    double rampGate = 1.0,
    Offset focal = focalRight,
  }) =>
      m.resolveAt(
        holdProgress: holdProgress,
        rampGate: rampGate,
        normalizedFocal: focal,
      );

  group('resolveAt identity conditions', () {
    test('none is always the identity sample', () {
      final s = resolve(const ZoomMovement());
      expect(s.scaleMul, 1.0);
      expect(s.extraTiltXRad, 0.0);
      expect(s.extraTiltYRad, 0.0);
      expect(s.focalDriftFrac, Offset.zero);
    });

    test('rampGate 0 zeroes any movement (faded out at the ramp)', () {
      final s = resolve(
        const ZoomMovement(kind: ZoomMovementKind.pushIn),
        rampGate: 0.0,
      );
      expect(s.scaleMul, 1.0);
    });

    test('holdProgress 0 is the identity (motion starts gently)', () {
      final s = resolve(
        const ZoomMovement(kind: ZoomMovementKind.pushIn),
        holdProgress: 0.0,
      );
      expect(s.scaleMul, 1.0);
    });
  });

  group('per-move channel isolation', () {
    test('pushIn only scales', () {
      final s = resolve(const ZoomMovement(kind: ZoomMovementKind.pushIn));
      expect(s.scaleMul, greaterThan(1.0));
      expect(s.extraTiltXRad, 0.0);
      expect(s.extraTiltYRad, 0.0);
      expect(s.focalDriftFrac, Offset.zero);
    });

    test('sweep only tilts (yaw)', () {
      final s = resolve(const ZoomMovement(kind: ZoomMovementKind.sweep));
      expect(s.scaleMul, 1.0);
      expect(s.extraTiltYRad.abs(), greaterThan(0.0));
      expect(s.extraTiltXRad, 0.0);
      expect(s.focalDriftFrac, Offset.zero);
    });

    test('drift only shifts the focal', () {
      final s = resolve(const ZoomMovement(kind: ZoomMovementKind.drift));
      expect(s.scaleMul, 1.0);
      expect(s.extraTiltXRad, 0.0);
      expect(s.extraTiltYRad, 0.0);
      expect(s.focalDriftFrac.dx.abs(), greaterThan(0.0));
    });
  });

  group('intensity + curve', () {
    test('dramatic push-in scales more than subtle', () {
      final sub = resolve(const ZoomMovement(kind: ZoomMovementKind.pushIn));
      final dra = resolve(const ZoomMovement(
          kind: ZoomMovementKind.pushIn,
          intensity: ZoomMovementIntensity.dramatic));
      expect(dra.scaleMul, greaterThan(sub.scaleMul));
    });

    test('push-in scale grows monotonically with holdProgress', () {
      const m = ZoomMovement(kind: ZoomMovementKind.pushIn);
      final a = resolve(m, holdProgress: 0.25).scaleMul;
      final b = resolve(m, holdProgress: 0.75).scaleMul;
      expect(b, greaterThan(a));
    });

    test('sweep direction follows the focal side', () {
      const m = ZoomMovement(kind: ZoomMovementKind.sweep);
      final right = resolve(m, focal: const Offset(0.5, 0)).extraTiltYRad;
      final left = resolve(m, focal: const Offset(-0.5, 0)).extraTiltYRad;
      expect(right.sign, isNot(equals(left.sign)));
    });
  });

  group('json', () {
    test('round-trips kind + intensity', () {
      const m = ZoomMovement(
          kind: ZoomMovementKind.sweep,
          intensity: ZoomMovementIntensity.dramatic);
      expect(ZoomMovement.fromJson(m.toJson()), m);
    });

    test('empty / unknown json defaults to none + subtle', () {
      final m = ZoomMovement.fromJson(const {});
      expect(m.kind, ZoomMovementKind.none);
      expect(m.intensity, ZoomMovementIntensity.subtle);
      final u = ZoomMovement.fromJson(const {'kind': 'bogus'});
      expect(u.kind, ZoomMovementKind.none);
    });
  });
}
