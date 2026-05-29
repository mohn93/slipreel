# Recording UX bundle (sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring 5 recording-lifecycle features online — 3-2-1 countdown, pause/resume (paused time excluded from output), global hotkeys (Cmd+Shift+1/2/P), system-sleep auto-pause + on-wake modal, long-recording warnings (30/60/90 min + 2 hr hard stop).

**Architecture:** Three native subsystems on the macOS plugin (writer pause/resume with PTS rebase, Carbon RegisterEventHotKey, NSWorkspace sleep observer) feed Dart Riverpod controllers that all funnel through a single `RecordingActionRouter`. The countdown sits between the router and `RecordingController.startRecording`. Pause/resume rebases PTS in `LiveRecordingWriter` so paused intervals are excluded from the output MP4.

**Tech Stack:** Flutter, Riverpod (StateNotifier + ChangeNotifier), Dart federated plugin, Swift (Carbon HIToolbox, NSWorkspace, AVFoundation), JSON sidecar via `path_provider`.

**Spec:** `docs/superpowers/specs/2026-05-29-recording-ux-bundle-design.md`

---

## File map (locked in before tasks)

### Created — Dart side
- `packages/screen_recorder/lib/state/recording_settings_store.dart` — JSON sidecar holding `countdownSeconds`
- `packages/screen_recorder/lib/state/recording_settings_controller.dart` — Riverpod controller + provider
- `packages/screen_recorder/lib/state/countdown_controller.dart` — `CountdownState` + `CountdownController` + provider
- `packages/screen_recorder/lib/state/recording_action_router.dart` — single funnel for start/stop/pause triggers
- `packages/screen_recorder/lib/state/hotkey_controller.dart` — registers Carbon hotkeys, subscribes to events
- `packages/screen_recorder/lib/state/sleep_observer.dart` — subscribes to native sleep EventChannel
- `packages/screen_recorder/lib/state/long_recording_watcher.dart` — fires events at 30/60/90/120 min thresholds
- `packages/screen_recorder/lib/ui/widgets/countdown_overlay.dart` — full-screen-of-bar countdown UI
- `packages/screen_recorder/lib/ui/bar/wake_modal.dart` — parameterized modal (on-wake + 90-min)
- `packages/screen_recorder/lib/ui/bar/recording_toast.dart` — transient overlay toast

### Modified — Dart side
- `packages/screen_recorder/lib/state/recording_state.dart` — add `RecordingStatus.paused`; add `pauseRecording` + `resumeRecording`; fix duration timer
- `packages/screen_recorder/lib/ui/bar/recording_pill.dart` — add Pause/Resume button; accept status
- `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` — route `_pickAndRecord` through `RecordingActionRouter`; wire countdown overlay + sleep modal mounting
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` — add "Recording" section
- `packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart` — add shortcuts card
- `packages/screen_recorder/lib/main.dart` — load settings store, construct router/hotkey/sleep/long-watcher controllers, register navigator key

### Modified — Platform interface
- `packages/screen_recorder_platform_interface/lib/src/constants.dart` — add hotkeys + sleep EventChannel names + 3 method-name constants
- `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` — add `registerRecordingHotkeys`/`unregisterRecordingHotkeys`/`startSleepObserver` defaults; add `recordingHotkeyStream`/`sleepEventStream` defaults

### Modified — macOS plugin
- `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift` — add `pause()`/`resume()` + paused flag + `pausedOffset: CMTime` + PTS rebase in `appendVideo`/`appendAudio`
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` — implement `pauseRecording`/`resumeRecording`/`registerRecordingHotkeys`/`unregisterRecordingHotkeys`/`startSleepObserver` cases
- `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` — Dart bindings + EventChannel subscribers

### Created — macOS plugin
- `packages/screen_recorder_macos/macos/Classes/HotkeyManager.swift` — Carbon `RegisterEventHotKey` registry + `InstallEventHandler` dispatcher
- `packages/screen_recorder_macos/macos/Classes/SleepObserver.swift` — `NSWorkspace` willSleep/didWake observers

### Created — tests
- `packages/screen_recorder/test/state/recording_settings_store_test.dart`
- `packages/screen_recorder/test/state/recording_settings_controller_test.dart`
- `packages/screen_recorder/test/state/countdown_controller_test.dart`
- `packages/screen_recorder/test/state/recording_controller_pause_test.dart`
- `packages/screen_recorder/test/state/recording_action_router_test.dart`
- `packages/screen_recorder/test/state/hotkey_controller_test.dart`
- `packages/screen_recorder/test/state/sleep_observer_test.dart`
- `packages/screen_recorder/test/state/long_recording_watcher_test.dart`
- `packages/screen_recorder/test/ui/widgets/countdown_overlay_test.dart`
- `packages/screen_recorder/test/ui/bar/recording_pill_test.dart` (extend existing if present, else create)
- `packages/screen_recorder/test/ui/bar/wake_modal_test.dart`
- `packages/screen_recorder/test/ui/bar/recording_toast_test.dart`

---

## Branch

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git checkout -b feat/recording-ux-bundle
```

Commit after each task. Merge to main only after the final task.

---

### Task 1: Add `RecordingStatus.paused` enum value

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`

- [ ] **Step 1: Add the enum value**

Open `packages/screen_recorder/lib/state/recording_state.dart`. Find the line:
```dart
enum RecordingStatus { idle, recording, processing, completed, error }
```
Replace with:
```dart
enum RecordingStatus { idle, recording, paused, processing, completed, error }
```

`paused` sits between `recording` and `processing` so the order reflects the lifecycle.

- [ ] **Step 2: Check `RecordingState.canStartRecording` + `isRecording` getters**

Search the same file for `canStartRecording` and `isRecording`. Both currently switch on `status`. Update so:
- `canStartRecording` returns true only for `idle`/`completed`/`error` (NOT for `paused`).
- `isRecording` returns true for BOTH `recording` AND `paused` (so existing code that gates UI on "is the user currently in a recording session" stays correct).

If the file uses an expression like `status == RecordingStatus.recording`, change to `status == RecordingStatus.recording || status == RecordingStatus.paused`.

- [ ] **Step 3: Run the existing recording-state tests**

```bash
cd packages/screen_recorder && flutter test test/state/recording_state*.dart
```
Expected: all existing tests pass (the only change is to two getters, behavior preserves the recording-lifecycle invariants for tests that don't care about `paused`).

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart
git commit -m "feat(app): add RecordingStatus.paused"
```

---

### Task 2: `RecordingSettingsStore` (JSON sidecar)

**Files:**
- Create: `packages/screen_recorder/lib/state/recording_settings_store.dart`
- Test: `packages/screen_recorder/test/state/recording_settings_store_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/recording_settings_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rec_settings_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('load returns default 3 on fresh install', () async {
    final store = RecordingSettingsStore(path: '${tmp.path}/recording_settings.json');
    final settings = await store.load();
    expect(settings.countdownSeconds, 3);
  });

  test('save + load round-trips countdownSeconds', () async {
    final store = RecordingSettingsStore(path: '${tmp.path}/recording_settings.json');
    await store.save(const RecordingSettings(countdownSeconds: 5));
    final settings = await store.load();
    expect(settings.countdownSeconds, 5);
  });

  test('corrupt JSON falls back to defaults', () async {
    final path = '${tmp.path}/recording_settings.json';
    await File(path).writeAsString('{ garbage');
    final store = RecordingSettingsStore(path: path);
    final settings = await store.load();
    expect(settings.countdownSeconds, 3);
  });

  test('rejects invalid countdownSeconds values (defaults to 3)', () async {
    final path = '${tmp.path}/recording_settings.json';
    await File(path).writeAsString('{"countdownSeconds": 99}');
    final store = RecordingSettingsStore(path: path);
    final settings = await store.load();
    expect(settings.countdownSeconds, 3);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/recording_settings_store_test.dart
```
Expected: FAIL — `recording_settings_store.dart` does not exist.

- [ ] **Step 3: Implement the store**

```dart
// packages/screen_recorder/lib/state/recording_settings_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/app_logger.dart';

/// User-facing recording preferences. Grows as more recording prefs land.
class RecordingSettings {
  const RecordingSettings({this.countdownSeconds = 3});
  final int countdownSeconds;

  RecordingSettings copyWith({int? countdownSeconds}) => RecordingSettings(
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      );

  Map<String, dynamic> toJson() => {'countdownSeconds': countdownSeconds};

  static const defaults = RecordingSettings();

  /// Only these countdown values are allowed; anything else falls back to the default.
  static const _validCountdowns = {0, 3, 5};

  static RecordingSettings fromJson(Map<String, dynamic> json) {
    final raw = json['countdownSeconds'];
    final countdown =
        (raw is int && _validCountdowns.contains(raw)) ? raw : defaults.countdownSeconds;
    return RecordingSettings(countdownSeconds: countdown);
  }
}

/// JSON sidecar under getApplicationSupportDirectory(). Mirrors the
/// MotionTuningStore pattern.
class RecordingSettingsStore {
  RecordingSettingsStore({required this.path});
  final String path;

  Future<RecordingSettings> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return RecordingSettings.defaults;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return RecordingSettings.fromJson(json);
    } catch (e, st) {
      AppLogger.platform.w('RecordingSettingsStore.load failed; falling back',
          error: e, stackTrace: st);
      return RecordingSettings.defaults;
    }
  }

  Future<void> save(RecordingSettings settings) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/recording_settings_store_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_settings_store.dart \
        packages/screen_recorder/test/state/recording_settings_store_test.dart
git commit -m "feat(app): RecordingSettingsStore (JSON sidecar)"
```

---

### Task 3: `RecordingSettingsController` + provider

**Files:**
- Create: `packages/screen_recorder/lib/state/recording_settings_controller.dart`
- Test: `packages/screen_recorder/test/state/recording_settings_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
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
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/recording_settings_controller_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the controller**

```dart
// packages/screen_recorder/lib/state/recording_settings_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'recording_settings_store.dart';

class RecordingSettingsController extends StateNotifier<RecordingSettings> {
  RecordingSettingsController({required this.store, required RecordingSettings initial})
      : super(initial);

  final RecordingSettingsStore store;

  static const _validCountdowns = {0, 3, 5};

  Future<void> setCountdownSeconds(int seconds) async {
    if (!_validCountdowns.contains(seconds)) return;
    state = state.copyWith(countdownSeconds: seconds);
    await store.save(state);
  }
}

final recordingSettingsStoreProvider = Provider<RecordingSettingsStore>(
  (ref) => throw UnimplementedError(
    'Override recordingSettingsStoreProvider in main()',
  ),
);

final recordingSettingsControllerProvider =
    StateNotifierProvider<RecordingSettingsController, RecordingSettings>(
  (ref) => throw UnimplementedError(
    'Override recordingSettingsControllerProvider in main()',
  ),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/recording_settings_controller_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_settings_controller.dart \
        packages/screen_recorder/test/state/recording_settings_controller_test.dart
git commit -m "feat(app): RecordingSettingsController + providers"
```

---

### Task 4: Native `LiveRecordingWriter.pause()` + `resume()` with PTS rebase

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`

The writer currently has `writerQueue: DispatchQueue` serializing all access. We add two new entry points (`pause`, `resume`) plus state (`isPaused`, `pauseStart`, `pausedOffset`), and gate `appendVideo`/`appendAudio` with the paused flag while rebasing PTS by the accumulated offset.

- [ ] **Step 1: Add the new state fields**

In `LiveRecordingWriter.swift`, find the `// MARK: - Properties` block (around line 30). After `private var writerActive = false` add:

```swift
  /// True when pause() has been called and not yet matched by resume().
  /// Sample buffers are dropped while this is true.
  private var isPaused = false

  /// Host-clock time when pause() was called. Set on pause, cleared on resume.
  private var pauseStart: CMTime?

  /// Accumulated paused duration. Subtracted from every sample's PTS so the
  /// output timeline has no gap.
  private var pausedOffset: CMTime = .zero
```

- [ ] **Step 2: Add `pause()` and `resume()` methods**

After the `stop()` method (around line 266), add:

```swift
  /// Pause appending sample buffers. Idempotent.
  func pause() {
    writerQueue.sync {
      guard isStarted, !isPaused else { return }
      isPaused = true
      pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
    }
  }

  /// Resume appending. Adds the elapsed paused duration to `pausedOffset` so
  /// subsequent samples have their PTS rebased seamlessly. Idempotent.
  func resume() {
    writerQueue.sync {
      guard isStarted, isPaused, let start = pauseStart else {
        isPaused = false
        pauseStart = nil
        return
      }
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(now, start))
      isPaused = false
      pauseStart = nil
    }
  }
```

- [ ] **Step 3: Gate `appendVideo` on `isPaused` + rebase PTS**

Find `appendVideo(_ sampleBuffer: CMSampleBuffer)` (around line 176). Replace its body with:

```swift
  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    writerQueue.sync {
      appendVideoCallCount += 1
      guard isStarted, let _ = assetWriter else { return }
      if isPaused { return }

      if !writerActive {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
          return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        do {
          try addVideoInputAndStartSession(formatDescription: formatDescription, pts: pts)
        } catch {
          return
        }
      }

      guard let input = videoInput else { return }
      if input.isReadyForMoreMediaData {
        let rebased = rebaseSampleBuffer(sampleBuffer)
        input.append(rebased ?? sampleBuffer)
        appendVideoAcceptedCount += 1
      } else {
        appendVideoNotReadyCount += 1
      }
    }
  }
```

- [ ] **Step 4: Gate `appendAudio` on `isPaused` + rebase PTS**

Find `appendAudio(...)` (around line 209). Replace with:

```swift
  func appendAudio(_ sampleBuffer: CMSampleBuffer, role: AudioTrackRole) {
    writerQueue.sync {
      guard isStarted, writerActive, let input = audioInputs[role] else { return }
      if isPaused { return }
      if input.isReadyForMoreMediaData {
        let rebased = rebaseSampleBuffer(sampleBuffer)
        input.append(rebased ?? sampleBuffer)
      }
    }
  }
```

- [ ] **Step 5: Add the PTS-rebase helper**

After `appendAudio`, add this private helper:

```swift
  /// Returns a new `CMSampleBuffer` with its PTS shifted back by `pausedOffset`
  /// so the output timeline excludes paused intervals. Returns `nil` if the
  /// offset is zero or the buffer can't be rewritten (caller falls back to
  /// the original sample).
  private func rebaseSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
    if pausedOffset == .zero { return nil }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    if count == 0 { return nil }
    var timing = Array(repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(
      sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
    for i in 0..<count {
      timing[i].presentationTimeStamp =
        CMTimeSubtract(timing[i].presentationTimeStamp, pausedOffset)
      if CMTimeCompare(timing[i].decodeTimeStamp, .invalid) != 0 &&
         CMTimeCompare(timing[i].decodeTimeStamp, .indefinite) != 0 {
        timing[i].decodeTimeStamp =
          CMTimeSubtract(timing[i].decodeTimeStamp, pausedOffset)
      }
    }
    var rebased: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: count,
      sampleTimingArray: &timing,
      sampleBufferOut: &rebased)
    return status == noErr ? rebased : nil
  }
```

- [ ] **Step 6: Make `stop()` drain a paused writer cleanly**

Find the `stop(...)` method (line 219). At the top of the `writerQueue.sync { ... }` block, BEFORE `videoInput?.markAsFinished()`, add:

```swift
      // Unpause before finalizing so writer drains its queues.
      if isPaused {
        isPaused = false
        pauseStart = nil
      }
```

- [ ] **Step 7: Compile-check via xcodebuild**

```bash
cd packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace \
             -scheme Runner \
             -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' \
             build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
git commit -m "feat(macos): LiveRecordingWriter pause/resume + PTS rebase"
```

---

### Task 5: Wire native `pauseRecording`/`resumeRecording` plugin cases

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

- [ ] **Step 1: Add the two cases to the switch in `handle(_:result:)`**

In `handle(_:result:)`, insert these cases (alphabetical with the existing recording controls, or just before `case "stopLiveRecording":`):

```swift
    case "pauseRecording":
      pauseRecording(result: result)

    case "resumeRecording":
      resumeRecording(result: result)
```

- [ ] **Step 2: Add the private helpers**

Find a recording-related helper like `stopLiveRecording(result:)` (around line 742). Add these two private functions nearby:

```swift
  private func pauseRecording(result: @escaping FlutterResult) {
    guard let writer = liveRecordingWriter else {
      result(FlutterError(code: "NOT_RECORDING",
                          message: "No active recording to pause", details: nil))
      return
    }
    writer.pause()
    result(nil)
  }

  private func resumeRecording(result: @escaping FlutterResult) {
    guard let writer = liveRecordingWriter else {
      result(FlutterError(code: "NOT_RECORDING",
                          message: "No active recording to resume", details: nil))
      return
    }
    writer.resume()
    result(nil)
  }
```

NOTE: `liveRecordingWriter` is the property name used by the existing plugin's recording flow — verify by searching for `LiveRecordingWriter` in the file before adding (the start path holds a reference somewhere). If the name differs, use the actual property reference; the logic is identical.

- [ ] **Step 3: xcodebuild check**

```bash
cd packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(macos): pauseRecording / resumeRecording plugin cases"
```

---

### Task 6: macOS Dart facade — `pauseRecording` / `resumeRecording`

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`

- [ ] **Step 1: Add the two method implementations**

After the existing recording-related overrides (e.g. `stopRecording`), add:

```dart
  @override
  Future<void> pauseRecording() async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.pauseRecording,
    );
  }

  @override
  Future<void> resumeRecording() async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.resumeRecording,
    );
  }
```

The constants `pauseRecording` and `resumeRecording` are already declared in `ScreenRecorderMethods`.

- [ ] **Step 2: Run analyzer**

```bash
cd packages/screen_recorder_macos && flutter analyze --no-fatal-infos
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git commit -m "feat(macos): dart bindings for pause/resume"
```

---

### Task 7: `RecordingController.pauseRecording` / `resumeRecording`

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Test: `packages/screen_recorder/test/state/recording_controller_pause_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/recording_controller_pause_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  int pauseCalls = 0;
  int resumeCalls = 0;
  @override
  Future<void> pauseRecording() async => pauseCalls++;
  @override
  Future<void> resumeRecording() async => resumeCalls++;
}

void main() {
  late _FakePlatform platform;
  setUp(() {
    platform = _FakePlatform();
    ScreenRecorderPlatform.instance = platform;
  });

  test('pauseRecording is a no-op when status != recording', () async {
    final c = RecordingController();
    expect(c.state.status, RecordingStatus.idle);
    await c.pauseRecording();
    expect(platform.pauseCalls, 0);
    expect(c.state.status, RecordingStatus.idle);
  });

  test('resumeRecording is a no-op when status != paused', () async {
    final c = RecordingController();
    await c.resumeRecording();
    expect(platform.resumeCalls, 0);
    expect(c.state.status, RecordingStatus.idle);
  });

  test('pauseRecording flips status to paused and calls native', () async {
    final c = RecordingController();
    c.state = c.state.copyWith(status: RecordingStatus.recording);
    await c.pauseRecording();
    expect(platform.pauseCalls, 1);
    expect(c.state.status, RecordingStatus.paused);
  });

  test('resumeRecording from paused flips status back to recording', () async {
    final c = RecordingController();
    c.state = c.state.copyWith(status: RecordingStatus.paused);
    await c.resumeRecording();
    expect(platform.resumeCalls, 1);
    expect(c.state.status, RecordingStatus.recording);
  });
}
```

NOTE: `RecordingController.state =` is a protected setter on `StateNotifier`. The test sets it via a `@visibleForTesting` setter you'll add in Step 3.

- [ ] **Step 2: Run the test, verify it fails (compile error)**

```bash
cd packages/screen_recorder && flutter test test/state/recording_controller_pause_test.dart
```
Expected: FAIL — `pauseRecording`/`resumeRecording` not found on `RecordingController`.

- [ ] **Step 3: Add the methods to `RecordingController`**

Open `packages/screen_recorder/lib/state/recording_state.dart`. After `stopRecording` (around line 270), add:

```dart
  Future<void> pauseRecording() async {
    if (state.status != RecordingStatus.recording) return;
    _durationTimer?.cancel();
    _durationTimer = null;
    // Capture elapsed-so-far so resume can restart from where we paused.
    final elapsed = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : state.duration;
    _startTime = null;
    state = state.copyWith(status: RecordingStatus.paused, duration: elapsed);
    await ScreenRecorderPlatform.instance.pauseRecording();
  }

  Future<void> resumeRecording() async {
    if (state.status != RecordingStatus.paused) return;
    await ScreenRecorderPlatform.instance.resumeRecording();
    // Re-anchor _startTime to "now minus elapsed" so the periodic timer
    // continues to fire correct durations from where we paused.
    _startTime = DateTime.now().subtract(state.duration);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startTime != null) {
        state = state.copyWith(duration: DateTime.now().difference(_startTime!));
      }
    });
    state = state.copyWith(status: RecordingStatus.recording);
  }
```

Also add at the very top of the class (alongside the existing test-visible setter if there is one, or as a new one):

```dart
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  set state(RecordingState value) => super.state = value;
```

(If `@visibleForTesting` already exists or the StateNotifier base allows external state writes in tests, skip this.)

Add import at top of file if not already present:
```dart
import 'package:flutter/foundation.dart' show visibleForTesting;
```

- [ ] **Step 4: Make `stopRecording` accept `paused` as well**

In `stopRecording`, the first line is `if (!state.isRecording) return;`. Since Task 1 made `isRecording` return true for both `recording` and `paused`, this already works. Verify by reading the current state.

- [ ] **Step 5: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/recording_controller_pause_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 6: Run the full state suite**

```bash
cd packages/screen_recorder && flutter test test/state/
```
Expected: all pass; no regressions.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/test/state/recording_controller_pause_test.dart
git commit -m "feat(app): RecordingController pause/resume"
```

---

### Task 8: `CountdownController` + `CountdownState`

**Files:**
- Create: `packages/screen_recorder/lib/state/countdown_controller.dart`
- Test: `packages/screen_recorder/test/state/countdown_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/countdown_controller_test.dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';

void main() {
  test('initial state is inactive with remaining 0', () {
    final c = CountdownController();
    expect(c.state.active, isFalse);
    expect(c.state.remaining, 0);
  });

  test('run(3) ticks down each second; fires onComplete at 0', () {
    fakeAsync((async) {
      final c = CountdownController();
      int completed = 0;
      c.run(seconds: 3, onComplete: () => completed++);
      expect(c.state.remaining, 3);
      expect(c.state.active, isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(c.state.remaining, 2);
      async.elapse(const Duration(seconds: 1));
      expect(c.state.remaining, 1);
      async.elapse(const Duration(seconds: 1));
      expect(c.state.remaining, 0);
      expect(c.state.active, isFalse);
      expect(completed, 1);
    });
  });

  test('cancel mid-flight stops the timer; onComplete does NOT fire', () {
    fakeAsync((async) {
      final c = CountdownController();
      int completed = 0;
      c.run(seconds: 3, onComplete: () => completed++);
      async.elapse(const Duration(seconds: 1));
      c.cancel();
      async.elapse(const Duration(seconds: 5));
      expect(c.state.active, isFalse);
      expect(completed, 0);
    });
  });

  test('run(0) fires onComplete immediately', () {
    fakeAsync((async) {
      final c = CountdownController();
      int completed = 0;
      c.run(seconds: 0, onComplete: () => completed++);
      async.flushMicrotasks();
      expect(completed, 1);
      expect(c.state.active, isFalse);
    });
  });

  test('run while already active is a no-op', () {
    fakeAsync((async) {
      final c = CountdownController();
      int firstCompleted = 0;
      int secondCompleted = 0;
      c.run(seconds: 3, onComplete: () => firstCompleted++);
      c.run(seconds: 5, onComplete: () => secondCompleted++);
      async.elapse(const Duration(seconds: 3));
      expect(firstCompleted, 1);
      expect(secondCompleted, 0);
      expect(c.state.active, isFalse);
    });
  });
}
```

Also add `fake_async` to the dev_dependencies of `packages/screen_recorder/pubspec.yaml` if not already present. (Check first: `grep fake_async packages/screen_recorder/pubspec.yaml`. If present, skip.) If not, add to `dev_dependencies`:
```yaml
  fake_async: ^1.3.1
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/countdown_controller_test.dart
```
Expected: FAIL — `countdown_controller.dart` does not exist.

- [ ] **Step 3: Implement the controller**

```dart
// packages/screen_recorder/lib/state/countdown_controller.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class CountdownState {
  const CountdownState({this.remaining = 0, this.active = false});
  final int remaining;
  final bool active;

  CountdownState copyWith({int? remaining, bool? active}) => CountdownState(
        remaining: remaining ?? this.remaining,
        active: active ?? this.active,
      );

  static const initial = CountdownState();
}

class CountdownController extends StateNotifier<CountdownState> {
  CountdownController() : super(CountdownState.initial);

  Timer? _timer;
  VoidCallback? _onComplete;

  /// Starts a countdown. If `seconds == 0`, fires `onComplete` next microtask
  /// and stays inactive. If already active, the call is a no-op.
  void run({required int seconds, required VoidCallback onComplete}) {
    if (state.active) return;
    if (seconds <= 0) {
      scheduleMicrotask(onComplete);
      return;
    }
    _onComplete = onComplete;
    state = CountdownState(remaining: seconds, active: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = state.remaining - 1;
      if (next <= 0) {
        _timer?.cancel();
        _timer = null;
        state = const CountdownState(remaining: 0, active: false);
        final cb = _onComplete;
        _onComplete = null;
        cb?.call();
      } else {
        state = state.copyWith(remaining: next);
      }
    });
  }

  /// Cancel without firing `onComplete`.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _onComplete = null;
    if (state.active) {
      state = CountdownState.initial;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final countdownControllerProvider =
    StateNotifierProvider<CountdownController, CountdownState>(
  (ref) => CountdownController(),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/countdown_controller_test.dart
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/countdown_controller.dart \
        packages/screen_recorder/test/state/countdown_controller_test.dart \
        packages/screen_recorder/pubspec.yaml
git commit -m "feat(app): CountdownController"
```

---

### Task 9: `CountdownOverlay` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/countdown_overlay.dart`
- Test: `packages/screen_recorder/test/ui/widgets/countdown_overlay_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/countdown_overlay_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';
import 'package:screen_recorder/ui/widgets/countdown_overlay.dart';

void main() {
  testWidgets('renders the remaining number while active', (tester) async {
    final ctrl = CountdownController();
    await tester.pumpWidget(ProviderScope(
      overrides: [countdownControllerProvider.overrideWith((ref) => ctrl)],
      child: const MaterialApp(home: Scaffold(body: CountdownOverlay())),
    ));
    ctrl.run(seconds: 3, onComplete: () {});
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('renders nothing when inactive', (tester) async {
    final ctrl = CountdownController();
    await tester.pumpWidget(ProviderScope(
      overrides: [countdownControllerProvider.overrideWith((ref) => ctrl)],
      child: const MaterialApp(home: Scaffold(body: CountdownOverlay())),
    ));
    await tester.pump();
    expect(find.text('3'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('Cancel button calls controller.cancel', (tester) async {
    final ctrl = CountdownController();
    await tester.pumpWidget(ProviderScope(
      overrides: [countdownControllerProvider.overrideWith((ref) => ctrl)],
      child: const MaterialApp(home: Scaffold(body: CountdownOverlay())),
    ));
    ctrl.run(seconds: 3, onComplete: () {});
    await tester.pump();
    expect(ctrl.state.active, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(ctrl.state.active, isFalse);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/widgets/countdown_overlay_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the overlay**

```dart
// packages/screen_recorder/lib/ui/widgets/countdown_overlay.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/countdown_controller.dart';

/// Renders inside the existing bar window. When the controller is active,
/// hides the bar's source picker behind a translucent backdrop and shows a
/// big centered countdown number with a Cancel button.
class CountdownOverlay extends ConsumerWidget {
  const CountdownOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(countdownControllerProvider);
    if (!state.active) return const SizedBox.shrink();

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xB3000000),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1.0),
                key: ValueKey(state.remaining),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutBack,
                builder: (_, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Text(
                  '${state.remaining}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 24),
              TextButton(
                onPressed: () =>
                    ref.read(countdownControllerProvider.notifier).cancel(),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/widgets/countdown_overlay_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/countdown_overlay.dart \
        packages/screen_recorder/test/ui/widgets/countdown_overlay_test.dart
git commit -m "feat(app): CountdownOverlay widget"
```

---

### Task 10: `RecordingActionRouter`

**Files:**
- Create: `packages/screen_recorder/lib/state/recording_action_router.dart`
- Test: `packages/screen_recorder/test/state/recording_action_router_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/recording_action_router_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

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

    // Listen for countdown activation.
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
```

NOTE: This test exercises the router via a ProviderContainer rather than constructing a Riverpod-managed instance. The router's signature accepts a `ProviderContainer` (or `Ref`).

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/recording_action_router_test.dart
```
Expected: FAIL — `recording_action_router.dart` does not exist.

- [ ] **Step 3: Implement the router**

```dart
// packages/screen_recorder/lib/state/recording_action_router.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'countdown_controller.dart';
import 'recording_settings_controller.dart';
import 'recording_state.dart';
import '../ui/widgets/permission_denied_sheet.dart';
import 'permissions_controller.dart';

/// Single funnel for every start/stop/pause trigger — UI button, hotkey,
/// sleep observer. Owns the countdown decision; delegates the deny-sheet
/// gate to RecordingController.startRecording's existing guard.
class RecordingActionRouter {
  RecordingActionRouter(this._container);
  final ProviderContainer _container;

  Future<void> start(BuildContext context) async {
    final settings = _container.read(recordingSettingsControllerProvider);
    final seconds = settings.countdownSeconds;

    Future<void> doStart() async {
      final controller = _container.read(recordingControllerProvider.notifier);
      final snapshot = _container.read(permissionsControllerProvider);
      await controller.startRecording(
        permissions: snapshot,
        onDenied: (kind) {
          if (!context.mounted) return Future.value();
          return PermissionDeniedSheet.show(context, kind);
        },
      );
    }

    if (seconds <= 0) {
      await doStart();
      return;
    }

    _container.read(countdownControllerProvider.notifier).run(
          seconds: seconds,
          onComplete: () {
            // Fire-and-forget: doStart awaits the native start internally;
            // we don't block the countdown callback on it.
            unawaited(doStart());
          },
        );
  }

  Future<void> stop() async {
    // If countdown is active, cancel it first (treats "stop during countdown"
    // as an abort).
    final countdown = _container.read(countdownControllerProvider);
    if (countdown.active) {
      _container.read(countdownControllerProvider.notifier).cancel();
      return;
    }
    await _container.read(recordingControllerProvider.notifier).stopRecording();
  }

  Future<void> pauseOrResume() async {
    final status = _container.read(recordingControllerProvider).status;
    final controller = _container.read(recordingControllerProvider.notifier);
    if (status == RecordingStatus.recording) {
      await controller.pauseRecording();
    } else if (status == RecordingStatus.paused) {
      await controller.resumeRecording();
    }
  }
}

/// Set in main() so HotkeyController + SleepObserver have a real router.
/// Throws by default so missing override is caught at first use.
final recordingActionRouterProvider = Provider<RecordingActionRouter>(
  (ref) => throw UnimplementedError(
    'Override recordingActionRouterProvider in main()',
  ),
);

/// Mutable singleton set by _MyAppState._initRecordingSurfaces (Task 23).
/// The bar's _pickAndRecord (Task 24) reads this to route start through the
/// countdown. Null until MyApp finishes its first frame.
RecordingActionRouter? recordingActionRouterRef;
```

Add to imports: `import 'dart:async';` (for `unawaited`).

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/recording_action_router_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_action_router.dart \
        packages/screen_recorder/test/state/recording_action_router_test.dart
git commit -m "feat(app): RecordingActionRouter"
```

---

### Task 11: Update `RecordingPill` with Pause/Resume button

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_pill.dart`
- Test: `packages/screen_recorder/test/ui/bar/recording_pill_test.dart` (create)

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/bar/recording_pill_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';

Widget _h({required RecordingStatus status, required Duration elapsed,
           VoidCallback? onStop, VoidCallback? onPauseOrResume}) {
  return MaterialApp(
    home: Scaffold(
      body: RecordingPill(
        status: status,
        elapsed: elapsed,
        onStop: onStop ?? () {},
        onPauseOrResume: onPauseOrResume ?? () {},
      ),
    ),
  );
}

void main() {
  testWidgets('shows Pause button when recording', (tester) async {
    await tester.pumpWidget(_h(
        status: RecordingStatus.recording, elapsed: const Duration(seconds: 5)));
    expect(find.byKey(const Key('pill-pause')), findsOneWidget);
    expect(find.byKey(const Key('pill-resume')), findsNothing);
  });

  testWidgets('shows Resume button when paused', (tester) async {
    await tester.pumpWidget(_h(
        status: RecordingStatus.paused, elapsed: const Duration(seconds: 5)));
    expect(find.byKey(const Key('pill-resume')), findsOneWidget);
    expect(find.byKey(const Key('pill-pause')), findsNothing);
  });

  testWidgets('Pause tap calls onPauseOrResume', (tester) async {
    int taps = 0;
    await tester.pumpWidget(_h(
        status: RecordingStatus.recording,
        elapsed: Duration.zero,
        onPauseOrResume: () => taps++));
    await tester.tap(find.byKey(const Key('pill-pause')));
    expect(taps, 1);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/bar/recording_pill_test.dart
```
Expected: FAIL — `RecordingPill` signature doesn't match.

- [ ] **Step 3: Update the pill**

Replace `packages/screen_recorder/lib/ui/bar/recording_pill.dart` with:

```dart
import 'package:flutter/material.dart';

import '../../state/recording_state.dart';
import 'elapsed_format.dart';

class RecordingPill extends StatelessWidget {
  const RecordingPill({
    super.key,
    required this.status,
    required this.elapsed,
    required this.onStop,
    required this.onPauseOrResume,
  });

  final RecordingStatus status;
  final Duration elapsed;
  final VoidCallback onStop;
  final VoidCallback onPauseOrResume;

  @override
  Widget build(BuildContext context) {
    final isPaused = status == RecordingStatus.paused;
    return Container(
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: isPaused ? const Color(0xFF7E7E86) : const Color(0xFFE5484D),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatElapsed(elapsed),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          _PillButton(
            key: Key(isPaused ? 'pill-resume' : 'pill-pause'),
            onTap: onPauseOrResume,
            color: const Color(0xFF3F3F46),
            icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
          const SizedBox(width: 6),
          _PillButton(
            key: const Key('pill-stop'),
            onTap: onStop,
            color: const Color(0xFFE5484D),
            icon: Icons.stop_rounded,
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({super.key, required this.onTap, required this.color, required this.icon});
  final VoidCallback onTap;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}
```

- [ ] **Step 4: Update callers of `RecordingPill`**

Grep for `RecordingPill(`:
```bash
grep -rn "RecordingPill(" packages/screen_recorder/lib packages/screen_recorder/test
```

For each construction site, add the two new required params (`status:` and `onPauseOrResume:`). In `recording_bar_screen.dart` the construction is around the bar pill widget; pass:
- `status: ref.watch(recordingControllerProvider).status`
- `onPauseOrResume: () => ref.read(recordingActionRouterProvider).pauseOrResume()`

Update or add the `recordingActionRouterProvider` import.

- [ ] **Step 5: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/bar/recording_pill_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 6: Run the full app suite**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green (existing pill tests that don't pass the new params will need a small bump — fix in place).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_pill.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/recording_pill_test.dart
git commit -m "feat(app): Pause/Resume button on RecordingPill"
```

---

### Task 12: `SettingsScreen` Recording section

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/settings_screen.dart`

- [ ] **Step 1: Convert to ConsumerStatefulWidget (if not already a Consumer)**

Open `packages/screen_recorder/lib/ui/screens/settings_screen.dart`. If it's currently `StatefulWidget`, change the class to `ConsumerStatefulWidget` and `State<...>` to `ConsumerState<...>`. Update imports to include `package:flutter_riverpod/flutter_riverpod.dart`.

- [ ] **Step 2: Add a "Recording" section above the existing "Template" section**

In `build()`, before `_buildSectionTitle('Template'),`, add:

```dart
            _buildSectionTitle('Recording'),
            const SizedBox(height: 12),
            _buildCountdownPicker(),
            const SizedBox(height: 16),
            _buildShortcutsCard(),
            const SizedBox(height: 32),
```

- [ ] **Step 3: Add the two helper methods**

In the same `_SettingsScreenState`, add:

```dart
  Widget _buildCountdownPicker() {
    final value = ref.watch(recordingSettingsControllerProvider).countdownSeconds;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Countdown before recording',
            style: TextStyle(color: Colors.white)),
        ToggleButtons(
          isSelected: [value == 0, value == 3, value == 5],
          onPressed: (i) {
            final next = [0, 3, 5][i];
            ref
                .read(recordingSettingsControllerProvider.notifier)
                .setCountdownSeconds(next);
          },
          borderRadius: BorderRadius.circular(8),
          children: const [Text(' Off '), Text(' 3 s '), Text(' 5 s ')],
        ),
      ],
    );
  }

  Widget _buildShortcutsCard() {
    const rows = [
      ('⌘⇧1', 'Start recording'),
      ('⌘⇧2', 'Stop recording'),
      ('⌘⇧P', 'Pause / Resume'),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Keyboard shortcuts',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(
                    width: 56,
                    child: Text(r.$1,
                        style: const TextStyle(
                            color: Colors.white, fontFamily: 'Menlo'))),
                Text(r.$2, style: const TextStyle(color: Colors.white70)),
              ]),
            ),
        ],
      ),
    );
  }
```

Add the import:
```dart
import '../../state/recording_settings_controller.dart';
```

- [ ] **Step 4: Run analyzer**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/screens/settings_screen.dart
```
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/settings_screen.dart
git commit -m "feat(app): Recording section in SettingsScreen"
```

---

### Task 13: Onboarding `ReadyPage` shortcuts card

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart`

- [ ] **Step 1: Insert the shortcuts card above the CTA**

Open the file. Before the `SizedBox(width: 280, child: FilledButton(...))` CTA block, add:

```dart
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShortcutRow(combo: '⌘⇧1', label: 'Start recording from anywhere'),
                SizedBox(height: 4),
                _ShortcutRow(combo: '⌘⇧2', label: 'Stop'),
                SizedBox(height: 4),
                _ShortcutRow(combo: '⌘⇧P', label: 'Pause / Resume'),
              ],
            ),
          ),
          const SizedBox(height: 16),
```

At the bottom of the file (after `ReadyPage`), add:

```dart
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.combo, required this.label});
  final String combo;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
          width: 60,
          child: Text(combo,
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'Menlo', fontSize: 13))),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
    ]);
  }
}
```

- [ ] **Step 2: Run analyzer**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/screens/onboarding/pages/ready_page.dart
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart
git commit -m "feat(app): ReadyPage shortcuts card"
```

---

### Task 14: Native `HotkeyManager.swift` (Carbon)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/HotkeyManager.swift`

This file owns the Carbon `RegisterEventHotKey` registry and the `InstallEventHandler` dispatcher. It emits events via a closure the plugin sets after attaching its EventChannel sink.

- [ ] **Step 1: Implement the file**

```swift
// packages/screen_recorder_macos/macos/Classes/HotkeyManager.swift
import AppKit
import Carbon.HIToolbox

/// Owns the Carbon hotkey registration + event handler. Wires three fixed
/// hotkeys (Cmd+Shift+1/2/P) and forwards each press through `onAction`.
final class HotkeyManager {
  enum Action: String { case start, stop, pauseToggle }

  /// Set by the plugin after the hotkeys EventChannel sink is attached.
  var onAction: ((Action) -> Void)?
  /// Set similarly for conflict reports.
  var onConflict: ((UInt32) -> Void)?

  private var hotKeyRefs: [EventHotKeyRef?] = []
  private var handlerRef: EventHandlerRef?
  private var registered = false

  func registerAll() {
    if registered { return }
    let signature: OSType = 0x736C7270 /* 'slrp' */
    let modifiers = UInt32(cmdKey | shiftKey)
    let entries: [(UInt32, UInt32, Action)] = [
      (1, UInt32(kVK_ANSI_1), .start),
      (2, UInt32(kVK_ANSI_2), .stop),
      (3, UInt32(kVK_ANSI_P), .pauseToggle),
    ]

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(),
                        { (_, event, ctx) -> OSStatus in
                          guard let ctx = ctx, let event = event else { return noErr }
                          let manager = Unmanaged<HotkeyManager>.fromOpaque(ctx)
                            .takeUnretainedValue()
                          var hkID = EventHotKeyID()
                          let status = GetEventParameter(event,
                                                          EventParamName(kEventParamDirectObject),
                                                          EventParamType(typeEventHotKeyID),
                                                          nil,
                                                          MemoryLayout<EventHotKeyID>.size,
                                                          nil,
                                                          &hkID)
                          if status == noErr {
                            manager.dispatch(id: hkID.id)
                          }
                          return noErr
                        },
                        1,
                        &spec,
                        selfPtr,
                        &handlerRef)

    for (id, keyCode, _) in entries {
      var ref: EventHotKeyRef?
      let hkID = EventHotKeyID(signature: signature, id: id)
      let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                       GetApplicationEventTarget(), 0, &ref)
      if status == noErr {
        hotKeyRefs.append(ref)
      } else {
        onConflict?(id)
      }
    }
    registered = true
  }

  func unregisterAll() {
    for ref in hotKeyRefs { if let ref = ref { UnregisterEventHotKey(ref) } }
    hotKeyRefs.removeAll()
    if let handler = handlerRef { RemoveEventHandler(handler); handlerRef = nil }
    registered = false
  }

  private func dispatch(id: UInt32) {
    switch id {
    case 1: onAction?(.start)
    case 2: onAction?(.stop)
    case 3: onAction?(.pauseToggle)
    default: break
    }
  }
}
```

- [ ] **Step 2: xcodebuild check**

```bash
cd packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/HotkeyManager.swift
git commit -m "feat(macos): HotkeyManager (Carbon RegisterEventHotKey)"
```

---

### Task 15: Native `SleepObserver.swift`

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/SleepObserver.swift`

- [ ] **Step 1: Implement the file**

```swift
// packages/screen_recorder_macos/macos/Classes/SleepObserver.swift
import AppKit

final class SleepObserver {
  enum Event: String { case willSleep, didWake }

  var onEvent: ((Event) -> Void)?

  private var sleepToken: NSObjectProtocol?
  private var wakeToken: NSObjectProtocol?

  /// Idempotent — second call is a no-op.
  func start() {
    if sleepToken != nil { return }
    let center = NSWorkspace.shared.notificationCenter
    sleepToken = center.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main) { [weak self] _ in self?.onEvent?(.willSleep) }
    wakeToken = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main) { [weak self] _ in self?.onEvent?(.didWake) }
  }

  func stop() {
    let center = NSWorkspace.shared.notificationCenter
    if let t = sleepToken { center.removeObserver(t); sleepToken = nil }
    if let t = wakeToken { center.removeObserver(t); wakeToken = nil }
  }
}
```

- [ ] **Step 2: xcodebuild check**

```bash
cd packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/SleepObserver.swift
git commit -m "feat(macos): SleepObserver (NSWorkspace willSleep/didWake)"
```

---

### Task 16: Wire HotkeyManager + SleepObserver through the plugin

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`

- [ ] **Step 1: Add EventChannel + method-name constants**

In `constants.dart`, add to `ScreenRecorderChannels`:
```dart
  static const String hotkeys = 'com.slipreel.screen_recorder/hotkeys';
  static const String sleep = 'com.slipreel.screen_recorder/sleep';
```

In `ScreenRecorderMethods`, add:
```dart
  static const String registerRecordingHotkeys = 'registerRecordingHotkeys';
  static const String unregisterRecordingHotkeys = 'unregisterRecordingHotkeys';
  static const String startSleepObserver = 'startSleepObserver';
```

- [ ] **Step 2: Add fields + EventChannel setup in plugin**

In `ScreenRecorderMacosPlugin.swift`, near the other private properties, add:

```swift
  private let hotkeyManager = HotkeyManager()
  private let sleepObserver = SleepObserver()
  private var hotkeyEventSink: FlutterEventSink?
  private var sleepEventSink: FlutterEventSink?
```

In the `register(with:)` method (the static FlutterPlugin registration), after the existing method channel is created, add two EventChannels:

```swift
    let hotkeysChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/hotkeys",
      binaryMessenger: registrar.messenger)
    let sleepChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/sleep",
      binaryMessenger: registrar.messenger)
    hotkeysChannel.setStreamHandler(instance.hotkeysStreamHandler)
    sleepChannel.setStreamHandler(instance.sleepStreamHandler)
```

Add two private stream-handler properties as `FlutterStreamHandler` instances:

```swift
  private lazy var hotkeysStreamHandler: FlutterStreamHandler = StreamHandler(
    onListen: { [weak self] sink in
      self?.hotkeyEventSink = sink
      self?.hotkeyManager.onAction = { action in
        sink(["action": action.rawValue])
      }
      self?.hotkeyManager.onConflict = { id in
        sink(["event": "conflict", "id": id])
      }
    },
    onCancel: { [weak self] in
      self?.hotkeyEventSink = nil
      self?.hotkeyManager.onAction = nil
      self?.hotkeyManager.onConflict = nil
    })

  private lazy var sleepStreamHandler: FlutterStreamHandler = StreamHandler(
    onListen: { [weak self] sink in
      self?.sleepEventSink = sink
      self?.sleepObserver.onEvent = { event in
        sink(["event": event.rawValue])
      }
    },
    onCancel: { [weak self] in
      self?.sleepEventSink = nil
      self?.sleepObserver.onEvent = nil
    })
```

If `StreamHandler` doesn't exist as a helper, add this small adapter at the bottom of the file:

```swift
private final class StreamHandler: NSObject, FlutterStreamHandler {
  let onListenCb: (@escaping FlutterEventSink) -> Void
  let onCancelCb: () -> Void
  init(onListen: @escaping (@escaping FlutterEventSink) -> Void,
       onCancel: @escaping () -> Void) {
    self.onListenCb = onListen
    self.onCancelCb = onCancel
  }
  func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink)
      -> FlutterError? {
    onListenCb(eventSink); return nil
  }
  func onCancel(withArguments _: Any?) -> FlutterError? {
    onCancelCb(); return nil
  }
}
```

- [ ] **Step 3: Add the three new method-channel cases**

In the `handle(_:result:)` switch, add:

```swift
    case "registerRecordingHotkeys":
      hotkeyManager.registerAll()
      result(nil)

    case "unregisterRecordingHotkeys":
      hotkeyManager.unregisterAll()
      result(nil)

    case "startSleepObserver":
      sleepObserver.start()
      result(nil)
```

- [ ] **Step 4: xcodebuild check**

```bash
cd packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/constants.dart \
        packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(macos): wire HotkeyManager + SleepObserver to method channel"
```

---

### Task 17: macOS Dart facade — hotkey + sleep methods + streams

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`

- [ ] **Step 1: Add abstract surface on the interface**

In `screen_recorder_platform_interface.dart`, add:

```dart
  Future<void> registerRecordingHotkeys() async {}
  Future<void> unregisterRecordingHotkeys() async {}
  Future<void> startSleepObserver() async {}

  /// Hotkey events. Each event is a Map: `{"action": "start"|"stop"|"pauseToggle"}`
  /// or `{"event": "conflict", "id": int}` for registration conflicts.
  Stream<Map<dynamic, dynamic>> get hotkeyEvents => const Stream.empty();

  /// Sleep events. Each event is a Map: `{"event": "willSleep"|"didWake"}`.
  Stream<Map<dynamic, dynamic>> get sleepEvents => const Stream.empty();
```

- [ ] **Step 2: Implement in the macOS Dart facade**

In `screen_recorder_macos_method_channel.dart`, add:

```dart
  static const _hotkeysChannel = EventChannel(ScreenRecorderChannels.hotkeys);
  static const _sleepChannel = EventChannel(ScreenRecorderChannels.sleep);

  @override
  Future<void> registerRecordingHotkeys() async {
    await _recordingChannel.invokeMethod<void>(
        ScreenRecorderMethods.registerRecordingHotkeys);
  }

  @override
  Future<void> unregisterRecordingHotkeys() async {
    await _recordingChannel.invokeMethod<void>(
        ScreenRecorderMethods.unregisterRecordingHotkeys);
  }

  @override
  Future<void> startSleepObserver() async {
    await _recordingChannel.invokeMethod<void>(
        ScreenRecorderMethods.startSleepObserver);
  }

  @override
  Stream<Map<dynamic, dynamic>> get hotkeyEvents =>
      _hotkeysChannel.receiveBroadcastStream().cast<Map<dynamic, dynamic>>();

  @override
  Stream<Map<dynamic, dynamic>> get sleepEvents =>
      _sleepChannel.receiveBroadcastStream().cast<Map<dynamic, dynamic>>();
```

Add the import:
```dart
import 'package:flutter/services.dart';  // (already present likely)
```

- [ ] **Step 3: Run analyzer on both packages**

```bash
cd packages/screen_recorder_platform_interface && flutter analyze --no-fatal-infos
cd ../screen_recorder_macos && flutter analyze --no-fatal-infos
```
Expected: clean both.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
        packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git commit -m "feat(interface,macos): hotkey + sleep streams + method bindings"
```

---

### Task 18: `HotkeyController`

**Files:**
- Create: `packages/screen_recorder/lib/state/hotkey_controller.dart`
- Test: `packages/screen_recorder/test/state/hotkey_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/hotkey_controller_test.dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/hotkey_controller.dart';
import 'package:screen_recorder/state/recording_action_router.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  final _controller = StreamController<Map<dynamic, dynamic>>.broadcast();
  int registerCalls = 0, unregisterCalls = 0;
  @override
  Future<void> registerRecordingHotkeys() async => registerCalls++;
  @override
  Future<void> unregisterRecordingHotkeys() async => unregisterCalls++;
  @override
  Stream<Map<dynamic, dynamic>> get hotkeyEvents => _controller.stream;
  void emit(Map<dynamic, dynamic> e) => _controller.add(e);
}

class _RecordingActions {
  int starts = 0, stops = 0, pauses = 0;
}

class _FakeRouter implements RecordingActionRouter {
  _FakeRouter(this.actions);
  final _RecordingActions actions;
  @override
  Future<void> start(BuildContext _) async => actions.starts++;
  @override
  Future<void> stop() async => actions.stops++;
  @override
  Future<void> pauseOrResume() async => actions.pauses++;
}

void main() {
  test('register on construction; unregister on dispose', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    expect(fake.registerCalls, 1);
    ctrl.dispose();
    expect(fake.unregisterCalls, 1);
  });

  test('start action routes to router.start', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'action': 'start'});
    await Future<void>.delayed(Duration.zero);
    expect(actions.starts, 1);
    ctrl.dispose();
  });

  test('stop action routes to router.stop', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'action': 'stop'});
    await Future<void>.delayed(Duration.zero);
    expect(actions.stops, 1);
    ctrl.dispose();
  });

  test('pauseToggle action routes to pauseOrResume', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'action': 'pauseToggle'});
    await Future<void>.delayed(Duration.zero);
    expect(actions.pauses, 1);
    ctrl.dispose();
  });

  test('conflict events do not throw', () async {
    final fake = _FakePlatform();
    final actions = _RecordingActions();
    final ctrl = HotkeyController(
        platform: fake,
        router: _FakeRouter(actions),
        rootContextProvider: () => null);
    await Future<void>.delayed(Duration.zero);
    fake.emit({'event': 'conflict', 'id': 1});
    await Future<void>.delayed(Duration.zero);
    expect(actions.starts, 0);
    ctrl.dispose();
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/hotkey_controller_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the controller**

```dart
// packages/screen_recorder/lib/state/hotkey_controller.dart
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'recording_action_router.dart';

/// Subscribes to the native hotkey EventChannel and routes events through
/// the RecordingActionRouter.
class HotkeyController {
  HotkeyController({
    required ScreenRecorderPlatform platform,
    required RecordingActionRouter router,
    required BuildContext? Function() rootContextProvider,
  })  : _platform = platform,
        _router = router,
        _rootContextProvider = rootContextProvider {
    _init();
  }

  final ScreenRecorderPlatform _platform;
  final RecordingActionRouter _router;
  final BuildContext? Function() _rootContextProvider;
  StreamSubscription<Map<dynamic, dynamic>>? _sub;

  Future<void> _init() async {
    await _platform.registerRecordingHotkeys();
    _sub = _platform.hotkeyEvents.listen(_onEvent);
  }

  void _onEvent(Map<dynamic, dynamic> event) {
    final action = event['action'] as String?;
    switch (action) {
      case 'start':
        final ctx = _rootContextProvider();
        if (ctx != null) _router.start(ctx);
        break;
      case 'stop':
        _router.stop();
        break;
      case 'pauseToggle':
        _router.pauseOrResume();
        break;
      default:
        final conflict = event['event'];
        if (conflict == 'conflict') {
          AppLogger.platform.w('Hotkey conflict on id ${event['id']}');
        }
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _platform.unregisterRecordingHotkeys();
  }
}

final hotkeyControllerProvider = Provider<HotkeyController>(
  (ref) => throw UnimplementedError(
    'Override hotkeyControllerProvider in main()',
  ),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/hotkey_controller_test.dart
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/hotkey_controller.dart \
        packages/screen_recorder/test/state/hotkey_controller_test.dart
git commit -m "feat(app): HotkeyController"
```

---

### Task 19: `SleepObserver`

**Files:**
- Create: `packages/screen_recorder/lib/state/sleep_observer.dart`
- Test: `packages/screen_recorder/test/state/sleep_observer_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/sleep_observer_test.dart
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
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/sleep_observer_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the observer**

```dart
// packages/screen_recorder/lib/state/sleep_observer.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'recording_action_router.dart';
import 'recording_state.dart';

/// Auto-pauses recording on macOS sleep and surfaces a callback for the
/// on-wake modal. Tracks whether the current pause originated here so manual
/// pauses don't trigger the wake modal.
class SleepObserver {
  SleepObserver({
    required ScreenRecorderPlatform platform,
    required RecordingActionRouter router,
    required ProviderContainer container,
    this.onWake,
  })  : _platform = platform,
        _router = router,
        _container = container {
    _init();
  }

  final ScreenRecorderPlatform _platform;
  final RecordingActionRouter _router;
  final ProviderContainer _container;
  final VoidCallback? onWake;

  StreamSubscription<Map<dynamic, dynamic>>? _sub;
  ProviderSubscription<RecordingState>? _stateSub;

  /// True iff the current paused state was triggered by willSleep.
  bool pausedBySleep = false;

  Future<void> _init() async {
    await _platform.startSleepObserver();
    _sub = _platform.sleepEvents.listen(_onEvent);
    _stateSub = _container.listen(recordingControllerProvider, (prev, next) {
      // Clear flag on any transition OUT of paused.
      if (prev?.status == RecordingStatus.paused &&
          next.status != RecordingStatus.paused) {
        pausedBySleep = false;
      }
    });
  }

  void _onEvent(Map<dynamic, dynamic> event) {
    final kind = event['event'] as String?;
    switch (kind) {
      case 'willSleep':
        final status = _container.read(recordingControllerProvider).status;
        if (status == RecordingStatus.recording) {
          pausedBySleep = true;
          _router.pauseOrResume();
        }
        break;
      case 'didWake':
        if (pausedBySleep) onWake?.call();
        break;
    }
  }

  void dispose() {
    _sub?.cancel();
    _stateSub?.close();
    _sub = null;
    _stateSub = null;
  }
}

final sleepObserverProvider = Provider<SleepObserver>(
  (ref) => throw UnimplementedError(
    'Override sleepObserverProvider in main()',
  ),
);

typedef VoidCallback = void Function();
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/sleep_observer_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/sleep_observer.dart \
        packages/screen_recorder/test/state/sleep_observer_test.dart
git commit -m "feat(app): SleepObserver"
```

---

### Task 20: `WakeModal` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/wake_modal.dart`
- Test: `packages/screen_recorder/test/ui/bar/wake_modal_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/bar/wake_modal_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/wake_modal.dart';

Widget _harness({required Duration auto, required VoidCallback onPrimary,
                  required VoidCallback onSecondary}) {
  return MaterialApp(
    home: Scaffold(
      body: WakeModal(
        title: 'Welcome back',
        body: 'Your recording was paused.',
        primaryLabel: 'Resume',
        secondaryLabel: 'Stop & save',
        autoStopAfter: auto,
        onPrimary: onPrimary,
        onSecondary: onSecondary,
      ),
    ),
  );
}

void main() {
  testWidgets('primary button triggers onPrimary', (tester) async {
    int p = 0, s = 0;
    await tester.pumpWidget(_harness(
        auto: const Duration(seconds: 60),
        onPrimary: () => p++,
        onSecondary: () => s++));
    await tester.tap(find.text('Resume'));
    expect(p, 1);
    expect(s, 0);
  });

  testWidgets('secondary button triggers onSecondary', (tester) async {
    int p = 0, s = 0;
    await tester.pumpWidget(_harness(
        auto: const Duration(seconds: 60),
        onPrimary: () => p++,
        onSecondary: () => s++));
    await tester.tap(find.text('Stop & save'));
    expect(p, 0);
    expect(s, 1);
  });

  testWidgets('auto-stop fires onSecondary after the timeout',
      (tester) async {
    int s = 0;
    await tester.pumpWidget(_harness(
        auto: const Duration(seconds: 2),
        onPrimary: () {},
        onSecondary: () => s++));
    await tester.pump(const Duration(seconds: 3));
    expect(s, 1);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/bar/wake_modal_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the modal**

```dart
// packages/screen_recorder/lib/ui/bar/wake_modal.dart
import 'dart:async';

import 'package:flutter/material.dart';

class WakeModal extends StatefulWidget {
  const WakeModal({
    super.key,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.secondaryLabel,
    required this.autoStopAfter,
    required this.onPrimary,
    required this.onSecondary,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final String secondaryLabel;
  final Duration autoStopAfter;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;

  @override
  State<WakeModal> createState() => _WakeModalState();
}

class _WakeModalState extends State<WakeModal> {
  Timer? _autoTimer;
  late int _remainingSec;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _remainingSec = widget.autoStopAfter.inSeconds;
    _autoTimer = Timer(widget.autoStopAfter, () {
      if (mounted) widget.onSecondary();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remainingSec = (_remainingSec - 1).clamp(0, 1 << 30));
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title),
          if (_remainingSec > 0)
            Text(
              'Auto-stop in ${_remainingSec}s',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
        ],
      ),
      content: Text(widget.body),
      actions: [
        TextButton(
            onPressed: () {
              _autoTimer?.cancel();
              widget.onSecondary();
            },
            child: Text(widget.secondaryLabel)),
        FilledButton(
            onPressed: () {
              _autoTimer?.cancel();
              widget.onPrimary();
            },
            child: Text(widget.primaryLabel)),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/bar/wake_modal_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/wake_modal.dart \
        packages/screen_recorder/test/ui/bar/wake_modal_test.dart
git commit -m "feat(app): WakeModal"
```

---

### Task 21: `RecordingToast` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/recording_toast.dart`
- Test: `packages/screen_recorder/test/ui/bar/recording_toast_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/bar/recording_toast_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_toast.dart';

void main() {
  testWidgets('renders the message and auto-dismisses', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Builder(builder: (ctx) {
        return Scaffold(body: ElevatedButton(
          onPressed: () => RecordingToast.show(ctx, 'Hello toast'),
          child: const Text('go'),
        ));
      }),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('Hello toast'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Hello toast'), findsNothing);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/bar/recording_toast_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the toast**

```dart
// packages/screen_recorder/lib/ui/bar/recording_toast.dart
import 'dart:async';

import 'package:flutter/material.dart';

class RecordingToast {
  static OverlayEntry? _entry;
  static Timer? _dismiss;

  static void show(BuildContext context, String message, {IconData icon = Icons.info_outline}) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry?.remove();
    _dismiss?.cancel();
    final entry = OverlayEntry(builder: (_) => _ToastWidget(message: message, icon: icon));
    _entry = entry;
    overlay.insert(entry);
    _dismiss = Timer(const Duration(seconds: 6), () {
      entry.remove();
      if (_entry == entry) _entry = null;
    });
  }
}

class _ToastWidget extends StatelessWidget {
  const _ToastWidget({required this.message, required this.icon});
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: const Color(0xFF2C2C30),
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(message,
                  style:
                      const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/bar/recording_toast_test.dart
```
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_toast.dart \
        packages/screen_recorder/test/ui/bar/recording_toast_test.dart
git commit -m "feat(app): RecordingToast"
```

---

### Task 22: `LongRecordingWatcher`

**Files:**
- Create: `packages/screen_recorder/lib/state/long_recording_watcher.dart`
- Test: `packages/screen_recorder/test/state/long_recording_watcher_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/long_recording_watcher_test.dart
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
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/long_recording_watcher_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the watcher**

```dart
// packages/screen_recorder/lib/state/long_recording_watcher.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'recording_state.dart';

enum ThresholdAction { toast30, toast60, modal90, hardStop }

class LongRecordingWatcher {
  LongRecordingWatcher({
    required ProviderContainer container,
    required void Function(ThresholdAction) onFire,
  })  : _container = container,
        _onFire = onFire {
    _sub = container.listen(recordingControllerProvider, _onChange);
  }

  final ProviderContainer _container;
  final void Function(ThresholdAction) _onFire;
  ProviderSubscription<RecordingState>? _sub;

  static const _thresholds = <(Duration, ThresholdAction)>[
    (Duration(minutes: 30), ThresholdAction.toast30),
    (Duration(minutes: 60), ThresholdAction.toast60),
    (Duration(minutes: 90), ThresholdAction.modal90),
    (Duration(minutes: 120), ThresholdAction.hardStop),
  ];

  final Set<ThresholdAction> _fired = {};

  void _onChange(RecordingState? prev, RecordingState next) {
    if (next.status == RecordingStatus.idle ||
        next.status == RecordingStatus.error ||
        next.status == RecordingStatus.completed) {
      _fired.clear();
      return;
    }
    for (final entry in _thresholds) {
      if (next.duration >= entry.$1 && !_fired.contains(entry.$2)) {
        _fired.add(entry.$2);
        _onFire(entry.$2);
      }
    }
  }

  void dispose() {
    _sub?.close();
    _sub = null;
  }
}

final longRecordingWatcherProvider = Provider<LongRecordingWatcher>(
  (ref) => throw UnimplementedError(
    'Override longRecordingWatcherProvider in main()',
  ),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/long_recording_watcher_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/long_recording_watcher.dart \
        packages/screen_recorder/test/state/long_recording_watcher_test.dart
git commit -m "feat(app): LongRecordingWatcher"
```

---

### Task 23: Wire everything in `main()` + `MyApp`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

This task wires the new controllers into the app lifecycle. It's the biggest integration task — the others have been small additions.

- [ ] **Step 1: Add the navigator key for routed BuildContext**

In `main.dart`, near other top-level state, add:

```dart
final rootNavigatorKey = GlobalKey<NavigatorState>();
```

In `MyApp`'s `MaterialApp`, pass `navigatorKey: rootNavigatorKey`.

- [ ] **Step 2: Construct stores and controllers in `main()`**

After `tipsController.load()` and before `runApp`, insert:

```dart
  final recordingSettingsStore = RecordingSettingsStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'recording_settings.json',
    ),
  );
  final initialRecordingSettings = await recordingSettingsStore.load();
```

- [ ] **Step 3: Wire all the new providers in the ProviderScope.overrides**

In the `runApp(ProviderScope(overrides: [...]))` block, add:

```dart
      recordingSettingsStoreProvider.overrideWithValue(recordingSettingsStore),
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: recordingSettingsStore, initial: initialRecordingSettings)),
```

Add the imports at top:

```dart
import 'state/recording_settings_store.dart';
import 'state/recording_settings_controller.dart';
import 'state/recording_action_router.dart';
import 'state/hotkey_controller.dart';
import 'state/sleep_observer.dart';
import 'state/long_recording_watcher.dart';
import 'ui/bar/wake_modal.dart';
import 'ui/bar/recording_toast.dart';
```

- [ ] **Step 4: Construct router + observers in `_MyAppState` (not main)**

Router/hotkey/sleep/long-watcher all need a `ProviderContainer` reference, which is naturally available inside `_MyAppState` via `ProviderScope.containerOf(context)`. Update `_MyAppState`:

```dart
class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  RecordingActionRouter? _router;
  HotkeyController? _hotkeyController;
  SleepObserver? _sleepObserver;
  LongRecordingWatcher? _longWatcher;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initRecordingSurfaces());
  }

  void _initRecordingSurfaces() {
    final container = ProviderScope.containerOf(context);
    final router = RecordingActionRouter(container);
    _router = router;
    recordingActionRouterRef = router;
    _hotkeyController = HotkeyController(
      platform: ScreenRecorderPlatform.instance,
      router: router,
      rootContextProvider: () => rootNavigatorKey.currentContext,
    );
    _sleepObserver = SleepObserver(
      platform: ScreenRecorderPlatform.instance,
      router: router,
      container: container,
      onWake: _showWakeModal,
    );
    _longWatcher = LongRecordingWatcher(
      container: container,
      onFire: _onThresholdFire,
    );
  }

  void _showWakeModal() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => WakeModal(
        title: 'Welcome back',
        body: 'Your recording was paused while the Mac slept.',
        primaryLabel: 'Resume',
        secondaryLabel: 'Stop & save',
        autoStopAfter: const Duration(seconds: 10),
        onPrimary: () {
          Navigator.of(ctx).pop();
          _router?.pauseOrResume();
        },
        onSecondary: () {
          Navigator.of(ctx).pop();
          _router?.stop();
        },
      ),
    );
  }

  void _onThresholdFire(ThresholdAction action) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    switch (action) {
      case ThresholdAction.toast30:
        RecordingToast.show(ctx, "You've been recording for 30 minutes");
      case ThresholdAction.toast60:
        RecordingToast.show(ctx, "You've been recording for 60 minutes");
      case ThresholdAction.modal90:
        showDialog<void>(
          context: ctx,
          barrierDismissible: false,
          builder: (_) => WakeModal(
            title: 'Still recording?',
            body: "You've been recording for 90 minutes.",
            primaryLabel: 'Continue recording',
            secondaryLabel: 'Stop & save',
            autoStopAfter: const Duration(seconds: 30),
            onPrimary: () => Navigator.of(ctx).pop(),
            onSecondary: () {
              Navigator.of(ctx).pop();
              _router?.stop();
            },
          ),
        );
      case ThresholdAction.hardStop:
        _router?.stop();
        RecordingToast.show(ctx, "Recording capped at 2 hours and saved");
    }
  }

  @override
  void dispose() {
    _hotkeyController?.dispose();
    _sleepObserver?.dispose();
    _longWatcher?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ... existing didChangeAppLifecycleState + build, unchanged ...
}
```

Do NOT add a `recordingActionRouterProvider.overrideWith(...)` line. The provider stays as the throwing default (it exists so future code can request the router via Riverpod if needed, but right now the only access path is the global `recordingActionRouterRef` set by `_MyAppState._initRecordingSurfaces`). Task 24 wires the bar's `_pickAndRecord` to use that global.

- [ ] **Step 5: Run analyzer + full app test suite**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos && flutter test
```
Expected: clean analyze; full suite green.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(app): wire router + hotkeys + sleep + long-watcher in main"
```

---

### Task 24: Wire `_pickAndRecord` to go through the router (use countdown)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`

The `_pickAndRecord` method currently calls `controller.startRecording(...)` directly. To honor the countdown setting and unify the start path with the hotkey, route through `_router`.

- [ ] **Step 1: Use the global `recordingActionRouterRef` from Task 10**

Task 10 declared `RecordingActionRouter? recordingActionRouterRef;` in `recording_action_router.dart`, and Task 23 sets it in `_MyAppState._initRecordingSurfaces`. The bar reads it directly:

```dart
await recordingActionRouterRef?.start(context);
```

No new field needed on `_RecordingBarScreenState`. If the ref is null (very early frame before MyApp settled), the call is a no-op — safe.

- [ ] **Step 2: Replace the two `startRecording(...)` calls in `_pickAndRecord`**

For BOTH `BarSourceMode.display`/`BarSourceMode.window` AND `BarSourceMode.area` branches, replace:

```dart
final snapshot = ref.read(permissionsControllerProvider);
await controller.startRecording(
    microphone: ref.read(microphoneControllerProvider),
    systemAudio: ref.read(systemAudioControllerProvider),
    permissions: snapshot,
    onDenied: (kind) => PermissionDeniedSheet.show(context, kind));
```

with:

```dart
controller.selectSource(/* same selectSource args as today */);
await recordingActionRouterRef?.start(context);
```

The router internally reads `microphone` / `systemAudio` / `permissions` and calls through `RecordingController.startRecording`. Update `RecordingActionRouter.start` if it doesn't already include the mic/system audio — re-read Task 10's `_doStart` and confirm it includes them. If not, expand:

```dart
Future<void> doStart() async {
  final controller = _container.read(recordingControllerProvider.notifier);
  final snapshot = _container.read(permissionsControllerProvider);
  await controller.startRecording(
    microphone: _container.read(microphoneControllerProvider),
    systemAudio: _container.read(systemAudioControllerProvider),
    permissions: snapshot,
    onDenied: (kind) {
      if (!context.mounted) return Future.value();
      return PermissionDeniedSheet.show(context, kind);
    },
  );
}
```

(Imports for `microphoneControllerProvider` and `systemAudioControllerProvider` in `recording_action_router.dart`.)

- [ ] **Step 3: Add the countdown overlay to the bar's window**

In the recording bar's main widget (where the bar content renders inside the bar window), wrap the existing content in a `Stack` with the `CountdownOverlay` on top:

```dart
return Stack(children: [
  /* existing bar / pill / etc. content */,
  const CountdownOverlay(),
]);
```

Add import:
```dart
import '../widgets/countdown_overlay.dart';
```

- [ ] **Step 4: Run the full app suite**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/lib/state/recording_action_router.dart
git commit -m "feat(app): route _pickAndRecord through router + mount countdown overlay"
```

---

### Task 25: Manual verification + xcodebuild + melos run

This is not a code task — final verification.

- [ ] **Run repo-wide checks:**
  ```bash
  cd /Users/mohn93/Desktop/side_projects/screenflow_studio
  melos run analyze --no-select
  melos run test --no-select
  cd packages/screen_recorder_macos/example/macos && \
    xcodebuild -workspace Runner.xcworkspace -scheme Runner \
               -configuration Debug -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -10
  ```
  Expected: analyze clean (only pre-existing infos), tests green, xcodebuild SUCCEEDED.

- [ ] **Manual on a real Mac:**
  1. Reset onboarding via `ext.slipreel.resetOnboarding`; restart; complete onboarding; verify the ReadyPage shortcuts card renders.
  2. Settings → Recording → flip Countdown between 0/3/5; verify next recording start honors it.
  3. From any focused app, press `Cmd+Shift+1` → countdown overlay appears in the bar → recording starts at "GO!".
  4. Mid-recording: `Cmd+Shift+P` → pill shows Resume button + grey dot + elapsed counter stops. Press again → pulses red and elapsed counter resumes.
  5. Stop a 30-second recording; play back → output MP4 is 30 s with no pause gap (paused interval excluded).
  6. Energy → "Put display to sleep" 1 min, start a recording, wait → wake → modal "Welcome back" with 10 s auto-stop. Verify both Resume and Stop & save paths.
  7. Fake a long recording: pause the device clock or manually set `_durationTimer` to a long offset (or just wait); verify 30 / 60 / 90 / 120 min thresholds each fire correctly.
  8. Verify `Cmd+Shift+2` stops cleanly from both `recording` and `paused`.

---

## Self-review

**Spec coverage:**
- Pause/resume on the writer (PTS rebase) → Task 4 ✓
- Plugin pauseRecording/resumeRecording cases → Task 5 ✓
- Dart facade pause/resume → Task 6 ✓
- RecordingController.pause/resume + duration handling → Task 7 ✓
- Countdown controller + overlay → Tasks 8, 9 ✓
- Settings store + UI → Tasks 2, 3, 12 ✓
- Onboarding ReadyPage shortcuts → Task 13 ✓
- HotkeyManager (native) + HotkeyController (Dart) → Tasks 14, 16, 17, 18 ✓
- SleepObserver (native) + Dart → Tasks 15, 16, 17, 19 ✓
- WakeModal → Task 20 ✓
- RecordingToast → Task 21 ✓
- LongRecordingWatcher → Task 22 ✓
- Lifecycle wiring (main + MyApp) → Task 23 ✓
- _pickAndRecord routed + countdown mounted → Task 24 ✓
- RecordingPill pause/resume button → Task 11 ✓
- RecordingStatus.paused enum → Task 1 ✓
- Final verification → Task 25 ✓

**Placeholder scan:** no TBDs or "implement later" patterns.

**Type consistency:**
- `RecordingStatus.paused` defined Task 1; consumed Tasks 7, 10, 11, 19, 22.
- `RecordingSettings` / `countdownSeconds` defined Task 2; consumed Tasks 3, 10, 12, 23.
- `ThresholdAction` defined Task 22; consumed Task 23.
- `RecordingActionRouter` defined Task 10; consumed Tasks 18, 19, 23, 24.

**Out of scope (per spec):** hotkey remap UI, hotkey conflict UI, per-source countdown, configurable thresholds, paused-state crash recovery (sub-project C), Win/Linux, telemetry. Not in plan; correct.
