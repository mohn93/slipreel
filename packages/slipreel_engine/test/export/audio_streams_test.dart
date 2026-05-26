import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

void main() {
  group('parseAudioStreams', () {
    test('parses an ffprobe JSON stream list', () {
      const json = '''
      {"streams":[
        {"index":0,"codec_name":"aac","channels":1,"bit_rate":"128000"},
        {"index":1,"codec_name":"aac","channels":2,"bit_rate":"192000"}
      ]}''';
      final streams = parseAudioStreams(json);
      expect(streams.length, 2);
      expect(streams[0].index, 0);
      expect(streams[0].channels, 1);
      expect(streams[0].bitrateKbps, 128);
      expect(streams[1].channels, 2);
    });

    test('handles missing/absent bitrate and empty list', () {
      expect(parseAudioStreams('{"streams":[]}'), isEmpty);
      final s = parseAudioStreams(
          '{"streams":[{"index":0,"codec_name":"aac","channels":1}]}');
      expect(s.single.bitrateKbps, isNull);
    });
  });

  group('inferAudioRoles', () {
    AudioStreamInfo s(int i, int ch) =>
        AudioStreamInfo(index: i, channels: ch, codecName: 'aac');

    test('two tracks: mono=mic, stereo=system', () {
      final roles = inferAudioRoles([s(0, 1), s(1, 2)]);
      expect(roles[AudioRole.microphone], 0);
      expect(roles[AudioRole.system], 1);
    });

    test('one mono track = mic', () {
      final roles = inferAudioRoles([s(0, 1)]);
      expect(roles[AudioRole.microphone], 0);
      expect(roles.containsKey(AudioRole.system), isFalse);
    });

    test('one stereo track = system', () {
      final roles = inferAudioRoles([s(0, 2)]);
      expect(roles[AudioRole.system], 0);
      expect(roles.containsKey(AudioRole.microphone), isFalse);
    });

    test('two equal-channel tracks fall back to order (first=mic)', () {
      final roles = inferAudioRoles([s(0, 2), s(1, 2)]);
      expect(roles[AudioRole.microphone], 0);
      expect(roles[AudioRole.system], 1);
    });

    test('no tracks => empty', () {
      expect(inferAudioRoles(const []), isEmpty);
    });
  });
}
