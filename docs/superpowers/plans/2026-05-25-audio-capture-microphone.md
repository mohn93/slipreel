# Audio Capture — Sub-project 1 (Foundation + Microphone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user record from a chosen microphone (or none) with optional noise reduction / disable-AGC, muxed as its own AAC track into the MP4, controlled by a live microphone dropdown on the recording bar.

**Architecture:** A `MicrophoneController` (Riverpod) holds the current `MicrophoneConfig?` (null = off, the launch default). The bar renders a live mic control from it and opens a native `NSMenu` (`showMicrophoneMenu`) to change it. `RecordingController.startRecording` passes the config into `RecordingSettings.microphone`, which flows over the method channel to native, where `AudioCaptureManager` selects the chosen CoreAudio device + applies AVAudioEngine voice processing, and `LiveRecordingWriter` (now track-keyed) muxes it as an audio track.

**Tech Stack:** Flutter/Dart, Riverpod, `plugin_platform_interface`, method channels; Swift / AVFoundation (AVAudioEngine voice processing), CoreAudio (device enumeration + selection), AppKit `NSMenu`, AVAssetWriter.

**Spec:** `docs/superpowers/specs/2026-05-25-audio-capture-microphone-design.md`
**Branch:** `feat/audio-mic-capture` (already created).

---

## Conventions for this plan

- **Run Dart tests from the package directory.** Commands below `cd` into the right package.
- **Dart tasks are TDD** (red → green → commit). **Swift tasks aren't unit-tested in this repo** (consistent with the existing native code); they are implement → `flutter build macos` (compile gate) → manual verification, committed once building.
- Build the native side with: `cd packages/screen_recorder_macos/example && flutter build macos --debug` (compiles the plugin against the example host).
- Commit after each task. Stage only the files the task touched (the repo has untracked `DerivedData/` churn — never `git add -A`).

---

## File Structure

**Created**
- `packages/screen_recorder_platform_interface/lib/src/models/microphone_config.dart` — `MicrophoneConfig` (deviceUid, deviceLabel, reduceNoise, disableAgc) + `MicrophoneMenuResult`.
- `packages/screen_recorder_platform_interface/test/models/microphone_config_test.dart`
- `packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart`
- `packages/screen_recorder/lib/state/microphone_controller.dart` — `MicrophoneController` + provider.
- `packages/screen_recorder/test/state/microphone_controller_test.dart`
- `packages/screen_recorder_macos/macos/Classes/AudioDeviceCatalog.swift` — CoreAudio enumeration + UID→AudioDeviceID.
- `packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart`

**Modified**
- `packages/screen_recorder_platform_interface/lib/src/models/audio_device_info.dart` — add `isDefault`.
- `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart` — replace `captureAudio`/`audioDeviceIds` with `microphone`.
- `packages/screen_recorder_platform_interface/lib/src/constants.dart` — add `showMicrophoneMenu`.
- `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` — add `showMicrophoneMenu`.
- `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` — export `microphone_config.dart` (barrel).
- `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` — implement `showMicrophoneMenu`.
- `packages/screen_recorder/lib/state/recording_state.dart` — `startRecording({MicrophoneConfig? microphone})`.
- `packages/screen_recorder/lib/ui/bar/recording_bar.dart` — `_MicControl`, new `RecordingBar` params.
- `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` — wire mic config + tap.
- `packages/screen_recorder/test/ui/bar/recording_bar_test.dart` — update `bar()` helper for new params.
- `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart` — fake controller signature + fake platform `showMicrophoneMenu`.
- `packages/screen_recorder/test/integration/cross_platform_test.dart` — drop removed `captureAudio` arg.
- `packages/screen_recorder_macos/example/lib/main.dart` — drop removed `captureAudio` arg.
- `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift` — track-keyed audio inputs.
- `packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift` — device selection + DSP.
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` — `getAudioDevices`, `showMicrophoneMenu`, live-path `microphone` wiring.

---

## Task 1: `MicrophoneConfig` + `MicrophoneMenuResult` models

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/microphone_config.dart`
- Create: `packages/screen_recorder_platform_interface/test/models/microphone_config_test.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (barrel export)

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder_platform_interface/test/models/microphone_config_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('MicrophoneConfig', () {
    const cfg = MicrophoneConfig(
      deviceUid: 'AppleHDAEngineInput:1B,0,1,0:1',
      deviceLabel: 'MacBook Pro Microphone',
      reduceNoise: true,
      disableAgc: false,
    );

    test('toJson round-trips through fromJson', () {
      final back = MicrophoneConfig.fromJson(cfg.toJson());
      expect(back, cfg);
    });

    test('toJson emits all fields', () {
      final json = cfg.toJson();
      expect(json['deviceUid'], 'AppleHDAEngineInput:1B,0,1,0:1');
      expect(json['deviceLabel'], 'MacBook Pro Microphone');
      expect(json['reduceNoise'], true);
      expect(json['disableAgc'], false);
    });

    test('reduceNoise/disableAgc default to false', () {
      const c = MicrophoneConfig(deviceUid: 'x', deviceLabel: 'X');
      expect(c.reduceNoise, false);
      expect(c.disableAgc, false);
    });

    test('copyWith overrides only the given fields', () {
      final c = cfg.copyWith(disableAgc: true);
      expect(c.disableAgc, true);
      expect(c.reduceNoise, true);
      expect(c.deviceUid, cfg.deviceUid);
    });

    test('value equality', () {
      expect(cfg, const MicrophoneConfig(
        deviceUid: 'AppleHDAEngineInput:1B,0,1,0:1',
        deviceLabel: 'MacBook Pro Microphone',
        reduceNoise: true,
        disableAgc: false,
      ));
      expect(cfg == cfg.copyWith(reduceNoise: false), false);
    });
  });

  group('MicrophoneMenuResult', () {
    test('parses a device selection', () {
      final r = MicrophoneMenuResult.fromJson({
        'cancelled': false,
        'config': {
          'deviceUid': 'uid-1',
          'deviceLabel': 'Mic One',
          'reduceNoise': false,
          'disableAgc': false,
        },
      });
      expect(r.cancelled, false);
      expect(r.config?.deviceUid, 'uid-1');
    });

    test('parses "Don\'t record" (config null, not cancelled)', () {
      final r = MicrophoneMenuResult.fromJson({'cancelled': false, 'config': null});
      expect(r.cancelled, false);
      expect(r.config, isNull);
    });

    test('parses a dismissal', () {
      final r = MicrophoneMenuResult.fromJson({'cancelled': true, 'config': null});
      expect(r.cancelled, true);
      expect(r.config, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/microphone_config_test.dart`
Expected: FAIL — `MicrophoneConfig`/`MicrophoneMenuResult` undefined (compile error).

- [ ] **Step 3: Write minimal implementation**

`packages/screen_recorder_platform_interface/lib/src/models/microphone_config.dart`:
```dart
/// A chosen microphone input and its capture options. `null` (absence of this
/// config) means "don't record microphone".
class MicrophoneConfig {
  /// Stable CoreAudio device UID, used to re-resolve the device at capture time.
  final String deviceUid;

  /// Human-readable device name, shown on the bar's mic control.
  final String deviceLabel;

  /// Enable AVAudioEngine voice processing (noise suppression + level normalize).
  final bool reduceNoise;

  /// Turn off automatic gain control. Only honored on macOS 14+.
  final bool disableAgc;

  const MicrophoneConfig({
    required this.deviceUid,
    required this.deviceLabel,
    this.reduceNoise = false,
    this.disableAgc = false,
  });

  Map<String, dynamic> toJson() => {
        'deviceUid': deviceUid,
        'deviceLabel': deviceLabel,
        'reduceNoise': reduceNoise,
        'disableAgc': disableAgc,
      };

  factory MicrophoneConfig.fromJson(Map<String, dynamic> json) => MicrophoneConfig(
        deviceUid: json['deviceUid'] as String,
        deviceLabel: json['deviceLabel'] as String,
        reduceNoise: json['reduceNoise'] as bool? ?? false,
        disableAgc: json['disableAgc'] as bool? ?? false,
      );

  MicrophoneConfig copyWith({
    String? deviceUid,
    String? deviceLabel,
    bool? reduceNoise,
    bool? disableAgc,
  }) =>
      MicrophoneConfig(
        deviceUid: deviceUid ?? this.deviceUid,
        deviceLabel: deviceLabel ?? this.deviceLabel,
        reduceNoise: reduceNoise ?? this.reduceNoise,
        disableAgc: disableAgc ?? this.disableAgc,
      );

  @override
  bool operator ==(Object other) =>
      other is MicrophoneConfig &&
      other.deviceUid == deviceUid &&
      other.deviceLabel == deviceLabel &&
      other.reduceNoise == reduceNoise &&
      other.disableAgc == disableAgc;

  @override
  int get hashCode => Object.hash(deviceUid, deviceLabel, reduceNoise, disableAgc);

  @override
  String toString() =>
      'MicrophoneConfig($deviceLabel, reduceNoise: $reduceNoise, disableAgc: $disableAgc)';
}

/// Result of the native microphone menu. [cancelled] true means the user
/// dismissed the menu (no change). When not cancelled, [config] is the new
/// selection, or null for "Don't record microphone".
class MicrophoneMenuResult {
  final bool cancelled;
  final MicrophoneConfig? config;

  const MicrophoneMenuResult({required this.cancelled, this.config});

  factory MicrophoneMenuResult.fromJson(Map<String, dynamic> json) {
    final c = json['config'];
    return MicrophoneMenuResult(
      cancelled: json['cancelled'] as bool? ?? false,
      config: c == null
          ? null
          : MicrophoneConfig.fromJson(Map<String, dynamic>.from(c as Map)),
    );
  }
}
```

Add to the barrel `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (alongside the other `export 'src/models/...';` lines):
```dart
export 'src/models/microphone_config.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/microphone_config_test.dart`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/models/microphone_config.dart \
        packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart \
        packages/screen_recorder_platform_interface/test/models/microphone_config_test.dart
git commit -m "feat(audio): add MicrophoneConfig + MicrophoneMenuResult models"
```

---

## Task 2: `AudioDeviceInfo.isDefault`

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/audio_device_info.dart`
- Create: `packages/screen_recorder_platform_interface/test/models/audio_device_info_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder_platform_interface/test/models/audio_device_info_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('AudioDeviceInfo', () {
    test('round-trips isDefault=true', () {
      const d = AudioDeviceInfo(
        id: 'uid-1', name: 'Built-in', type: AudioDeviceType.microphone,
        isDefault: true);
      final back = AudioDeviceInfo.fromJson(d.toJson());
      expect(back.id, 'uid-1');
      expect(back.name, 'Built-in');
      expect(back.type, AudioDeviceType.microphone);
      expect(back.isDefault, true);
    });

    test('isDefault defaults to false when absent', () {
      final d = AudioDeviceInfo.fromJson({
        'id': 'x', 'name': 'X', 'type': 'microphone',
      });
      expect(d.isDefault, false);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/audio_device_info_test.dart`
Expected: FAIL — `isDefault` is not a parameter of `AudioDeviceInfo`.

- [ ] **Step 3: Write minimal implementation**

Edit `packages/screen_recorder_platform_interface/lib/src/models/audio_device_info.dart` to add the field (keep the rest of the class as-is):
```dart
class AudioDeviceInfo {
  final String id;
  final String name;
  final AudioDeviceType type;
  final bool isDefault;

  const AudioDeviceInfo({
    required this.id,
    required this.name,
    required this.type,
    this.isDefault = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'isDefault': isDefault,
    };
  }

  factory AudioDeviceInfo.fromJson(Map<String, dynamic> json) {
    return AudioDeviceInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      type: AudioDeviceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => AudioDeviceType.unknown,
      ),
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'AudioDeviceInfo(id: $id, name: $name, type: $type, isDefault: $isDefault)';
  }
}

enum AudioDeviceType {
  system,
  microphone,
  unknown,
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/audio_device_info_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/models/audio_device_info.dart \
        packages/screen_recorder_platform_interface/test/models/audio_device_info_test.dart
git commit -m "feat(audio): add isDefault to AudioDeviceInfo"
```

---

## Task 3: `RecordingSettings` — replace audio fields with `microphone`

This is a breaking model change. To keep the whole workspace compiling, this task also drops the now-removed `captureAudio` argument at its three construction sites (the controller temporarily passes no mic; Task 7 wires the real value in).

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart`
- Create: `packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart`
- Modify: `packages/screen_recorder/lib/state/recording_state.dart:127` (remove `captureAudio: true,`)
- Modify: `packages/screen_recorder/test/integration/cross_platform_test.dart:119,150,187` (remove `captureAudio: false,`)
- Modify: `packages/screen_recorder_macos/example/lib/main.dart:99` (remove `captureAudio: true,`)

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('RecordingSettings.microphone', () {
    test('toJson emits microphone map when set', () {
      const s = RecordingSettings(
        source: RecordingSource.screen,
        microphone: MicrophoneConfig(deviceUid: 'uid', deviceLabel: 'Mic'),
      );
      final json = s.toJson();
      expect(json['microphone'], isA<Map>());
      expect(json['microphone']['deviceUid'], 'uid');
      expect(json.containsKey('captureAudio'), false);
      expect(json.containsKey('audioDeviceIds'), false);
    });

    test('toJson emits null microphone when off', () {
      const s = RecordingSettings(source: RecordingSource.screen);
      expect(s.toJson()['microphone'], isNull);
    });

    test('fromJson parses microphone', () {
      final s = RecordingSettings.fromJson({
        'source': 'window',
        'microphone': {'deviceUid': 'u', 'deviceLabel': 'L', 'reduceNoise': true, 'disableAgc': false},
      });
      expect(s.microphone?.deviceUid, 'u');
      expect(s.microphone?.reduceNoise, true);
    });

    test('fromJson with no microphone key yields null (off)', () {
      final s = RecordingSettings.fromJson({'source': 'screen'});
      expect(s.microphone, isNull);
    });

    test('copyWith replaces microphone', () {
      const s = RecordingSettings(source: RecordingSource.screen);
      final s2 = s.copyWith(microphone: const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L'));
      expect(s2.microphone?.deviceUid, 'u');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/recording_settings_test.dart`
Expected: FAIL — `microphone` is not a parameter of `RecordingSettings`.

- [ ] **Step 3: Write minimal implementation**

Replace `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart` body with:
```dart
import 'microphone_config.dart';

/// Settings for a recording session
class RecordingSettings {
  final RecordingSource source;
  final String? sourceId;
  final int frameRate;

  /// The microphone to record, or null for "don't record microphone".
  final MicrophoneConfig? microphone;

  final bool captureCursor;
  final int? maxDurationSeconds;

  const RecordingSettings({
    required this.source,
    this.sourceId,
    this.frameRate = 30,
    this.microphone,
    this.captureCursor = true,
    this.maxDurationSeconds,
  });

  Map<String, dynamic> toJson() {
    return {
      'source': source.name,
      'sourceId': sourceId,
      'frameRate': frameRate,
      'microphone': microphone?.toJson(),
      'captureCursor': captureCursor,
      'maxDurationSeconds': maxDurationSeconds,
    };
  }

  factory RecordingSettings.fromJson(Map<String, dynamic> json) {
    final mic = json['microphone'];
    return RecordingSettings(
      source: RecordingSource.values.firstWhere(
        (e) => e.name == json['source'],
        orElse: () => RecordingSource.screen,
      ),
      sourceId: json['sourceId'] as String?,
      frameRate: json['frameRate'] as int? ?? 30,
      microphone: mic == null
          ? null
          : MicrophoneConfig.fromJson(Map<String, dynamic>.from(mic as Map)),
      captureCursor: json['captureCursor'] as bool? ?? true,
      maxDurationSeconds: json['maxDurationSeconds'] as int?,
    );
  }

  RecordingSettings copyWith({
    RecordingSource? source,
    String? sourceId,
    int? frameRate,
    MicrophoneConfig? microphone,
    bool? captureCursor,
    int? maxDurationSeconds,
  }) {
    return RecordingSettings(
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      frameRate: frameRate ?? this.frameRate,
      microphone: microphone ?? this.microphone,
      captureCursor: captureCursor ?? this.captureCursor,
      maxDurationSeconds: maxDurationSeconds ?? this.maxDurationSeconds,
    );
  }

  @override
  String toString() {
    return 'RecordingSettings(source: $source, sourceId: $sourceId, fps: $frameRate, mic: ${microphone?.deviceLabel ?? "off"}, cursor: $captureCursor)';
  }
}

enum RecordingSource {
  screen,
  window,
  area,
}
```

Now remove the broken `captureAudio` arguments so the rest compiles:
- `packages/screen_recorder/lib/state/recording_state.dart` — delete the line `captureAudio: true,` inside the `RecordingSettings(...)` in `startRecording` (leave the rest; `microphone` stays unset = null for now).
- `packages/screen_recorder/test/integration/cross_platform_test.dart` — delete the three `captureAudio: false,` lines.
- `packages/screen_recorder_macos/example/lib/main.dart` — delete the `captureAudio: true,` line.

- [ ] **Step 4: Run tests to verify green across affected packages**

Run:
```bash
cd packages/screen_recorder_platform_interface && flutter test test/models/recording_settings_test.dart
cd ../screen_recorder && flutter test test/integration/cross_platform_test.dart
```
Expected: both PASS. (If `cross_platform_test` references `audioDeviceIds` anywhere, remove those too — grep first: `grep -rn "captureAudio\|audioDeviceIds" packages/screen_recorder/test` must return nothing.)

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart \
        packages/screen_recorder_platform_interface/test/models/recording_settings_test.dart \
        packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/test/integration/cross_platform_test.dart \
        packages/screen_recorder_macos/example/lib/main.dart
git commit -m "feat(audio): RecordingSettings.microphone replaces captureAudio/audioDeviceIds"
```

---

## Task 4: Platform interface — `showMicrophoneMenu` + channel constant

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`

- [ ] **Step 1: Write the failing test**

Append to `packages/screen_recorder_platform_interface/test/models/microphone_config_test.dart` a group that asserts the default interface method throws (mirrors how `pickSource` is unsupported by default). Add at top: `import 'package:plugin_platform_interface/plugin_platform_interface.dart';` and a minimal fake:
```dart
// --- append inside main() ---
group('ScreenRecorderPlatform.showMicrophoneMenu default', () {
  test('throws UnsupportedError by default', () {
    final p = _BarePlatform();
    expect(() => p.showMicrophoneMenu(null), throwsUnsupportedError);
  });
});

// --- append at file scope (bottom) ---
class _BarePlatform extends ScreenRecorderPlatform with MockPlatformInterfaceMixin {}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/microphone_config_test.dart`
Expected: FAIL — `showMicrophoneMenu` is not defined on `ScreenRecorderPlatform`.

- [ ] **Step 3: Write minimal implementation**

In `packages/screen_recorder_platform_interface/lib/src/constants.dart`, add to `ScreenRecorderMethods`:
```dart
  static const String showMicrophoneMenu = 'showMicrophoneMenu';
```

In `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`, add `import 'models/microphone_config.dart';` to the imports and this method (place it after `pickSource`):
```dart
  /// Shows the native microphone dropdown (NSMenu) seeded with [current].
  /// Returns the user's choice; see [MicrophoneMenuResult].
  Future<MicrophoneMenuResult> showMicrophoneMenu(MicrophoneConfig? current) {
    throw UnsupportedError('showMicrophoneMenu() is not supported on this platform.');
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/microphone_config_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/constants.dart \
        packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
        packages/screen_recorder_platform_interface/test/models/microphone_config_test.dart
git commit -m "feat(audio): add showMicrophoneMenu to platform interface"
```

---

## Task 5: MethodChannel — implement `showMicrophoneMenu`

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Modify: `packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart`. Extend the mock handler's switch and add two tests:
```dart
// inside the setUp switch, before `default`:
          case 'showMicrophoneMenu':
            return {
              'cancelled': false,
              'config': {
                'deviceUid': (methodCall.arguments as Map?)?['deviceUid'] ?? 'picked-uid',
                'deviceLabel': 'Picked Mic',
                'reduceNoise': false,
                'disableAgc': false,
              },
            };
```
```dart
// new tests:
  test('showMicrophoneMenu sends current config and decodes the result', () async {
    final result = await platform.showMicrophoneMenu(
      const MicrophoneConfig(deviceUid: 'current-uid', deviceLabel: 'Current'));
    expect(result.cancelled, false);
    expect(result.config?.deviceLabel, 'Picked Mic');
  });

  test('showMicrophoneMenu(null) is allowed', () async {
    final result = await platform.showMicrophoneMenu(null);
    expect(result, isA<MicrophoneMenuResult>());
  });
```
Add `import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';` to the test imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_macos && flutter test test/screen_recorder_macos_method_channel_test.dart`
Expected: FAIL — `showMicrophoneMenu` not implemented on `MethodChannelScreenRecorderMacos`.

- [ ] **Step 3: Write minimal implementation**

Add to `MethodChannelScreenRecorderMacos` (in `screen_recorder_macos_method_channel.dart`), after `pickSource`:
```dart
  @override
  Future<MicrophoneMenuResult> showMicrophoneMenu(MicrophoneConfig? current) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.showMicrophoneMenu,
      current?.toJson(),
    );
    if (raw == null) {
      return const MicrophoneMenuResult(cancelled: true);
    }
    return MicrophoneMenuResult.fromJson(raw);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_macos && flutter test test/screen_recorder_macos_method_channel_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart \
        packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart
git commit -m "feat(audio): MethodChannel showMicrophoneMenu"
```

---

## Task 6: `MicrophoneController` + provider

**Files:**
- Create: `packages/screen_recorder/lib/state/microphone_controller.dart`
- Create: `packages/screen_recorder/test/state/microphone_controller_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder/test/state/microphone_controller_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/microphone_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('starts off (null)', () {
    expect(MicrophoneController().state, isNull);
  });

  test('set applies a config', () {
    final c = MicrophoneController();
    const cfg = MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L');
    c.set(cfg);
    expect(c.state, cfg);
  });

  test('set(null) turns it off', () {
    final c = MicrophoneController();
    c.set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L'));
    c.set(null);
    expect(c.state, isNull);
  });

  test('setting an equal config does not emit a new state', () {
    final c = MicrophoneController();
    const cfg = MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L');
    c.set(cfg);
    var emissions = 0;
    final remove = c.addListener((_) => emissions++); // fires once immediately
    c.set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'L')); // equal → no-op
    remove();
    expect(emissions, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/microphone_controller_test.dart`
Expected: FAIL — `MicrophoneController` undefined.

- [ ] **Step 3: Write minimal implementation**

`packages/screen_recorder/lib/state/microphone_controller.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current microphone selection (null = "don't record microphone").
/// In-memory only — resets to off each launch (the spec's launch default).
class MicrophoneController extends StateNotifier<MicrophoneConfig?> {
  MicrophoneController() : super(null);

  void set(MicrophoneConfig? config) {
    if (config != state) state = config;
  }
}

final microphoneControllerProvider =
    StateNotifierProvider<MicrophoneController, MicrophoneConfig?>(
        (ref) => MicrophoneController());
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/microphone_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/microphone_controller.dart \
        packages/screen_recorder/test/state/microphone_controller_test.dart
git commit -m "feat(audio): MicrophoneController + provider (off by default)"
```

---

## Task 7: `RecordingController.startRecording({MicrophoneConfig? microphone})`

Threads the chosen mic config into `RecordingSettings.microphone`.

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Create: `packages/screen_recorder/test/state/recording_state_mic_test.dart`
- Modify: `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart` (bump the fake's override signature so the tree stays green; Task 9 extends it further)

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder/test/state/recording_state_mic_test.dart` — verify the controller builds settings with the passed mic. Capture the settings via a fake platform's `startLiveRecording`. This mirrors the proven `recording_state_region_test.dart` pattern (fake `PathProviderPlatform`, fake `ScreenRecorderPlatform`, settle with a zero delay, then `dispose()` to stop the duration timer):
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '/tmp/test-docs';
}

class _CapturingPlatform extends ScreenRecorderPlatform
    with MockPlatformInterfaceMixin {
  RecordingSettings? capturedSettings;

  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    capturedSettings = settings;
  }

  @override
  Stream<CursorPosition> get cursorStream => const Stream.empty();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
  });

  test('startRecording forwards the microphone config into settings', () async {
    final platform = _CapturingPlatform();
    ScreenRecorderPlatform.instance = platform;
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');

    const mic = MicrophoneConfig(
        deviceUid: 'u', deviceLabel: 'L', reduceNoise: true);
    await c.startRecording(microphone: mic);
    await Future<void>.delayed(Duration.zero);

    expect(platform.capturedSettings?.microphone, mic);
    c.dispose();
  });

  test('startRecording with no mic leaves settings.microphone null', () async {
    final platform = _CapturingPlatform();
    ScreenRecorderPlatform.instance = platform;
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');

    await c.startRecording();
    await Future<void>.delayed(Duration.zero);

    expect(platform.capturedSettings?.microphone, isNull);
    c.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/recording_state_mic_test.dart`
Expected: FAIL — `startRecording` takes no `microphone` argument.

- [ ] **Step 3: Write minimal implementation**

In `packages/screen_recorder/lib/state/recording_state.dart`, change the signature and pass it through:
```dart
  Future<void> startRecording({MicrophoneConfig? microphone}) async {
    if (!state.canStartRecording ||
        state.selectedSourceId == null ||
        state.selectedSourceKind == null) return;
    try {
      // ... unchanged state set + outputPath ...

      final settings = RecordingSettings(
        source: state.selectedSourceKind!,
        sourceId: state.selectedSourceId,
        frameRate: _defaultFps,
        microphone: microphone,
        captureCursor: true,
      );
      // ... rest unchanged ...
```
(`MicrophoneConfig` is exported by the platform-interface barrel already imported in this file.)

Then keep the screen test compiling: in `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`, change the `_FakeRecordingController` override
```dart
  @override
  Future<void> startRecording() async => startCalls++;
```
to the new signature (Task 9 will extend it to capture the mic):
```dart
  @override
  Future<void> startRecording({MicrophoneConfig? microphone}) async => startCalls++;
```
(`MicrophoneConfig` is already available via the platform-interface import in that test.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/state/recording_state_mic_test.dart test/state/recording_state_test.dart test/ui/bar/recording_bar_screen_test.dart`
Expected: PASS (existing `recording_state_test.dart` and `recording_bar_screen_test.dart` still green — `startRecording` with no args is unchanged behavior).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/test/state/recording_state_mic_test.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart
git commit -m "feat(audio): startRecording threads MicrophoneConfig into settings"
```

---

## Task 8: Bar `_MicControl` + `RecordingBar` params

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Create: `packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart`
- Modify: `packages/screen_recorder/test/ui/bar/recording_bar_test.dart` (update `bar()` helper)

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _wrap(Widget c) => MaterialApp(home: Scaffold(body: c));

RecordingBar _bar({MicrophoneConfig? mic, VoidCallback? onMicTap}) => RecordingBar(
      onPickMode: (_) {},
      onClose: () {},
      onGearTap: () {},
      onDragStart: () {},
      microphone: mic,
      onMicTap: onMicTap ?? () {},
    );

void main() {
  testWidgets('off state shows "No microphone"', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(mic: null)));
    expect(find.text('No microphone'), findsOneWidget);
  });

  testWidgets('on state shows the device label', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(
        mic: const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'MacBook Pro Mic'))));
    expect(find.text('MacBook Pro Mic'), findsOneWidget);
    expect(find.text('No microphone'), findsNothing);
  });

  testWidgets('a very long device label does not overflow', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(
        mic: const MicrophoneConfig(
            deviceUid: 'u',
            deviceLabel:
                'Extremely Long Virtual Audio Capture Device Name That Would Overflow'))));
    await tester.pump();
    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });

  testWidgets('tapping the mic control fires onMicTap', (tester) async {
    _wide(tester);
    var tapped = false;
    await tester.pumpWidget(_wrap(_bar(onMicTap: () => tapped = true)));
    await tester.tap(find.byKey(const Key('bar-mic')));
    expect(tapped, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_mic_test.dart`
Expected: FAIL — `RecordingBar` has no `microphone`/`onMicTap` params; no `bar-mic` key.

- [ ] **Step 3: Write minimal implementation**

In `packages/screen_recorder/lib/ui/bar/recording_bar.dart`:

(a) Add the import at top:
```dart
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
```

(b) Add fields + constructor params to `RecordingBar`:
```dart
  const RecordingBar({
    super.key,
    required this.onPickMode,
    required this.onClose,
    required this.onGearTap,
    required this.onDragStart,
    this.microphone,
    required this.onMicTap,
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onClose;
  final VoidCallback onGearTap;
  final VoidCallback onDragStart;

  /// Current microphone selection (null = off). Renders the mic control state.
  final MicrophoneConfig? microphone;

  /// Fired when the mic control is tapped (opens the native mic menu).
  final VoidCallback onMicTap;
```

(c) Replace the mic `_AvPlaceholder` line:
```dart
            const _AvPlaceholder(icon: LucideIcons.micOff, label: 'No microphone'),
```
with:
```dart
            _MicControl(microphone: microphone, onTap: onMicTap),
```
(Leave the camera and system-audio `_AvPlaceholder`s untouched.)

(d) Add the new widget (after `_AvPlaceholder`):
```dart
/// Live microphone control: icon + (truncated) device name + chevron. Greyed
/// when off. Tapping opens the native mic menu via [onTap].
class _MicControl extends StatelessWidget {
  const _MicControl({required this.microphone, required this.onTap});

  final MicrophoneConfig? microphone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = microphone != null;
    final label = on ? microphone!.deviceLabel : 'No microphone';
    final iconColor = on ? const Color(0xFFE9E9EC) : const Color(0xFF6E6E76);
    final textColor = on ? const Color(0xFFE9E9EC) : const Color(0xFF6E6E76);
    return SpringHoverButton(
      key: const Key('bar-mic'),
      onTap: onTap,
      child: SizedBox(
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(on ? LucideIcons.mic : LucideIcons.micOff,
                    size: 22, color: iconColor),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(fontSize: 10, color: textColor)),
                ),
                const SizedBox(width: 2),
                Icon(LucideIcons.chevronDown,
                    size: 13, color: const Color(0xFF7E7E86)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

(e) Update `packages/screen_recorder/test/ui/bar/recording_bar_test.dart`'s `bar()` helper so the existing tests still compile — add the two new params with defaults:
```dart
  RecordingBar bar({
    void Function(BarSourceMode)? onPickMode,
    VoidCallback? onClose,
    VoidCallback? onGearTap,
    VoidCallback? onDragStart,
    MicrophoneConfig? microphone,
    VoidCallback? onMicTap,
  }) =>
      RecordingBar(
        onPickMode: onPickMode ?? (_) {},
        onClose: onClose ?? () {},
        onGearTap: onGearTap ?? () {},
        onDragStart: onDragStart ?? () {},
        microphone: microphone,
        onMicTap: onMicTap ?? () {},
      );
```
Add `import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';` to that test's imports.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_mic_test.dart test/ui/bar/recording_bar_test.dart`
Expected: PASS (both files). The old test "shows the three disabled A/V placeholders" still passes because it asserts `No camera` / `No microphone` / `No system audio` — but `No microphone` is now the (off-state) mic control label, which still renders that text. ✔

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_test.dart
git commit -m "feat(audio): live microphone control on the recording bar"
```

---

## Task 9: Wire the bar mic control in `RecordingBarScreen`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Modify: `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`

- [ ] **Step 1: Write the failing test**

In `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart` (the `_FakeRecordingController` override signature was already bumped in Task 7; this test uses the real controller, so it isn't touched here):

(a) Add a `showMicrophoneMenu` override + fields to the existing file-level `_FakePlatform`:
```dart
  MicrophoneConfig? menuReturns;
  int showMicMenuCalls = 0;

  @override
  Future<MicrophoneMenuResult> showMicrophoneMenu(MicrophoneConfig? current) async {
    showMicMenuCalls++;
    return MicrophoneMenuResult(cancelled: false, config: menuReturns);
  }
```

(b) Add a test:
```dart
  testWidgets('tapping the mic control opens the menu and updates state',
      (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform()
      ..menuReturns = const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic One');
    ScreenRecorderPlatform.instance = fakePlatform;

    late WidgetRef capturedRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [windowChromeProvider.overrideWithValue(_FakeChrome())],
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
```
Add imports: `import 'package:screen_recorder/state/microphone_controller.dart';` (and `MicrophoneConfig`/`MicrophoneMenuResult` come from the platform-interface barrel already imported).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_screen_test.dart`
Expected: FAIL — `RecordingBar` in the screen still constructed without `microphone`/`onMicTap`; provider not updated on tap.

- [ ] **Step 3: Write minimal implementation**

In `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`:

(a) Add import:
```dart
import '../../state/microphone_controller.dart';
```

(b) Add the tap handler method:
```dart
  Future<void> _onMicTap() async {
    final current = ref.read(microphoneControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showMicrophoneMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(microphoneControllerProvider.notifier).set(result.config);
  }
```

(c) Update `_buildBar()` to read the provider and pass the new params:
```dart
  Widget _buildBar() => RecordingBar(
        onPickMode: _pickAndRecord,
        onClose: () => SystemNavigator.pop(),
        onGearTap: _onGearTap,
        onDragStart: () => ref.read(windowChromeProvider).startWindowDrag(),
        microphone: ref.watch(microphoneControllerProvider),
        onMicTap: _onMicTap,
      );
```
> `_buildBar()` is called from `build()`, so `ref.watch` here rebuilds the bar when the mic selection changes. (It already runs inside `build`.)

(d) Pass the selected mic into recording start. In `_pickAndRecord`, change both `await controller.startRecording();` calls to:
```dart
        await controller.startRecording(
            microphone: ref.read(microphoneControllerProvider));
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_screen_test.dart`
Expected: PASS (new test + all existing screen tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart
git commit -m "feat(audio): wire mic dropdown + selection into RecordingBarScreen"
```

---

## Task 10: Native — track-keyed `LiveRecordingWriter`

Swift task: implement → build → commit. (No Swift unit tests in this repo.)

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`

- [ ] **Step 1: Implement track-keyed audio inputs**

Replace the single-`captureAudio` design with a role-keyed set:
```swift
enum AudioTrackRole: String { case microphone, system }
```
- Change init: replace `captureAudio: Bool` with `audioTracks: [AudioTrackRole]`; store it.
- Add `private var audioInputs: [AudioTrackRole: AVAssetWriterInput] = [:]` and **remove** the single `audioInput` property.
- In `start()`, replace the `if captureAudio { ... }` block with a loop:
```swift
for role in audioTracks {
  let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(for: role))
  input.expectsMediaDataInRealTime = true
  guard writer.canAdd(input) else { throw WriterError.cannotAddAudioInput }
  writer.add(input)
  audioInputs[role] = input
}
```
- Add the settings helper (mic = today's mono/48k/128k; system gets stereo later in Sub 2):
```swift
private static func audioSettings(for role: AudioTrackRole) -> [String: Any] {
  let channels = (role == .system) ? 2 : 1
  return [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 48000,
    AVNumberOfChannelsKey: channels,
    AVEncoderBitRateKey: 128_000,
  ]
}
```
- Change `appendAudio` to take a role:
```swift
func appendAudio(_ sampleBuffer: CMSampleBuffer, role: AudioTrackRole) {
  guard isStarted, writerActive, let input = audioInputs[role] else { return }
  if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
}
```
- In `stop()`, replace `audioInput?.markAsFinished()` with:
```swift
audioInputs.values.forEach { $0.markAsFinished() }
```

- [ ] **Step 2: Implement the call-site change in the plugin (compile dependency)**

In `ScreenRecorderMacosPlugin.swift` around line 491, change the writer construction so it compiles. Replace:
```swift
          fps: fps, captureAudio: captureAudio)
```
with (Task 14 finishes the mic wiring; for now derive tracks from the legacy bool so it builds):
```swift
          fps: fps, audioTracks: captureAudio ? [.microphone] : [])
```
And change the existing live-path `writer.appendAudio(buf)` call (around line 517's block) to `writer.appendAudio(buf, role: .microphone)`.

- [ ] **Step 3: Build to verify it compiles**

Run: `cd packages/screen_recorder_macos/example && flutter build macos --debug`
Expected: BUILD SUCCEEDED. (SourceKit "No such module FlutterMacOS" diagnostics in an editor are false positives; the CLI build is the source of truth.)

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift \
        packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(audio): track-keyed audio inputs in LiveRecordingWriter"
```

---

## Task 11: Native — CoreAudio device enumeration (`getAudioDevices`)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/AudioDeviceCatalog.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (`getAudioDevices` body, ~line 195)

- [ ] **Step 1: Implement `AudioDeviceCatalog`**

`packages/screen_recorder_macos/macos/Classes/AudioDeviceCatalog.swift`:
```swift
import Foundation
import CoreAudio

/// Enumerates audio INPUT devices via CoreAudio (lists built-in, USB, virtual
/// like VB-Cable, and continuity devices — more complete than AVCaptureDevice),
/// and resolves a stable device UID back to a live AudioDeviceID at capture time.
enum AudioDeviceCatalog {
  /// All input-capable devices as `[ "id": UID, "name": ..., "type": "microphone", "isDefault": Bool ]`.
  static func inputDevices() -> [[String: Any]] {
    let defaultID = defaultInputDeviceID()
    var result: [[String: Any]] = []
    for id in allDeviceIDs() where hasInputStreams(id) {
      guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, kAudioObjectPropertyName) else { continue }
      result.append([
        "id": uid,
        "name": name,
        "type": "microphone",
        "isDefault": id == defaultID,
      ])
    }
    return result
  }

  /// Resolve a device UID to the current AudioDeviceID, or nil if not present.
  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var deviceID = AudioDeviceID(0)
    var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let inSize = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
        &address, inSize, uidPtr, &outSize, &deviceID)
    }
    return (status == noErr && deviceID != 0) ? deviceID : nil
  }

  // MARK: - CoreAudio helpers

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
    return ids
  }

  private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr
    else { return false }
    return dataSize > 0
  }

  private static func defaultInputDeviceID() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &size, &deviceID)
    return deviceID
  }

  private static func stringProperty(_ id: AudioDeviceID,
                                     _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cfStr: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
    }
    return status == noErr ? (cfStr as String) : nil
  }
}
```

- [ ] **Step 2: Use it in the plugin's `getAudioDevices`**

Replace the body of `private func getAudioDevices(result:)` (~line 195) with:
```swift
  private func getAudioDevices(result: @escaping FlutterResult) {
    result(AudioDeviceCatalog.inputDevices())
  }
```

- [ ] **Step 3: Build**

Run: `cd packages/screen_recorder_macos/example && flutter build macos --debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification**

Boot the example app via the flutter-qa harness (or run the slipreel app) and call `getAudioDevices()` (e.g. add a temporary debug button, or verify in Task 13/15 via the menu). Confirm the returned list includes the built-in mic with `isDefault: true`. Document the observed device list in the commit message body.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/AudioDeviceCatalog.swift \
        packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(audio): CoreAudio input-device enumeration for getAudioDevices"
```

---

## Task 12: Native — `AudioCaptureManager` device selection + DSP

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift`

- [ ] **Step 1: Add a microphone-capture entry point with device + DSP**

Add this method (keep the existing `startCapture(includeMicrophone:includeSystem:)` for the legacy spool path):
```swift
  /// Start capturing a specific microphone device with optional voice
  /// processing. [deviceUid] nil → system default input.
  func startMicrophoneCapture(deviceUid: String?, reduceNoise: Bool, disableAgc: Bool) throws {
    guard !isCapturing else { throw AudioCaptureError.alreadyCapturing }
    guard checkMicrophonePermission() else { throw AudioCaptureError.permissionDenied }

    let engine = AVAudioEngine()
    audioEngine = engine
    let input = engine.inputNode

    // Select the chosen device (falls back to default if the UID is gone).
    if let uid = deviceUid, let devID = AudioDeviceCatalog.deviceID(forUID: uid) {
      try input.auAudioUnit.setDeviceID(devID)
    }

    // Noise suppression + level normalization via voice processing.
    if reduceNoise {
      try input.setVoiceProcessingEnabled(true)
      if #available(macOS 14.0, *) {
        input.isVoiceProcessingAGCEnabled = !disableAgc
      }
    }

    inputNode = input
    let format = input.outputFormat(forBus: 0)
    currentFormat = format
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
      self?.processAudioBuffer(buffer, time: time)
    }

    try engine.start()
    isCapturing = true
  }
```
> Note: `auAudioUnit.setDeviceID(_:)` and `setVoiceProcessingEnabled(_:)` are throwing macOS APIs on `AVAudioInputNode`. `isVoiceProcessingAGCEnabled` is macOS 14+ (hence the `#available` gate). `processAudioBuffer` already emits `onSampleBufferReceived`.

- [ ] **Step 2: Build**

Run: `cd packages/screen_recorder_macos/example && flutter build macos --debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift
git commit -m "feat(audio): AudioCaptureManager device selection + voice-processing DSP"
```

---

## Task 13: Native — `showMicrophoneMenu` NSMenu

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

- [ ] **Step 1: Add the menu handler**

(a) Register the method in the `handle(_:result:)` switch (next to `getAudioDevices`):
```swift
    case "showMicrophoneMenu":
      showMicrophoneMenu(args: call.arguments as? [String: Any], result: result)
```

(b) Add a menu target (top-level, near the file's other helpers) that records which item fired:
```swift
private final class MicMenuTarget: NSObject {
  enum Action { case device(uid: String, label: String), toggleReduceNoise, toggleDisableAgc, dontRecord }
  var action: Action?
  var deviceUid: String?
  var deviceLabel: String?
  @objc func pickDevice(_ s: NSMenuItem) {
    if let pair = s.representedObject as? [String: String] {
      action = .device(uid: pair["uid"] ?? "", label: pair["label"] ?? "")
    }
  }
  @objc func toggleReduceNoise(_ s: NSMenuItem) { action = .toggleReduceNoise }
  @objc func toggleDisableAgc(_ s: NSMenuItem) { action = .toggleDisableAgc }
  @objc func dontRecord(_ s: NSMenuItem) { action = .dontRecord }
}
```

(c) Add the handler. It seeds the menu from `current`, pops it at the cursor (blocking, like the gear menu), computes the new config, requests mic permission if a device was newly chosen, and returns `{ cancelled, config }`:
```swift
  private func showMicrophoneMenu(args: [String: Any]?, result: @escaping FlutterResult) {
    let current = args // {deviceUid, deviceLabel, reduceNoise, disableAgc} or nil
    let curUid = current?["deviceUid"] as? String
    let curReduceNoise = current?["reduceNoise"] as? Bool ?? false
    let curDisableAgc = current?["disableAgc"] as? Bool ?? false

    DispatchQueue.main.async {
      let target = MicMenuTarget()
      let menu = NSMenu()
      let status = AVCaptureDevice.authorizationStatus(for: .audio)

      if status == .denied || status == .restricted {
        let info = NSMenuItem(
          title: "Microphone access denied — enable in System Settings ▸ Privacy",
          action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
      }

      for dev in AudioDeviceCatalog.inputDevices() {
        let uid = dev["id"] as? String ?? ""
        let name = dev["name"] as? String ?? uid
        let isDefault = dev["isDefault"] as? Bool ?? false
        let item = NSMenuItem(
          title: isDefault ? "\(name) (default)" : name,
          action: #selector(MicMenuTarget.pickDevice(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = ["uid": uid, "label": name]
        item.state = (uid == curUid) ? .on : .off
        menu.addItem(item)
      }

      menu.addItem(.separator())

      let noise = NSMenuItem(title: "Reduce noise and normalize volume",
        action: #selector(MicMenuTarget.toggleReduceNoise(_:)), keyEquivalent: "")
      noise.target = target
      noise.state = curReduceNoise ? .on : .off
      noise.isEnabled = (curUid != nil) // only meaningful with a device selected
      menu.addItem(noise)

      if #available(macOS 14.0, *) {
        let agc = NSMenuItem(title: "Disable auto gain control",
          action: #selector(MicMenuTarget.toggleDisableAgc(_:)), keyEquivalent: "")
        agc.target = target
        agc.state = curDisableAgc ? .on : .off
        agc.isEnabled = (curUid != nil && curReduceNoise)
        menu.addItem(agc)
      }

      menu.addItem(.separator())
      let off = NSMenuItem(title: "Don't record microphone",
        action: #selector(MicMenuTarget.dontRecord(_:)), keyEquivalent: "")
      off.target = target
      off.state = (curUid == nil) ? .on : .off
      menu.addItem(off)

      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

      // Compute the new config from the click.
      func reply(_ config: [String: Any]?) {
        result(["cancelled": false, "config": config as Any])
      }
      func configMap(uid: String, label: String, reduceNoise: Bool, disableAgc: Bool) -> [String: Any] {
        ["deviceUid": uid, "deviceLabel": label, "reduceNoise": reduceNoise, "disableAgc": disableAgc]
      }

      switch target.action {
      case .none:
        result(["cancelled": true, "config": NSNull()])
      case .dontRecord:
        reply(nil)
      case .toggleReduceNoise:
        guard let uid = curUid, let label = current?["deviceLabel"] as? String else { reply(nil); return }
        reply(configMap(uid: uid, label: label, reduceNoise: !curReduceNoise, disableAgc: curDisableAgc))
      case .toggleDisableAgc:
        guard let uid = curUid, let label = current?["deviceLabel"] as? String else { reply(nil); return }
        reply(configMap(uid: uid, label: label, reduceNoise: curReduceNoise, disableAgc: !curDisableAgc))
      case .device(let uid, let label):
        // Newly selecting a device: ensure permission first.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
              if granted {
                reply(configMap(uid: uid, label: label, reduceNoise: curReduceNoise, disableAgc: curDisableAgc))
              } else {
                reply(nil)
              }
            }
          }
        } else if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
          reply(configMap(uid: uid, label: label, reduceNoise: curReduceNoise, disableAgc: curDisableAgc))
        } else {
          reply(nil) // denied/restricted
        }
      }
    }
  }
```
> Ensure `import AVFoundation` (for `AVCaptureDevice`) and `import AppKit` are present at the top of the plugin file (add if missing).

- [ ] **Step 2: Build**

Run: `cd packages/screen_recorder_macos/example && flutter build macos --debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (deferred to Task 15)**

The menu needs the running app + the bar UI; full manual check happens in Task 15. Build success is the gate here.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(audio): native showMicrophoneMenu (NSMenu) with device list + DSP toggles"
```

---

## Task 14: Native — live-path `microphone` wiring

Replace the legacy `captureAudio` bool read on the **live** path with the new `microphone` map, and configure the chosen device + DSP.

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (the `startLiveRecording` handler, ~line 428–523)

- [ ] **Step 1: Implement**

(a) Around line 428, replace:
```swift
    let captureAudio = args["captureAudio"] as? Bool ?? false
```
with:
```swift
    let micArgs = args["microphone"] as? [String: Any]   // nil → don't record mic
    let captureMic = micArgs != nil
```

(b) At the writer construction (~line 491), replace:
```swift
          fps: fps, audioTracks: captureAudio ? [.microphone] : [])
```
with:
```swift
          fps: fps, audioTracks: captureMic ? [.microphone] : [])
```

(c) Replace the live-path audio block (~line 517, the `if captureAudio { ... }` that starts `AudioCaptureManager` and routes `onSampleBufferReceived`) with:
```swift
        if let mic = micArgs {
          let uid = mic["deviceUid"] as? String
          let reduceNoise = mic["reduceNoise"] as? Bool ?? false
          let disableAgc = mic["disableAgc"] as? Bool ?? false
          audioManager.onSampleBufferReceived = { [weak liveWriter] buf in
            liveWriter?.appendAudio(buf, role: .microphone)
          }
          try audioManager.startMicrophoneCapture(
            deviceUid: uid, reduceNoise: reduceNoise, disableAgc: disableAgc)
        }
```
> Use the existing local variable names from the surrounding code for the writer (`liveWriter`) and the audio manager (`audioManager`). If they differ, match them. Keep the existing cursor-tracking block below unchanged.

- [ ] **Step 2: Build**

Run: `cd packages/screen_recorder_macos/example && flutter build macos --debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(audio): live recording captures the selected microphone track"
```

---

## Task 15: End-to-end manual verification

No code (or only tiny fixups). Verify the whole feature on a real machine.

**Files:** none expected (fix-forward only if a check fails — re-enter systematic-debugging).

- [ ] **Step 1: Full Dart test gate**

Run each package's suite; all green:
```bash
cd packages/screen_recorder_platform_interface && flutter test
cd ../screen_recorder_macos && flutter test
cd ../screen_recorder && flutter test
cd ../slipreel_engine && flutter test
```

- [ ] **Step 2: Boot the app (flutter-qa harness)**

Boot the `screen_recorder` app on macOS. Confirm the bar shows the mic control reading **"No microphone"** (grey, micOff icon) by default.

- [ ] **Step 3: Open the mic menu**

Click the mic control. Confirm the native menu lists real input devices (built-in marked "(default)"), the "Reduce noise…" row (disabled until a device is selected), "Disable auto gain control" (present only on macOS 14+), and "Don't record microphone" (checked).

- [ ] **Step 4: Select a device + record**

Pick the built-in mic (grant permission when prompted). The bar control updates to the device name (white, mic icon). Record a display for ~5s while making sound, then stop.

- [ ] **Step 5: Verify the output has audio**

```bash
ffprobe -hide_banner -show_streams -select_streams a "<the recording_*.mp4 in ~/Documents>"
```
Expected: exactly one AAC audio stream (48 kHz). Play the file — audio is audible.

- [ ] **Step 6: Verify "Don't record" produces no audio track**

Set the mic to "Don't record microphone", record again, and `ffprobe` → **no** audio stream.

- [ ] **Step 7: Verify noise reduction doesn't break capture**

Re-select a device, toggle "Reduce noise and normalize volume" on, record → output still has an audible audio track.

- [ ] **Step 8: Final commit (if any fixups were needed)**

```bash
git add -p   # stage only intentional fixes
git commit -m "fix(audio): address issues found in E2E microphone verification"
```

---

## After all tasks

Dispatch a final whole-implementation code review (per subagent-driven-development), then use **superpowers:finishing-a-development-branch** to wrap up `feat/audio-mic-capture` (the user merges; never push without an explicit request).

The deferred **Sub-projects 2 (system audio) & 3 (editor mixing + export downmix)** are specified in `docs/superpowers/specs/2026-05-25-audio-capture-roadmap.md` for a future cycle.
