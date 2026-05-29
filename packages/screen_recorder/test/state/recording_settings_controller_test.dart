// packages/screen_recorder/test/state/recording_settings_controller_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rec_settings_ctrl_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('initial state is the passed-in settings', () {
    final store = RecordingSettingsStore(path: '${tmp.path}/s.json');
    final ctrl = RecordingSettingsController(
        store: store, initial: const RecordingSettings(countdownSeconds: 5));
    expect(ctrl.state.countdownSeconds, 5);
  });

  test('setCountdownSeconds updates state + persists', () async {
    final store = RecordingSettingsStore(path: '${tmp.path}/s.json');
    final ctrl = RecordingSettingsController(store: store, initial: RecordingSettings.defaults);
    await ctrl.setCountdownSeconds(5);
    expect(ctrl.state.countdownSeconds, 5);
    final reloaded = await store.load();
    expect(reloaded.countdownSeconds, 5);
  });

  test('setCountdownSeconds rejects invalid values', () async {
    final store = RecordingSettingsStore(path: '${tmp.path}/s.json');
    final ctrl = RecordingSettingsController(store: store, initial: RecordingSettings.defaults);
    await ctrl.setCountdownSeconds(99);
    expect(ctrl.state.countdownSeconds, 3); // unchanged
  });
}
