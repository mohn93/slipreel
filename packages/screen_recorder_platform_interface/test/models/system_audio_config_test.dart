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
}
