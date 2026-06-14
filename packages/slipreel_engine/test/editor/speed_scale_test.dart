import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/speed_scale.dart';

void main() {
  test('endpoints map to the range bounds', () {
    expect(SpeedScale.speedFromPos(0), closeTo(0.25, 1e-9));
    expect(SpeedScale.speedFromPos(1), closeTo(24.0, 1e-9));
    expect(SpeedScale.posFromSpeed(0.25), closeTo(0.0, 1e-9));
    expect(SpeedScale.posFromSpeed(24.0), closeTo(1.0, 1e-9));
  });

  test('the midpoint is the geometric mean (log scale)', () {
    expect(SpeedScale.speedFromPos(0.5), closeTo(math.sqrt(0.25 * 24.0), 1e-9));
  });

  test('pos -> speed -> pos round-trips', () {
    for (final s in <double>[0.3, 1.0, 2.5, 7.0, 20.0]) {
      expect(SpeedScale.speedFromPos(SpeedScale.posFromSpeed(s)),
          closeTo(s, 1e-9));
    }
  });

  test('is monotonically increasing', () {
    expect(SpeedScale.speedFromPos(0.3),
        lessThan(SpeedScale.speedFromPos(0.7)));
  });

  test('out-of-range inputs clamp', () {
    expect(SpeedScale.speedFromPos(-1), closeTo(0.25, 1e-9));
    expect(SpeedScale.speedFromPos(2), closeTo(24.0, 1e-9));
    expect(SpeedScale.posFromSpeed(100), closeTo(1.0, 1e-9));
    expect(SpeedScale.posFromSpeed(0.01), closeTo(0.0, 1e-9));
  });

  test('snap pulls near-detent values to the detent', () {
    expect(SpeedScale.snap(1.0), 1.0);
    expect(SpeedScale.snap(2.1), 2.0);
    expect(SpeedScale.snap(0.99), 1.0);
  });

  test('snap leaves clearly-between values alone', () {
    expect(SpeedScale.snap(2.6), closeTo(2.6, 1e-9));
    expect(SpeedScale.snap(6.0), closeTo(6.0, 1e-9));
  });
}
