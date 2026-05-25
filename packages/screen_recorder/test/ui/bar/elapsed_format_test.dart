import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/elapsed_format.dart';

void main() {
  test('formats as m:ss with zero-padded seconds, uncapped minutes', () {
    expect(formatElapsed(Duration.zero), '0:00');
    expect(formatElapsed(const Duration(seconds: 5)), '0:05');
    expect(formatElapsed(const Duration(seconds: 14)), '0:14');
    expect(formatElapsed(const Duration(seconds: 65)), '1:05');
    expect(formatElapsed(const Duration(minutes: 10, seconds: 5)), '10:05');
    expect(formatElapsed(const Duration(minutes: 75)), '75:00');
  });
}
