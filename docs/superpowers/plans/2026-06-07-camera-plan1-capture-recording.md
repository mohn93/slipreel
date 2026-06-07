# Camera — Plan 1: Capture & Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record the user's webcam alongside the screen as a separate, time-aligned `.camera.mov` sidecar (plus a `.camera.json` metadata sidecar), with a live draggable self-view bubble while recording and a camera device picker on the recording bar.

**Architecture:** A new native `CameraCaptureManager` owns an `AVCaptureSession` (video device → `AVCaptureVideoDataOutput`) feeding two consumers: a `CameraSidecarWriter` (`AVAssetWriter` → `<recording>.mp4.camera.mov`, anchored to the screen recording so the two timelines align via a stored microsecond offset) and a draggable, circular self-view `NSPanel`. Dart plumbs a `CameraConfig` through the existing `RecordingSettings` → `startLiveRecording` path (the method channel already spreads `settings.toJson()`), and the recording controller writes the `.camera.json` metadata sidecar on stop. The recording bar's existing disabled "No camera" placeholder becomes a real device chip mirroring the mic chip.

**Tech Stack:** Swift (AVFoundation/AppKit) for capture; Dart/Flutter + Riverpod for control; the `screen_recorder_platform_interface` method-channel contract.

**Spec:** `docs/superpowers/specs/2026-06-07-camera-facecam-design.md` (§1–3, §7 capture/recording portions).

**Scope note:** This is Plan 1 of 3. It ends with aligned sidecar files on disk and a working bar control. Editor placement/preview (Plan 2) and export compositing (Plan 3) are separate plans. Nothing here renders the camera anywhere except the live self-view.

---

## Conventions used in this plan

- **Camera sidecar video path:** derived natively from the screen MP4 path as `outputPath + ".camera.mov"`. Dart never passes a separate path; both sides use this convention.
- **Camera metadata sidecar path:** `outputPath + ".camera.json"`, written by Dart on stop.
- **Alignment:** the camera writer anchors its `AVAssetWriter` session to its own first sample (reusing `LiveRecordingWriter`'s proven pattern). The plugin computes `cameraOffsetMicros = round((cameraFirstSampleHostSeconds − screenFirstFrameHostSeconds) * 1e6)` and returns it in the stop payload. Plan 2's editor shifts camera time by this offset. (This is a deliberate, more-robust refinement of the spec's "anchor to the same origin" wording — no cross-manager coordination, no dropped frames.)
- **Native test policy:** this repo has no Swift XCTest target, and `flutter build macos` is broken in this environment. Native tasks therefore finish with a **compile-check** (`xcodebuild … -destination 'platform=macOS,arch=x86_64' build`) and a **manual verification note**, not an automated test. Dart tasks use real TDD.

**Compile-check command (used by every native task):**
```bash
cd packages/screen_recorder/macos
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -30
```
Expected on success: `** BUILD SUCCEEDED **`.

---

## File structure

**New files**
- `packages/screen_recorder_platform_interface/lib/src/models/camera_config.dart` — `CameraConfig` + `CameraMenuResult`.
- `packages/slipreel_engine/lib/models/camera_sidecar_meta.dart` — `CameraSidecarMeta` (the `.camera.json` model).
- `packages/screen_recorder/lib/state/camera_controller.dart` — `CameraController` (in-memory selection).
- `packages/screen_recorder_macos/macos/Classes/CameraSidecarWriter.swift` — single-track `AVAssetWriter` for the camera.
- `packages/screen_recorder_macos/macos/Classes/CameraSelfViewPanel.swift` — draggable circular self-view window.
- `packages/screen_recorder_macos/macos/Classes/CameraCaptureManager.swift` — session + data output + device resolve + wiring.
- Test files listed per task.

**Modified files**
- `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart` — add `camera` field.
- `packages/screen_recorder_platform_interface/lib/src/models/recording_result.dart` — add camera fields.
- `packages/screen_recorder_platform_interface/lib/src/constants.dart` — new method names.
- `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` — new abstract methods.
- `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` — implement them.
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` — handlers + start/stop/pause wiring.
- `packages/screen_recorder/macos/Runner/Info.plist` — `NSCameraUsageDescription`.
- `packages/screen_recorder/lib/state/recording_state.dart` — camera plumbing in `startRecording`/`stopRecording`.
- `packages/screen_recorder/lib/state/recording_action_router.dart` — read camera config.
- `packages/screen_recorder/lib/ui/bar/recording_bar.dart` — real camera chip.
- `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` — `_onCameraTap` + wiring.

---

## Task 1: `CameraConfig` model (platform interface)

Mirrors `MicrophoneConfig`: a chosen camera device. `null` (absence) means "don't record camera".

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/camera_config.dart`
- Test: `packages/screen_recorder_platform_interface/test/models/camera_config_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/models/camera_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/camera_config.dart';

void main() {
  group('CameraConfig', () {
    test('json round-trips', () {
      const c = CameraConfig(deviceUid: 'cam-uid-1', deviceLabel: 'FaceTime HD');
      final back = CameraConfig.fromJson(c.toJson());
      expect(back, c);
    });

    test('equality and hashCode by value', () {
      const a = CameraConfig(deviceUid: 'u', deviceLabel: 'L');
      const b = CameraConfig(deviceUid: 'u', deviceLabel: 'L');
      const d = CameraConfig(deviceUid: 'u', deviceLabel: 'OTHER');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == d, isFalse);
    });

    test('CameraMenuResult parses a config payload', () {
      final r = CameraMenuResult.fromJson({
        'cancelled': false,
        'config': {'deviceUid': 'u', 'deviceLabel': 'L'},
      });
      expect(r.cancelled, isFalse);
      expect(r.config, const CameraConfig(deviceUid: 'u', deviceLabel: 'L'));
    });

    test('CameraMenuResult parses a null config (don\'t record)', () {
      final r = CameraMenuResult.fromJson({'cancelled': false, 'config': null});
      expect(r.cancelled, isFalse);
      expect(r.config, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/camera_config_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'src/models/camera_config.dart'`.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder_platform_interface/lib/src/models/camera_config.dart

/// A chosen camera (webcam) device. `null` (absence of this config) means
/// "don't record camera". Capture-time only — look/placement is an editor
/// concern handled in Plan 2.
class CameraConfig {
  /// Stable AVCaptureDevice uniqueID, used to re-resolve the device at capture.
  final String deviceUid;

  /// Human-readable device name, shown on the bar's camera control.
  final String deviceLabel;

  const CameraConfig({required this.deviceUid, required this.deviceLabel});

  Map<String, dynamic> toJson() => {
        'deviceUid': deviceUid,
        'deviceLabel': deviceLabel,
      };

  factory CameraConfig.fromJson(Map<String, dynamic> json) => CameraConfig(
        deviceUid: json['deviceUid'] as String,
        deviceLabel: json['deviceLabel'] as String,
      );

  CameraConfig copyWith({String? deviceUid, String? deviceLabel}) =>
      CameraConfig(
        deviceUid: deviceUid ?? this.deviceUid,
        deviceLabel: deviceLabel ?? this.deviceLabel,
      );

  @override
  bool operator ==(Object other) =>
      other is CameraConfig &&
      other.deviceUid == deviceUid &&
      other.deviceLabel == deviceLabel;

  @override
  int get hashCode => Object.hash(deviceUid, deviceLabel);

  @override
  String toString() => 'CameraConfig($deviceLabel)';
}

/// Result of the native camera menu. [cancelled] true means the user dismissed
/// it (no change). When not cancelled, [config] is the new selection, or null
/// for "Don't record camera".
class CameraMenuResult {
  final bool cancelled;
  final CameraConfig? config;

  const CameraMenuResult({required this.cancelled, this.config});

  factory CameraMenuResult.fromJson(Map<String, dynamic> json) {
    final c = json['config'];
    return CameraMenuResult(
      cancelled: json['cancelled'] as bool? ?? false,
      config: c == null
          ? null
          : CameraConfig.fromJson(Map<String, dynamic>.from(c as Map)),
    );
  }
}
```

- [ ] **Step 4: Export it from the package barrel**

In `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`, add an export next to the other model exports (search for `export 'src/models/microphone_config.dart';` and add below it):

```dart
export 'src/models/camera_config.dart';
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/camera_config_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/models/camera_config.dart \
        packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart \
        packages/screen_recorder_platform_interface/test/models/camera_config_test.dart
git commit -m "feat(camera): CameraConfig + CameraMenuResult model"
```

---

## Task 2: Add `camera` to `RecordingSettings`

Threads the camera selection through the existing settings object so `startLiveRecording`'s `...settings.toJson()` spread carries it to native with zero method-channel signature changes.

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart`
- Test: `packages/screen_recorder_platform_interface/test/models/recording_settings_camera_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/models/recording_settings_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/recording_settings.dart';
import 'package:screen_recorder_platform_interface/src/models/camera_config.dart';

void main() {
  group('RecordingSettings.camera', () {
    test('defaults to null and serializes as null', () {
      const s = RecordingSettings(source: RecordingSource.screen);
      expect(s.camera, isNull);
      expect(s.toJson()['camera'], isNull);
    });

    test('round-trips a camera config through json', () {
      const s = RecordingSettings(
        source: RecordingSource.screen,
        camera: CameraConfig(deviceUid: 'cam', deviceLabel: 'FaceTime HD'),
      );
      final back = RecordingSettings.fromJson(s.toJson());
      expect(back.camera, const CameraConfig(deviceUid: 'cam', deviceLabel: 'FaceTime HD'));
    });

    test('copyWith can set and clear camera via the sentinel', () {
      const base = RecordingSettings(
        source: RecordingSource.screen,
        camera: CameraConfig(deviceUid: 'cam', deviceLabel: 'L'),
      );
      // Omitting camera preserves it.
      expect(base.copyWith(frameRate: 60).camera, isNotNull);
      // Passing null clears it.
      expect(base.copyWith(camera: null).camera, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/recording_settings_camera_test.dart`
Expected: FAIL — `The named parameter 'camera' isn't defined`.

- [ ] **Step 3: Implement — add the field, json, and copyWith sentinel**

In `recording_settings.dart`:

a) Add the import at the top (below the existing imports):
```dart
import 'camera_config.dart';
```

b) Add the field after `systemAudio` (line ~14):
```dart
  /// The camera to record, or null for "don't record camera".
  final CameraConfig? camera;
```

c) Add the constructor param after `this.systemAudio,` (line ~24):
```dart
    this.camera,
```

d) Add to `toJson()` after the `systemAudio` entry:
```dart
      'camera': camera?.toJson(),
```

e) In `fromJson`, add a local after `final sys = json['systemAudio'];`:
```dart
    final cam = json['camera'];
```
and add the named arg in the returned `RecordingSettings(...)` after `systemAudio: ...,`:
```dart
      camera: cam == null
          ? null
          : CameraConfig.fromJson(Map<String, dynamic>.from(cam as Map)),
```

f) In `copyWith`, add the sentinel parameter after `Object? systemAudio = _unset,`:
```dart
    Object? camera = _unset,
```
and the resolution in the returned object after `systemAudio: ...,`:
```dart
      camera: identical(camera, _unset)
          ? this.camera
          : camera as CameraConfig?,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/recording_settings_camera_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the package's full test suite (guard against breaking existing settings tests)**

Run: `cd packages/screen_recorder_platform_interface && flutter test`
Expected: PASS (all existing + new).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart \
        packages/screen_recorder_platform_interface/test/models/recording_settings_camera_test.dart
git commit -m "feat(camera): thread CameraConfig through RecordingSettings"
```

---

## Task 3: Camera permission plumbing (constants → interface → method channel → native → Info.plist)

Adds typed `getCameraPermission` / `requestCameraPermission` mirroring the microphone permission methods, and declares `NSCameraUsageDescription`.

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
- Modify: `packages/screen_recorder/macos/Runner/Info.plist`
- Test: `packages/screen_recorder_macos/test/camera_permission_channel_test.dart`

- [ ] **Step 1: Write the failing test (method-channel wire mapping)**

```dart
// packages/screen_recorder_macos/test/camera_permission_channel_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final platform = MethodChannelScreenRecorderMacos();
  final calls = <String>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getCameraPermission') return 'granted';
      if (call.method == 'requestCameraPermission') return 'denied';
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('getCameraPermission maps the wire string to a status', () async {
    final status = await platform.getCameraPermission();
    expect(calls, contains('getCameraPermission'));
    expect(status, PermissionStatus.granted);
  });

  test('requestCameraPermission maps the wire string to a status', () async {
    final status = await platform.requestCameraPermission();
    expect(calls, contains('requestCameraPermission'));
    expect(status, PermissionStatus.denied);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_macos && flutter test test/camera_permission_channel_test.dart`
Expected: FAIL — `The method 'getCameraPermission' isn't defined for the type 'MethodChannelScreenRecorderMacos'`.

- [ ] **Step 3: Add method-name constants**

In `constants.dart`, inside `ScreenRecorderMethods`, after `requestMicrophonePermission` (line ~55):
```dart
  static const String getCameraPermission = 'getCameraPermission';
  static const String requestCameraPermission = 'requestCameraPermission';
  static const String showCameraMenu = 'showCameraMenu';
```

- [ ] **Step 4: Add abstract methods to the platform interface**

In `screen_recorder_platform_interface.dart`, after `requestMicrophonePermission` (line ~165):
```dart
  /// Typed status query for Camera (macOS AVCaptureDevice .video).
  Future<PermissionStatus> getCameraPermission() async =>
      PermissionStatus.unsupported;

  /// Triggers the system camera-permission prompt the first time, otherwise
  /// returns the current status without re-prompting. No-op on unsupported
  /// platforms.
  Future<PermissionStatus> requestCameraPermission() async =>
      PermissionStatus.unsupported;
```

- [ ] **Step 5: Implement in the method channel**

In `screen_recorder_macos_method_channel.dart`, after `requestMicrophonePermission` (line ~130):
```dart
  @override
  Future<PermissionStatus> getCameraPermission() async {
    final wire = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.getCameraPermission,
    );
    return PermissionStatusCodec.fromWire(wire);
  }

  @override
  Future<PermissionStatus> requestCameraPermission() async {
    final wire = await _recordingChannel.invokeMethod<String>(
      ScreenRecorderMethods.requestCameraPermission,
    );
    return PermissionStatusCodec.fromWire(wire);
  }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd packages/screen_recorder_macos && flutter test test/camera_permission_channel_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 7: Add native handlers**

In `ScreenRecorderMacosPlugin.swift`, in the `handle(_:result:)` switch, after the `requestMicrophonePermission` case (line ~274):
```swift
    case "getCameraPermission":
      let status = AVCaptureDevice.authorizationStatus(for: .video)
      switch status {
      case .authorized: result("granted")
      case .denied:     result("denied")
      case .notDetermined: result("notDetermined")
      case .restricted: result("restricted")
      @unknown default: result("notDetermined")
      }
    case "requestCameraPermission":
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          result(granted ? "granted" : "denied")
        }
      }
```

- [ ] **Step 8: Declare the usage string in Info.plist**

In `packages/screen_recorder/macos/Runner/Info.plist`, after the `NSMicrophoneUsageDescription` key/string pair (before `</dict>`):
```xml
	<key>NSCameraUsageDescription</key>
	<string>Slipreel needs camera access to record your webcam alongside your screen.</string>
```

- [ ] **Step 9: Compile-check native**

Run the compile-check command from the conventions section.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/constants.dart \
        packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
        packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart \
        packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift \
        packages/screen_recorder/macos/Runner/Info.plist \
        packages/screen_recorder_macos/test/camera_permission_channel_test.dart
git commit -m "feat(camera): camera permission plumbing + NSCameraUsageDescription"
```

---

## Task 4: `showCameraMenu` (device picker)

The native NSMenu listing video devices + "Don't record camera", mirroring `showMicrophoneMenu`. Returns a `CameraMenuResult`.

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
- Test: `packages/screen_recorder_macos/test/show_camera_menu_channel_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_macos/test/show_camera_menu_channel_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final platform = MethodChannelScreenRecorderMacos();

  test('showCameraMenu forwards current config and parses the chosen device',
      () async {
    Map<dynamic, dynamic>? sentArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'showCameraMenu') {
        sentArgs = call.arguments as Map?;
        return {'cancelled': false, 'config': {'deviceUid': 'cam2', 'deviceLabel': 'External'}};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final result = await platform.showCameraMenu(
        const CameraConfig(deviceUid: 'cam1', deviceLabel: 'FaceTime HD'));
    expect(sentArgs?['deviceUid'], 'cam1');
    expect(result.cancelled, isFalse);
    expect(result.config, const CameraConfig(deviceUid: 'cam2', deviceLabel: 'External'));
  });

  test('null channel result is a cancelled menu', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final result = await platform.showCameraMenu(null);
    expect(result.cancelled, isTrue);
    expect(result.config, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_macos && flutter test test/show_camera_menu_channel_test.dart`
Expected: FAIL — `The method 'showCameraMenu' isn't defined`.

- [ ] **Step 3: Add the abstract method**

In `screen_recorder_platform_interface.dart`, after `showSystemAudioMenu` (line ~230):
```dart
  /// Shows the native camera dropdown (NSMenu) seeded with [current].
  /// Returns the user's choice; see [CameraMenuResult].
  Future<CameraMenuResult> showCameraMenu(CameraConfig? current) {
    throw UnsupportedError('showCameraMenu() is not supported on this platform.');
  }
```

- [ ] **Step 4: Implement in the method channel**

In `screen_recorder_macos_method_channel.dart`, after `showSystemAudioMenu` (line ~307):
```dart
  @override
  Future<CameraMenuResult> showCameraMenu(CameraConfig? current) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.showCameraMenu,
      current?.toJson(),
    );
    if (raw == null) {
      return const CameraMenuResult(cancelled: true);
    }
    return CameraMenuResult.fromJson(raw);
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd packages/screen_recorder_macos && flutter test test/show_camera_menu_channel_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Add the native menu + dispatch case**

In `ScreenRecorderMacosPlugin.swift`, add a dispatch case in `handle(_:result:)` after `showSystemAudioMenu` (line ~195):
```dart
    case "showCameraMenu":
      showCameraMenu(args: call.arguments as? [String: Any], result: result)
```

Add the implementation method after `showSystemAudioMenu(...)` (after line ~504), plus a menu-target class near `MicMenuTarget` (after line ~1353):
```swift
  private func showCameraMenu(args: [String: Any]?, result: @escaping FlutterResult) {
    let curUid = args?["deviceUid"] as? String

    DispatchQueue.main.async {
      let target = CameraMenuTarget()
      let menu = NSMenu()
      let status = AVCaptureDevice.authorizationStatus(for: .video)

      if status == .denied || status == .restricted {
        let info = NSMenuItem(
          title: "Camera access denied — enable in System Settings ▸ Privacy",
          action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
      }

      for dev in CameraCaptureManager.availableDevices() {
        let uid = dev["uid"] ?? ""
        let name = dev["label"] ?? uid
        let item = NSMenuItem(
          title: name,
          action: #selector(CameraMenuTarget.pickDevice(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = ["uid": uid, "label": name]
        item.state = (uid == curUid) ? .on : .off
        menu.addItem(item)
      }

      menu.addItem(.separator())
      let off = NSMenuItem(title: "Don't record camera",
        action: #selector(CameraMenuTarget.dontRecord(_:)), keyEquivalent: "")
      off.target = target
      off.state = (curUid == nil) ? .on : .off
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
      case .device(let uid, let label):
        // Ensure permission before committing a newly selected device.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
          AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
              granted ? reply(["deviceUid": uid, "deviceLabel": label]) : reply(nil)
            }
          }
        } else if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
          reply(["deviceUid": uid, "deviceLabel": label])
        } else {
          reply(nil)
        }
      }
    }
  }
```

```swift
// MARK: - Camera Menu Target  (place near MicMenuTarget)

private final class CameraMenuTarget: NSObject {
  enum Action { case device(uid: String, label: String), dontRecord }
  var action: Action?
  @objc func pickDevice(_ s: NSMenuItem) {
    if let pair = s.representedObject as? [String: String] {
      action = .device(uid: pair["uid"] ?? "", label: pair["label"] ?? "")
    }
  }
  @objc func dontRecord(_ s: NSMenuItem) { action = .dontRecord }
}
```

> Note: `CameraCaptureManager.availableDevices()` is created in Task 7. Until then this file won't compile — Tasks 4→7 land together before the next compile-check. Sequence Task 7 immediately after this one, OR temporarily stub `availableDevices()` returning `[]`. The compile-check for the native side is deferred to **Task 7 Step (compile-check)**.

- [ ] **Step 7: Commit (Dart side verified; native compiles after Task 7)**

```bash
git add packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
        packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart \
        packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift \
        packages/screen_recorder_macos/test/show_camera_menu_channel_test.dart
git commit -m "feat(camera): showCameraMenu device picker (Dart verified)"
```

---

## Task 5: `CameraSidecarWriter.swift` (native)

A single-video-track `AVAssetWriter` that encodes incoming camera `CMSampleBuffer`s to H.264 in `<outputPath>.camera.mov`, anchoring its session to the first sample and applying the same pause/resume PTS rebasing as `LiveRecordingWriter`. Records the first sample's host-clock seconds for cross-track alignment.

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/CameraSidecarWriter.swift`

- [ ] **Step 1: Write the file**

```swift
// packages/screen_recorder_macos/macos/Classes/CameraSidecarWriter.swift
import Foundation
import AVFoundation
import CoreMedia

/// Writes the camera webcam track to its own .mov, time-aligned to the screen
/// recording. Modeled on LiveRecordingWriter but with a single H.264-encoded
/// video input (camera frames arrive uncompressed from AVCaptureVideoDataOutput,
/// so the writer compresses them — no manual VideoToolbox stage).
///
/// The session is anchored to the first appended sample. `firstSampleHostSeconds`
/// captures that sample's host-clock time so the plugin can compute the
/// microsecond offset between the camera and screen timelines.
final class CameraSidecarWriter {
  enum WriterError: LocalizedError {
    case alreadyStarted, cannotAddInput, startFailed(Error?), finalizeFailed(Error?)
    var errorDescription: String? {
      switch self {
      case .alreadyStarted: return "CameraSidecarWriter already started"
      case .cannotAddInput: return "AVAssetWriter would not accept the camera input"
      case .startFailed(let e): return "startWriting failed: \(e?.localizedDescription ?? "?")"
      case .finalizeFailed(let e): return "finishWriting failed: \(e?.localizedDescription ?? "?")"
      }
    }
  }

  private let outputURL: URL
  private let width: Int
  private let height: Int

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var isStarted = false
  private var writerActive = false
  private(set) var frameCount: Int = 0

  /// Host-clock seconds of the first appended sample's PTS. nil until first frame.
  private(set) var firstSampleHostSeconds: Double?

  // Pause/resume — identical semantics to LiveRecordingWriter.
  private var isPaused = false
  private var pauseStart: CMTime?
  private var pausedOffset: CMTime = .zero

  private let queue = DispatchQueue(label: "com.slipreel.screen_recorder.camera-writer")

  init(outputPath: String, width: Int, height: Int) {
    self.outputURL = URL(fileURLWithPath: outputPath)
    self.width = width
    self.height = height
  }

  func start() throws {
    try queue.sync {
      guard !isStarted else { throw WriterError.alreadyStarted }
      try? FileManager.default.removeItem(at: outputURL)
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      writer.movieFragmentInterval = CMTimeMakeWithSeconds(5.0, preferredTimescale: 600)

      let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ]
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw WriterError.cannotAddInput }
      writer.add(input)

      self.assetWriter = writer
      self.videoInput = input
      self.isStarted = true
    }
  }

  /// Append one camera sample. The first call starts the writer session anchored
  /// at that sample's PTS and records its host-clock time.
  func append(_ sampleBuffer: CMSampleBuffer) {
    queue.sync {
      guard isStarted, let writer = assetWriter, let input = videoInput else { return }
      if isPaused { return }
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      if !writerActive {
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: pts)
        // PTS here is on the host time clock (same as SCStream); record seconds.
        firstSampleHostSeconds = CMTimeGetSeconds(pts)
        writerActive = true
      }

      guard input.isReadyForMoreMediaData else { return }
      let rebased = rebaseSampleBuffer(sampleBuffer) ?? sampleBuffer
      input.append(rebased)
      frameCount += 1
    }
  }

  func stop(completion: @escaping (Result<String, Error>) -> Void) {
    queue.async {
      guard self.isStarted, let writer = self.assetWriter else {
        completion(.success(self.outputURL.path)); return
      }
      if self.isPaused { self.isPaused = false; self.pauseStart = nil }
      self.videoInput?.markAsFinished()
      if !self.writerActive {
        self.isStarted = false
        completion(.success(self.outputURL.path)); return
      }
      let path = self.outputURL.path
      writer.finishWriting {
        writer.status == .completed
          ? completion(.success(path))
          : completion(.failure(WriterError.finalizeFailed(writer.error)))
      }
      self.isStarted = false
    }
  }

  func pause() {
    queue.sync {
      guard isStarted, writerActive, !isPaused else { return }
      isPaused = true
      pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
    }
  }

  func resume() {
    queue.sync {
      guard isStarted, isPaused, let start = pauseStart else {
        isPaused = false; pauseStart = nil; return
      }
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(now, start))
      isPaused = false; pauseStart = nil
    }
  }

  private func rebaseSampleBuffer(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
    if pausedOffset == .zero { return nil }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    if count == 0 { return nil }
    var timing = Array(repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
    for i in 0..<count {
      timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, pausedOffset)
      if CMTimeCompare(timing[i].decodeTimeStamp, .invalid) != 0 &&
         CMTimeCompare(timing[i].decodeTimeStamp, .indefinite) != 0 {
        timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, pausedOffset)
      }
    }
    var out: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sb,
      sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
    return status == noErr ? out : nil
  }
}
```

- [ ] **Step 2: Compile-check is deferred to Task 7** (this file is consumed by `CameraCaptureManager`). Proceed to Task 6.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/CameraSidecarWriter.swift
git commit -m "feat(camera): CameraSidecarWriter (aligned .camera.mov writer)"
```

---

## Task 6: `CameraSelfViewPanel.swift` (native self-view)

A borderless, always-on-top, draggable circular `NSPanel` showing an `AVCaptureVideoPreviewLayer`. Reports its final position as a normalized point so Plan 2 can seed the first camera region.

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/CameraSelfViewPanel.swift`

- [ ] **Step 1: Write the file**

```swift
// packages/screen_recorder_macos/macos/Classes/CameraSelfViewPanel.swift
import AVFoundation
import Cocoa

/// A small, draggable, circular self-view window shown while recording so the
/// user can frame themselves. Fed by the shared AVCaptureSession's preview layer.
/// Reports its final center as a normalized point (0..1) in the main screen's
/// visible frame so the editor can seed the first camera region.
final class CameraSelfViewPanel: NSPanel {
  private let previewLayer: AVCaptureVideoPreviewLayer
  private static let diameter: CGFloat = 180

  init(session: AVCaptureSession) {
    self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
    let frame = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
    super.init(contentRect: frame,
               styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let host = NSView(frame: frame)
    host.wantsLayer = true
    host.layer?.cornerRadius = Self.diameter / 2
    host.layer?.masksToBounds = true
    previewLayer.frame = frame
    previewLayer.videoGravity = .resizeAspectFill
    host.layer?.addSublayer(previewLayer)
    contentView = host

    // Default position: bottom-right of the main screen's visible frame, inset.
    if let vf = NSScreen.main?.visibleFrame {
      let x = vf.maxX - Self.diameter - 32
      let y = vf.minY + 32
      setFrameOrigin(NSPoint(x: x, y: y))
    }
  }

  override var canBecomeKey: Bool { false }

  func show() { orderFrontRegardless() }

  /// The final center as a normalized (0..1) point in the main screen's visible
  /// frame, top-left origin (matches the editor's canvas coordinate space).
  func normalizedCenter() -> (x: Double, y: Double) {
    guard let vf = NSScreen.main?.visibleFrame else { return (0.82, 0.82) }
    let c = NSPoint(x: frame.midX, y: frame.midY)
    let nx = (Double(c.x) - Double(vf.minX)) / Double(vf.width)
    // Cocoa origin is bottom-left; flip Y to top-left for the editor.
    let nyBottom = (Double(c.y) - Double(vf.minY)) / Double(vf.height)
    let ny = 1.0 - nyBottom
    return (min(max(nx, 0), 1), min(max(ny, 0), 1))
  }

  func close() { orderOut(nil) }
}
```

- [ ] **Step 2: Compile-check deferred to Task 7.** Proceed to Task 7.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/CameraSelfViewPanel.swift
git commit -m "feat(camera): draggable circular self-view panel"
```

---

## Task 7: `CameraCaptureManager.swift` (native session + wiring)

Owns the `AVCaptureSession`, resolves the device by UID, fans frames to the writer, drives the self-view, and exposes device enumeration. This is the file `showCameraMenu` (Task 4) and the plugin (Task 8) call into.

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/CameraCaptureManager.swift`

- [ ] **Step 1: Write the file**

```swift
// packages/screen_recorder_macos/macos/Classes/CameraCaptureManager.swift
import AVFoundation
import Cocoa
import CoreMedia

/// Captures the webcam during a screen recording. Owns an AVCaptureSession with
/// a video device input and a video-data output; fans each frame to a
/// CameraSidecarWriter (.camera.mov) and a draggable self-view panel.
///
/// Frames carry host-time PTS (same clock as SCStream), so the writer's first
/// sample time aligns with the screen track via a stored offset (computed by the
/// plugin). Capture resolution is capped to 1080p.
final class CameraCaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  struct StopInfo {
    let frameCount: Int
    let width: Int
    let height: Int
    let firstSampleHostSeconds: Double?
    let selfViewX: Double
    let selfViewY: Double
  }

  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let sampleQueue = DispatchQueue(label: "com.slipreel.screen_recorder.camera-capture")

  private var writer: CameraSidecarWriter?
  private var selfView: CameraSelfViewPanel?
  private var outWidth = 0
  private var outHeight = 0

  /// All connected video capture devices as [{uid,label}] for the picker menu.
  static func availableDevices() -> [[String: String]] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
      mediaType: .video, position: .unspecified)
    return discovery.devices.map { ["uid": $0.uniqueID, "label": $0.localizedName] }
  }

  /// Start capturing [deviceUid] to [outputPath].camera.mov and show the self-view.
  /// Throws if the device can't be resolved or the session can't be configured.
  func start(deviceUid: String, outputPath: String) throws {
    let device: AVCaptureDevice
    if let d = AVCaptureDevice(uniqueID: deviceUid) {
      device = d
    } else if let d = AVCaptureDevice.default(for: .video) {
      device = d
    } else {
      throw NSError(domain: "CameraCaptureManager", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No camera device available"])
    }

    session.beginConfiguration()
    session.sessionPreset = .high
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw NSError(domain: "CameraCaptureManager", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
    }
    session.addInput(input)

    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: sampleQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw NSError(domain: "CameraCaptureManager", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add camera output"])
    }
    session.addOutput(output)
    session.commitConfiguration()

    // Resolve capture dimensions (cap to 1080p tall), then create the writer.
    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    var w = Int(dims.width)
    var h = Int(dims.height)
    if h > 1080 {
      let scale = 1080.0 / Double(h)
      w = Int((Double(w) * scale).rounded()) & ~1   // keep even
      h = 1080
    }
    outWidth = max(2, w)
    outHeight = max(2, h)

    let w2 = CameraSidecarWriter(outputPath: outputPath + ".camera.mov",
                                 width: outWidth, height: outHeight)
    try w2.start()
    writer = w2

    session.startRunning()

    DispatchQueue.main.async {
      let panel = CameraSelfViewPanel(session: self.session)
      panel.show()
      self.selfView = panel
    }
  }

  func pause() { writer?.pause() }
  func resume() { writer?.resume() }

  /// Stop the session + self-view, finalize the writer, and return capture info.
  func stop(completion: @escaping (StopInfo) -> Void) {
    session.stopRunning()
    let captured = writer
    let frames = captured?.frameCount ?? 0
    let firstHost = captured?.firstSampleHostSeconds
    let w = outWidth, h = outHeight

    DispatchQueue.main.async {
      let center = self.selfView?.normalizedCenter() ?? (0.82, 0.82)
      self.selfView?.close()
      self.selfView = nil
      captured?.stop { _ in
        completion(StopInfo(frameCount: frames, width: w, height: h,
                            firstSampleHostSeconds: firstHost,
                            selfViewX: center.x, selfViewY: center.y))
      }
    }
  }

  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    writer?.append(sampleBuffer)
  }
}
```

- [ ] **Step 2: Compile-check native (Tasks 4–7 together)**

Run the compile-check command from the conventions section.
Expected: `** BUILD SUCCEEDED **`. (This is the first build that exercises `CameraCaptureManager.availableDevices()` referenced by `showCameraMenu`, plus the writer and panel.)
If it fails, fix the reported Swift API mismatch (e.g. `externalUnknown` deprecation on newer SDKs → use `.external` guarded by `#available`) before continuing.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/CameraCaptureManager.swift
git commit -m "feat(camera): CameraCaptureManager (session + writer + self-view wiring)"
```

---

## Task 8: Plugin wiring — start/stop/pause/resume

Wire `CameraCaptureManager` into the recording lifecycle: start it when `args["camera"]` is present, return camera info in the stop payload, forward pause/resume, and tear it down on partial failure.

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

- [ ] **Step 1: Add a stored property**

Near the other live-recording properties (after `private var systemAudioManager: Any?`, line ~13):
```swift
  private var cameraManager: CameraCaptureManager?
```

- [ ] **Step 2: Start the camera in `startLiveRecording`**

In `startLiveRecording`, after the system-audio start block (after line ~688, before the `liveStartTime` comment), add:
```swift
        if let cam = args["camera"] as? [String: Any],
           let camUid = cam["deviceUid"] as? String {
          let manager = CameraCaptureManager()
          do {
            try manager.start(deviceUid: camUid, outputPath: outputPath)
            self.cameraManager = manager
          } catch {
            // Degrade gracefully: drop the camera, keep recording screen-only.
            NSLog("Camera capture failed to start: \(error)")
          }
        }
```

- [ ] **Step 3: Forward pause/resume**

In `pauseRecording(result:)`, after `writer.pause()` (line ~909):
```swift
    cameraManager?.pause()
```
In `resumeRecording(result:)`, after `writer.resume()` (line ~919):
```swift
    cameraManager?.resume()
```

- [ ] **Step 4: Return camera info from `stopLiveRecording`**

The camera stop is async (finalizing its writer). Restructure the stop payload assembly so it waits for the camera. In `stopLiveRecording`, replace the `writer.stop { stopResult in … }` block (lines ~877–894) with:

```swift
        let cam = self.cameraManager
        self.cameraManager = nil

        writer.stop { stopResult in
          switch stopResult {
          case .success(let path):
            // Compute camera fields (if any), then reply. cam.stop is async.
            let finish: (CameraCaptureManager.StopInfo?) -> Void = { camInfo in
              var payload: [String: Any] = [
                "outputPath": path,
                "droppedFrames": droppedFrames,
                "cpuPctSamples": stats?.cpuPctSamples ?? [],
                "memBytesSamples": (stats?.memBytesSamples ?? []).map { Int($0) },
                "width": self.liveCaptureWidth,
                "height": self.liveCaptureHeight,
              ]
              if let ci = camInfo, ci.frameCount > 0 {
                let screenHost = self.firstVideoFrameHostSeconds ?? ci.firstSampleHostSeconds ?? 0
                let camHost = ci.firstSampleHostSeconds ?? screenHost
                payload["cameraFrameCount"] = ci.frameCount
                payload["cameraWidth"] = ci.width
                payload["cameraHeight"] = ci.height
                payload["cameraOffsetMicros"] = Int((camHost - screenHost) * 1_000_000)
                payload["cameraSelfViewX"] = ci.selfViewX
                payload["cameraSelfViewY"] = ci.selfViewY
              }
              result(payload)
            }
            if let cam = cam {
              cam.stop { info in finish(info) }
            } else {
              finish(nil)
            }
          case .failure(let err):
            cam?.stop { _ in }
            result(FlutterError(code: "LIVE_STOP_FAILED",
                                message: "Failed to finalize: \(err.localizedDescription)",
                                details: nil))
          }
        }
```

This references `self.firstVideoFrameHostSeconds`, which does not exist yet — add it.

- [ ] **Step 5: Capture the screen's first-frame host seconds**

Add a property near `firstVideoFrameAt` (after line ~78):
```swift
  /// Host-clock seconds of the first screen video sample's PTS, used to align
  /// the camera track. Set alongside `firstVideoFrameAt`.
  private var firstVideoFrameHostSeconds: Double?
```

In the `captureManager?.onFrameReceived` closure, inside the `if self.firstVideoFrameAt == nil` block (after line ~652, where `ptsSeconds` is computed), set it:
```swift
            self.firstVideoFrameHostSeconds = CMTimeGetSeconds(pts)
```
(Place it right after `self.firstVideoFrameAt = FirstFrameTiming.captureInstant(...)`.)

Also clear it wherever `firstVideoFrameAt = nil` is set — in `stopLiveRecording` (line ~862) and `tearDownPartialLiveRecording` (line ~815), add alongside each:
```swift
        self.firstVideoFrameHostSeconds = nil
```
(stop path uses `firstVideoFrameAt = nil` with no `self.`; match the surrounding style — in `stopLiveRecording` it's `firstVideoFrameAt = nil`, so add `firstVideoFrameHostSeconds = nil`; in teardown it's `firstVideoFrameAt = nil`, add `firstVideoFrameHostSeconds = nil`.)

- [ ] **Step 6: Tear down camera on partial failure**

In `tearDownPartialLiveRecording()`, after the system-audio teardown (after line ~803, `self.systemAudioManager = nil`):
```swift
    if let cam = cameraManager {
      cam.stop { _ in }
      cameraManager = nil
    }
```

- [ ] **Step 7: Compile-check native**

Run the compile-check command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(camera): wire CameraCaptureManager into recording lifecycle"
```

---

## Task 9: Dart side — result fields, `.camera.json` meta, controller, recording plumbing

Surface the native camera fields, persist the `.camera.json` sidecar, and thread `CameraConfig` from a new `CameraController` through to `startRecording`.

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/recording_result.dart`
- Create: `packages/slipreel_engine/lib/models/camera_sidecar_meta.dart`
- Create: `packages/screen_recorder/lib/state/camera_controller.dart`
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Modify: `packages/screen_recorder/lib/state/recording_action_router.dart`
- Tests:
  - `packages/screen_recorder_platform_interface/test/models/recording_result_camera_test.dart`
  - `packages/slipreel_engine/test/models/camera_sidecar_meta_test.dart`

### 9a. RecordingResult camera fields

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/models/recording_result_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/recording_result.dart';

void main() {
  test('parses camera fields when present', () {
    final r = RecordingResult.fromMap({
      'outputPath': '/tmp/r.mp4', 'width': 1920, 'height': 1080,
      'cameraFrameCount': 300, 'cameraWidth': 1280, 'cameraHeight': 720,
      'cameraOffsetMicros': 12000, 'cameraSelfViewX': 0.8, 'cameraSelfViewY': 0.75,
    });
    expect(r.cameraFrameCount, 300);
    expect(r.cameraWidth, 1280);
    expect(r.cameraHeight, 720);
    expect(r.cameraOffsetMicros, 12000);
    expect(r.cameraSelfViewX, 0.8);
    expect(r.cameraSelfViewY, 0.75);
    expect(r.hasCamera, isTrue);
  });

  test('absent camera fields => hasCamera false', () {
    final r = RecordingResult.fromMap({'outputPath': '/tmp/r.mp4', 'width': 1, 'height': 1});
    expect(r.cameraFrameCount, 0);
    expect(r.hasCamera, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/recording_result_camera_test.dart`
Expected: FAIL — `The getter 'cameraFrameCount' isn't defined`.

- [ ] **Step 3: Implement**

Replace the body of `recording_result.dart` with:
```dart
import 'native_perf_stats.dart';

/// Result of a live recording session: the output file path plus the actual
/// capture dimensions, native perf stats, and (when a camera was recorded) the
/// camera sidecar dimensions, frame count, alignment offset, and self-view
/// position.
class RecordingResult {
  final String outputPath;
  final int width;
  final int height;
  final NativePerfStats perfStats;

  /// Camera sidecar info. [cameraFrameCount] == 0 means no camera was recorded.
  final int cameraFrameCount;
  final int cameraWidth;
  final int cameraHeight;

  /// Microseconds to add to a camera-track time to get screen-track time
  /// (`cameraFirst − screenFirst`). Usually small; can be negative.
  final int cameraOffsetMicros;

  /// Self-view final center, normalized (0..1) in canvas space, top-left origin.
  final double cameraSelfViewX;
  final double cameraSelfViewY;

  const RecordingResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.perfStats,
    this.cameraFrameCount = 0,
    this.cameraWidth = 0,
    this.cameraHeight = 0,
    this.cameraOffsetMicros = 0,
    this.cameraSelfViewX = 0.82,
    this.cameraSelfViewY = 0.82,
  });

  bool get hasCamera => cameraFrameCount > 0;

  factory RecordingResult.fromMap(Map<String, dynamic> map) {
    return RecordingResult(
      outputPath: map['outputPath'] as String? ?? '',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      perfStats: NativePerfStats.fromMap(map),
      cameraFrameCount: (map['cameraFrameCount'] as num?)?.toInt() ?? 0,
      cameraWidth: (map['cameraWidth'] as num?)?.toInt() ?? 0,
      cameraHeight: (map['cameraHeight'] as num?)?.toInt() ?? 0,
      cameraOffsetMicros: (map['cameraOffsetMicros'] as num?)?.toInt() ?? 0,
      cameraSelfViewX: (map['cameraSelfViewX'] as num?)?.toDouble() ?? 0.82,
      cameraSelfViewY: (map['cameraSelfViewY'] as num?)?.toDouble() ?? 0.82,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/recording_result_camera_test.dart`
Expected: PASS (2 tests).

### 9b. CameraSidecarMeta model

- [ ] **Step 5: Write the failing test**

```dart
// packages/slipreel_engine/test/models/camera_sidecar_meta_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';

void main() {
  test('json round-trips', () {
    const m = CameraSidecarMeta(
      deviceLabel: 'FaceTime HD', width: 1280, height: 720,
      frameCount: 300, offsetMicros: 12000, selfViewX: 0.8, selfViewY: 0.75);
    final back = CameraSidecarMeta.fromJson(jsonDecode(jsonEncode(m.toJson())));
    expect(back, m);
  });

  test('saveForVideo writes <video>.camera.json then loads back', () async {
    final dir = await Directory.systemTemp.createTemp('cam_meta');
    final video = '${dir.path}/r.mp4';
    const m = CameraSidecarMeta(
      deviceLabel: 'Cam', width: 640, height: 480,
      frameCount: 10, offsetMicros: 0, selfViewX: 0.5, selfViewY: 0.5);
    await m.saveForVideo(video);
    final f = File('$video.camera.json');
    expect(f.existsSync(), isTrue);
    final loaded = await CameraSidecarMeta.loadForVideo(video);
    expect(loaded, m);
    await dir.delete(recursive: true);
  });

  test('loadForVideo returns null when absent', () async {
    final loaded = await CameraSidecarMeta.loadForVideo('/no/such/file.mp4');
    expect(loaded, isNull);
  });
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_sidecar_meta_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../camera_sidecar_meta.dart'`.

- [ ] **Step 7: Implement**

```dart
// packages/slipreel_engine/lib/models/camera_sidecar_meta.dart
import 'dart:convert';
import 'dart:io';

/// Metadata for a recorded camera sidecar, persisted as `<video>.camera.json`.
/// Its presence is the editor's signal that a `<video>.camera.mov` exists and a
/// camera track can be shown. The actual video lives in the .camera.mov.
class CameraSidecarMeta {
  final String deviceLabel;
  final int width;
  final int height;
  final int frameCount;

  /// Microseconds to add to a camera-track time to reach screen-track time.
  final int offsetMicros;

  /// Self-view final center, normalized (0..1) in canvas space, top-left origin.
  final double selfViewX;
  final double selfViewY;

  const CameraSidecarMeta({
    required this.deviceLabel,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.offsetMicros,
    required this.selfViewX,
    required this.selfViewY,
  });

  Map<String, dynamic> toJson() => {
        'deviceLabel': deviceLabel,
        'width': width,
        'height': height,
        'frameCount': frameCount,
        'offsetMicros': offsetMicros,
        'selfViewX': selfViewX,
        'selfViewY': selfViewY,
      };

  factory CameraSidecarMeta.fromJson(Map<String, dynamic> json) => CameraSidecarMeta(
        deviceLabel: json['deviceLabel'] as String? ?? 'Camera',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
        offsetMicros: (json['offsetMicros'] as num?)?.toInt() ?? 0,
        selfViewX: (json['selfViewX'] as num?)?.toDouble() ?? 0.82,
        selfViewY: (json['selfViewY'] as num?)?.toDouble() ?? 0.82,
      );

  /// Path of the camera video for a given screen video path.
  static String moviePathForVideo(String videoPath) => '$videoPath.camera.mov';

  Future<void> saveForVideo(String videoPath) async {
    final file = File('$videoPath.camera.json');
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(toJson()));
  }

  static Future<CameraSidecarMeta?> loadForVideo(String videoPath) async {
    final file = File('$videoPath.camera.json');
    if (!file.existsSync()) return null;
    try {
      return CameraSidecarMeta.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CameraSidecarMeta &&
      other.deviceLabel == deviceLabel &&
      other.width == width &&
      other.height == height &&
      other.frameCount == frameCount &&
      other.offsetMicros == offsetMicros &&
      other.selfViewX == selfViewX &&
      other.selfViewY == selfViewY;

  @override
  int get hashCode => Object.hash(
      deviceLabel, width, height, frameCount, offsetMicros, selfViewX, selfViewY);
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_sidecar_meta_test.dart`
Expected: PASS (3 tests).

### 9c. CameraController

- [ ] **Step 9: Write the failing test**

```dart
// packages/screen_recorder/test/state/camera_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/camera_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('defaults to off (null) and updates on set', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(cameraControllerProvider), isNull);
    c.read(cameraControllerProvider.notifier)
        .set(const CameraConfig(deviceUid: 'u', deviceLabel: 'L'));
    expect(c.read(cameraControllerProvider),
        const CameraConfig(deviceUid: 'u', deviceLabel: 'L'));
  });
}
```

- [ ] **Step 10: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/camera_controller_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 11: Implement**

```dart
// packages/screen_recorder/lib/state/camera_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current camera selection (null = "don't record camera").
/// In-memory only — resets to off each launch, mirroring MicrophoneController.
class CameraController extends StateNotifier<CameraConfig?> {
  CameraController() : super(null);

  void set(CameraConfig? config) {
    if (config != state) state = config;
  }
}

final cameraControllerProvider =
    StateNotifierProvider<CameraController, CameraConfig?>(
        (ref) => CameraController());
```

- [ ] **Step 12: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/camera_controller_test.dart`
Expected: PASS.

### 9d. RecordingController plumbing

- [ ] **Step 13: Thread camera into `startRecording` and write the sidecar on stop**

In `recording_state.dart`:

a) Add the import near the other engine model imports (line ~13):
```dart
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';
```

b) Add a `camera` parameter to `startRecording` (signature at line ~124):
```dart
    CameraConfig? camera,
```
(place after `SystemAudioConfig? systemAudio,`).

c) Add a camera permission gate after the microphone gate (after line ~151):
```dart
    if (camera != null &&
        permissions != null &&
        permissions.camera != PermissionStatus.granted &&
        permissions.camera != PermissionStatus.unsupported) {
      await onDenied?.call(PermissionKind.camera);
      return;
    }
```
> Depends on `PermissionsSnapshot.camera` and `PermissionKind.camera`. If these don't exist yet in `permissions_controller.dart`, add them in this step: a `camera` field on `PermissionsSnapshot` (default `PermissionStatus.unsupported`) and a `PermissionKind.camera` enum value. Grep `permissions_controller.dart` for `microphone` and mirror each occurrence for `camera`. (If wiring the full permissions bus is out of appetite here, gate only on a non-null `camera` + `onDenied`-less call and defer the bus hookup — but prefer mirroring mic.)

d) Pass `camera` into the built `RecordingSettings` (line ~178):
```dart
        camera: camera,
```
(place after `systemAudio: systemAudio,`).

e) In `stopRecording`, after the keystroke sidecar save block (after line ~274, before the metadata comment), persist the camera meta:
```dart
      // Save camera metadata sidecar when the native side recorded a camera.
      if (result.hasCamera) {
        final camMeta = CameraSidecarMeta(
          deviceLabel: 'Camera',
          width: result.cameraWidth,
          height: result.cameraHeight,
          frameCount: result.cameraFrameCount,
          offsetMicros: result.cameraOffsetMicros,
          selfViewX: result.cameraSelfViewX,
          selfViewY: result.cameraSelfViewY,
        );
        await camMeta.saveForVideo(result.outputPath);
        AppLogger.recording.i('Camera sidecar saved: ${result.cameraFrameCount} frames');
      }
```

- [ ] **Step 14: Read the camera config in the action router**

In `recording_action_router.dart`:

a) Add the import (after `import 'microphone_controller.dart';`):
```dart
import 'camera_controller.dart';
```

b) In `doStart()`, add a local (after `SystemAudioConfig? sysAudioConfig;`, line ~33):
```dart
      CameraConfig? cameraConfig;
```

c) In the try block that reads audio configs (after line ~39):
```dart
        cameraConfig = _container.read(cameraControllerProvider);
```

d) Pass it to `startRecording` (after `systemAudio: sysAudioConfig,`, line ~46):
```dart
        camera: cameraConfig,
```

- [ ] **Step 15: Run the affected suites**

Run:
```bash
cd packages/screen_recorder_platform_interface && flutter test
cd ../slipreel_engine && flutter test test/models/camera_sidecar_meta_test.dart
cd ../screen_recorder && flutter test test/state/camera_controller_test.dart
```
Expected: PASS. (If you added `PermissionsSnapshot.camera`, also run any `permissions_controller` tests.)

- [ ] **Step 16: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/models/recording_result.dart \
        packages/screen_recorder_platform_interface/test/models/recording_result_camera_test.dart \
        packages/slipreel_engine/lib/models/camera_sidecar_meta.dart \
        packages/slipreel_engine/test/models/camera_sidecar_meta_test.dart \
        packages/screen_recorder/lib/state/camera_controller.dart \
        packages/screen_recorder/test/state/camera_controller_test.dart \
        packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/lib/state/recording_action_router.dart \
        packages/screen_recorder/lib/state/permissions_controller.dart
git commit -m "feat(camera): result fields, .camera.json sidecar, controller + recording plumbing"
```

---

## Task 10: Recording bar camera chip

Replace the disabled `_AvPlaceholder('No camera')` with a real `_CameraControl` chip mirroring `_MicControl`, and wire `_onCameraTap` in the bar host.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Test: `packages/screen_recorder/test/ui/bar/camera_control_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/bar/camera_control_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  testWidgets('camera control shows label and fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CameraControlForTest(
          camera: const CameraConfig(deviceUid: 'u', deviceLabel: 'FaceTime HD'),
          onTap: () => taps++,
        ),
      ),
    ));
    expect(find.text('FaceTime HD'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bar-camera')));
    expect(taps, 1);
  });

  testWidgets('camera control shows "No camera" when off', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CameraControlForTest(camera: null, onTap: () {}),
      ),
    ));
    expect(find.text('No camera'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/camera_control_test.dart`
Expected: FAIL — `CameraControlForTest` isn't defined.

- [ ] **Step 3: Add the camera chip + params to `recording_bar.dart`**

a) Add `import 'package:lucide_icons_flutter/lucide_icons.dart';` is already present. Add params to `RecordingBar` (after `required this.onSystemAudioTap,` in the constructor, and matching fields):
```dart
    this.camera,
    required this.onCameraTap,
```
Fields (after the `onSystemAudioTap` field, ~line 61):
```dart
  /// Current camera selection (null = off).
  final CameraConfig? camera;

  /// Fired when the camera control is tapped (opens the native camera menu).
  final VoidCallback onCameraTap;
```

b) Replace the placeholder line (line ~118):
```dart
            const _AvPlaceholder(icon: LucideIcons.videoOff, label: 'No camera'),
```
with:
```dart
            _CameraControl(camera: camera, onTap: onCameraTap),
```

c) Add the `_CameraControl` widget + a test wrapper (place after `_SystemAudioControl` / its `SystemAudioControlForTest`, ~line 408):
```dart
/// Live camera control: icon + (truncated) device name + chevron, mirroring
/// [_MicControl]. Greyed when off. Tapping opens the native camera menu.
class _CameraControl extends StatefulWidget {
  const _CameraControl({required this.camera, required this.onTap});

  final CameraConfig? camera;
  final VoidCallback onTap;

  @override
  State<_CameraControl> createState() => _CameraControlState();
}

class _CameraControlState extends State<_CameraControl> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.camera != null;
    final label = on ? widget.camera!.deviceLabel : 'No camera';
    final active = on || _hover;
    return SpringHoverButton(
      key: const Key('bar-camera'),
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
                  Icon(on ? LucideIcons.video : LucideIcons.videoOff,
                      size: 22, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(label,
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

/// Test-only public wrapper around the private [_CameraControl].
@visibleForTesting
class CameraControlForTest extends StatelessWidget {
  const CameraControlForTest({super.key, this.camera, required this.onTap});
  final CameraConfig? camera;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) =>
      _CameraControl(camera: camera, onTap: onTap);
}
```
> `_AvPlaceholder` is now unused. Delete the `_AvPlaceholder` class (lines ~188–235) to avoid an analyzer "unused element" warning.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/camera_control_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the host (`recording_bar_screen.dart`)**

a) Add the import near the other state imports:
```dart
import '../../state/camera_controller.dart';
```

b) In `_buildBar()` (the `RecordingBar(...)` call, ~line 175), add:
```dart
        camera: ref.watch(cameraControllerProvider),
        onCameraTap: _onCameraTap,
```
(place after `onSystemAudioTap: _onSystemAudioTap,`).

c) Add the handler after `_onSystemAudioTap` (~line 237):
```dart
  Future<void> _onCameraTap() async {
    final current = ref.read(cameraControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showCameraMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(cameraControllerProvider.notifier).set(result.config);
  }
```

- [ ] **Step 6: Analyze + run the screen_recorder bar tests**

Run:
```bash
cd packages/screen_recorder && flutter analyze lib/ui/bar/recording_bar.dart lib/ui/bar/recording_bar_screen.dart
cd packages/screen_recorder && flutter test test/ui/bar/
```
Expected: no analyzer errors; bar tests PASS.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/camera_control_test.dart
git commit -m "feat(camera): recording-bar camera device chip + host wiring"
```

---

## Final verification (whole plan)

- [ ] **Run the full analyze + test sweep**

```bash
melos run analyze --no-select
melos run test --no-select
```
Expected: zero new analyzer warnings; all tests pass.

- [ ] **Native compile-check**

Run the compile-check command from the conventions section. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Manual verification on a real Mac (requires user)**

These cannot be automated here (native capture + hardware + window drag + the broken `flutter build macos`). Hand to the user:
1. Launch the app; the recording bar shows a **Camera** chip ("No camera"). Tap it → device menu lists webcams + "Don't record camera". Pick one → first launch prompts for camera permission; chip shows the device name.
2. Start a recording → a **circular self-view bubble** appears; drag it to a corner.
3. Pause/resume mid-recording → self-view stays; no crash.
4. Stop → next to `recording_<ts>.mp4` there is a `recording_<ts>.mp4.camera.mov` and a `recording_<ts>.mp4.camera.json`. Open the `.mov` in QuickTime — it plays the webcam.
5. Inspect `.camera.json`: `frameCount > 0`, plausible `width`/`height`, a small `offsetMicros`, and `selfViewX/Y` near where the bubble was left.
6. Record with the camera **off** → no `.camera.*` files are produced; recording is unaffected.
7. Deny camera permission, then record with a camera selected → recording proceeds **screen-only**, no `.camera.*` files, no crash (graceful degrade).

---

## Self-review (completed by plan author)

- **Spec coverage (§1–3, §7 capture/recording):** capture manager + session + 1080p cap (Task 7) ✓; sidecar writer with pause/resume rebase + alignment (Task 5/8) ✓; self-view panel + seed position (Task 6/8/9) ✓; device picker + bar chip (Task 4/10) ✓; `cameraDevice` through `RecordingSettings` (Task 2) ✓; `.camera.json` metadata (Task 9) ✓; `NSCameraUsageDescription` + permission (Task 3) ✓; graceful degrade on permission/device failure (Task 8 NSLog path + manual check 7) ✓. **Deferred to Plan 2/3 (correctly):** editor model, preview, export compositing.
- **Alignment-offset deviation from spec wording** is called out explicitly in the conventions section.
- **Type consistency:** `CameraConfig` (Task 1) → `RecordingSettings.camera` (Task 2) → native `args["camera"]` (Task 8) → `RecordingResult.camera*` (Task 9a) → `CameraSidecarMeta` (Task 9b). `availableDevices()`/`StopInfo` names match between Tasks 4/7/8. `cameraControllerProvider` matches between Tasks 9c/9d/10.
- **Cross-task dependency note:** native Tasks 4–7 share one compile-check at Task 7 Step 2 (since `showCameraMenu` references `CameraCaptureManager.availableDevices()`). This is stated at each affected step.
- **Open risk:** Task 9d touches `permissions_controller.dart` (adding `PermissionsSnapshot.camera` / `PermissionKind.camera`). The executing agent must grep-and-mirror the microphone wiring there; if the permissions bus is larger than expected, the step gives a documented fallback.
