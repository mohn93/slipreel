import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/system_audio_config.dart';

void main() {
  group('SystemAudioConfig', () {
    test('allApps round-trips through JSON', () {
      const c = SystemAudioConfig(mode: SystemAudioMode.allApps);
      final json = c.toJson();
      expect(json, {'mode': 'allApps', 'bundleIds': <String>[]});
      expect(SystemAudioConfig.fromJson(json), c);
    });

    test('selectedApps round-trips with bundleIds', () {
      const c = SystemAudioConfig(
        mode: SystemAudioMode.selectedApps,
        bundleIds: ['com.apple.Music', 'com.tinyspeck.slackmacgap'],
      );
      expect(SystemAudioConfig.fromJson(c.toJson()), c);
    });

    test('equality is order-insensitive for bundleIds', () {
      const a = SystemAudioConfig(
        mode: SystemAudioMode.selectedApps, bundleIds: ['a', 'b']);
      const b = SystemAudioConfig(
        mode: SystemAudioMode.selectedApps, bundleIds: ['b', 'a']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith replaces fields', () {
      const c = SystemAudioConfig(mode: SystemAudioMode.allApps);
      final d = c.copyWith(
        mode: SystemAudioMode.selectedApps, bundleIds: ['x']);
      expect(d.mode, SystemAudioMode.selectedApps);
      expect(d.bundleIds, ['x']);
    });
  });

  group('SystemAudioMenuResult', () {
    test('decodes a cancelled result', () {
      final r = SystemAudioMenuResult.fromJson(
          {'cancelled': true, 'config': null});
      expect(r.cancelled, isTrue);
      expect(r.config, isNull);
    });

    test('decodes an off (null config) result', () {
      final r = SystemAudioMenuResult.fromJson(
          {'cancelled': false, 'config': null});
      expect(r.cancelled, isFalse);
      expect(r.config, isNull);
    });

    test('decodes a selected-apps config', () {
      final r = SystemAudioMenuResult.fromJson({
        'cancelled': false,
        'config': {'mode': 'selectedApps', 'bundleIds': ['com.apple.Music']},
      });
      expect(r.cancelled, isFalse);
      expect(r.config,
          const SystemAudioConfig(
              mode: SystemAudioMode.selectedApps,
              bundleIds: ['com.apple.Music']));
    });
  });
}
