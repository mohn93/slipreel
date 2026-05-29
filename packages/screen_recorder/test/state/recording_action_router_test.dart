import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;

class _FakePlatform extends ScreenRecorderPlatform {
  int pauseCalls = 0, resumeCalls = 0;
  @override
  Future<void> pauseRecording() async => pauseCalls++;
  @override
  Future<void> resumeRecording() async => resumeCalls++;
}

void main() {
  setUp(() {
    ScreenRecorderPlatform.instance = _FakePlatform();
  });

  test('pauseOrResume: from recording calls pauseRecording', () async {
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 0))),
    ]);
    addTearDown(container.dispose);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.recording);
    final router = RecordingActionRouter(container);
    await router.pauseOrResume();
    expect(container.read(recordingControllerProvider).status,
        RecordingStatus.paused);
  });

  test('pauseOrResume: from paused calls resumeRecording', () async {
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 0))),
    ]);
    addTearDown(container.dispose);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.paused);
    final router = RecordingActionRouter(container);
    await router.pauseOrResume();
    expect(container.read(recordingControllerProvider).status,
        RecordingStatus.recording);
  });

  testWidgets('start: 0-second countdown bypasses overlay', (tester) async {
    int countdownRuns = 0;
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 0))),
    ]);
    addTearDown(container.dispose);
    container.listen(countdownControllerProvider, (_, next) {
      if (next.active) countdownRuns++;
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          return Scaffold(body: ElevatedButton(
            onPressed: () => RecordingActionRouter(container).start(ctx),
            child: const Text('go'),
          ));
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(countdownRuns, 0);
  });
}
