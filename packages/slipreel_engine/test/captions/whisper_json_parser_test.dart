import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

const _fixture = '''
{
  "result": {"language": "en"},
  "transcription": [
    {"offsets": {"from": 0, "to": 4000}, "text": " Hello world."},
    {"offsets": {"from": 4000, "to": 8000}, "text": "  "},
    {"offsets": {"from": 8000, "to": 12000}, "text": "Second line"}
  ]
}
''';

void main() {
  group('parseWhisperJson', () {
    test('maps offsets (ms) to micros and trims text', () {
      final segs = parseWhisperJson(_fixture);
      expect(segs.length, 2); // empty/whitespace segment dropped
      expect(segs.first.startMicros, 0);
      expect(segs.first.endMicros, 4000000);
      expect(segs.first.text, 'Hello world.');
      expect(segs.first.id, 'seg_0');
      expect(segs.last.text, 'Second line');
      expect(segs.last.id, 'seg_2');
    });

    test('returns empty list on malformed JSON', () {
      expect(parseWhisperJson('not json'), isEmpty);
      expect(parseWhisperJson('{}'), isEmpty);
    });

    test('skips entry with wrong-typed offsets/text without throwing', () {
      // "from"/"to" are string-encoded numbers, "text" is an integer — all
      // wrong types.  The parser must return [] (entry skipped), never throw.
      const badJson = '''
{
  "transcription": [
    {"offsets": {"from": "0", "to": "4000"}, "text": 42}
  ]
}
''';
      expect(() => parseWhisperJson(badJson), returnsNormally);
      expect(parseWhisperJson(badJson), isEmpty);
    });
  });

  group('shiftCaptionSegments', () {
    const segs = [
      CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000, text: 'x'),
      CaptionSegment(id: 'b', startMicros: 4000, endMicros: 8000, text: 'y'),
    ];

    test('adds the offset to every start/end, preserving id/text', () {
      final out = shiftCaptionSegments(segs, 240000);
      expect(out[0].startMicros, 240000);
      expect(out[0].endMicros, 241000);
      expect(out[1].startMicros, 244000);
      expect(out[1].endMicros, 248000);
      expect(out[0].id, 'a');
      expect(out[1].text, 'y');
    });

    test('offset 0 returns the input unchanged', () {
      expect(shiftCaptionSegments(segs, 0), same(segs));
    });

    test('empty list stays empty', () {
      expect(shiftCaptionSegments(const [], 240000), isEmpty);
    });
  });
}
