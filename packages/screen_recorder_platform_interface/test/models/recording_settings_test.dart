import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:screen_recorder_platform_interface/src/models/system_audio_config.dart';

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

  test('toJson includes systemAudio when set, null when off', () {
    const withSys = RecordingSettings(
      source: RecordingSource.screen,
      systemAudio: SystemAudioConfig(mode: SystemAudioMode.allApps),
    );
    expect(withSys.toJson()['systemAudio'],
        {'mode': 'allApps', 'bundleIds': <String>[]});

    const off = RecordingSettings(source: RecordingSource.screen);
    expect(off.toJson()['systemAudio'], isNull);
  });

  test('fromJson restores systemAudio', () {
    const c = RecordingSettings(
      source: RecordingSource.screen,
      systemAudio: SystemAudioConfig(
          mode: SystemAudioMode.selectedApps, bundleIds: ['com.apple.Music']),
    );
    final restored = RecordingSettings.fromJson(c.toJson());
    expect(restored.systemAudio, c.systemAudio);
  });

  test('copyWith replaces systemAudio', () {
    const c = RecordingSettings(source: RecordingSource.screen);
    final d = c.copyWith(
        systemAudio: const SystemAudioConfig(mode: SystemAudioMode.allApps));
    expect(d.systemAudio!.mode, SystemAudioMode.allApps);
  });
}
