# Recording Bar Audio Controls Simplification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the recording bar's device-mode audio swap so the bar always shows the same configurable mic + system-audio controls, and device audio is captured automatically — fixing the "stuck on phone selectors" bug (issue #11).

**Architecture:** The bar becomes a stateless configuration surface for screen recordings (mic + system audio), independent of the last-recorded source. The `_DeviceAudioControl` widget, the `deviceMode` swap, and the UI-level `deviceAudioEnabledProvider` toggle are deleted. `RecordingController.startDeviceRecording(captureDeviceAudio:)` keeps its parameter; the action router now always passes `true`.

**Tech Stack:** Flutter, Riverpod, Dart, `flutter_test`. Package: `packages/screen_recorder`.

## Global Constraints

- Do NOT run `dart format` on existing files — the pinned formatter reflows unrelated lines. Match surrounding style by hand.
- Verify with `flutter analyze` and `flutter test` (run from `packages/screen_recorder`); CI runs `melos test` but per-package is fine for local iteration.
- `RecordingController.startDeviceRecording({required String deviceId, required bool captureDeviceAudio, ...})` keeps its signature unchanged — only the UI toggle that feeds it is removed.
- `systemAudioControllerProvider` is never cleared on source change (existing behavior) — preserve that; do not add any clearing.

---

### Task 1: Remove the device-mode swap from the bar widget + screen, rewrite the widget test

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Test (rename): `packages/screen_recorder/test/ui/bar/recording_bar_device_mode_test.dart` → `packages/screen_recorder/test/ui/bar/recording_bar_audio_controls_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RecordingBar` constructor no longer accepts `deviceMode`, `deviceAudioEnabled`, or `onDeviceAudioTap`. All other params (`onPickMode`, `onClose`, `onGearTap`, `onDragStart`, `microphone`, `onMicTap`, `systemAudio`, `onSystemAudioTap`, `camera`, `onCameraTap`, `contentKey`, `micLevelStream`) are unchanged.

- [ ] **Step 1: Rewrite the widget test (failing — old keys/params gone)**

Delete `test/ui/bar/recording_bar_device_mode_test.dart` and create `test/ui/bar/recording_bar_audio_controls_test.dart` with this content:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A TipsController with all tips pre-seen so TipAnchor overlays don't
/// appear during bar tests (which test bar behaviour, not tips).
Future<TipsController> _allSeenController() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  for (final id in TipId.values) {
    await c.markSeen(id);
  }
  return c;
}

Widget _wrap(Widget child, TipsController tips) => ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => tips)],
      child: MaterialApp(home: Scaffold(body: child)),
    );

RecordingBar _bar({void Function(BarSourceMode)? onPickMode}) => RecordingBar(
      onPickMode: onPickMode ?? (_) {},
      onClose: () {},
      onGearTap: () {},
      onDragStart: () {},
      onMicTap: () {},
      onSystemAudioTap: () {},
      onCameraTap: () {},
    );

void main() {
  testWidgets('always renders the system-audio control and no device-audio control',
      (tester) async {
    _wide(tester);
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(), tips));

    expect(find.byKey(const Key('bar-system-audio')), findsOneWidget);
    expect(find.byKey(const Key('bar-device-audio')), findsNothing);
    expect(find.byKey(const Key('bar-mic')), findsOneWidget);
  });

  testWidgets('tapping the Device chip fires onPickMode(device)', (tester) async {
    _wide(tester);
    BarSourceMode? picked;
    final tips = await _allSeenController();
    await tester.pumpWidget(_wrap(_bar(onPickMode: (m) => picked = m), tips));
    await tester.tap(find.text('Device'));
    expect(picked, BarSourceMode.device);
  });
}
```

- [ ] **Step 2: Run the test to confirm it fails to compile**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_audio_controls_test.dart`
Expected: FAIL — compile error (the bar still has the `deviceMode` swap referencing `_DeviceAudioControl`, but more importantly the production code still defines params we no longer pass; this confirms we're editing the right surface).

- [ ] **Step 3: Strip the swap from `recording_bar.dart`**

In `packages/screen_recorder/lib/ui/bar/recording_bar.dart`:

Remove these three constructor parameters from the `const RecordingBar({...})` initializer list:
```dart
    this.deviceMode = false,
    this.deviceAudioEnabled = true,
    this.onDeviceAudioTap,
```

Remove these three field declarations and their doc comments (the block starting with `/// True when the armed source is an external device...` through `final VoidCallback? onDeviceAudioTap;`):
```dart
  /// True when the armed source is an external device (iPhone/iPad). In this
  /// mode the system-audio control is replaced by a device-audio control (the
  /// device feeds its own audio over USB; host system-audio capture is N/A).
  final bool deviceMode;

  /// Whether device audio capture is enabled. Only meaningful when
  /// [deviceMode] is true.
  final bool deviceAudioEnabled;

  /// Fired when the device-audio control is tapped (toggles device audio).
  /// Only used when [deviceMode] is true.
  final VoidCallback? onDeviceAudioTap;
```

Replace the swap in `build` — change:
```dart
            if (deviceMode)
              _DeviceAudioControl(
                enabled: deviceAudioEnabled,
                onTap: onDeviceAudioTap ?? () {},
              )
            else
              _SystemAudioControl(
                  systemAudio: systemAudio, onTap: onSystemAudioTap),
```
to:
```dart
            _SystemAudioControl(
                systemAudio: systemAudio, onTap: onSystemAudioTap),
```

Delete the entire `_DeviceAudioControl` widget class (the block from `/// Device-audio control shown in device mode IN PLACE OF [_SystemAudioControl].` through its closing `}` at the end of `_DeviceAudioControlState`).

- [ ] **Step 4: Strip the device-mode wiring from `recording_bar_screen.dart`**

In `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`:

Remove the `_deviceAudio` field and its comment:
```dart
  // Whether device-audio capture is enabled when recording an external device.
  // Threaded into startDeviceRecording via the action router's device-audio
  // flag provider.
  bool _deviceAudio = true;
```

In `_buildBar`, remove the `deviceMode` computation and its comment:
```dart
    // Device mode: the bar swaps its system-audio control for a device-audio
    // toggle when an external device (iPhone/iPad) is the armed source.
    final deviceMode = ref.watch(recordingControllerProvider
            .select((s) => s.selectedSourceKind)) ==
        RecordingSource.device;
```

In the `RecordingBar(...)` call inside `_buildBar`, remove these three arguments:
```dart
      deviceMode: deviceMode,
      deviceAudioEnabled: _deviceAudio,
      onDeviceAudioTap: _onDeviceAudioTap,
```

Remove the `_onDeviceAudioTap` method entirely:
```dart
  void _onDeviceAudioTap() {
    setState(() => _deviceAudio = !_deviceAudio);
    ref.read(deviceAudioEnabledProvider.notifier).state = _deviceAudio;
  }
```

Note: `RecordingSource` may now be unused in this file. After the edits, if `flutter analyze` (Step 5) reports the `screen_recorder_platform_interface` import or `RecordingSource` as unused, leave the import (it is used elsewhere for `RecordingSource` in `_pickAndRecord`) — do not remove imports that analyze still needs. Only remove an import if analyze explicitly flags it unused.

- [ ] **Step 5: Run analyze + the widget test**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/bar/recording_bar.dart lib/ui/bar/recording_bar_screen.dart && flutter test test/ui/bar/recording_bar_audio_controls_test.dart`
Expected: analyze reports no NEW errors for these files; the test PASSES (both test cases green).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_device_mode_test.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_audio_controls_test.dart
git commit -m "fix(bar): always show system-audio control; remove device-mode swap (#11)"
```

---

### Task 2: Remove the UI-level device-audio provider; router always captures device audio

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_action_router.dart`
- Test: `packages/screen_recorder/test/state/recording_action_router_test.dart` (already exercises the device start path; no edits expected — used only to confirm green)

**Interfaces:**
- Consumes: `RecordingController.startDeviceRecording({required bool captureDeviceAudio, ...})` (unchanged).
- Produces: `deviceAudioEnabledProvider` no longer exists. The device branch in `RecordingActionRouter.start` passes `captureDeviceAudio: true`.

- [ ] **Step 1: Edit the router**

In `packages/screen_recorder/lib/state/recording_action_router.dart`:

In the device branch of `doStart`, change:
```dart
        await controller.startDeviceRecording(
          deviceId: state.selectedSourceId!,
          captureDeviceAudio:
              _container.read(deviceAudioEnabledProvider),
          microphone: micConfig,
```
to:
```dart
        await controller.startDeviceRecording(
          deviceId: state.selectedSourceId!,
          // A device recording inherently includes its own audio (carried over
          // USB); there is no UI toggle — it is always captured.
          captureDeviceAudio: true,
          microphone: micConfig,
```

Delete the `deviceAudioEnabledProvider` definition and its doc comment:
```dart
/// Whether device-audio capture is enabled for the next device recording
/// (iPhone/iPad over USB). Driven by the bar's device-audio control; read by
/// [RecordingActionRouter] when starting a device source. Defaults to true.
final deviceAudioEnabledProvider = StateProvider<bool>((ref) => true);
```

- [ ] **Step 2: Run analyze to confirm no dangling references**

Run: `cd packages/screen_recorder && flutter analyze lib/state/recording_action_router.dart && grep -rn "deviceAudioEnabledProvider" lib test`
Expected: analyze clean for the file; the `grep` returns NO matches (provider fully removed).

- [ ] **Step 3: Run the router + device controller tests**

Run: `cd packages/screen_recorder && flutter test test/state/recording_action_router_test.dart test/state/recording_device_test.dart`
Expected: PASS (the device start path still routes; `recording_device_test.dart` still exercises `captureDeviceAudio` true/false at the controller level, which is untouched).

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_action_router.dart
git commit -m "fix(recording): always capture device audio; drop deviceAudioEnabledProvider (#11)"
```

---

### Task 3: Full package verification

**Files:** none (verification only).

- [ ] **Step 1: Analyze the whole package**

Run: `cd packages/screen_recorder && flutter analyze`
Expected: No errors. (Pre-existing warnings unrelated to these files are acceptable, but no new ones referencing `deviceMode`, `deviceAudio`, or `_DeviceAudioControl`.)

- [ ] **Step 2: Run the full package test suite**

Run: `cd packages/screen_recorder && flutter test`
Expected: All tests PASS. Confirm there are no lingering references:
`grep -rn "deviceMode\|_DeviceAudioControl\|deviceAudioEnabled\|onDeviceAudioTap\|bar-device-audio" lib test` returns NO matches.

- [ ] **Step 3: Commit any incidental fixes (only if Step 1/2 required edits)**

```bash
git add -A
git commit -m "test: verify recording-bar audio-control simplification (#11)"
```

---

## Self-Review

**Spec coverage:**
- "Remove device-mode swap; always render `_SystemAudioControl`" → Task 1 Step 3. ✓
- "Delete `_DeviceAudioControl`" → Task 1 Step 3. ✓
- "Remove `deviceMode` computation, `_deviceAudio`, `_onDeviceAudioTap`" → Task 1 Step 4. ✓
- "Delete `deviceAudioEnabledProvider`; pass `captureDeviceAudio: true`" → Task 2 Step 1. ✓
- "Keep `startDeviceRecording(captureDeviceAudio:)`; mic unchanged; system-audio never cleared" → Global Constraints + nothing edits them. ✓
- "Rewrite/rename the device-mode test" → Task 1 Step 1. ✓
- "Update router/device tests; remove provider refs" → Task 2 (no edits needed; verified by grep). ✓
- "Run analyze + tests green" → Task 3. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; all code shown verbatim. ✓

**Type consistency:** Widget keys `bar-system-audio` / `bar-device-audio` / `bar-mic` match `recording_bar.dart`. `captureDeviceAudio` matches `startDeviceRecording` signature. `deviceAudioEnabledProvider` removed everywhere it was referenced (router + screen). ✓
