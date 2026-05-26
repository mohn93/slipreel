import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/microphone_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('starts off (null)', () {
    expect(MicrophoneController().state, isNull);
  });

  test('set applies a config', () {
    final c = MicrophoneController();
    const cfg = MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L');
    c.set(cfg);
    expect(c.state, cfg);
  });

  test('set(null) turns it off', () {
    final c = MicrophoneController();
    c.set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L'));
    c.set(null);
    expect(c.state, isNull);
  });

  test('setting an equal config does not emit a new state', () {
    final c = MicrophoneController();
    const cfg = MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L');
    c.set(cfg);
    var emissions = 0;
    final remove = c.addListener((_) => emissions++); // fires once immediately
    c.set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L')); // equal → no-op
    remove();
    expect(emissions, 1);
  });
}
