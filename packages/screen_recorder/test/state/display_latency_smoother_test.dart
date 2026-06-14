import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/display_latency_smoother.dart';

void main() {
  test('starts at zero before any sample', () {
    expect(DisplayLatencySmoother().value, Duration.zero);
  });

  test('first non-null sample seeds the value exactly', () {
    final s = DisplayLatencySmoother(alpha: 0.3);
    s.add(80000); // 80 ms in micros
    expect(s.value, const Duration(milliseconds: 80));
  });

  test('subsequent samples move toward the new value by alpha', () {
    final s = DisplayLatencySmoother(alpha: 0.5);
    s.add(80000); // seed 80 ms
    s.add(0); // ema = 0.5*0 + 0.5*80 = 40 ms
    expect(s.value, const Duration(milliseconds: 40));
  });

  test('negative raw samples are clamped to zero before smoothing', () {
    final s = DisplayLatencySmoother(alpha: 1.0);
    s.add(-5000);
    expect(s.value, Duration.zero);
  });

  test('null samples are ignored — value holds', () {
    final s = DisplayLatencySmoother(alpha: 1.0);
    s.add(50000);
    s.add(null);
    expect(s.value, const Duration(milliseconds: 50));
  });
}
