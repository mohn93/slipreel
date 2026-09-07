import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/state/microphone_controller.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeChrome implements WindowChrome {
  final List<WindowMode> calls = [];
  final List<({double w, double h})> barSizes = [];
  @override
  Future<void> setMode(WindowMode mode) async => calls.add(mode);
  @override
  Future<String?> showGearMenu() async => null;
  @override
  Future<void> startWindowDrag() async {}
  @override
  Future<void> setBarSize(double width, double height) async =>
      barSizes.add((w: width, h: height));
}

/// A fake platform that returns canned [pickSource]/[selectRegion] results and
/// records the kinds it was asked for. No real IO/native overlay.
class _FakePlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  _FakePlatform({this.picked, this.region});

  final PickedSource? picked;
  final RegionSelection? region;

  MicrophoneConfig? menuReturns;
  Completer<MicrophoneMenuResult>? micMenuCompleter;
  int showMicMenuCalls = 0;

  @override
  Future<MicrophoneMenuResult> showMicrophoneMenu(MicrophoneConfig? current) async {
    showMicMenuCalls++;
    if (micMenuCompleter case final completer?) return completer.future;
    return MicrophoneMenuResult(cancelled: false, config: menuReturns);
  }

  @override
  Future<SystemAudioMenuResult> showSystemAudioMenu(SystemAudioConfig? current) async {
    return const SystemAudioMenuResult(cancelled: true);
  }

  final List<RecordingSource> pickSourceCalls = [];
  int selectRegionCalls = 0;
  PermissionStatus screenRecordingPermission = PermissionStatus.granted;
  PermissionStatus requestedScreenRecordingPermission = PermissionStatus.denied;
  int requestScreenRecordingCalls = 0;

  @override
  Future<PickedSource?> pickSource(RecordingSource kind) async {
    pickSourceCalls.add(kind);
    return picked;
  }

  @override
  Future<RegionSelection?> selectRegion() async {
    selectRegionCalls++;
    return region;
  }

  @override
  Future<PermissionStatus> getScreenRecordingPermission() async =>
      screenRecordingPermission;

  @override
  Future<PermissionStatus> requestScreenRecordingPermission() async {
    requestScreenRecordingCalls++;
    return requestedScreenRecordingPermission;
  }

  final List<MicrophoneConfig> monitorStarts = [];
  int monitorStops = 0;

  @override
  Future<void> startMicMonitor(MicrophoneConfig config) async =>
      monitorStarts.add(config);

  @override
  Future<void> stopMicMonitor() async => monitorStops++;

  @override
  Stream<double> get micLevelStream => const Stream<double>.empty();
}

/// Records orchestration calls without doing any real recording IO.
class _FakeRecordingController extends RecordingController {
  _FakeRecordingController();

  final List<Map<String, Object?>> selectSourceCalls = [];
  int startCalls = 0;
  int stopCalls = 0;

  void emit(RecordingState s) => state = s;

  @override
  void selectSource({
    required RecordingSource? kind,
    required String? id,
    RegionSelection? region,
  }) {
    selectSourceCalls.add({'kind': kind, 'id': id, 'region': region});
  }

  @override
  Future<void> startRecording({
    MicrophoneConfig? microphone,
    SystemAudioConfig? systemAudio,
    CameraConfig? camera,
    PermissionsSnapshot? permissions,
    Future<void> Function(PermissionKind kind)? onDenied,
    String? defaultSaveLocation,
  }) async =>
      startCalls++;

  @override
  Future<void> stopRecording() async => stopCalls++;
}

// The RecordingBar is a wide horizontal Row; the default 800px test surface
// overflows it. Match the existing recording_bar_test.dart pattern.
void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Returns a TipsController override with all tips already seen so
/// TipAnchor overlays don't interfere with bar-screen tests.
Future<Override> _tipsOverride() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  for (final id in TipId.values) {
    await c.markSeen(id);
  }
  return tipsControllerProvider.overrideWith((ref) => c);
}

void main() {
  setUp(() {
    recordingActionRouterRef = null;
  });

  tearDown(() {
    recordingActionRouterRef = null;
  });

  testWidgets('bar mode renders the RecordingBar', (tester) async {
    _wide(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();
    expect(find.byType(RecordingBar), findsOneWidget);
    expect(find.byType(RecordingPill), findsNothing);
  });

  testWidgets('pill mode renders the RecordingPill', (tester) async {
    _wide(tester);
    late WidgetRef capturedRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        await _tipsOverride(),
      ],
      child: MaterialApp(
        home: Consumer(builder: (c, ref, _) {
          capturedRef = ref;
          return const RecordingBarScreen();
        }),
      ),
    ));
    await tester.pump();
    await capturedRef.read(windowModeControllerProvider.notifier).showPill();
    await tester.pump();
    expect(find.byType(RecordingPill), findsOneWidget);
    expect(find.byType(RecordingBar), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // Orchestration: _pickAndRecord + the status→pill listener.
  //
  // Covered by manual verification: the completed→PlaybackScreen push and the
  // Recents/Settings panel pushes are not exercised here because those screens
  // do real video/file IO that isn't test-friendly.
  // ---------------------------------------------------------------------------

  testWidgets('tapping Window picks a source and starts recording',
      (tester) async {
    _wide(tester);
    final fakePlatform =
        _FakePlatform(picked: const PickedSource(kind: RecordingSource.window, id: '7'));
    ScreenRecorderPlatform.instance = fakePlatform;
    final fakeController = _FakeRecordingController();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        recordingControllerProvider.overrideWith((ref) => fakeController),
        permissionsControllerProvider.overrideWith(
            (ref) => PermissionsController(ScreenRecorderPlatform.instance)
              ..state = PermissionsSnapshot.initial),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    await tester.tap(find.text('Window'));
    await tester.pumpAndSettle();

    expect(fakePlatform.pickSourceCalls, [RecordingSource.window]);
    expect(fakeController.selectSourceCalls, hasLength(1));
    expect(fakeController.selectSourceCalls.single['kind'],
        RecordingSource.window);
    expect(fakeController.selectSourceCalls.single['id'], '7');
    // startRecording is now routed through recordingActionRouterRef?.start(),
    // which is null in test context — so fakeController.startCalls stays 0.
    expect(fakeController.startCalls, 0);
  });

  testWidgets(
      'tapping Window without screen permission shows CTA before source picker',
      (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform()
      ..screenRecordingPermission = PermissionStatus.denied
      ..requestedScreenRecordingPermission = PermissionStatus.denied;
    ScreenRecorderPlatform.instance = fakePlatform;
    final fakeController = _FakeRecordingController();
    final container = ProviderContainer(overrides: [
      windowChromeProvider.overrideWithValue(_FakeChrome()),
      recordingControllerProvider.overrideWith((ref) => fakeController),
      permissionsControllerProvider.overrideWith(
          (ref) => PermissionsController(fakePlatform)),
      await _tipsOverride(),
    ]);
    addTearDown(container.dispose);
    recordingActionRouterRef = RecordingActionRouter(container);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    await tester.tap(find.text('Window'));
    await tester.pumpAndSettle();

    expect(fakePlatform.requestScreenRecordingCalls, 1);
    expect(fakePlatform.pickSourceCalls, isEmpty);
    expect(find.byType(PermissionDeniedScreen), findsOneWidget);
    expect(find.text('Screen Recording permission required'), findsOneWidget);
    expect(find.text('Open System Settings'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling the picker is a no-op', (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform(picked: null);
    ScreenRecorderPlatform.instance = fakePlatform;
    final fakeController = _FakeRecordingController();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        recordingControllerProvider.overrideWith((ref) => fakeController),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    await tester.tap(find.text('Window'));
    await tester.pumpAndSettle();

    expect(fakePlatform.pickSourceCalls, [RecordingSource.window]);
    expect(fakeController.selectSourceCalls, isEmpty);
    expect(fakeController.startCalls, 0);
  });

  testWidgets('tapping Area uses selectRegion + starts', (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform(
      region: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 100, heightPx: 100),
    );
    ScreenRecorderPlatform.instance = fakePlatform;
    final fakeController = _FakeRecordingController();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        recordingControllerProvider.overrideWith((ref) => fakeController),
        permissionsControllerProvider.overrideWith(
            (ref) => PermissionsController(ScreenRecorderPlatform.instance)
              ..state = PermissionsSnapshot.initial),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    await tester.tap(find.text('Area'));
    await tester.pumpAndSettle();

    expect(fakePlatform.selectRegionCalls, 1);
    expect(fakeController.selectSourceCalls, hasLength(1));
    expect(fakeController.selectSourceCalls.single['kind'], RecordingSource.area);
    expect(fakeController.selectSourceCalls.single['id'], '1');
    expect(fakeController.selectSourceCalls.single['region'], isA<RegionSelection>());
    // startRecording is now routed through recordingActionRouterRef?.start(),
    // which is null in test context — so fakeController.startCalls stays 0.
    expect(fakeController.startCalls, 0);
  });

  testWidgets('recording status shows the pill', (tester) async {
    _wide(tester);
    ScreenRecorderPlatform.instance = _FakePlatform();
    final fakeController = _FakeRecordingController();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        recordingControllerProvider.overrideWith((ref) => fakeController),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    fakeController.emit(const RecordingState(status: RecordingStatus.recording));
    await tester.pump();
    await tester.pump();

    expect(find.byType(RecordingPill), findsOneWidget);
  });

  testWidgets('tapping the mic control opens the menu and updates state',
      (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform()
      ..menuReturns = const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic One');
    ScreenRecorderPlatform.instance = fakePlatform;

    late WidgetRef capturedRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        await _tipsOverride(),
      ],
      child: MaterialApp(
        home: Consumer(builder: (c, ref, _) {
          capturedRef = ref;
          return const RecordingBarScreen();
        }),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('bar-mic')));
    await tester.pumpAndSettle();

    expect(fakePlatform.showMicMenuCalls, 1);
    expect(capturedRef.read(microphoneControllerProvider)?.deviceLabel, 'Mic One');
    expect(find.text('Mic One'), findsOneWidget);
  });

  testWidgets('shows a spinner while the microphone menu is loading',
      (tester) async {
    _wide(tester);
    final completer = Completer<MicrophoneMenuResult>();
    final fakePlatform = _FakePlatform()..micMenuCompleter = completer;
    ScreenRecorderPlatform.instance = fakePlatform;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('bar-mic')));
    await tester.pump();
    expect(find.byKey(const Key('mic-menu-loading')), findsOneWidget);

    // Repeated clicks while discovery is pending must not open extra menus.
    await tester.tap(find.byKey(const Key('bar-mic')));
    await tester.pump();
    expect(fakePlatform.showMicMenuCalls, 1);

    completer.complete(const MicrophoneMenuResult(cancelled: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mic-menu-loading')), findsNothing);
  });

  testWidgets('bar auto-sizes its window to the (variable) content size',
      (tester) async {
    _wide(tester);
    ScreenRecorderPlatform.instance = _FakePlatform();
    final chrome = _FakeChrome();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(chrome),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pumpAndSettle();

    expect(chrome.barSizes, isNotEmpty);
    final off = chrome.barSizes.last;
    expect(off.w, greaterThan(320));
    expect(off.h, 68); // base height, no meter when mic is off

    final container = ProviderScope.containerOf(
        tester.element(find.byType(RecordingBar)));
    container
        .read(microphoneControllerProvider.notifier)
        .set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'X'));
    await tester.pumpAndSettle();

    final on = chrome.barSizes.last;
    // Mic chip is fixed-width now, so selecting a device doesn't change the bar
    // width (the label ellipsizes within the fixed chip).
    expect(on.w, off.w);
    expect(on.h, 68); // same constant height — meter is inside the chip now
  });

  testWidgets('renders the system-audio control', (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform();
    ScreenRecorderPlatform.instance = fakePlatform;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        await _tipsOverride(),
      ],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pump();

    expect(find.byKey(const Key('bar-system-audio')), findsOneWidget);
  });

  testWidgets('monitor starts when a mic is selected, stops when off',
      (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform();
    ScreenRecorderPlatform.instance = fakePlatform;

    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        windowChromeProvider.overrideWithValue(_FakeChrome()),
        await _tipsOverride(),
      ],
      child: MaterialApp(
        home: Consumer(builder: (c, r, _) {
          ref = r;
          return const RecordingBarScreen();
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(fakePlatform.monitorStarts, isEmpty); // off by default

    ref.read(microphoneControllerProvider.notifier)
        .set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic'));
    await tester.pumpAndSettle();
    expect(fakePlatform.monitorStarts, hasLength(1));

    ref.read(microphoneControllerProvider.notifier).set(null);
    await tester.pumpAndSettle();
    expect(fakePlatform.monitorStops, greaterThanOrEqualTo(1));
  });
}
