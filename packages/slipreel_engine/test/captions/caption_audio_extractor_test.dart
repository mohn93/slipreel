// packages/slipreel_engine/test/captions/caption_audio_extractor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/caption_audio_extractor.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
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

  group('captionAudioOffsetMicros', () {
    AudioStreamInfo s(int idx, int ch, int startMicros) => AudioStreamInfo(
        index: idx, channels: ch, codecName: 'aac', startMicros: startMicros);

    test('empty streams → 0', () {
      expect(captionAudioOffsetMicros(CaptionAudioSource.mic, const []), 0);
    });

    test('mic uses stream 0 start_time', () {
      expect(
        captionAudioOffsetMicros(
            CaptionAudioSource.mic, [s(0, 1, 200000), s(1, 2, 240000)]),
        200000,
      );
    });

    test('system (two streams) uses stream 1 start_time', () {
      expect(
        captionAudioOffsetMicros(
            CaptionAudioSource.system, [s(0, 1, 200000), s(1, 2, 240000)]),
        240000,
      );
    });

    test('system with one stream falls back to stream 0 (matches extraction)',
        () {
      expect(
          captionAudioOffsetMicros(CaptionAudioSource.system, [s(0, 2, 240000)]),
          240000);
    });

    test('mixed uses the EARLIER stream start (amix aligns to earliest)', () {
      expect(
        captionAudioOffsetMicros(
            CaptionAudioSource.mixed, [s(0, 1, 260000), s(1, 2, 240000)]),
        240000,
      );
    });

    test('mixed with one stream uses stream 0', () {
      expect(
          captionAudioOffsetMicros(CaptionAudioSource.mixed, [s(0, 1, 200000)]),
          200000);
    });
  });
}
