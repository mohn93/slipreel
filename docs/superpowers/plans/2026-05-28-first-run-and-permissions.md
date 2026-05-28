# First-run & Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-run onboarding, a Dart-side permission status surface, an on-demand "permission denied → System Settings" sheet, and a 5-tip contextual coachmark system — wiring the existing native permission probes (Screen Recording, Microphone, Accessibility) all the way up to UI.

**Architecture:** Bottom-up. Define shared `PermissionStatus` types in the federated interface package, expose three new typed `get*Permission` plugin methods (plus a missing `requestMicrophonePermission`) through the macOS plugin, then build a Riverpod `PermissionsController` on top. UI layers — onboarding screens, deny sheet, contextual tips — consume that one source of truth. SharedPreferences holds two persisted keys: `slipreel.onboarding_complete` (bool) and `slipreel.tips_seen` (Set<String>).

**Tech Stack:** Flutter, Riverpod (StateNotifier), Dart federated plugin, Swift (ScreenCaptureKit / AVCaptureDevice / AXIsProcessTrusted), `shared_preferences`, `url_launcher`.

**Spec:** `docs/superpowers/specs/2026-05-28-first-run-and-permissions-design.md`

---

## File map (locked in before tasks)

### Created
- `packages/screen_recorder_platform_interface/lib/src/permission_status.dart` — enums + codec for permission status
- `packages/screen_recorder/lib/state/permissions_controller.dart` — Riverpod controller + provider + lifecycle observer
- `packages/screen_recorder/lib/onboarding/onboarding_store.dart` — SharedPreferences wrapper for the first-run flag
- `packages/screen_recorder/lib/onboarding/tips_store.dart` — SharedPreferences wrapper for the seen-tip set
- `packages/screen_recorder/lib/onboarding/tips_controller.dart` — TipId enum + copy map + Riverpod controller + provider
- `packages/screen_recorder/lib/onboarding/tip_anchor.dart` — widget that wraps a child with a GlobalKey
- `packages/screen_recorder/lib/onboarding/tip_overlay.dart` — coachmark renderer (backdrop, cutout, callout bubble)
- `packages/screen_recorder/lib/ui/widgets/permission_denied_sheet.dart` — modal bottom sheet + deep-link launcher
- `packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart` — 3-page PageView root
- `packages/screen_recorder/lib/ui/screens/onboarding/pages/welcome_page.dart`
- `packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart`
- `packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart`

### Modified
- `packages/screen_recorder_platform_interface/lib/src/constants.dart` — add 4 method-name constants
- `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` — 4 new abstract methods (default returns `PermissionStatus.unsupported` / no-op)
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` — 4 new method-channel cases
- `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` — Dart bindings for the 4 new methods
- `packages/screen_recorder/lib/state/recording_state.dart` — guard `startRecording` on Screen Rec permission
- `packages/screen_recorder/lib/main.dart` — load `OnboardingStore`, init `PermissionsController`, route to `OnboardingScreen` when flag is false, register reset VM-service extension
- `packages/screen_recorder/lib/ui/bar/recording_bar.dart` — wrap the Display button in `TipAnchor(TipId.barModePicker)`
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (or whichever file holds the editor's TrimHandle / zoom track / inspector tabs / export button) — wrap those four widgets in `TipAnchor(TipId.editor*)`

### Created (tests)
- `packages/screen_recorder_platform_interface/test/permission_status_test.dart`
- `packages/screen_recorder/test/state/permissions_controller_test.dart`
- `packages/screen_recorder/test/onboarding/onboarding_store_test.dart`
- `packages/screen_recorder/test/onboarding/tips_store_test.dart`
- `packages/screen_recorder/test/onboarding/tips_controller_test.dart`
- `packages/screen_recorder/test/onboarding/tip_anchor_test.dart`
- `packages/screen_recorder/test/ui/widgets/permission_denied_sheet_test.dart`
- `packages/screen_recorder/test/ui/screens/onboarding/onboarding_screen_test.dart`

---

## Branch

All tasks land on a feature branch.

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git checkout -b feat/first-run-permissions
```

Commit after each task. Open PR (or merge to main) only after the final task.

---

### Task 1: Shared `PermissionStatus` types in the federated interface

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/permission_status.dart`
- Test: `packages/screen_recorder_platform_interface/test/permission_status_test.dart`
- Modify (export): `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/permission_status_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/permission_status.dart';

void main() {
  group('PermissionStatusCodec', () {
    test('round-trips all known values', () {
      for (final s in PermissionStatus.values) {
        expect(PermissionStatusCodec.fromWire(s.wire), s);
      }
    });

    test('unknown wire string falls back to notDetermined', () {
      expect(PermissionStatusCodec.fromWire('nonsense'),
          PermissionStatus.notDetermined);
    });

    test('null wire string falls back to notDetermined', () {
      expect(PermissionStatusCodec.fromWire(null),
          PermissionStatus.notDetermined);
    });

    test('PermissionKind has exactly three members', () {
      expect(PermissionKind.values, hasLength(3));
      expect(PermissionKind.values, containsAll(const [
        PermissionKind.screenRecording,
        PermissionKind.microphone,
        PermissionKind.accessibility,
      ]));
    });
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run from the repo root:
```bash
cd packages/screen_recorder_platform_interface && flutter test test/permission_status_test.dart
```
Expected: FAIL — `permission_status.dart` does not exist.

- [ ] **Step 3: Implement the types**

```dart
// packages/screen_recorder_platform_interface/lib/src/permission_status.dart

/// The three permission kinds Slipreel cares about today.
enum PermissionKind { screenRecording, microphone, accessibility }

/// Status of a single permission kind, in a shape that maps cleanly to
/// macOS's `AVAuthorizationStatus` + ScreenCaptureKit + AX states, and
/// degrades to `unsupported` everywhere else.
enum PermissionStatus {
  granted('granted'),
  denied('denied'),
  notDetermined('notDetermined'),
  restricted('restricted'),
  unsupported('unsupported');

  const PermissionStatus(this.wire);

  /// The string used on the method-channel wire.
  final String wire;
}

/// Decodes wire strings sent by native side. Unknown / null values
/// fall back to [PermissionStatus.notDetermined] — safer than throwing
/// because an unrecognised status should let the user attempt to Grant
/// rather than soft-lock the UI.
class PermissionStatusCodec {
  const PermissionStatusCodec._();

  static PermissionStatus fromWire(String? wire) {
    if (wire == null) return PermissionStatus.notDetermined;
    for (final s in PermissionStatus.values) {
      if (s.wire == wire) return s;
    }
    return PermissionStatus.notDetermined;
  }
}
```

- [ ] **Step 4: Export from the package barrel**

Open `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` and add (alongside the existing exports):
```dart
export 'src/permission_status.dart';
```

- [ ] **Step 5: Run the test, verify it passes**

```bash
cd packages/screen_recorder_platform_interface && flutter test test/permission_status_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/permission_status.dart \
        packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart \
        packages/screen_recorder_platform_interface/test/permission_status_test.dart
git commit -m "feat(interface): PermissionKind + PermissionStatus shared types"
```

---

### Task 2: Method-name constants + abstract methods on the interface

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`

- [ ] **Step 1: Add method-name constants**

Open `packages/screen_recorder_platform_interface/lib/src/constants.dart` and add inside `class ScreenRecorderMethods`:
```dart
  static const String getScreenRecordingPermission = 'getScreenRecordingPermission';
  static const String getMicrophonePermission = 'getMicrophonePermission';
  static const String getAccessibilityPermission = 'getAccessibilityPermission';
  static const String requestMicrophonePermission = 'requestMicrophonePermission';
```

- [ ] **Step 2: Add abstract methods on the platform interface**

Open `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`. Find the existing `requestPermissions` / `checkPermissions` / `isAccessibilityTrusted` methods and add immediately after them:

```dart
  /// Typed status query for Screen Recording (macOS ScreenCaptureKit).
  /// Default returns [PermissionStatus.unsupported] for platforms that
  /// haven't implemented this yet (Win/Linux).
  Future<PermissionStatus> getScreenRecordingPermission() async =>
      PermissionStatus.unsupported;

  /// Typed status query for Microphone (macOS AVCaptureDevice).
  Future<PermissionStatus> getMicrophonePermission() async =>
      PermissionStatus.unsupported;

  /// Typed status query for Accessibility (macOS AXIsProcessTrusted).
  Future<PermissionStatus> getAccessibilityPermission() async =>
      PermissionStatus.unsupported;

  /// Triggers the system mic-permission prompt the first time, otherwise
  /// returns the current status without re-prompting. No-op on unsupported
  /// platforms.
  Future<PermissionStatus> requestMicrophonePermission() async =>
      PermissionStatus.unsupported;
```

Also add at the top of the file (if not already present):
```dart
import 'permission_status.dart';
```

- [ ] **Step 3: Run analyzer on the interface package**

```bash
cd packages/screen_recorder_platform_interface && flutter analyze --no-fatal-infos
```
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/constants.dart \
        packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart
git commit -m "feat(interface): expose typed get/request permission methods"
```

---

### Task 3: macOS Swift — implement 4 new method cases

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

The four new cases share helpers already in `ScreenCaptureManager.swift` (screen rec) and `AudioCaptureManager.swift` (mic). `AXIsProcessTrusted()` is already used elsewhere in the plugin.

- [ ] **Step 1: Add the four cases to the giant `switch method` in `handle(_:result:)`**

Insert these cases alongside the existing permission cases (after `requestAccessibilityPermission`):

```swift
case "getScreenRecordingPermission":
  Task {
    let manager = ScreenCaptureManager()
    let granted = await manager.checkPermission()
    result(granted ? "granted" : "denied")
  }

case "getMicrophonePermission":
  let status = AVCaptureDevice.authorizationStatus(for: .audio)
  switch status {
  case .authorized: result("granted")
  case .denied:     result("denied")
  case .notDetermined: result("notDetermined")
  case .restricted: result("restricted")
  @unknown default: result("notDetermined")
  }

case "getAccessibilityPermission":
  // AX has no `notDetermined` — you're either trusted or not.
  result(AXIsProcessTrusted() ? "granted" : "denied")

case "requestMicrophonePermission":
  AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
      result(granted ? "granted" : "denied")
    }
  }
```

Make sure `import AVFoundation` is present at the top of the file (it is, since `AudioCaptureManager` already uses it; confirm by searching the file).

- [ ] **Step 2: Compile-check via xcodebuild**

Per `[[macos_build_verify_command]]` in project memory, `flutter build macos` is broken in this dev env; use xcodebuild instead:

```bash
cd packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace \
             -scheme Runner \
             -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' \
             build 2>&1 | tail -30
```
Expected: `BUILD SUCCEEDED`.

If the example app's pods are stale, run `pod install` in `packages/screen_recorder_macos/example/macos/` first.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(macos): native cases for typed permission queries + requestMic"
```

---

### Task 4: macOS Dart facade — implement the 4 new methods

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`

- [ ] **Step 1: Add the four method implementations**

Open the file and add (after the existing `checkPermissions` / `requestPermissions` / `isAccessibilityTrusted` overrides):

```dart
  @override
  Future<PermissionStatus> getScreenRecordingPermission() async {
    final wire = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.getScreenRecordingPermission,
    );
    return PermissionStatusCodec.fromWire(wire);
  }

  @override
  Future<PermissionStatus> getMicrophonePermission() async {
    final wire = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.getMicrophonePermission,
    );
    return PermissionStatusCodec.fromWire(wire);
  }

  @override
  Future<PermissionStatus> getAccessibilityPermission() async {
    final wire = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.getAccessibilityPermission,
    );
    return PermissionStatusCodec.fromWire(wire);
  }

  @override
  Future<PermissionStatus> requestMicrophonePermission() async {
    final wire = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.requestMicrophonePermission,
    );
    return PermissionStatusCodec.fromWire(wire);
  }
```

Make sure these imports are present at the top of the file:
```dart
import 'package:screen_recorder_platform_interface/src/permission_status.dart';
// (or via the barrel — check what existing code uses)
```

- [ ] **Step 2: Run analyzer**

```bash
cd packages/screen_recorder_macos && flutter analyze --no-fatal-infos
```
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git commit -m "feat(macos): dart bindings for typed permission queries"
```

---

### Task 5: `PermissionsController` (Riverpod, the bus)

**Files:**
- Create: `packages/screen_recorder/lib/state/permissions_controller.dart`
- Test: `packages/screen_recorder/test/state/permissions_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/permissions_controller_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  PermissionStatus screenRec = PermissionStatus.notDetermined;
  PermissionStatus mic = PermissionStatus.notDetermined;
  PermissionStatus ax = PermissionStatus.notDetermined;

  @override
  Future<PermissionStatus> getScreenRecordingPermission() async => screenRec;
  @override
  Future<PermissionStatus> getMicrophonePermission() async => mic;
  @override
  Future<PermissionStatus> getAccessibilityPermission() async => ax;

  @override
  Future<PermissionStatus> requestMicrophonePermission() async {
    mic = PermissionStatus.granted;
    return mic;
  }
}

void main() {
  test('refreshAll reads all three kinds into snapshot', () async {
    final fake = _FakePlatform()
      ..screenRec = PermissionStatus.granted
      ..mic = PermissionStatus.denied
      ..ax = PermissionStatus.notDetermined;

    final controller = PermissionsController(fake);
    await controller.refreshAll();

    expect(controller.state.screenRec, PermissionStatus.granted);
    expect(controller.state.microphone, PermissionStatus.denied);
    expect(controller.state.accessibility, PermissionStatus.notDetermined);
  });

  test('request(microphone) updates state', () async {
    final fake = _FakePlatform();
    final controller = PermissionsController(fake);
    await controller.refreshAll();
    expect(controller.state.microphone, PermissionStatus.notDetermined);

    final result = await controller.request(PermissionKind.microphone);

    expect(result, PermissionStatus.granted);
    expect(controller.state.microphone, PermissionStatus.granted);
  });

  test('initial snapshot before refreshAll has all unsupported', () {
    final controller = PermissionsController(_FakePlatform());
    expect(controller.state.screenRec, PermissionStatus.unsupported);
    expect(controller.state.microphone, PermissionStatus.unsupported);
    expect(controller.state.accessibility, PermissionStatus.unsupported);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/permissions_controller_test.dart
```
Expected: FAIL — `permissions_controller.dart` does not exist.

- [ ] **Step 3: Implement the controller**

```dart
// packages/screen_recorder/lib/state/permissions_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Immutable snapshot of all three permission states.
class PermissionsSnapshot {
  const PermissionsSnapshot(this.byKind);

  final Map<PermissionKind, PermissionStatus> byKind;

  PermissionStatus get screenRec =>
      byKind[PermissionKind.screenRecording] ?? PermissionStatus.unsupported;
  PermissionStatus get microphone =>
      byKind[PermissionKind.microphone] ?? PermissionStatus.unsupported;
  PermissionStatus get accessibility =>
      byKind[PermissionKind.accessibility] ?? PermissionStatus.unsupported;

  static const PermissionsSnapshot initial = PermissionsSnapshot({
    PermissionKind.screenRecording: PermissionStatus.unsupported,
    PermissionKind.microphone: PermissionStatus.unsupported,
    PermissionKind.accessibility: PermissionStatus.unsupported,
  });
}

/// The single source of truth for permission state in the app.
/// Read by onboarding, the deny sheet, and RecordingController.
class PermissionsController extends StateNotifier<PermissionsSnapshot> {
  PermissionsController(this._platform) : super(PermissionsSnapshot.initial);

  final ScreenRecorderPlatform _platform;

  Future<void> refreshAll() async {
    try {
      final results = await Future.wait([
        _platform.getScreenRecordingPermission(),
        _platform.getMicrophonePermission(),
        _platform.getAccessibilityPermission(),
      ]);
      state = PermissionsSnapshot({
        PermissionKind.screenRecording: results[0],
        PermissionKind.microphone: results[1],
        PermissionKind.accessibility: results[2],
      });
    } catch (e, st) {
      AppLogger.permissions.e('refreshAll failed', error: e, stackTrace: st);
      // Leave state alone — keep last good snapshot.
    }
  }

  Future<PermissionStatus> request(PermissionKind kind) async {
    PermissionStatus result;
    switch (kind) {
      case PermissionKind.screenRecording:
        final granted = await _platform.requestPermissions();
        result = granted ? PermissionStatus.granted : PermissionStatus.denied;
      case PermissionKind.microphone:
        result = await _platform.requestMicrophonePermission();
      case PermissionKind.accessibility:
        // AX request opens System Settings; status updates after the
        // user toggles + the app is relaunched OR resumes.
        await _platform.requestAccessibilityPermission();
        result = await _platform.getAccessibilityPermission();
    }
    state = PermissionsSnapshot({
      ...state.byKind,
      kind: result,
    });
    return result;
  }
}

final permissionsControllerProvider =
    StateNotifierProvider<PermissionsController, PermissionsSnapshot>(
  (ref) => throw UnimplementedError(
    'Override permissionsControllerProvider in main() with a real instance',
  ),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/permissions_controller_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/permissions_controller.dart \
        packages/screen_recorder/test/state/permissions_controller_test.dart
git commit -m "feat(app): PermissionsController + provider (Riverpod)"
```

---

### Task 6: Lifecycle — refresh permissions on `AppLifecycleState.resumed`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart` (`MyApp` becomes Stateful)

- [ ] **Step 1: Convert `MyApp` to a StatefulConsumerWidget and add the observer**

Replace the current `MyApp` with:

```dart
class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key, required this.onboardingDone});

  final bool onboardingDone;

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User may have flipped a permission in System Settings; re-probe.
      ref.read(permissionsControllerProvider.notifier).refreshAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slipreel',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      navigatorObservers: [
        if (debugProbe.navigatorObserver() case final observer?) observer,
      ],
      home: widget.onboardingDone
          ? const RecordingBarScreen()
          : const OnboardingScreen(),
    );
  }
}
```

Add the import at top:
```dart
import 'state/permissions_controller.dart';
import 'ui/screens/onboarding/onboarding_screen.dart';
```

NOTE: `OnboardingScreen` does not exist yet — Step 3 below is a placeholder import. The plan creates it in Task 10. For now, stub it so this task compiles.

- [ ] **Step 2: Add a temporary stub for `OnboardingScreen` so this task compiles**

Create `packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart` as a 1-line placeholder:

```dart
import 'package:flutter/material.dart';

/// Stub — replaced in Task 10 with the real 3-page flow.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Onboarding (stub)')));
}
```

- [ ] **Step 3: Wire the controller into `main()`**

In `main()`, after `tuningStore.load()` and before `runApp`:

```dart
  final permissionsController =
      PermissionsController(ScreenRecorderPlatform.instance);
  await permissionsController.refreshAll();

  // Onboarding flag is added in Task 7; for now hardcode true so we
  // route straight to RecordingBarScreen.
  const onboardingDone = true;
```

Then update the `runApp` call:

```dart
  runApp(ProviderScope(
    overrides: [
      motionTuningProvider.overrideWith(
        (ref) => MotionTuningController(
          initial: loadedTuning ?? MotionTuning.defaults,
        ),
      ),
      motionTuningStoreProvider.overrideWithValue(tuningStore),
      windowChromeProvider.overrideWithValue(MethodChannelWindowChrome()),
      permissionsControllerProvider.overrideWith((ref) => permissionsController),
    ],
    child: const MyApp(onboardingDone: onboardingDone),
  ));
```

Add import:
```dart
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
```

- [ ] **Step 4: Run analyzer + the existing app test suite**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos && flutter test
```
Expected: clean analyze, full suite green (no regressions to existing tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/main.dart \
        packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart
git commit -m "feat(app): wire PermissionsController + resume-refresh in MyApp"
```

---

### Task 7: `OnboardingStore`

**Files:**
- Create: `packages/screen_recorder/lib/onboarding/onboarding_store.dart`
- Test: `packages/screen_recorder/test/onboarding/onboarding_store_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/onboarding/onboarding_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/onboarding_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns false on fresh install', () async {
    final store = OnboardingStore();
    expect(await store.load(), isFalse);
  });

  test('markComplete persists; subsequent load returns true', () async {
    final store = OnboardingStore();
    await store.markComplete();
    expect(await store.load(), isTrue);
  });

  test('reset returns flag to false', () async {
    final store = OnboardingStore();
    await store.markComplete();
    await store.reset();
    expect(await store.load(), isFalse);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/onboarding/onboarding_store_test.dart
```
Expected: FAIL — `onboarding_store.dart` does not exist.

- [ ] **Step 3: Implement the store**

```dart
// packages/screen_recorder/lib/onboarding/onboarding_store.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingStore {
  static const _key = 'slipreel.onboarding_complete';

  Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final onboardingStoreProvider = Provider<OnboardingStore>(
  (ref) => throw UnimplementedError(
    'Override onboardingStoreProvider in main() with a real instance',
  ),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/onboarding/onboarding_store_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/onboarding/onboarding_store.dart \
        packages/screen_recorder/test/onboarding/onboarding_store_test.dart
git commit -m "feat(app): OnboardingStore (shared_preferences)"
```

---

### Task 8: `PermissionDeniedSheet`

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/permission_denied_sheet.dart`
- Test: `packages/screen_recorder/test/ui/widgets/permission_denied_sheet_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/permission_denied_sheet_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeUrlLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  String? lastUrl;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    return true;
  }
  @override
  Future<bool> launch(String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    lastUrl = url;
    return true;
  }
}

void main() {
  late _FakeUrlLauncher fake;

  setUp(() {
    fake = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fake;
  });

  Future<void> pumpAndShow(WidgetTester tester, PermissionKind kind) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  PermissionDeniedSheet.show(context, kind),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Screen Recording: deep-links to ScreenCapture pane',
      (tester) async {
    await pumpAndShow(tester, PermissionKind.screenRecording);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      fake.lastUrl,
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    );
  });

  testWidgets('Microphone: deep-links to Microphone pane', (tester) async {
    await pumpAndShow(tester, PermissionKind.microphone);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      fake.lastUrl,
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
    );
  });

  testWidgets('Accessibility: deep-links to Accessibility pane',
      (tester) async {
    await pumpAndShow(tester, PermissionKind.accessibility);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      fake.lastUrl,
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
    );
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/widgets/permission_denied_sheet_test.dart
```
Expected: FAIL — `permission_denied_sheet.dart` does not exist.

- [ ] **Step 3: Implement the sheet**

```dart
// packages/screen_recorder/lib/ui/widgets/permission_denied_sheet.dart
import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

class PermissionDeniedSheet extends StatelessWidget {
  const PermissionDeniedSheet({super.key, required this.kind});
  final PermissionKind kind;

  static const _urls = {
    PermissionKind.screenRecording:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    PermissionKind.microphone:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
    PermissionKind.accessibility:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
  };

  static const _titles = {
    PermissionKind.screenRecording: 'Screen Recording permission required',
    PermissionKind.microphone: 'Microphone permission required',
    PermissionKind.accessibility: 'Accessibility permission required',
  };

  static const _bodies = {
    PermissionKind.screenRecording:
      'Slipreel needs Screen Recording access in System Settings to capture your screen.',
    PermissionKind.microphone:
      'Slipreel needs Microphone access in System Settings to record your voice.',
    PermissionKind.accessibility:
      'Slipreel needs Accessibility access in System Settings to track clicks.',
  };

  static Future<void> show(BuildContext context, PermissionKind kind) {
    return showModalBottomSheet<void>(
      context: context,
      isDismissible: true,
      showDragHandle: true,
      builder: (_) => PermissionDeniedSheet(kind: kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_titles[kind]!,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(_bodies[kind]!,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                final ok = await launchUrl(Uri.parse(_urls[kind]!));
                if (!context.mounted) return;
                if (ok) Navigator.of(context).pop();
              },
              child: const Text('Open System Settings'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/widgets/permission_denied_sheet_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/permission_denied_sheet.dart \
        packages/screen_recorder/test/ui/widgets/permission_denied_sheet_test.dart
git commit -m "feat(app): PermissionDeniedSheet with per-kind deep links"
```

---

### Task 9: Wire deny sheet into `startRecording`

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`

The existing `startRecording(microphone:, systemAudio:)` lives on `RecordingController` (a `StateNotifier<RecordingState>`). It doesn't have a `BuildContext`. To surface the sheet, we pass a `BuildContext` from the caller, OR we set a flag on state that the UI listens for.

Cleanest: pass a `BuildContext? deniedSheetContext` parameter to `startRecording`. The caller in `recording_bar.dart` already has the context. If null (tests), we skip the sheet and just set an error.

- [ ] **Step 1: Add a permission guard at the top of `startRecording`**

Open `packages/screen_recorder/lib/state/recording_state.dart`. Modify the `startRecording` signature and prepend the guard:

```dart
Future<void> startRecording({
  MicrophoneConfig? microphone,
  SystemAudioConfig? systemAudio,
  PermissionsSnapshot? permissions,
  Future<void> Function(PermissionKind kind)? onDenied,
}) async {
  if (!state.canStartRecording ||
      state.selectedSourceId == null ||
      state.selectedSourceKind == null) return;

  // Permission gate: if the caller passed a snapshot AND a `onDenied`
  // callback, short-circuit when Screen Recording isn't granted.
  // (Both nullable so existing tests that don't care about permissions
  // still work — non-passing callers just get the old behavior.)
  if (permissions != null &&
      permissions.screenRec != PermissionStatus.granted &&
      permissions.screenRec != PermissionStatus.unsupported) {
    await onDenied?.call(PermissionKind.screenRecording);
    return;
  }
  // ... existing body unchanged ...
```

Add the import at the top of the file:
```dart
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'permissions_controller.dart';
```

- [ ] **Step 2: Update the call site in `recording_bar_screen.dart` (or wherever `startRecording` is called)**

Find the call(s) to `startRecording(`. Update to pass the snapshot + sheet callback:

```dart
final snapshot = ref.read(permissionsControllerProvider);
await ref.read(recordingControllerProvider.notifier).startRecording(
  microphone: micConfig,
  systemAudio: sysAudioConfig,
  permissions: snapshot,
  onDenied: (kind) => PermissionDeniedSheet.show(context, kind),
);
```

Add imports as needed.

- [ ] **Step 3: Run the app's existing test suite (no new tests required for this task — covered by `permission_denied_sheet_test.dart` and integration testing)**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart
git commit -m "feat(app): gate startRecording on Screen Recording permission"
```

---

### Task 10: `OnboardingScreen` root (3-page PageView with dot indicator)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart` (replace the stub)

- [ ] **Step 1: Implement the root**

Replace the stub created in Task 6 with:

```dart
// packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/onboarding/onboarding_store.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';
import 'pages/permissions_page.dart';
import 'pages/ready_page.dart';
import 'pages/welcome_page.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;

  void _next() {
    _pageController.animateToPage(
      _page + 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    await ref.read(onboardingStoreProvider).markComplete();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const RecordingBarScreen()),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                WelcomePage(onNext: _next),
                PermissionsPage(onNext: _next),
                ReadyPage(onFinish: _finish),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? Colors.white : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Add stubs for the three page files so this compiles**

```dart
// packages/screen_recorder/lib/ui/screens/onboarding/pages/welcome_page.dart
import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onNext});
  final VoidCallback onNext;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Welcome (stub)'));
}
```

```dart
// packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart
import 'package:flutter/material.dart';

class PermissionsPage extends StatelessWidget {
  const PermissionsPage({super.key, required this.onNext});
  final VoidCallback onNext;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Permissions (stub)'));
}
```

```dart
// packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart
import 'package:flutter/material.dart';

class ReadyPage extends StatelessWidget {
  const ReadyPage({super.key, required this.onFinish});
  final VoidCallback onFinish;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Ready (stub)'));
}
```

- [ ] **Step 3: Run analyzer**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/onboarding/
git commit -m "feat(app): OnboardingScreen 3-page PageView root + page stubs"
```

---

### Task 11: `WelcomePage`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/pages/welcome_page.dart`

- [ ] **Step 1: Replace stub with real Welcome content**

```dart
import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(Icons.videocam,
                size: 56, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 32),
          Text('Welcome to Slipreel',
              style: theme.textTheme.displaySmall),
          const SizedBox(height: 12),
          Text(
            'Polished screen recordings with smart defaults.',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          SizedBox(
            width: 240,
            child: FilledButton(
              onPressed: onNext,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Get started'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Run analyzer**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/onboarding/pages/welcome_page.dart
git commit -m "feat(app): onboarding WelcomePage"
```

---

### Task 12: `PermissionsPage`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart`
- Test: `packages/screen_recorder/test/ui/screens/onboarding/onboarding_screen_test.dart`

This is the substantive page. Each of the three rows reads from `permissionsControllerProvider` and renders one of three button states. Continue is enabled iff Screen Rec is granted.

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/screens/onboarding/onboarding_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/screens/onboarding/pages/permissions_page.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

PermissionsSnapshot _snap({
  PermissionStatus screen = PermissionStatus.notDetermined,
  PermissionStatus mic = PermissionStatus.notDetermined,
  PermissionStatus ax = PermissionStatus.notDetermined,
}) =>
    PermissionsSnapshot({
      PermissionKind.screenRecording: screen,
      PermissionKind.microphone: mic,
      PermissionKind.accessibility: ax,
    });

class _StubController extends StateNotifier<PermissionsSnapshot>
    implements PermissionsController {
  _StubController(super.s);
  @override
  Future<void> refreshAll() async {}
  @override
  Future<PermissionStatus> request(PermissionKind kind) async =>
      state.byKind[kind] ?? PermissionStatus.unsupported;
  @override
  ScreenRecorderPlatform get _platform => throw UnimplementedError();
}

Future<void> pump(WidgetTester tester, PermissionsSnapshot snapshot) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      permissionsControllerProvider
          .overrideWith((ref) => _StubController(snapshot)),
    ],
    child: MaterialApp(
      home: Scaffold(body: PermissionsPage(onNext: () {})),
    ),
  ));
}

void main() {
  testWidgets('Continue is disabled when Screen Rec is not granted',
      (tester) async {
    await pump(tester, _snap(screen: PermissionStatus.notDetermined));
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('Continue is enabled when Screen Rec is granted',
      (tester) async {
    await pump(
        tester,
        _snap(
          screen: PermissionStatus.granted,
          mic: PermissionStatus.denied,
          ax: PermissionStatus.denied,
        ));
    final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('Granted rows show a check mark', (tester) async {
    await pump(tester, _snap(mic: PermissionStatus.granted));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/screens/onboarding/onboarding_screen_test.dart
```
Expected: FAIL — `PermissionsPage` is still a stub.

- [ ] **Step 3: Implement the page**

```dart
// packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class PermissionsPage extends ConsumerWidget {
  const PermissionsPage({super.key, required this.onNext});
  final VoidCallback onNext;

  static const _labels = {
    PermissionKind.screenRecording: 'Screen Recording',
    PermissionKind.microphone: 'Microphone',
    PermissionKind.accessibility: 'Accessibility',
  };

  static const _subtitles = {
    PermissionKind.screenRecording: 'Required to capture your screen.',
    PermissionKind.microphone: 'Optional — for voice narration.',
    PermissionKind.accessibility: 'Optional — for richer click tracking.',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(permissionsControllerProvider);
    final screenRecGranted = snap.screenRec == PermissionStatus.granted;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Permissions',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          for (final kind in PermissionKind.values)
            _PermissionRow(
              kind: kind,
              label: _labels[kind]!,
              subtitle: _subtitles[kind]!,
              status: snap.byKind[kind] ?? PermissionStatus.unsupported,
              onGrant: () => ref
                  .read(permissionsControllerProvider.notifier)
                  .request(kind),
              onOpenSettings: () =>
                  PermissionDeniedSheet.show(context, kind),
            ),
          const Spacer(),
          FilledButton(
            onPressed: screenRecGranted ? onNext : null,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.kind,
    required this.label,
    required this.subtitle,
    required this.status,
    required this.onGrant,
    required this.onOpenSettings,
  });

  final PermissionKind kind;
  final String label;
  final String subtitle;
  final PermissionStatus status;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                Text(subtitle,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Colors.white60)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RowAction(
              status: status,
              onGrant: onGrant,
              onOpenSettings: onOpenSettings),
        ],
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.status,
    required this.onGrant,
    required this.onOpenSettings,
  });
  final PermissionStatus status;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case PermissionStatus.granted:
        return const Icon(Icons.check_circle, color: Colors.greenAccent);
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return OutlinedButton(
          onPressed: onOpenSettings,
          child: const Text('Open System Settings'),
        );
      case PermissionStatus.notDetermined:
      case PermissionStatus.unsupported:
        return FilledButton.tonal(
          onPressed: onGrant,
          child: const Text('Grant'),
        );
    }
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/screens/onboarding/onboarding_screen_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart \
        packages/screen_recorder/test/ui/screens/onboarding/onboarding_screen_test.dart
git commit -m "feat(app): onboarding PermissionsPage with per-row actions"
```

---

### Task 13: `ReadyPage`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart`

- [ ] **Step 1: Replace stub with real Ready content**

```dart
import 'package:flutter/material.dart';

class ReadyPage extends StatelessWidget {
  const ReadyPage({super.key, required this.onFinish});
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(),
          const Icon(Icons.check_circle,
              color: Colors.greenAccent, size: 80),
          const SizedBox(height: 24),
          Text("You're all set",
              style: Theme.of(context).textTheme.displaySmall),
          const SizedBox(height: 12),
          Text(
            'Press the Display button on the recording bar to start.',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          SizedBox(
            width: 280,
            child: FilledButton(
              onPressed: onFinish,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Record my first video'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Run analyzer**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart
git commit -m "feat(app): onboarding ReadyPage"
```

---

### Task 14: Route to `OnboardingScreen` based on the flag

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

- [ ] **Step 1: Load the OnboardingStore in `main()` and pass to MyApp**

In `main()`, replace the `const onboardingDone = true;` placeholder from Task 6 with the real load:

```dart
  final onboardingStore = OnboardingStore();
  final onboardingDone = await onboardingStore.load();
```

In the `ProviderScope.overrides` list, add:
```dart
  onboardingStoreProvider.overrideWithValue(onboardingStore),
```

Add the import:
```dart
import 'onboarding/onboarding_store.dart';
```

- [ ] **Step 2: Run the app suite**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(app): route to OnboardingScreen when onboarding flag is false"
```

---

### Task 15: `TipsStore`

**Files:**
- Create: `packages/screen_recorder/lib/onboarding/tips_store.dart`
- Test: `packages/screen_recorder/test/onboarding/tips_store_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/onboarding/tips_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('load returns empty set on fresh install', () async {
    final store = TipsStore();
    expect(await store.load(), isEmpty);
  });

  test('markSeen + load round-trips', () async {
    final store = TipsStore();
    await store.markSeen('tip.bar.modePicker');
    await store.markSeen('tip.editor.trim');
    final loaded = await store.load();
    expect(loaded, {'tip.bar.modePicker', 'tip.editor.trim'});
  });

  test('clearAll wipes the set', () async {
    final store = TipsStore();
    await store.markSeen('tip.x');
    await store.clearAll();
    expect(await store.load(), isEmpty);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/onboarding/tips_store_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the store**

```dart
// packages/screen_recorder/lib/onboarding/tips_store.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TipsStore {
  static const _key = 'slipreel.tips_seen';

  Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  Future<void> markSeen(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key) ?? const <String>[]).toSet()
      ..add(id);
    await prefs.setStringList(_key, current.toList(growable: false));
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final tipsStoreProvider = Provider<TipsStore>(
  (ref) => throw UnimplementedError(
    'Override tipsStoreProvider in main() with a real instance',
  ),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/onboarding/tips_store_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/onboarding/tips_store.dart \
        packages/screen_recorder/test/onboarding/tips_store_test.dart
git commit -m "feat(app): TipsStore (shared_preferences)"
```

---

### Task 16: `TipsController` (enum + copy map + Riverpod controller)

**Files:**
- Create: `packages/screen_recorder/lib/onboarding/tips_controller.dart`
- Test: `packages/screen_recorder/test/onboarding/tips_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/onboarding/tips_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shouldShow returns true for an unseen id', () async {
    final c = TipsController(TipsStore());
    await c.load();
    expect(c.shouldShow(TipId.barModePicker), isTrue);
  });

  test('markSeen flips shouldShow to false', () async {
    final c = TipsController(TipsStore());
    await c.load();
    await c.markSeen(TipId.barModePicker);
    expect(c.shouldShow(TipId.barModePicker), isFalse);
  });

  test('only one tip can be active at a time', () async {
    final c = TipsController(TipsStore());
    await c.load();
    expect(c.tryClaim(TipId.barModePicker), isTrue);
    expect(c.tryClaim(TipId.editorTrimHandles), isFalse);
    c.release(TipId.barModePicker);
    expect(c.tryClaim(TipId.editorTrimHandles), isTrue);
  });

  test('copyFor returns the registered message', () {
    final c = TipsController(TipsStore());
    expect(c.copyFor(TipId.barModePicker), isNotEmpty);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/onboarding/tips_controller_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the controller**

```dart
// packages/screen_recorder/lib/onboarding/tips_controller.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tips_store.dart';

enum TipId {
  barModePicker,
  editorTrimHandles,
  editorZoomKeyframe,
  editorInspector,
  editorExport,
}

const _copy = {
  TipId.barModePicker:
    'Pick a capture mode: Display, Window, Area, or a connected Device.',
  TipId.editorTrimHandles:
    'Drag these to trim the start and end of your clip.',
  TipId.editorZoomKeyframe:
    'Tap the timeline to add a smooth zoom keyframe.',
  TipId.editorInspector:
    'Customize cursor, background, frame, and motion here.',
  TipId.editorExport:
    'Cmd+E to export with smart presets.',
};

class TipsController extends ChangeNotifier {
  TipsController(this._store);

  final TipsStore _store;
  Set<String> _seen = {};
  TipId? _activeTip;

  Future<void> load() async {
    _seen = await _store.load();
    notifyListeners();
  }

  bool shouldShow(TipId id) => !_seen.contains(id.name);

  Future<void> markSeen(TipId id) async {
    if (_seen.add(id.name)) {
      await _store.markSeen(id.name);
      notifyListeners();
    }
  }

  /// Returns true if `id` becomes the active tip (no other tip is showing).
  /// Caller must `release(id)` when the tip is dismissed.
  bool tryClaim(TipId id) {
    if (_activeTip != null) return false;
    _activeTip = id;
    return true;
  }

  void release(TipId id) {
    if (_activeTip == id) {
      _activeTip = null;
    }
  }

  String copyFor(TipId id) => _copy[id]!;

  TipId? get activeTip => _activeTip;
}

final tipsControllerProvider =
    ChangeNotifierProvider<TipsController>((ref) => throw UnimplementedError(
          'Override tipsControllerProvider in main() with a loaded instance',
        ));
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/onboarding/tips_controller_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/onboarding/tips_controller.dart \
        packages/screen_recorder/test/onboarding/tips_controller_test.dart
git commit -m "feat(app): TipsController + TipId enum + copy registry"
```

---

### Task 17: `TipOverlay` (the coachmark renderer)

**Files:**
- Create: `packages/screen_recorder/lib/onboarding/tip_overlay.dart`

- [ ] **Step 1: Implement the overlay**

```dart
// packages/screen_recorder/lib/onboarding/tip_overlay.dart
import 'package:flutter/material.dart';

/// Draws a 60% black backdrop with a rounded-rect cutout around
/// [anchorRect] and a callout bubble pointing at the cutout.
class TipOverlay extends StatelessWidget {
  const TipOverlay({
    super.key,
    required this.anchorRect,
    required this.message,
    required this.onDismiss,
  });

  final Rect anchorRect;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Backdrop with cutout.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _BackdropPainter(anchorRect)),
          ),
        ),
        // Tap outside the bubble dismisses.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        // Callout positioned below the anchor (or above if no room below).
        _Callout(
          anchorRect: anchorRect,
          message: message,
          onDismiss: onDismiss,
        ),
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.anchorRect);
  final Rect anchorRect;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0x99000000);
    final cutoutRRect =
        RRect.fromRectAndRadius(anchorRect.inflate(6), const Radius.circular(10));
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(cutoutRRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.anchorRect != anchorRect;
}

class _Callout extends StatelessWidget {
  const _Callout({
    required this.anchorRect,
    required this.message,
    required this.onDismiss,
  });
  final Rect anchorRect;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    final spaceBelow = mq.height - anchorRect.bottom;
    final placeBelow = spaceBelow >= 140;
    final dy = placeBelow ? anchorRect.bottom + 16 : anchorRect.top - 140;

    return Positioned(
      top: dy.clamp(16.0, mq.height - 160),
      left: 16,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: onDismiss,
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run analyzer**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/onboarding/tip_overlay.dart
git commit -m "feat(app): TipOverlay (dim backdrop + cutout + callout bubble)"
```

---

### Task 18: `TipAnchor` (the widget that fires the overlay)

**Files:**
- Create: `packages/screen_recorder/lib/onboarding/tip_anchor.dart`
- Test: `packages/screen_recorder/test/onboarding/tip_anchor_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/onboarding/tip_anchor_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tip_anchor.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TipsController> _freshController() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  return c;
}

void main() {
  testWidgets('first mount fires the overlay; Got it dismisses + marks seen',
      (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TipAnchor(
              tipId: TipId.barModePicker,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(); // post-frame callback
    await tester.pumpAndSettle();

    expect(find.text('Got it'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    expect(find.text('Got it'), findsNothing);
    expect(c.shouldShow(TipId.barModePicker), isFalse);
  });

  testWidgets('already-seen anchor never fires', (tester) async {
    final c = await _freshController();
    await c.markSeen(TipId.barModePicker);
    await tester.pumpWidget(ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TipAnchor(
              tipId: TipId.barModePicker,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsNothing);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/onboarding/tip_anchor_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the anchor**

```dart
// packages/screen_recorder/lib/onboarding/tip_anchor.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tips_controller.dart';
import 'tip_overlay.dart';

class TipAnchor extends ConsumerStatefulWidget {
  const TipAnchor({super.key, required this.tipId, required this.child});

  final TipId tipId;
  final Widget child;

  @override
  ConsumerState<TipAnchor> createState() => _TipAnchorState();
}

class _TipAnchorState extends ConsumerState<TipAnchor> {
  final _key = GlobalKey();
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryShow());
  }

  void _tryShow() {
    if (!mounted) return;
    final controller = ref.read(tipsControllerProvider);
    if (!controller.shouldShow(widget.tipId)) return;
    final ctx = _key.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    if (!controller.tryClaim(widget.tipId)) return;

    final offset = box.localToGlobal(Offset.zero);
    final rect = offset & box.size;
    _entry = OverlayEntry(
      builder: (_) => TipOverlay(
        anchorRect: rect,
        message: controller.copyFor(widget.tipId),
        onDismiss: _dismiss,
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  Future<void> _dismiss() async {
    final controller = ref.read(tipsControllerProvider);
    _entry?.remove();
    _entry = null;
    controller.release(widget.tipId);
    await controller.markSeen(widget.tipId);
  }

  @override
  void dispose() {
    final controller = ref.read(tipsControllerProvider);
    _entry?.remove();
    _entry = null;
    controller.release(widget.tipId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Container(key: _key, child: widget.child);
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/onboarding/tip_anchor_test.dart
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/onboarding/tip_anchor.dart \
        packages/screen_recorder/test/onboarding/tip_anchor_test.dart
git commit -m "feat(app): TipAnchor widget — fires coachmark on first visible mount"
```

---

### Task 19: Wire all 5 tips + initialize `TipsController` in main

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart` (load + override the tips controller)
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart` (Tip 1)
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (Tips 2–5)

- [ ] **Step 1: Initialize and override the controller in `main()`**

In `main()`, after `onboardingStore`:

```dart
  final tipsStore = TipsStore();
  final tipsController = TipsController(tipsStore);
  await tipsController.load();
```

In the `ProviderScope.overrides` list, add:
```dart
  tipsStoreProvider.overrideWithValue(tipsStore),
  tipsControllerProvider.overrideWith((ref) => tipsController),
```

Add imports:
```dart
import 'onboarding/tips_controller.dart';
import 'onboarding/tips_store.dart';
```

- [ ] **Step 2: Wrap Tip 1 — Display button on the recording bar**

Open `packages/screen_recorder/lib/ui/bar/recording_bar.dart`. Find the `_Mode` widget call for the Display button (around line 154 per the file map). Wrap it:

```dart
TipAnchor(
  tipId: TipId.barModePicker,
  child: _Mode(/* existing args */),
),
```

Add imports at top:
```dart
import '../../onboarding/tip_anchor.dart';
import '../../onboarding/tips_controller.dart';
```

- [ ] **Step 3: Wrap Tips 2 + 3 — trim handle and zoom track in the editor**

Open `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (or the timeline widget file it imports). Locate the trim handle widget and the zoom track widget. Wrap each:

```dart
// Trim handle
TipAnchor(tipId: TipId.editorTrimHandles, child: TrimHandle(/* args */)),

// Zoom track row
TipAnchor(tipId: TipId.editorZoomKeyframe, child: ZoomTrack(/* args */)),
```

The exact widget names depend on the existing file structure — pick the smallest containing widget that's stable across builds (not a `Positioned`'s inner child that may rebuild with a new key).

Add imports as needed.

- [ ] **Step 4: Wrap Tip 4 — Inspector tab strip**

In the editor file, locate the inspector tab bar. Wrap:

```dart
TipAnchor(tipId: TipId.editorInspector, child: InspectorTabBar(/* args */)),
```

- [ ] **Step 5: Wrap Tip 5 — Export button**

In the editor toolbar, wrap the Export CTA:

```dart
TipAnchor(tipId: TipId.editorExport, child: ExportButton(/* args */)),
```

- [ ] **Step 6: Run the full app test suite**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/main.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): wire 5 TipAnchors + init TipsController in main"
```

---

### Task 20: QA reset hook (`ext.slipreel.resetOnboarding`)

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

- [ ] **Step 1: Register the extension inside `_registerSlipreelDebugExtensions()`**

Add this block at the end of the function body in main.dart:

```dart
  developer.registerExtension(
    'ext.slipreel.resetOnboarding',
    (method, params) async {
      await OnboardingStore().reset();
      await TipsStore().clearAll();
      return developer.ServiceExtensionResponse.result('{"reset": true}');
    },
  );
```

- [ ] **Step 2: Run analyzer + full suite**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos && flutter test
```
Expected: clean analyze, full suite green.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "chore(app): ext.slipreel.resetOnboarding VM-service extension for QA"
```

---

### Task 21: End-to-end manual verification on a live Mac

This is not a code task — it's the manual checklist from the spec. Run after Task 20 has merged.

- [ ] **Verify cold-start onboarding:**
  ```
  # In a running flutter session attached to the macOS app:
  # Call the QA reset hook via the VM service (flutter-qa MCP tool, or
  # `flutter` devtools "Run extension" UI):
  ext.slipreel.resetOnboarding
  # Hot restart the app.
  ```
  Expected: Welcome page renders. Click `[Get started]` → Permissions page. Click `[Grant]` on Screen Recording — system dialog appears, grant → row flips to ✓. Repeat for Mic + Accessibility. Click `[Continue]` → Ready page. Click `[Record my first video]` → `RecordingBarScreen` appears.

- [ ] **Verify post-onboarding deny path:**
  Revoke Screen Recording in System Settings → Privacy & Security → Screen Recording. Switch back to Slipreel; the resume-refresh fires. Click the Display button to start a recording. Expected: `PermissionDeniedSheet(screenRecording)` appears with `[Open System Settings]`. Click it → System Settings opens at the Screen Recording pane.

- [ ] **Verify the 5 tips:**
  Reset via `ext.slipreel.resetOnboarding`, hot restart, complete onboarding. On the recording bar — `tip.barModePicker` coachmark fires. Dismiss. Start a recording → open editor — `tip.editorTrimHandles` fires. Dismiss. Continue interacting; the remaining three tips fire as their surfaces become visible. Quit + relaunch; no tip fires again.

- [ ] **Verify non-regression:**
  ```bash
  cd /Users/mohn93/Desktop/side_projects/screenflow_studio
  melos run analyze --no-select
  melos run test --no-select
  ```
  Expected: both exit 0.

---

## Self-review

**Spec coverage:**
- Permission status surface (PermissionsController) → Task 5 ✓
- Platform interface additions → Tasks 1, 2 ✓
- Native macOS bindings → Tasks 3, 4 ✓
- OnboardingStore + flag → Task 7 ✓
- OnboardingScreen 3 pages + routing → Tasks 10–14 ✓
- Hard gate on Screen Rec in onboarding → Task 12 (test) ✓
- PermissionDeniedSheet with per-kind deep links → Task 8 ✓
- RecordingController guard → Task 9 ✓
- Lifecycle refresh on resume → Task 6 ✓
- TipsStore + TipsController + TipAnchor + TipOverlay → Tasks 15–18 ✓
- 5 registered tips → Task 19 ✓
- QA reset hook → Task 20 ✓
- Manual verification → Task 21 ✓

**Placeholder scan:** no TBDs, no "implement later", no skipped code blocks.

**Type consistency:** `PermissionStatus` / `PermissionKind` defined in Task 1 and used identically across Tasks 2, 3, 4, 5, 8, 9, 12. `TipId` defined in Task 16 and used identically in Tasks 17, 18, 19. `PermissionsSnapshot` defined in Task 5 and used identically in Tasks 9, 12.

**Out of scope (per spec):** Win/Linux native permission implementations, telemetry, "new feature tour" on app upgrade, custom System Settings panes for older macOS. Not in the plan; correct.

