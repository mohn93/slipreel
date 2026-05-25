import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('AudioDeviceInfo', () {
    test('round-trips isDefault=true', () {
      const d = AudioDeviceInfo(
        id: 'uid-1', name: 'Built-in', type: AudioDeviceType.microphone,
        isDefault: true);
      final back = AudioDeviceInfo.fromJson(d.toJson());
      expect(back.id, 'uid-1');
      expect(back.name, 'Built-in');
      expect(back.type, AudioDeviceType.microphone);
      expect(back.isDefault, true);
    });

    test('isDefault defaults to false when absent', () {
      final d = AudioDeviceInfo.fromJson({
        'id': 'x', 'name': 'X', 'type': 'microphone',
      });
      expect(d.isDefault, false);
    });
  });
}
