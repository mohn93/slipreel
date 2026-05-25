import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('MicrophoneConfig', () {
    const cfg = MicrophoneConfig(
      deviceUid: 'AppleHDAEngineInput:1B,0,1,0:1',
      deviceLabel: 'MacBook Pro Microphone',
      reduceNoise: true,
      disableAgc: false,
    );

    test('toJson round-trips through fromJson', () {
      final back = MicrophoneConfig.fromJson(cfg.toJson());
      expect(back, cfg);
    });

    test('toJson emits all fields', () {
      final json = cfg.toJson();
      expect(json['deviceUid'], 'AppleHDAEngineInput:1B,0,1,0:1');
      expect(json['deviceLabel'], 'MacBook Pro Microphone');
      expect(json['reduceNoise'], true);
      expect(json['disableAgc'], false);
    });

    test('reduceNoise/disableAgc default to false', () {
      const c = MicrophoneConfig(deviceUid: 'x', deviceLabel: 'X');
      expect(c.reduceNoise, false);
      expect(c.disableAgc, false);
    });

    test('copyWith overrides only the given fields', () {
      final c = cfg.copyWith(disableAgc: true);
      expect(c.disableAgc, true);
      expect(c.reduceNoise, true);
      expect(c.deviceUid, cfg.deviceUid);
    });

    test('value equality', () {
      expect(cfg, const MicrophoneConfig(
        deviceUid: 'AppleHDAEngineInput:1B,0,1,0:1',
        deviceLabel: 'MacBook Pro Microphone',
        reduceNoise: true,
        disableAgc: false,
      ));
      expect(cfg == cfg.copyWith(reduceNoise: false), false);
    });
  });

  group('MicrophoneMenuResult', () {
    test('parses a device selection', () {
      final r = MicrophoneMenuResult.fromJson({
        'cancelled': false,
        'config': {
          'deviceUid': 'uid-1',
          'deviceLabel': 'Mic One',
          'reduceNoise': false,
          'disableAgc': false,
        },
      });
      expect(r.cancelled, false);
      expect(r.config?.deviceUid, 'uid-1');
    });

    test('parses "Don\'t record" (config null, not cancelled)', () {
      final r = MicrophoneMenuResult.fromJson({'cancelled': false, 'config': null});
      expect(r.cancelled, false);
      expect(r.config, isNull);
    });

    test('parses a dismissal', () {
      final r = MicrophoneMenuResult.fromJson({'cancelled': true, 'config': null});
      expect(r.cancelled, true);
      expect(r.config, isNull);
    });
  });
}
