import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/caption_transcriber.dart';

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
  });
}
