import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/rendering/caption_renderer.dart';

void main() {
  const segs = [
    CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000, text: 'one'),
    CaptionSegment(id: 'b', startMicros: 1000, endMicros: 2000, text: 'two'),
  ];

  group('activeCaptionAt', () {
    test('returns the segment whose half-open range contains t', () {
      expect(activeCaptionAt(segs, 500)?.text, 'one');
      expect(activeCaptionAt(segs, 1000)?.text, 'two');
      expect(activeCaptionAt(segs, 1999)?.text, 'two');
    });
    test('returns null in gaps / out of range', () {
      expect(activeCaptionAt(segs, 2000), isNull);
      expect(activeCaptionAt(const [], 0), isNull);
    });
  });

  group('captionFontSize', () {
    test('scales with canvas height and fontScale', () {
      final base = captionFontSize(1000, 1.0);
      expect(captionFontSize(2000, 1.0), closeTo(base * 2, 0.001));
      expect(captionFontSize(1000, 2.0), closeTo(base * 2, 0.001));
    });
  });
}
