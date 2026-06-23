// packages/slipreel_engine/test/captions/caption_audio_extractor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

void main() {
  group('buildCaptionAudioArgs', () {
    test('mic maps stream 0, 16k mono wav', () {
      final a = buildCaptionAudioArgs(
          'in.mov', CaptionAudioSource.mic, 2, 'out.wav');
      expect(a, containsAllInOrder(['-map', '0:a:0']));
      expect(a, containsAllInOrder(['-ar', '16000']));
      expect(a, containsAllInOrder(['-ac', '1']));
      expect(a, containsAllInOrder(['-c:a', 'pcm_s16le']));
      expect(a.last, 'out.wav');
    });

    test('system maps stream 1', () {
      final a = buildCaptionAudioArgs(
          'in.mov', CaptionAudioSource.system, 2, 'out.wav');
      expect(a, containsAllInOrder(['-map', '0:a:1']));
    });

    test('mixed uses amix of both streams', () {
      final a = buildCaptionAudioArgs(
          'in.mov', CaptionAudioSource.mixed, 2, 'out.wav');
      expect(a, contains('-filter_complex'));
      expect(
        a,
        contains('[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]'),
      );
      expect(a, containsAllInOrder(['-map', '[aout]']));
    });

    test('mixed/system fall back to stream 0 when only one stream exists', () {
      final a = buildCaptionAudioArgs(
          'in.mov', CaptionAudioSource.mixed, 1, 'out.wav');
      expect(a, containsAllInOrder(['-map', '0:a:0']));
      expect(a, isNot(contains('-filter_complex')));
    });

    test('system + 1 stream falls back to -map 0:a:0 without -filter_complex',
        () {
      final a = buildCaptionAudioArgs(
          'in.mov', CaptionAudioSource.system, 1, 'out.wav');
      expect(a, containsAllInOrder(['-map', '0:a:0']));
      expect(a, isNot(contains('-filter_complex')));
    });
  });

  group('availableCaptionSources', () {
    test('two streams → mic, system, mixed', () {
      expect(availableCaptionSources(2),
          [CaptionAudioSource.mic, CaptionAudioSource.system, CaptionAudioSource.mixed]);
    });
    test('one stream → mic only', () {
      expect(availableCaptionSources(1), [CaptionAudioSource.mic]);
    });
    test('no streams → empty', () {
      expect(availableCaptionSources(0), isEmpty);
    });
  });
}
