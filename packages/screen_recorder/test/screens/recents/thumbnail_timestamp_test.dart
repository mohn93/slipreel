@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/recents/thumbnail_timestamp.dart';

void main() {
  test('uses 10% in for a normal clip, clamped to >= 1s', () {
    expect(thumbTimestamp(const Duration(milliseconds: 41823)),
        const Duration(milliseconds: 4182));
    expect(thumbTimestamp(const Duration(seconds: 4)),
        const Duration(seconds: 1));
  });

  test('short clip (<=1.2s) uses the midpoint', () {
    expect(thumbTimestamp(const Duration(milliseconds: 800)),
        const Duration(milliseconds: 400));
  });

  test('never past duration - 200ms', () {
    final t = thumbTimestamp(const Duration(milliseconds: 1100));
    expect(t.inMilliseconds, lessThanOrEqualTo(900));
  });

  test('zero / unknown duration → zero', () {
    expect(thumbTimestamp(Duration.zero), Duration.zero);
  });
}
