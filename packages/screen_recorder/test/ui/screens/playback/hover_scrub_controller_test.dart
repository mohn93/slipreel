import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback/hover_scrub_controller.dart';

void main() {
  group('HoverScrubController', () {
    late List<Duration> seeks;
    late HoverScrubController c;
    setUp(() {
      seeks = [];
      c = HoverScrubController(seekTo: seeks.add);
    });

    test('track updates intendedPosition only when not hovering', () {
      c.track(const Duration(seconds: 1));
      expect(c.intendedPosition, const Duration(seconds: 1));
      c.hoverSeek(const Duration(seconds: 5)); // now hovering
      c.track(const Duration(seconds: 2)); // ignored while hovering
      expect(c.intendedPosition, const Duration(seconds: 1));
    });

    test('seek clears hover, sets intended, and seeks', () {
      c.hoverSeek(const Duration(seconds: 5));
      c.seek(const Duration(seconds: 3));
      expect(c.isHovering, isFalse);
      expect(c.intendedPosition, const Duration(seconds: 3));
      expect(seeks.last, const Duration(seconds: 3));
    });

    test('hoverSeek sets hovering and seeks (preview) without moving anchor', () {
      c.track(const Duration(seconds: 2));
      c.hoverSeek(const Duration(seconds: 8));
      expect(c.isHovering, isTrue);
      expect(c.intendedPosition, const Duration(seconds: 2));
      expect(seeks.last, const Duration(seconds: 8));
    });

    test('hoverEnd restores the anchor and clears hover', () {
      c.track(const Duration(seconds: 2));
      c.hoverSeek(const Duration(seconds: 8));
      c.hoverEnd();
      expect(c.isHovering, isFalse);
      expect(seeks.last, const Duration(seconds: 2));
    });

    test('hoverEnd is a no-op when not hovering', () {
      c.hoverEnd();
      expect(seeks, isEmpty);
    });

    test('seekToStart resets to zero', () {
      c.track(const Duration(seconds: 5));
      c.seekToStart();
      expect(c.isHovering, isFalse);
      expect(c.intendedPosition, Duration.zero);
      expect(seeks.last, Duration.zero);
    });

    test('seekToEnd seeks 1ms before duration, clears hover', () {
      c.hoverSeek(const Duration(seconds: 1));
      c.seekToEnd(const Duration(seconds: 10));
      expect(c.isHovering, isFalse);
      expect(seeks.last, const Duration(seconds: 10) - const Duration(milliseconds: 1));
    });

    test('seekToEnd is a no-op seek when duration is zero', () {
      c.seekToEnd(Duration.zero);
      expect(seeks, isEmpty);
    });
  });
}
