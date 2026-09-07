import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;

void main() {
  test('RecordingSettings round-trips capture configs', () {
    const mic = MicrophoneConfig(
      deviceUid: 'uid-1',
      deviceLabel: 'Mic',
      reduceNoise: false,
      disableAgc: false,
    );
    const settings = RecordingSettings(countdownSeconds: 5, microphone: mic);
    final restored = RecordingSettings.fromJson(settings.toJson());
    expect(restored.countdownSeconds, 5);
    expect(restored.microphone?.deviceUid, 'uid-1');
    expect(restored.systemAudio, isNull);
    expect(restored.camera, isNull);
  });

  test('old JSON without capture keys loads as null', () {
    final restored = RecordingSettings.fromJson({'countdownSeconds': 3});
    expect(restored.microphone, isNull);
    expect(restored.systemAudio, isNull);
    expect(restored.camera, isNull);
  });
}
