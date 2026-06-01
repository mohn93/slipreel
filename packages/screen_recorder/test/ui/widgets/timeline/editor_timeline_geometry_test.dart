import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart'
    show pixelsPerSecondForTest, timeToXForTest, xToTimeForTest,
         contentWidthForTest;

void main() {
  group('_pixelsPerSecond', () {
    test('viewport=600, total=10s, scale=1.0 → 60 px/s', () {
      expect(
        pixelsPerSecondForTest(600, const Duration(seconds: 10), 1.0),
        60.0,
      );
    });

    test('scale=2.0 doubles it', () {
      expect(
        pixelsPerSecondForTest(600, const Duration(seconds: 10), 2.0),
        120.0,
      );
    });

    test('total=Duration.zero returns 0 (no division by zero)', () {
      expect(
        pixelsPerSecondForTest(600, Duration.zero, 1.0),
        0.0,
      );
    });
  });

  group('_timeToX', () {
    test('5s at 60 px/s → 300 px', () {
      expect(timeToXForTest(const Duration(seconds: 5), 60.0), 300.0);
    });

    test('any time at 0 px/s → 0', () {
      expect(timeToXForTest(const Duration(seconds: 5), 0.0), 0.0);
    });
  });

  group('_xToTime', () {
    test('300 px at 60 px/s → 5s', () {
      expect(xToTimeForTest(300.0, 60.0), const Duration(seconds: 5));
    });

    test('any px at 0 px/s → Duration.zero', () {
      expect(xToTimeForTest(300.0, 0.0), Duration.zero);
    });
  });

  group('_contentWidth', () {
    test('viewport=600, scale=1.0 → 600', () {
      expect(contentWidthForTest(600, 1.0), 600.0);
    });

    test('viewport=600, scale=2.0 → 1200', () {
      expect(contentWidthForTest(600, 2.0), 1200.0);
    });
  });
}
