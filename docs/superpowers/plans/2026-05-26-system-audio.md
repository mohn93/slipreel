# System Audio Capture (Sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture system/app audio (all-apps or a selected set of apps) as a second AAC track (track 1) in the recorded MP4, alongside the microphone track (track 0), with a live bar control.

**Architecture:** A dedicated audio-only `SCStream` (separate from the video stream) captures system audio via `SCStreamConfiguration.capturesAudio`; its `CMSampleBuffer`s are appended to the existing track-keyed `LiveRecordingWriter` as `role: .system`. The Dart side mirrors the microphone feature end-to-end: a `SystemAudioConfig` model, a `SystemAudioController`, a `RecordingSettings.systemAudio` field, a native `showSystemAudioMenu` NSMenu that chains into a native multi-select app picker, and a `_SystemAudioControl` bar widget.

**Tech Stack:** Flutter (Dart, Riverpod, flutter_test), Swift/ScreenCaptureKit/AVFoundation, method+event channels, fvm-managed Flutter. Min macOS target raised 12.3 → 13.0.

**Reference spec:** `docs/superpowers/specs/2026-05-26-system-audio-design.md`

**Conventions:**
- Run Flutter commands with `fvm flutter ...` from `packages/screen_recorder` (app) or the relevant package dir.
- The app records via the **`startLiveRecording`** path (NOT the legacy `startRecording`).
- `LiveRecordingWriter` already has `AudioTrackRole { microphone, system }`, `appendAudio(_:role:)`, and stereo/48k AAC settings for `.system` — **do not modify it**.
- Never `git add -A` (untracked `DerivedData/` churn). Stage explicit paths.
- Never push.

---

## File Structure

**New files:**
- `packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart` — `SystemAudioMode`, `SystemAudioConfig`, `SystemAudioMenuResult`.
- `packages/screen_recorder_platform_interface/test/models/system_audio_config_test.dart`
- `packages/screen_recorder/lib/state/system_audio_controller.dart`
- `packages/screen_recorder/test/state/system_audio_controller_test.dart`
- `packages/screen_recorder_macos/macos/Classes/SystemAudioCaptureManager.swift`
- `packages/screen_recorder_macos/macos/Classes/SystemAudioAppPicker.swift`

**Modified files:**
- `packages/screen_recorder/macos/Podfile`, `.../macos/Runner.xcodeproj/project.pbxproj`, `packages/screen_recorder_macos/macos/screen_recorder_macos.podspec` — deployment target 13.0.
- `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart` — `systemAudio` field.
- `packages/screen_recorder_platform_interface/lib/src/constants.dart` — `showSystemAudioMenu` method name.
- `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` — `showSystemAudioMenu` abstract method.
- `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` — `showSystemAudioMenu` impl.
- `packages/screen_recorder/lib/state/recording_state.dart` — thread `systemAudio` into `startRecording`/`RecordingSettings`.
- `packages/screen_recorder/lib/ui/bar/recording_bar.dart` — `_SystemAudioControl` + `RecordingBar.systemAudio`/`onSystemAudioTap` params.
- `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` — `_onSystemAudioTap`, pass `systemAudio` to `startRecording`.
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` — `showSystemAudioMenu` handler, `startLiveRecording`/`stopLiveRecording`/`tearDownPartialLiveRecording` wiring.
- `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (barrel) — export `system_audio_config.dart` if models are individually exported.

---

## Task 1: Raise macOS deployment target to 13.0

**Files:**
- Modify: `packages/screen_recorder/macos/Podfile`
- Modify: `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj`
- Modify: `packages/screen_recorder_macos/macos/screen_recorder_macos.podspec`

- [ ] **Step 1: Find the current target declarations**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
grep -rn "12.3\|MACOSX_DEPLOYMENT_TARGET\|platform :osx\|s.platform" \
  packages/screen_recorder/macos/Podfile \
  packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj \
  packages/screen_recorder_macos/macos/screen_recorder_macos.podspec
```
Expected: a `platform :osx, '12.3'` (or similar) in the Podfile, `MACOSX_DEPLOYMENT_TARGET = 12.3;` lines in the pbxproj, and `s.platform = :osx, '12.3'` in the podspec.

- [ ] **Step 2: Edit Podfile**

In `packages/screen_recorder/macos/Podfile`, change the platform line to:
```ruby
platform :osx, '13.0'
```
If there is a `post_install` block that sets `config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '12.3'`, change it to `'13.0'`.

- [ ] **Step 3: Edit the Xcode project**

In `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj`, replace every `MACOSX_DEPLOYMENT_TARGET = 12.3;` with `MACOSX_DEPLOYMENT_TARGET = 13.0;` (there are typically 3 — Debug, Release, Profile).

- [ ] **Step 4: Edit the plugin podspec**

In `packages/screen_recorder_macos/macos/screen_recorder_macos.podspec`, change:
```ruby
s.platform = :osx, '13.0'
```
(was `'12.3'`).

- [ ] **Step 5: Reinstall pods and verify the build**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/macos
pod install
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter build macos --debug 2>&1 | tail -20
```
Expected: build succeeds (no deployment-target warnings). If `pod install` complains it's not in a workspace dir, run it from `packages/screen_recorder/macos` as shown.

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/macos/Podfile \
        packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj \
        packages/screen_recorder_macos/macos/screen_recorder_macos.podspec \
        packages/screen_recorder/macos/Podfile.lock
git commit -m "build(macos): raise deployment target 12.3 -> 13.0 for system audio"
```

---

## Task 2: `SystemAudioConfig` model

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart`
- Test: `packages/screen_recorder_platform_interface/test/models/system_audio_config_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_platform_interface/test/models/system_audio_config_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/system_audio_config.dart';

void main() {
  group('SystemAudioConfig', () {
    test('allApps round-trips through JSON', () {
      const c = SystemAudioConfig(mode: SystemAudioMode.allApps);
      final json = c.toJson();
      expect(json, {'mode': 'allApps', 'bundleIds': <String>[]});
      expect(SystemAudioConfig.fromJson(json), c);
    });

    test('selectedApps round-trips with bundleIds', () {
      const c = SystemAudioConfig(
        mode: SystemAudioMode.selectedApps,
        bundleIds: ['com.apple.Music', 'com.tinyspeck.slackmacgap'],
      );
      expect(SystemAudioConfig.fromJson(c.toJson()), c);
    });

    test('equality is order-insensitive for bundleIds', () {
      const a = SystemAudioConfig(
        mode: SystemAudioMode.selectedApps, bundleIds: ['a', 'b']);
      const b = SystemAudioConfig(
        mode: SystemAudioMode.selectedApps, bundleIds: ['b', 'a']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith replaces fields', () {
      const c = SystemAudioConfig(mode: SystemAudioMode.allApps);
      final d = c.copyWith(
        mode: SystemAudioMode.selectedApps, bundleIds: ['x']);
      expect(d.mode, SystemAudioMode.selectedApps);
      expect(d.bundleIds, ['x']);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_platform_interface
fvm flutter test test/models/system_audio_config_test.dart
```
Expected: FAIL — `system_audio_config.dart` does not exist.

- [ ] **Step 3: Write the model**

Create `packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart`:
```dart
/// Which apps' system audio to capture.
enum SystemAudioMode { allApps, selectedApps }

/// A system-audio capture selection. `null` (absence of this config) means
/// "don't record system audio". For [SystemAudioMode.allApps], [bundleIds] is
/// empty; for [SystemAudioMode.selectedApps] it holds the chosen app bundle ids.
class SystemAudioConfig {
  final SystemAudioMode mode;
  final List<String> bundleIds;

  const SystemAudioConfig({required this.mode, this.bundleIds = const []});

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'bundleIds': bundleIds,
      };

  factory SystemAudioConfig.fromJson(Map<String, dynamic> json) =>
      SystemAudioConfig(
        mode: SystemAudioMode.values.byName(json['mode'] as String),
        bundleIds:
            (json['bundleIds'] as List?)?.cast<String>() ?? const <String>[],
      );

  SystemAudioConfig copyWith({SystemAudioMode? mode, List<String>? bundleIds}) =>
      SystemAudioConfig(
        mode: mode ?? this.mode,
        bundleIds: bundleIds ?? this.bundleIds,
      );

  @override
  bool operator ==(Object other) =>
      other is SystemAudioConfig &&
      other.mode == mode &&
      _setEquals(other.bundleIds, bundleIds);

  @override
  int get hashCode => Object.hash(mode, Object.hashAllUnordered(bundleIds));

  @override
  String toString() => 'SystemAudioConfig($mode, ${bundleIds.length} apps)';

  static bool _setEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return a.toSet().containsAll(b);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_platform_interface
fvm flutter test test/models/system_audio_config_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart \
        packages/screen_recorder_platform_interface/test/models/system_audio_config_test.dart
git commit -m "feat(model): SystemAudioConfig + SystemAudioMode"
```

---

## Task 3: `SystemAudioMenuResult`

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart`
- Test: `packages/screen_recorder_platform_interface/test/models/system_audio_config_test.dart`

- [ ] **Step 1: Add failing tests**

Append inside `main()` in `system_audio_config_test.dart`:
```dart
  group('SystemAudioMenuResult', () {
    test('decodes a cancelled result', () {
      final r = SystemAudioMenuResult.fromJson(
          {'cancelled': true, 'config': null});
      expect(r.cancelled, isTrue);
      expect(r.config, isNull);
    });

    test('decodes an off (null config) result', () {
      final r = SystemAudioMenuResult.fromJson(
          {'cancelled': false, 'config': null});
      expect(r.cancelled, isFalse);
      expect(r.config, isNull);
    });

    test('decodes a selected-apps config', () {
      final r = SystemAudioMenuResult.fromJson({
        'cancelled': false,
        'config': {'mode': 'selectedApps', 'bundleIds': ['com.apple.Music']},
      });
      expect(r.cancelled, isFalse);
      expect(r.config,
          const SystemAudioConfig(
              mode: SystemAudioMode.selectedApps,
              bundleIds: ['com.apple.Music']));
    });
  });
```

Add the import already present (`system_audio_config.dart` exports `SystemAudioMenuResult` from the same file).

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_platform_interface
fvm flutter test test/models/system_audio_config_test.dart
```
Expected: FAIL — `SystemAudioMenuResult` undefined.

- [ ] **Step 3: Add `SystemAudioMenuResult`**

Append to `system_audio_config.dart`:
```dart
/// Result of the native system-audio menu. [cancelled] true means the user
/// dismissed it (no change). When not cancelled, [config] is the new selection,
/// or null for "Don't record system audio".
class SystemAudioMenuResult {
  final bool cancelled;
  final SystemAudioConfig? config;

  const SystemAudioMenuResult({required this.cancelled, this.config});

  factory SystemAudioMenuResult.fromJson(Map<String, dynamic> json) {
    final c = json['config'];
    return SystemAudioMenuResult(
      cancelled: json['cancelled'] as bool? ?? false,
      config: c == null
          ? null
          : SystemAudioConfig.fromJson(Map<String, dynamic>.from(c as Map)),
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_platform_interface
fvm flutter test test/models/system_audio_config_test.dart
```
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart \
        packages/screen_recorder_platform_interface/test/models/system_audio_config_test.dart
git commit -m "feat(model): SystemAudioMenuResult"
```

---

## Task 4: `SystemAudioController`

**Files:**
- Create: `packages/screen_recorder/lib/state/system_audio_controller.dart`
- Test: `packages/screen_recorder/test/state/system_audio_controller_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/system_audio_controller_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/system_audio_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('starts off, then transitions all -> selected -> off', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(systemAudioControllerProvider.notifier);

    expect(container.read(systemAudioControllerProvider), isNull);

    notifier.set(const SystemAudioConfig(mode: SystemAudioMode.allApps));
    expect(container.read(systemAudioControllerProvider)!.mode,
        SystemAudioMode.allApps);

    notifier.set(const SystemAudioConfig(
        mode: SystemAudioMode.selectedApps, bundleIds: ['com.apple.Music']));
    expect(container.read(systemAudioControllerProvider)!.bundleIds,
        ['com.apple.Music']);

    notifier.set(null);
    expect(container.read(systemAudioControllerProvider), isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/state/system_audio_controller_test.dart
```
Expected: FAIL — `system_audio_controller.dart` does not exist.

- [ ] **Step 3: Write the controller**

Create `packages/screen_recorder/lib/state/system_audio_controller.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current system-audio selection (null = "don't record system
/// audio"). In-memory only — resets to off each launch, mirroring
/// [microphoneControllerProvider].
class SystemAudioController extends StateNotifier<SystemAudioConfig?> {
  SystemAudioController() : super(null);

  void set(SystemAudioConfig? config) {
    if (config != state) state = config;
  }
}

final systemAudioControllerProvider =
    StateNotifierProvider<SystemAudioController, SystemAudioConfig?>(
        (ref) => SystemAudioController());
```

> If the import `package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart` does not re-export `SystemAudioConfig`, add `export 'src/models/system_audio_config.dart';` to that barrel file (check Task 5 Step 3) — it must be exported for both this controller and `RecordingSettings`.

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/state/system_audio_controller_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/state/system_audio_controller.dart \
        packages/screen_recorder/test/state/system_audio_controller_test.dart
git commit -m "feat(state): SystemAudioController"
```

---

## Task 5: `RecordingSettings.systemAudio` + barrel export

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (barrel; export the new model)
- Test: `packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart` (create if absent)

- [ ] **Step 1: Write the failing test**

Create or append `packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/recording_settings.dart';
import 'package:screen_recorder_platform_interface/src/models/system_audio_config.dart';

void main() {
  test('toJson includes systemAudio when set, null when off', () {
    const withSys = RecordingSettings(
      source: RecordingSource.screen,
      systemAudio: SystemAudioConfig(mode: SystemAudioMode.allApps),
    );
    expect(withSys.toJson()['systemAudio'],
        {'mode': 'allApps', 'bundleIds': <String>[]});

    const off = RecordingSettings(source: RecordingSource.screen);
    expect(off.toJson()['systemAudio'], isNull);
  });

  test('fromJson restores systemAudio', () {
    const c = RecordingSettings(
      source: RecordingSource.screen,
      systemAudio: SystemAudioConfig(
          mode: SystemAudioMode.selectedApps, bundleIds: ['com.apple.Music']),
    );
    final restored = RecordingSettings.fromJson(c.toJson());
    expect(restored.systemAudio, c.systemAudio);
  });

  test('copyWith replaces systemAudio', () {
    const c = RecordingSettings(source: RecordingSource.screen);
    final d = c.copyWith(
        systemAudio: const SystemAudioConfig(mode: SystemAudioMode.allApps));
    expect(d.systemAudio!.mode, SystemAudioMode.allApps);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_platform_interface
fvm flutter test test/models/recording_settings_test.dart
```
Expected: FAIL — `systemAudio` is not a parameter of `RecordingSettings`.

- [ ] **Step 3: Add the field**

In `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart`:

Add the import at the top:
```dart
import 'system_audio_config.dart';
```
Add the field after `microphone` (line ~10):
```dart
  /// The system-audio selection, or null for "don't record system audio".
  final SystemAudioConfig? systemAudio;
```
Add to the constructor (after `this.microphone,`):
```dart
    this.systemAudio,
```
Add to `toJson()` (after the `'microphone'` line):
```dart
      'systemAudio': systemAudio?.toJson(),
```
Add to `fromJson` — before the `return`:
```dart
    final sys = json['systemAudio'];
```
and inside the returned `RecordingSettings(...)` (after `microphone:` block):
```dart
      systemAudio: sys == null
          ? null
          : SystemAudioConfig.fromJson(Map<String, dynamic>.from(sys as Map)),
```
Add to `copyWith` signature (after `MicrophoneConfig? microphone,`):
```dart
    SystemAudioConfig? systemAudio,
```
and to its body (after `microphone: microphone ?? this.microphone,`):
```dart
      systemAudio: systemAudio ?? this.systemAudio,
```

- [ ] **Step 4: Export the model from the barrel**

In `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`, add next to the other model exports:
```dart
export 'src/models/system_audio_config.dart';
```
(If the barrel exports models via a single `src/models.dart` aggregator, add the export there instead — match the existing pattern for `microphone_config.dart`.)

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_platform_interface
fvm flutter test test/models/recording_settings_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart \
        packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart \
        packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart
git commit -m "feat(model): RecordingSettings.systemAudio"
```

---

## Task 6: Platform interface + method channel `showSystemAudioMenu`

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Test: `packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside `main()` in `packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart` (mirror the existing `showMicrophoneMenu` test in that file — match its mock-channel setup):
```dart
  test('showSystemAudioMenu sends current and decodes the result', () async {
    final platform = MethodChannelScreenRecorderMacos();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      // Use the SAME channel the existing showMicrophoneMenu test uses.
      const MethodChannel('screen_recorder_macos/recording'),
      (call) async {
        calls.add(call);
        if (call.method == 'showSystemAudioMenu') {
          return <String, dynamic>{
            'cancelled': false,
            'config': {'mode': 'allApps', 'bundleIds': <String>[]},
          };
        }
        return null;
      },
    );

    final result = await platform.showSystemAudioMenu(
        const SystemAudioConfig(mode: SystemAudioMode.selectedApps,
            bundleIds: ['com.apple.Music']));

    expect(calls.single.method, 'showSystemAudioMenu');
    expect(calls.single.arguments,
        {'mode': 'selectedApps', 'bundleIds': ['com.apple.Music']});
    expect(result.cancelled, isFalse);
    expect(result.config!.mode, SystemAudioMode.allApps);
  });
```
Ensure the file imports `package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart`.

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_macos
fvm flutter test test/screen_recorder_macos_method_channel_test.dart
```
Expected: FAIL — `showSystemAudioMenu` not defined.

- [ ] **Step 3: Add the method-name constant**

In `packages/screen_recorder_platform_interface/lib/src/constants.dart`, after `showMicrophoneMenu`:
```dart
  static const String showSystemAudioMenu = 'showSystemAudioMenu';
```

- [ ] **Step 4: Add the abstract method**

In `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`, after the `showMicrophoneMenu` declaration (~line 183):
```dart
  /// Shows the native system-audio NSMenu (and, for "selected apps", the app
  /// picker). Returns the chosen selection, or a cancelled result.
  Future<SystemAudioMenuResult> showSystemAudioMenu(SystemAudioConfig? current) {
    throw UnsupportedError('showSystemAudioMenu() is not supported on this platform.');
  }
```
Make sure `SystemAudioConfig`/`SystemAudioMenuResult` are imported/exported in this file's scope (they are via the barrel/model export added in Task 5).

- [ ] **Step 5: Implement on the method channel**

In `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`, after the `showMicrophoneMenu` override (~line 252):
```dart
  @override
  Future<SystemAudioMenuResult> showSystemAudioMenu(
      SystemAudioConfig? current) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.showSystemAudioMenu,
      current?.toJson(),
    );
    if (raw == null) {
      return const SystemAudioMenuResult(cancelled: true);
    }
    return SystemAudioMenuResult.fromJson(raw);
  }
```

- [ ] **Step 6: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_macos
fvm flutter test test/screen_recorder_macos_method_channel_test.dart
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_platform_interface/lib/src/constants.dart \
        packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
        packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart \
        packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart
git commit -m "feat(channel): showSystemAudioMenu platform method"
```

---

## Task 7: Thread `systemAudio` through `RecordingController.startRecording`

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart:106-129`
- Test: `packages/screen_recorder/test/state/recording_controller_systemaudio_test.dart` (create)

**Context:** `startRecording` currently builds `RecordingSettings(... microphone: microphone ...)` from a `{MicrophoneConfig? microphone}` param. Add a `SystemAudioConfig? systemAudio` param and pass it into the settings. Verifying the exact settings reaches the platform requires a platform mock; the cheapest reliable test asserts the constructed `RecordingSettings` carries `systemAudio`. Since `startRecording` builds settings internally, extract the settings construction into a testable seam OR assert via a fake platform. Use the fake-platform approach below (mirrors existing recording tests).

- [ ] **Step 1: Write the failing test**

Look at an existing recording-controller test (e.g. `packages/screen_recorder/test/state/`) to copy its fake `ScreenRecorderPlatform` setup. Create `recording_controller_systemaudio_test.dart` capturing the `RecordingSettings` passed to `startLiveRecording`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
// + your project's fake platform + ProviderContainer setup (copy from the
//   existing recording controller test in this dir).

void main() {
  test('startRecording forwards systemAudio into RecordingSettings', () async {
    // Arrange: install a fake ScreenRecorderPlatform that records the
    // `settings` passed to startLiveRecording into `captured`.
    // Select a source so canStartRecording is satisfied, then:
    await controller.startRecording(
      microphone: null,
      systemAudio: const SystemAudioConfig(mode: SystemAudioMode.allApps),
    );
    expect(captured!.systemAudio,
        const SystemAudioConfig(mode: SystemAudioMode.allApps));
  });
}
```
(Fill the arrange section by copying the fake-platform + source-selection boilerplate from the nearest existing recording controller test. The behavioral assertion — `captured!.systemAudio` — is the part under test.)

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/state/recording_controller_systemaudio_test.dart
```
Expected: FAIL — `startRecording` has no `systemAudio` parameter.

- [ ] **Step 3: Add the parameter and thread it**

In `packages/screen_recorder/lib/state/recording_state.dart`, change the signature (line 106):
```dart
  Future<void> startRecording({
    MicrophoneConfig? microphone,
    SystemAudioConfig? systemAudio,
  }) async {
```
and the `RecordingSettings(...)` construction (line 123):
```dart
      final settings = RecordingSettings(
        source: state.selectedSourceKind!,
        sourceId: state.selectedSourceId,
        frameRate: _defaultFps,
        microphone: microphone,
        systemAudio: systemAudio,
        captureCursor: true,
      );
```
Ensure `SystemAudioConfig` is imported (it comes via the platform-interface barrel already imported in this file).

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/state/recording_controller_systemaudio_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/test/state/recording_controller_systemaudio_test.dart
git commit -m "feat(state): thread systemAudio into startRecording"
```

---

## Task 8: `_SystemAudioControl` bar widget

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Test: `packages/screen_recorder/test/ui/bar/system_audio_control_test.dart` (create)

**Context:** Mirror `_MicControl` (recording_bar.dart:225-305). The widget shows a speaker icon, a label, and a chevron, in the same fixed-width chip with the hover-brighten `TweenAnimationBuilder`. Label rules: off → "No system audio"; allApps → "System audio"; selectedApps with 1 app → that app's bundle id's display (use the last dotted segment as a fallback label — the bar only has bundleIds, so show "1 app"/"N apps" for selected mode to avoid needing names). Final decision: selectedApps → "N app(s)" (count-based; we don't carry names in config). Icon: `LucideIcons.volume2` when on, `LucideIcons.volumeOff` when off.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/ui/bar/system_audio_control_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  Widget host(SystemAudioConfig? cfg) => MaterialApp(
        home: Scaffold(
          body: SystemAudioControlForTest(systemAudio: cfg, onTap: () {}),
        ),
      );

  testWidgets('off shows "No system audio"', (t) async {
    await t.pumpWidget(host(null));
    expect(find.text('No system audio'), findsOneWidget);
  });

  testWidgets('all apps shows "System audio"', (t) async {
    await t.pumpWidget(
        host(const SystemAudioConfig(mode: SystemAudioMode.allApps)));
    expect(find.text('System audio'), findsOneWidget);
  });

  testWidgets('selected apps shows the count', (t) async {
    await t.pumpWidget(host(const SystemAudioConfig(
        mode: SystemAudioMode.selectedApps,
        bundleIds: ['a', 'b', 'c'])));
    expect(find.text('3 apps'), findsOneWidget);
  });
}
```

> The test references `SystemAudioControlForTest` — expose the private `_SystemAudioControl` for testing by adding a thin public wrapper at the bottom of `recording_bar.dart`:
> ```dart
> @visibleForTesting
> class SystemAudioControlForTest extends StatelessWidget {
>   const SystemAudioControlForTest({super.key, this.systemAudio, required this.onTap});
>   final SystemAudioConfig? systemAudio;
>   final VoidCallback onTap;
>   @override
>   Widget build(BuildContext context) =>
>       _SystemAudioControl(systemAudio: systemAudio, onTap: onTap);
> }
> ```
> (Add `import 'package:flutter/foundation.dart';` for `@visibleForTesting` if not present.)

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/ui/bar/system_audio_control_test.dart
```
Expected: FAIL — `SystemAudioControlForTest` / `_SystemAudioControl` undefined.

- [ ] **Step 3: Implement `_SystemAudioControl`**

In `packages/screen_recorder/lib/ui/bar/recording_bar.dart`, add the import if missing (`SystemAudioConfig` comes via `screen_recorder_platform_interface`), and add this class near `_MicControl`:
```dart
/// System-audio control: speaker icon + label + chevron, mirroring [_MicControl]
/// (fixed-width chip, hover-brighten). Greyed when off. Tapping opens the native
/// system-audio menu via [onTap].
class _SystemAudioControl extends StatefulWidget {
  const _SystemAudioControl({required this.systemAudio, required this.onTap});

  final SystemAudioConfig? systemAudio;
  final VoidCallback onTap;

  @override
  State<_SystemAudioControl> createState() => _SystemAudioControlState();
}

class _SystemAudioControlState extends State<_SystemAudioControl> {
  bool _hover = false;

  String get _label {
    final cfg = widget.systemAudio;
    if (cfg == null) return 'No system audio';
    switch (cfg.mode) {
      case SystemAudioMode.allApps:
        return 'System audio';
      case SystemAudioMode.selectedApps:
        final n = cfg.bundleIds.length;
        return n == 1 ? '1 app' : '$n apps';
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.systemAudio != null;
    final active = on || _hover;
    return SpringHoverButton(
      key: const Key('bar-system-audio'),
      onTap: widget.onTap,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: SizedBox(
        width: _kMicChipWidth,
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: active ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            builder: (context, t, _) {
              final color = Color.lerp(
                  const Color(0xFF6E6E76), const Color(0xFFE9E9EC), t)!;
              return Row(
                children: [
                  Icon(on ? LucideIcons.volume2 : LucideIcons.volumeOff,
                      size: 22, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        textAlign: TextAlign.left,
                        style: TextStyle(fontSize: 12, color: color)),
                  ),
                  const SizedBox(width: 2),
                  const Icon(LucideIcons.chevronDown,
                      size: 13, color: Color(0xFF7E7E86)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
```
Also add the `SystemAudioControlForTest` wrapper from Step 1's note.

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/ui/bar/system_audio_control_test.dart
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/test/ui/bar/system_audio_control_test.dart
git commit -m "feat(bar): _SystemAudioControl widget"
```

---

## Task 9: Wire the control into the bar + screen

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart` (replace the `_AvPlaceholder('No system audio')`, add `RecordingBar` params)
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` (`_onSystemAudioTap`, pass `systemAudio` to `startRecording`, pass to `RecordingBar`)
- Test: `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart` (extend)

- [ ] **Step 1: Write the failing test**

In `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`, add a test that the system-audio chip is present and tappable (mirror the existing `bar-mic` test in that file):
```dart
  testWidgets('renders the system-audio control', (tester) async {
    // ... pump the bar screen exactly like the existing mic test does ...
    expect(find.byKey(const Key('bar-system-audio')), findsOneWidget);
    // The old disabled placeholder text should be gone:
    expect(find.text('No system audio'), findsOneWidget); // now the live control's label
  });
```
(Reuse the screen-pumping harness already in that file. If the harness installs a fake platform, add a `showSystemAudioMenu` stub returning `SystemAudioMenuResult(cancelled: true)` so a tap is safe.)

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/ui/bar/recording_bar_screen_test.dart
```
Expected: FAIL — no widget with key `bar-system-audio` (still the disabled placeholder).

- [ ] **Step 3: Add `RecordingBar` params and swap the placeholder**

In `recording_bar.dart`, add to `RecordingBar`'s constructor + fields (next to `microphone`/`onMicTap`):
```dart
    this.systemAudio,
    required this.onSystemAudioTap,
```
```dart
  /// Current system-audio selection (null = off).
  final SystemAudioConfig? systemAudio;

  /// Fired when the system-audio control is tapped (opens the native menu).
  final VoidCallback onSystemAudioTap;
```
Replace the line:
```dart
            const _AvPlaceholder(icon: LucideIcons.volumeOff, label: 'No system audio'),
```
with:
```dart
            _SystemAudioControl(
                systemAudio: systemAudio, onTap: onSystemAudioTap),
```

- [ ] **Step 4: Wire the screen**

In `recording_bar_screen.dart`:

Add the import:
```dart
import '../../state/system_audio_controller.dart';
```
Add the tap handler (next to `_onMicTap`, ~line 155):
```dart
  Future<void> _onSystemAudioTap() async {
    final current = ref.read(systemAudioControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showSystemAudioMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(systemAudioControllerProvider.notifier).set(result.config);
  }
```
In `_buildBar()` (the `RecordingBar(...)` construction, ~line 122), add:
```dart
        systemAudio: ref.watch(systemAudioControllerProvider),
        onSystemAudioTap: _onSystemAudioTap,
```
In `_pickAndRecord` (the two `controller.startRecording(microphone: ...)` calls, lines 105 and 115), pass system audio too:
```dart
        await controller.startRecording(
            microphone: ref.read(microphoneControllerProvider),
            systemAudio: ref.read(systemAudioControllerProvider));
```
(apply to both call sites).

- [ ] **Step 5: Run to verify it passes**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter test test/ui/bar/recording_bar_screen_test.dart
```
Expected: PASS. Then run the full app suite to catch any `RecordingBar` constructor breakages elsewhere:
```bash
fvm flutter test 2>&1 | tail -5
```
Expected: all pass (fix any other `RecordingBar(...)` call sites that now need `onSystemAudioTap`).

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart
git commit -m "feat(bar): wire system-audio control + menu + startRecording"
```

---

## Task 10: Native `SystemAudioCaptureManager.swift`

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/SystemAudioCaptureManager.swift`

**Context:** Mirrors `AudioCaptureManager`'s callback shape (`onSampleBufferReceived: ((CMSampleBuffer) -> Void)?`) but sources from a dedicated audio-only `SCStream`. Not unit-testable; verified by build + manual ffprobe (Task 13).

- [ ] **Step 1: Write the manager**

Create `packages/screen_recorder_macos/macos/Classes/SystemAudioCaptureManager.swift`:
```swift
import Foundation
import ScreenCaptureKit
import CoreMedia

/// Capture mode for system audio.
enum SystemAudioMode: String { case allApps, selectedApps }

/// Captures system/app audio via a DEDICATED audio-only SCStream, independent
/// of the video capture stream, so the audio app-scope is decoupled from what
/// video is being recorded. Emits CMSampleBuffers via `onSampleBufferReceived`.
/// macOS 13.0+ (capturesAudio / excludesCurrentProcessAudio).
@available(macOS 13.0, *)
final class SystemAudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
  var onSampleBufferReceived: ((CMSampleBuffer) -> Void)?

  private var stream: SCStream?
  private let audioQueue = DispatchQueue(label: "com.slipreel.systemaudio")

  /// Start capturing. `mode == .selectedApps` uses `bundleIds`; if no running
  /// app matches, throws (caller treats system audio as unavailable and drops
  /// the track — recording continues).
  func start(mode: SystemAudioMode, bundleIds: [String]) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      throw NSError(domain: "SystemAudioCaptureManager", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "no display available"])
    }

    let filter: SCContentFilter
    switch mode {
    case .allApps:
      filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
    case .selectedApps:
      let chosen = content.applications.filter {
        bundleIds.contains($0.bundleIdentifier)
      }
      guard !chosen.isEmpty else {
        throw NSError(domain: "SystemAudioCaptureManager", code: -2,
          userInfo: [NSLocalizedDescriptionKey: "no selected app is running"])
      }
      filter = SCContentFilter(
        display: display, including: chosen, exceptingWindows: [])
    }

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    // We never consume video; keep the dummy video tiny.
    config.width = 2
    config.height = 2

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() {
    stream?.stopCapture { _ in }
    stream = nil
  }

  // MARK: SCStreamOutput
  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    onSampleBufferReceived?(sampleBuffer)
  }

  // MARK: SCStreamDelegate
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    NSLog("SystemAudioCaptureManager: stream stopped: \(error)")
  }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter build macos --debug 2>&1 | tail -20
```
Expected: build succeeds. (The file isn't referenced yet, but it must compile. Note: a SourceKit "cannot find X in scope" warning in the editor is a known false positive — trust the real build.)

- [ ] **Step 3: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_macos/macos/Classes/SystemAudioCaptureManager.swift
git commit -m "feat(macos): SystemAudioCaptureManager (dedicated audio SCStream)"
```

---

## Task 11: Wire system audio into the native recording lifecycle

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (`startLiveRecording` ~542-665, `stopLiveRecording`, `tearDownPartialLiveRecording`)

**Context:** Add a stored `systemAudioManager`, decode `systemAudio` args, include `.system` in the writer's `audioTracks`, start the manager after the mic block, and stop it on teardown/stop.

- [ ] **Step 1: Add the stored property**

Near `private var audioCaptureManager: AudioCaptureManager?` (line ~12), add:
```swift
  private var systemAudioManager: Any?  // SystemAudioCaptureManager (gated to macOS 13+)
```
(`Any?` avoids an availability annotation on the stored property; cast at use.)

- [ ] **Step 2: Decode args + compute roles**

In `startLiveRecording`, after `let micArgs = args["microphone"] as? [String: Any]` (line ~553) add:
```swift
    let sysArgs = args["systemAudio"] as? [String: Any]   // nil → don't record system audio
    let captureSystem = sysArgs != nil
```
Change the writer's `audioTracks` (line ~617) from `audioTracks: captureMic ? [.microphone] : []` to:
```swift
        audioTracks: {
          var roles: [AudioTrackRole] = []
          if captureMic { roles.append(.microphone) }
          if captureSystem { roles.append(.system) }
          return roles
        }(),
```

- [ ] **Step 3: Start the system manager after the mic block**

Immediately after the mic `if let mic = micArgs { ... }` block (ends ~line 653), add:
```swift
        if let sys = sysArgs, #available(macOS 13.0, *) {
          let modeStr = sys["mode"] as? String ?? "allApps"
          let mode = SystemAudioMode(rawValue: modeStr) ?? .allApps
          let bundleIds = (sys["bundleIds"] as? [String]) ?? []
          let manager = SystemAudioCaptureManager()
          manager.onSampleBufferReceived = { [weak writer] sb in
            writer?.appendAudio(sb, role: .system)
          }
          do {
            try await manager.start(mode: mode, bundleIds: bundleIds)
            self.systemAudioManager = manager
          } catch {
            // Degrade gracefully: drop the system track, keep recording.
            NSLog("System audio capture failed to start: \(error)")
          }
        }
```

- [ ] **Step 4: Stop on teardown + stop**

In `stopLiveRecording` (where `audioCaptureManager` is stopped/cleared) add:
```swift
        if #available(macOS 13.0, *),
           let sysMgr = self.systemAudioManager as? SystemAudioCaptureManager {
          sysMgr.stop()
        }
        self.systemAudioManager = nil
```
Do the same inside `tearDownPartialLiveRecording()` (mirror how it stops `audioCaptureManager`).

- [ ] **Step 5: Verify build**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter build macos --debug 2>&1 | tail -20
```
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(macos): wire system audio into startLiveRecording lifecycle"
```

---

## Task 12: Native `showSystemAudioMenu` handler + app picker panel

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/SystemAudioAppPicker.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (handle the `showSystemAudioMenu` method case + handler)

**Context:** The NSMenu mirrors `showMicrophoneMenu`'s target/popUp/reply pattern. When "selected apps…" is chosen, present the async app picker (modeled on `SourcePickerOverlay`'s continuation pattern) and reply with the resulting config. The picker lists `SCShareableContent.applications`.

- [ ] **Step 1: Write the app picker**

Create `packages/screen_recorder_macos/macos/Classes/SystemAudioAppPicker.swift`:
```swift
import AppKit
import ScreenCaptureKit

/// A small native multi-select panel of running apps, modeled on
/// SourcePickerOverlay's async-continuation pattern. Returns the chosen bundle
/// ids, or nil if cancelled. macOS 13+.
@available(macOS 13.0, *)
final class SystemAudioAppPicker: NSObject {
  private var window: NSWindow?
  private var continuation: CheckedContinuation<[String]?, Never>?
  private var rows: [(bundleId: String, checkbox: NSButton)] = []

  /// Present the picker with `preselected` bundle ids checked. Awaits the user.
  func pick(preselected: [String]) async -> [String]? {
    let content = try? await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    // Unique apps by bundle id, with a display name.
    var seen = Set<String>()
    let apps = (content?.applications ?? [])
      .filter { !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier).inserted }
      .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }

    return await withCheckedContinuation { cont in
      self.continuation = cont
      DispatchQueue.main.async { self.present(apps: apps, preselected: Set(preselected)) }
    }
  }

  private func present(apps: [SCRunningApplication], preselected: Set<String>) {
    let rowH: CGFloat = 28, pad: CGFloat = 16, w: CGFloat = 340
    let listH = CGFloat(max(1, apps.count)) * rowH
    let h = listH + pad * 2 + 44

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: w, height: h),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.title = "System audio — select apps"
    win.center()
    win.isReleasedWhenClosed = false

    let content = NSView(frame: win.contentView!.bounds)
    var y = h - pad - rowH
    for app in apps {
      let cb = NSButton(checkboxWithTitle: "  \(app.applicationName)",
                        target: nil, action: nil)
      cb.frame = NSRect(x: pad, y: y, width: w - pad * 2, height: rowH)
      cb.state = preselected.contains(app.bundleIdentifier) ? .on : .off
      cb.target = self
      cb.action = #selector(toggleChanged)
      content.addSubview(cb)
      rows.append((app.bundleIdentifier, cb))
      y -= rowH
    }

    let cancel = NSButton(title: "Cancel", target: self, action: #selector(onCancel))
    cancel.frame = NSRect(x: w - 180, y: pad, width: 80, height: 28)
    cancel.bezelStyle = .rounded
    content.addSubview(cancel)

    let done = NSButton(title: "Done", target: self, action: #selector(onDone))
    done.frame = NSRect(x: w - 92, y: pad, width: 80, height: 28)
    done.bezelStyle = .rounded
    done.keyEquivalent = "\r"
    self.doneButton = done
    content.addSubview(done)

    win.contentView = content
    self.window = win
    updateDoneEnabled()
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
  }

  private weak var doneButton: NSButton?

  @objc private func toggleChanged() { updateDoneEnabled() }

  private func updateDoneEnabled() {
    doneButton?.isEnabled = rows.contains { $0.checkbox.state == .on }
  }

  @objc private func onDone() {
    let chosen = rows.filter { $0.checkbox.state == .on }.map { $0.bundleId }
    finish(chosen)
  }

  @objc private func onCancel() { finish(nil) }

  private func finish(_ value: [String]?) {
    window?.orderOut(nil)
    window = nil
    rows = []
    continuation?.resume(returning: value)
    continuation = nil
  }
}
```

- [ ] **Step 2: Add the menu handler + method case**

In `ScreenRecorderMacosPlugin.swift`, add a `case "showSystemAudioMenu"` to the method-call switch (next to `case "showMicrophoneMenu"`):
```swift
    case "showSystemAudioMenu":
      showSystemAudioMenu(args: call.arguments as? [String: Any], result: result)
```
Add the handler (model on `showMicrophoneMenu`):
```swift
  private func showSystemAudioMenu(args: [String: Any]?, result: @escaping FlutterResult) {
    let curMode = args?["mode"] as? String          // "allApps" | "selectedApps" | nil(off)
    let curBundleIds = (args?["bundleIds"] as? [String]) ?? []

    DispatchQueue.main.async {
      guard #available(macOS 13.0, *) else {
        result(["cancelled": false, "config": NSNull()]); return
      }
      let target = SysAudioMenuTarget()
      let menu = NSMenu()

      let all = NSMenuItem(title: "Record system audio from all apps",
        action: #selector(SysAudioMenuTarget.pickAll(_:)), keyEquivalent: "")
      all.target = target
      all.state = (curMode == "allApps") ? .on : .off
      menu.addItem(all)

      let selected = NSMenuItem(title: "Record system audio from selected apps…",
        action: #selector(SysAudioMenuTarget.pickSelected(_:)), keyEquivalent: "")
      selected.target = target
      selected.state = (curMode == "selectedApps") ? .on : .off
      menu.addItem(selected)

      menu.addItem(.separator())
      let off = NSMenuItem(title: "Don't record system audio",
        action: #selector(SysAudioMenuTarget.dontRecord(_:)), keyEquivalent: "")
      off.target = target
      off.state = (curMode == nil) ? .on : .off
      menu.addItem(off)

      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

      func reply(_ config: [String: Any]?) {
        result(["cancelled": false, "config": (config as Any?) ?? NSNull()])
      }

      switch target.action {
      case .none:
        result(["cancelled": true, "config": NSNull()])
      case .dontRecord:
        reply(nil)
      case .all:
        reply(["mode": "allApps", "bundleIds": [String]()])
      case .selected:
        // Chain into the async multi-select picker.
        let picker = SystemAudioAppPicker()
        Task {
          let chosen = await picker.pick(preselected: curBundleIds)
          DispatchQueue.main.async {
            if let chosen = chosen, !chosen.isEmpty {
              reply(["mode": "selectedApps", "bundleIds": chosen])
            } else {
              result(["cancelled": true, "config": NSNull()])
            }
          }
        }
      }
    }
  }
```
Add the target class (near `MicMenuTarget`):
```swift
@available(macOS 13.0, *)
final class SysAudioMenuTarget: NSObject {
  enum Action { case none, all, selected, dontRecord }
  var action: Action = .none
  @objc func pickAll(_ s: Any) { action = .all }
  @objc func pickSelected(_ s: Any) { action = .selected }
  @objc func dontRecord(_ s: Any) { action = .dontRecord }
}
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter build macos --debug 2>&1 | tail -20
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder_macos/macos/Classes/SystemAudioAppPicker.swift \
        packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(macos): showSystemAudioMenu NSMenu + multi-select app picker"
```

---

## Task 13: Manual end-to-end verification (ffprobe)

**Files:** none (verification only).

- [ ] **Step 1: Run the app and record all-apps system audio**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
fvm flutter run -d macos
```
In the bar: click the system-audio chip → "Record system audio from all apps". Play audio in some app (e.g. music/video). Record ~10s of a display, then stop.

- [ ] **Step 2: Probe the output for two audio tracks**

```bash
f=$(ls -t ~/Documents/recording_*.mp4 | head -1)
ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels,sample_rate -of default=noprint_wrappers=1 "$f"
```
Expected (mic + system): two `codec_type=audio` streams — one **mono** (mic, channels=1) and one **stereo** (system, channels=2), both `aac`/`48000`, plus the `h264` video. With mic off + system on: one stereo audio track.

- [ ] **Step 3: Verify A/V alignment (no drift)**

```bash
ffprobe -v error -select_streams a -show_entries stream=index:packet=pts_time \
  -of csv=p=0 "$f" 2>/dev/null | head -3
```
Expected: audio packets begin at/near PTS 0 (the writer's first-video-PTS guard aligns both tracks; same behavior verified for the mic track in Sub-project 1).

- [ ] **Step 4: Record selected-apps and verify scope**

Re-run, choose "Record system audio from selected apps…", check exactly one playing app, Done. Record ~10s with that app playing AND another app playing. Stop. Confirm by listening / waveform that **only the selected app's audio** is in the system track:
```bash
f=$(ls -t ~/Documents/recording_*.mp4 | head -1)
ffmpeg -i "$f" -map 0:a:1 -t 10 /tmp/systrack.wav -y 2>/dev/null && afplay /tmp/systrack.wav
```
(Adjust `0:a:1` to the system track index from Step 2.)

- [ ] **Step 5: Record with system audio OFF**

Confirm "Don't record system audio" → the output has no system track (only mic, or no audio if mic is also off).

- [ ] **Step 6: Done — no commit (verification only).**

If any scenario fails, treat it as a bug: investigate with `log show --last 3m --predicate 'eventMessage CONTAINS "SystemAudioCaptureManager" OR eventMessage CONTAINS "System audio capture failed"'` and fix before considering the feature complete.

---

## Final review checklist (run after all tasks)

- [ ] Full Dart suite green: `cd packages/screen_recorder && fvm flutter test` and the platform-interface + macos package suites.
- [ ] `fvm flutter build macos --debug` clean.
- [ ] All four capture scenarios verified (Task 13).
- [ ] **Document the known interim limitation** (mic+system → only mic heard in playback/export until Sub-project 3) wherever release notes / the roadmap live.
- [ ] Update the `audio_capture_subproject1.md` memory (or a new S2 memory) to record S2 status.
