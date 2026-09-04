import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;

class _FakePlatform extends ScreenRecorderPlatform {
  int pauseCalls = 0, resumeCalls = 0;
  String? deviceStarted;

  /// Live Screen Recording status returned by [getScreenRecordingPermission]
  /// (what `refreshAll` reads). Configurable per-test.
  PermissionStatus screenRec = PermissionStatus.granted;

  /// Result of [requestScreenRecordingPermission] (the macOS prompt). Counts
  /// calls so a test can assert the start path actually REQUESTS, not just
  /// checks.
  PermissionStatus requestScreenRecResult = PermissionStatus.denied;
  int requestScreenRecCalls = 0;

  @override
  Future<void> pauseRecording() async => pauseCalls++;
  @override
  Future<void> resumeRecording() async => resumeCalls++;
  @override
  Future<void> startDeviceRecording({
    required String deviceId,
    required bool captureDeviceAudio,
    required MicrophoneConfig? microphone,
    required String outputPath,
  }) async {
    deviceStarted = deviceId;
  }

  @override
  Future<PermissionStatus> getScreenRecordingPermission() async => screenRec;
  @override
  Future<PermissionStatus> requestScreenRecordingPermission() async {
    requestScreenRecCalls++;
    return requestScreenRecResult;
  }
}

/// A permissions controller pre-seeded with a fixed camera status, so the
/// device pre-flight in [RecordingActionRouter.start] can be exercised without
/// a live platform channel.
class _SeededPermissions extends PermissionsController {
  _SeededPermissions(super.platform, PermissionStatus camera,
      {PermissionStatus screenRecording = PermissionStatus.granted}) {
    state = PermissionsSnapshot({
      PermissionKind.camera: camera,
      PermissionKind.screenRecording: screenRecording,
    });
  }
}

/// No-op window chrome so `windowModeControllerProvider` resolves in tests
/// (its default throws until overridden in main()).
class _NoopChrome implements WindowChrome {
  @override
  Future<void> setMode(WindowMode mode) async {}
  @override
  Future<String?> showGearMenu() async => null;
  @override
  Future<void> startWindowDrag() async {}
  @override
  Future<void> setBarSize(double width, double height) async {}
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

  testWidgets(
      'start: device + camera denied shows deny PANEL, skips countdown + native start',
      (tester) async {
    int countdownRuns = 0;
    final platform = _FakePlatform();
    ScreenRecorderPlatform.instance = platform;
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 3))),
      permissionsControllerProvider.overrideWith(
          (ref) => _SeededPermissions(platform, PermissionStatus.denied)),
      windowChromeProvider.overrideWithValue(_NoopChrome()),
    ]);
    addTearDown(container.dispose);
    container.listen(countdownControllerProvider, (_, next) {
      if (next.active) countdownRuns++;
    });
    container
        .read(recordingControllerProvider.notifier)
        .selectSource(kind: RecordingSource.device, id: 'uid-x');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          return Scaffold(
              body: ElevatedButton(
            onPressed: () => RecordingActionRouter(container).start(ctx),
            child: const Text('go'),
          ));
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    // Deny UI shows as a full-screen panel (not a clipped bottom sheet)...
    expect(find.byType(PermissionDeniedScreen), findsOneWidget);
    expect(find.text('Camera permission required'), findsOneWidget);
    // ...the countdown never ran (the gate is checked BEFORE it)...
    expect(countdownRuns, 0);
    // ...and neither the controller nor the native side started a recording.
    expect(container.read(recordingControllerProvider).status,
        RecordingStatus.idle);
    expect(platform.deviceStarted, isNull);
  });

  testWidgets(
      'start: device + camera granted clears the gate (no panel, countdown runs)',
      (tester) async {
    int countdownRuns = 0;
    final platform = _FakePlatform();
    ScreenRecorderPlatform.instance = platform;
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 3))),
      permissionsControllerProvider.overrideWith(
          (ref) => _SeededPermissions(platform, PermissionStatus.granted)),
      windowChromeProvider.overrideWithValue(_NoopChrome()),
    ]);
    addTearDown(container.dispose);
    container.listen(countdownControllerProvider, (_, next) {
      if (next.active) countdownRuns++;
    });
    container
        .read(recordingControllerProvider.notifier)
        .selectSource(kind: RecordingSource.device, id: 'uid-y');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          return Scaffold(
              body: ElevatedButton(
            onPressed: () => RecordingActionRouter(container).start(ctx),
            child: const Text('go'),
          ));
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();

    // No deny panel, and the countdown proceeds (the device recording itself
    // fires only after the 3s timer, which this test deliberately doesn't
    // advance).
    expect(find.byType(PermissionDeniedScreen), findsNothing);
    expect(countdownRuns, 1);

    // Cancel the live countdown timer before the test ends — the pending-timer
    // invariant check runs before addTearDown disposes the container.
    container.read(countdownControllerProvider.notifier).cancel();
  });

  testWidgets(
      'start: screen source + screen-recording denied REQUESTS it, then shows '
      'deny panel (skips countdown)', (tester) async {
    int countdownRuns = 0;
    final platform = _FakePlatform()
      ..screenRec = PermissionStatus.denied
      ..requestScreenRecResult = PermissionStatus.denied; // user declines / restart
    ScreenRecorderPlatform.instance = platform;
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 3))),
      permissionsControllerProvider
          .overrideWith((ref) => PermissionsController(platform)),
      windowChromeProvider.overrideWithValue(_NoopChrome()),
    ]);
    addTearDown(container.dispose);
    container.listen(countdownControllerProvider, (_, next) {
      if (next.active) countdownRuns++;
    });
    container
        .read(recordingControllerProvider.notifier)
        .selectSource(kind: RecordingSource.screen, id: '1');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          return Scaffold(
              body: ElevatedButton(
            onPressed: () => RecordingActionRouter(container).start(ctx),
            child: const Text('go'),
          ));
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    // The start path actively REQUESTED screen recording (not just checked)...
    expect(platform.requestScreenRecCalls, greaterThanOrEqualTo(1));
    // ...then showed the deny panel, before the countdown, and never recorded.
    expect(find.byType(PermissionDeniedScreen), findsOneWidget);
    expect(find.text('Screen Recording permission required'), findsOneWidget);
    expect(countdownRuns, 0);
    expect(
        container.read(recordingControllerProvider).status, RecordingStatus.idle);
  });

  testWidgets(
      'start: screen source + screen-recording granted clears the gate '
      '(no panel, no request, countdown runs)', (tester) async {
    int countdownRuns = 0;
    final platform = _FakePlatform()..screenRec = PermissionStatus.granted;
    ScreenRecorderPlatform.instance = platform;
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 3))),
      permissionsControllerProvider
          .overrideWith((ref) => PermissionsController(platform)),
      windowChromeProvider.overrideWithValue(_NoopChrome()),
    ]);
    addTearDown(container.dispose);
    container.listen(countdownControllerProvider, (_, next) {
      if (next.active) countdownRuns++;
    });
    container
        .read(recordingControllerProvider.notifier)
        .selectSource(kind: RecordingSource.screen, id: '1');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          return Scaffold(
              body: ElevatedButton(
            onPressed: () => RecordingActionRouter(container).start(ctx),
            child: const Text('go'),
          ));
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.byType(PermissionDeniedScreen), findsNothing);
    expect(platform.requestScreenRecCalls, 0); // granted ⇒ never had to prompt
    expect(countdownRuns, 1);
    container.read(countdownControllerProvider.notifier).cancel();
  });

  testWidgets(
      'start: stale cached snapshot says denied but LIVE re-check is granted ⇒ '
      'proceeds (no panel)', (tester) async {
    // Regression for "System Settings shows granted but the app denies": the
    // cached snapshot is stale; the live refresh must win.
    int countdownRuns = 0;
    final platform = _FakePlatform()
      ..screenRec = PermissionStatus.granted; // LIVE truth
    ScreenRecorderPlatform.instance = platform;
    final container = ProviderContainer(overrides: [
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: RecordingSettingsStore(path: '/dev/null'),
              initial: const RecordingSettings(countdownSeconds: 3))),
      permissionsControllerProvider.overrideWith((ref) => _SeededPermissions(
          platform, PermissionStatus.granted,
          screenRecording: PermissionStatus.denied)), // STALE cache
      windowChromeProvider.overrideWithValue(_NoopChrome()),
    ]);
    addTearDown(container.dispose);
    container.listen(countdownControllerProvider, (_, next) {
      if (next.active) countdownRuns++;
    });
    container
        .read(recordingControllerProvider.notifier)
        .selectSource(kind: RecordingSource.screen, id: '1');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          return Scaffold(
              body: ElevatedButton(
            onPressed: () => RecordingActionRouter(container).start(ctx),
            child: const Text('go'),
          ));
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();

    // The live refresh overrode the stale "denied" cache ⇒ no panel, no prompt,
    // countdown proceeds.
    expect(find.byType(PermissionDeniedScreen), findsNothing);
    expect(platform.requestScreenRecCalls, 0);
    expect(countdownRuns, 1);
    container.read(countdownControllerProvider.notifier).cancel();
  });
}
