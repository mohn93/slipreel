import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('RecordingSettings.microphone', () {
    test('toJson emits microphone map when set', () {
      const s = RecordingSettings(
        source: RecordingSource.screen,
        microphone: MicrophoneConfig(deviceUid: 'uid', deviceLabel: 'Mic'),
      );
      final json = s.toJson();
      expect(json['microphone'], isA<Map>());
      expect(json['microphone']['deviceUid'], 'uid');
      expect(json.containsKey('captureAudio'), false);
      expect(json.containsKey('audioDeviceIds'), false);
    });

    test('toJson emits null microphone when off', () {
      const s = RecordingSettings(source: RecordingSource.screen);
      expect(s.toJson()['microphone'], isNull);
    });

    test('fromJson parses microphone', () {
      final s = RecordingSettings.fromJson({
        'source': 'window',
        'microphone': {'deviceUid': 'u', 'deviceLabel': 'L', 'reduceNoise': true, 'disableAgc': false},
      });
      expect(s.microphone?.deviceUid, 'u');
      expect(s.microphone?.reduceNoise, true);
    });

    test('fromJson with no microphone key yields null (off)', () {
      final s = RecordingSettings.fromJson({'source': 'screen'});
      expect(s.microphone, isNull);
    });

    test('copyWith replaces microphone', () {
      const s = RecordingSettings(source: RecordingSource.screen);
      final s2 = s.copyWith(microphone: const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L'));
      expect(s2.microphone?.deviceUid, 'u');
    });
  });
}
