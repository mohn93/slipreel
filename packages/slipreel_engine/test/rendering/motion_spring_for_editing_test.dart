// Regression test for M4: editing the cursor "Motion stiffness"/"Motion
// damping" sliders in the None preset must not leave the snap sentinel (-1)
// in the untouched field. A negative damping ratio produces an exponentially
// growing (divergent) spring; a stiffness<=0 silently keeps snap mode.
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';

void main() {
  group('MotionSpring.forEditing', () {
    test('snap sentinel becomes a valid spring built from the fallbacks', () {
      final base = MotionSpring.snap.forEditing(stiffness: 180, damping: 1.0);
      expect(base.isSnap, isFalse);
      expect(base.stiffness, 180);
      expect(base.damping, 1.0);
    });

    test('editing stiffness alone yields a valid (non-divergent) spring', () {
      final edited =
          MotionSpring.snap.forEditing(stiffness: 180, damping: 1.0)
              .copyWith(stiffness: 500);
      expect(edited.isSnap, isFalse);
      expect(edited.stiffness, 500);
      expect(edited.damping, 1.0, reason: 'damping must NOT stay at the -1 sentinel');
    });

    test('editing damping alone yields a valid, rendered (non-snap) spring', () {
      final edited =
          MotionSpring.snap.forEditing(stiffness: 180, damping: 1.0)
              .copyWith(damping: 0.5);
      expect(edited.isSnap, isFalse,
          reason: 'stiffness must NOT stay <=0, or the renderer ignores damping');
      expect(edited.stiffness, 180);
      expect(edited.damping, 0.5);
    });

    test('a real (non-snap) spring is returned unchanged', () {
      const real = MotionSpring(stiffness: 220, damping: 0.8);
      final base = real.forEditing(stiffness: 180, damping: 1.0);
      expect(base, real);
    });
  });
}
