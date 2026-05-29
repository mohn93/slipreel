import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/state/sleep_observer.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  final c = StreamController<Map<dynamic, dynamic>>.broadcast();
  int startCalls = 0;
  @override
  Future<void> startSleepObserver() async => startCalls++;
  @override
  Stream<Map<dynamic, dynamic>> get sleepEvents => c.stream;
}

class _FakeRouter implements RecordingActionRouter {
  int pauses = 0, stops = 0, starts = 0;
  @override
  Future<void> start(_) async => starts++;
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> pauseOrResume() async => pauses++;
}

void main() {
  test('willSleep when recording pauses', () async {
    final fake = _FakePlatform();
    final router = _FakeRouter();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.recording);
    final observer = SleepObserver(
        platform: fake, router: router, container: container);
    await Future<void>.delayed(Duration.zero);
    fake.c.add({'event': 'willSleep'});
    await Future<void>.delayed(Duration.zero);
    expect(router.pauses, 1);
    expect(observer.pausedBySleep, isTrue);
    observer.dispose();
  });

  test('willSleep when idle is a no-op', () async {
    final fake = _FakePlatform();
    final router = _FakeRouter();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final observer = SleepObserver(
        platform: fake, router: router, container: container);
    await Future<void>.delayed(Duration.zero);
    fake.c.add({'event': 'willSleep'});
    await Future<void>.delayed(Duration.zero);
    expect(router.pauses, 0);
    expect(observer.pausedBySleep, isFalse);
    observer.dispose();
  });

  test('didWake when not pausedBySleep does not call onWake', () async {
    final fake = _FakePlatform();
    final router = _FakeRouter();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    int wakeCalls = 0;
    final observer = SleepObserver(
        platform: fake,
        router: router,
        container: container,
        onWake: () => wakeCalls++);
    await Future<void>.delayed(Duration.zero);
    fake.c.add({'event': 'didWake'});
    await Future<void>.delayed(Duration.zero);
    expect(wakeCalls, 0);
    observer.dispose();
  });

  test('manual resume clears the pausedBySleep flag', () async {
    final fake = _FakePlatform();
    final router = _FakeRouter();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.recording);
    final observer = SleepObserver(
        platform: fake, router: router, container: container);
    await Future<void>.delayed(Duration.zero);
    fake.c.add({'event': 'willSleep'});
    await Future<void>.delayed(Duration.zero);
    expect(observer.pausedBySleep, isTrue);
    // Simulate manual transition paused -> recording.
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.paused);
    container.read(recordingControllerProvider.notifier).state =
        const RecordingState(status: RecordingStatus.recording);
    await Future<void>.delayed(Duration.zero);
    expect(observer.pausedBySleep, isFalse);
    observer.dispose();
  });
}
