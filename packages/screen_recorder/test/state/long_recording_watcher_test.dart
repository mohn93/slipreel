import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/long_recording_watcher.dart';
import 'package:screen_recorder/state/recording_state.dart';

void main() {
  test('fires toast30 at 30 min and toast60 at 60 min', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final fired = <ThresholdAction>[];
    final watcher = LongRecordingWatcher(
        container: container, onFire: (a) => fired.add(a));

    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.recording);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(
            status: RecordingStatus.recording,
            duration: Duration(minutes: 30));
    await Future<void>.delayed(Duration.zero);

    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(
            status: RecordingStatus.recording,
            duration: Duration(minutes: 60));
    await Future<void>.delayed(Duration.zero);

    expect(fired, contains(ThresholdAction.toast30));
    expect(fired, contains(ThresholdAction.toast60));
    watcher.dispose();
  });

  test('does not refire on the same threshold', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final fired = <ThresholdAction>[];
    final watcher = LongRecordingWatcher(
        container: container, onFire: (a) => fired.add(a));

    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(
            status: RecordingStatus.recording,
            duration: Duration(minutes: 30));
    await Future<void>.delayed(Duration.zero);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(
            status: RecordingStatus.recording,
            duration: Duration(minutes: 31));
    await Future<void>.delayed(Duration.zero);
    expect(fired.where((a) => a == ThresholdAction.toast30).length, 1);
    watcher.dispose();
  });

  test('resets fired set when status returns to idle', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final fired = <ThresholdAction>[];
    final watcher = LongRecordingWatcher(
        container: container, onFire: (a) => fired.add(a));

    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(
            status: RecordingStatus.recording,
            duration: Duration(minutes: 30));
    await Future<void>.delayed(Duration.zero);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.idle);
    await Future<void>.delayed(Duration.zero);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(
            status: RecordingStatus.recording,
            duration: Duration(minutes: 30));
    await Future<void>.delayed(Duration.zero);
    expect(fired.where((a) => a == ThresholdAction.toast30).length, 2);
    watcher.dispose();
  });
}
