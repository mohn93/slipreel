import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart'
    show pixelsPerSecondForTest, timeToXForTest, xToTimeForTest,
         contentWidthForTest, progressFromHoverForTest;

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

  group('_progressFromHover (hover-scrub offset correction)', () {
    // At scale=1.0 content==viewport, so scrollOffset is always 0 and
    // viewportX/viewportWidth is the same as contentX/contentWidth.
    test('scale=1.0, no scroll: mid-viewport → 0.5', () {
      expect(
        progressFromHoverForTest(
          300, // viewportX
          0,   // scrollOffset
          600, // viewportWidth
          1.0, // scale
        ),
        0.5,
      );
    });

    // At scale=2.0, contentWidth=1200.  If the user scrolls 300 px and
    // then hovers at viewport-x=300, the cursor is at content-x=600
    // which is 600/1200 = 0.5 of the total duration.
    test('scale=2.0, scrollOffset=300, viewportX=300 → 0.5', () {
      expect(
        progressFromHoverForTest(
          300, // viewportX
          300, // scrollOffset
          600, // viewportWidth (content = 1200)
          2.0, // scale
        ),
        0.5,
      );
    });

    // Beginning of content (viewportX=0, no scroll) → 0.0
    test('scale=2.0, at content start → 0.0', () {
      expect(
        progressFromHoverForTest(0, 0, 600, 2.0),
        0.0,
      );
    });

    // End of content: scrolled all the way (600 px) + viewportX=600 →
    // content-x = 1200 / 1200 = 1.0, clamped.
    test('scale=2.0, at content end → 1.0', () {
      expect(
        progressFromHoverForTest(600, 600, 600, 2.0),
        1.0,
      );
    });

    // Overshoot is clamped to 1.0.
    test('scale=2.0, overshoot → clamped to 1.0', () {
      expect(
        progressFromHoverForTest(700, 600, 600, 2.0),
        1.0,
      );
    });

    // Scale=1.0 with no scroll: hovering at viewport-x=150 out of 600
    // → 0.25 of total duration.
    test('scale=1.0, viewportX=150, viewport=600 → 0.25', () {
      expect(
        progressFromHoverForTest(150, 0, 600, 1.0),
        0.25,
      );
    });
  });
}
