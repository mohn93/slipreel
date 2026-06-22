import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

void main() {
  group('CaptionSegment', () {
    test('JSON round-trips', () {
      const s = CaptionSegment(
        id: 'seg_0',
        startMicros: 1000000,
        endMicros: 3500000,
        text: 'Hello world',
      );
      final back = CaptionSegment.fromJson(s.toJson());
      expect(back, s);
    });

    test('isActiveAtMicros is half-open [start, end)', () {
      const s = CaptionSegment(
          id: 'a', startMicros: 1000, endMicros: 2000, text: 'x');
      expect(s.isActiveAtMicros(999), isFalse);
      expect(s.isActiveAtMicros(1000), isTrue);
      expect(s.isActiveAtMicros(1999), isTrue);
      expect(s.isActiveAtMicros(2000), isFalse);
    });

    test('copyWith replaces only the named field', () {
      const s = CaptionSegment(
          id: 'a', startMicros: 0, endMicros: 10, text: 'old');
      expect(s.copyWith(text: 'new').text, 'new');
      expect(s.copyWith(text: 'new').id, 'a');
    });

    test('CaptionAudioSource labels are present', () {
      expect(CaptionAudioSource.mic.label, 'Microphone');
      expect(CaptionAudioSource.system.label, 'System audio');
      expect(CaptionAudioSource.mixed.label, 'Both (mixed)');
    });
  });
}
