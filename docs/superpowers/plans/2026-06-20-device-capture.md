# Device Capture (iPhone/iPad over USB) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the recording bar's Device chip record a USB-connected iPhone/iPad screen + audio to an `.mp4` that opens in the existing editor.

**Architecture:** A new native `DeviceCaptureManager` drives an `AVCaptureSession` over the external iOS device, supplying raw video frames + raw audio via callbacks. The plugin's new `startDeviceRecording` wires those into the SAME `VideoToolboxEncoder` → `LiveRecordingWriter` pipeline the screen path uses (so output format, fragmented-MP4 recovery, and finalize are shared) and reuses the existing `stopLiveRecording`. A new `RecordingSource.device` + a Flutter device picker flow through the existing start/countdown/editor path.

**Tech Stack:** Flutter + flutter_riverpod (StateNotifier), Swift/AVFoundation (AVCaptureSession), CoreMediaIO (DAL device enablement), melos monorepo (`screen_recorder`, `screen_recorder_platform_interface`, `screen_recorder_macos`).

**Spec:** `docs/superpowers/specs/2026-06-20-device-capture-design.md`

## Global Constraints

- iPhone + iPad over USB only (AVFoundation external device). No AirPlay, no Android.
- Device audio captured by default (toggleable) → mapped to the existing `systemAudio` `AudioTrackRole` so the editor's system-audio track + mixing handle it unchanged. Mic stays the mic track.
- Device recordings write NO `.cursor.json` / `.keystrokes.json` sidecars (no input tracking on a touch device).
- Native cannot be unit-tested here; verify native via `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build` (the env's `flutter build macos` is broken). Capture itself is user-verified with a physical device.
- Dart work is TDD (red → green). Run the WHOLE package test suite before finishing, not just per-task tests.
- Stage only the exact files each task lists — never `git add -A` (the repo has unrelated untracked files: `.codex/`, `devtools_options.yaml`, `Podfile.lock`, docs specs).

---

### Task 1: `DeviceSource` model + `RecordingSource.device` + platform interface methods

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart` (add `device` to `RecordingSource`)
- Create: `packages/screen_recorder_platform_interface/lib/src/models/device_source.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` (add `listDevices()` + `startDeviceRecording(...)`)
- Modify: `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (export `device_source.dart` — check the barrel file's existing exports and match)
- Test: `packages/screen_recorder_platform_interface/test/device_source_test.dart`

**Interfaces:**
- Produces: `enum RecordingSource { screen, window, area, device }`; `enum DeviceKind { phone, tablet }`; `class DeviceSource { final String id; final String name; final DeviceKind kind; ... }` with `toJson()/fromJson(Map)`; `Future<List<DeviceSource>> listDevices()`; `Future<void> startDeviceRecording({required String deviceId, required bool captureDeviceAudio, required bool captureMic, required String outputPath})`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/device_source_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('DeviceSource round-trips through JSON', () {
    const s = DeviceSource(id: 'uid-1', name: 'Mohanned\'s iPhone', kind: DeviceKind.phone);
    final j = s.toJson();
    expect(j, {'id': 'uid-1', 'name': "Mohanned's iPhone", 'kind': 'phone'});
    final back = DeviceSource.fromJson(j);
    expect(back.id, 'uid-1');
    expect(back.name, "Mohanned's iPhone");
    expect(back.kind, DeviceKind.phone);
  });

  test('DeviceKind.fromName maps native labels; unknown → tablet/phone fallback', () {
    expect(DeviceSource.fromJson({'id': 'a', 'name': 'iPad', 'kind': 'tablet'}).kind, DeviceKind.tablet);
    // Unknown kind string falls back to phone (most common).
    expect(DeviceSource.fromJson({'id': 'a', 'name': 'X', 'kind': 'weird'}).kind, DeviceKind.phone);
  });

  test('RecordingSource has a device value', () {
    expect(RecordingSource.values.contains(RecordingSource.device), isTrue);
  });
}
```

- [ ] **Step 2: Run it, confirm fail**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/device_source_test.dart`
Expected: FAIL (DeviceSource/DeviceKind undefined, RecordingSource.device missing).

- [ ] **Step 3: Add `device` to the enum**

In `recording_settings.dart`, change:
```dart
enum RecordingSource {
  screen,
  window,
  area,
  device,
}
```

- [ ] **Step 4: Create the model**

```dart
// packages/screen_recorder_platform_interface/lib/src/models/device_source.dart

/// A connected external recordable device (iPhone/iPad over USB).
enum DeviceKind { phone, tablet }

class DeviceSource {
  const DeviceSource({required this.id, required this.name, required this.kind});

  /// Stable AVFoundation uniqueID of the capture device.
  final String id;

  /// Human label, e.g. "Mohanned's iPhone".
  final String name;

  final DeviceKind kind;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind == DeviceKind.tablet ? 'tablet' : 'phone',
      };

  factory DeviceSource.fromJson(Map<String, dynamic> json) => DeviceSource(
        id: json['id'] as String,
        name: json['name'] as String,
        // Unknown/missing → phone (the common case).
        kind: (json['kind'] as String?) == 'tablet'
            ? DeviceKind.tablet
            : DeviceKind.phone,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceSource &&
      other.id == id &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, kind);
}
```

- [ ] **Step 5: Add the abstract platform methods**

In `screen_recorder_platform_interface.dart` (the abstract class), add (near `pickSource`):
```dart
/// Enumerate connected external recordable devices (iPhone/iPad over USB).
/// Returns empty when none are connected/trusted.
Future<List<DeviceSource>> listDevices() {
  throw UnsupportedError('listDevices() is not supported on this platform.');
}

/// Start recording the given device to [outputPath].
Future<void> startDeviceRecording({
  required String deviceId,
  required bool captureDeviceAudio,
  required bool captureMic,
  required String outputPath,
}) {
  throw UnsupportedError(
    'startDeviceRecording() is not supported on this platform.',
  );
}
```
Ensure the barrel export file exports `src/models/device_source.dart` (match how it exports `recording_settings.dart`).

- [ ] **Step 6: Run it, confirm pass**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/device_source_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 7: Analyze + commit**

```bash
cd packages/screen_recorder_platform_interface && flutter analyze lib test/device_source_test.dart
git add packages/screen_recorder_platform_interface/lib/src/models/device_source.dart \
  packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart \
  packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
  packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart \
  packages/screen_recorder_platform_interface/test/device_source_test.dart
git commit -m "feat(device): RecordingSource.device + DeviceSource model + platform methods"
```

---

### Task 2: Method-channel implementation of `listDevices` / `startDeviceRecording`

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Modify: the methods-name constants file (find `ScreenRecorderMethods` — likely `packages/screen_recorder_macos/lib/...`; grep `class ScreenRecorderMethods` / `startLiveRecording =`). Add `listDevices` and `startDeviceRecording` constants matching the existing string style.
- Test: `packages/screen_recorder_macos/test/method_channel_device_test.dart`

**Interfaces:**
- Consumes: `DeviceSource` (Task 1), method-name constants.
- Produces: concrete `listDevices()` returning parsed `DeviceSource`s; `startDeviceRecording(...)` invoking the channel with `{deviceId, captureDeviceAudio, captureMic, outputPath}`.

- [ ] **Step 1: Write the failing test** (uses the Flutter mock method-channel messenger)

```dart
// packages/screen_recorder_macos/test/method_channel_device_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = MethodChannelScreenRecorderMacos();
  // The recording channel name — read it from the class; the test below uses
  // whatever channel listDevices/startDeviceRecording invoke. Match the
  // existing channel the class already uses for startLiveRecording.
  const channel = MethodChannel('screen_recorder_macos/recording');
  final log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'listDevices') {
        return [
          {'id': 'uid-1', 'name': 'iPhone', 'kind': 'phone'},
          {'id': 'uid-2', 'name': 'iPad', 'kind': 'tablet'},
        ];
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    log.clear();
  });

  test('listDevices parses the native list into DeviceSources', () async {
    final devices = await platform.listDevices();
    expect(devices.map((d) => d.id), ['uid-1', 'uid-2']);
    expect(devices[1].kind, DeviceKind.tablet);
  });

  test('startDeviceRecording forwards args over the channel', () async {
    await platform.startDeviceRecording(
      deviceId: 'uid-1',
      captureDeviceAudio: true,
      captureMic: false,
      outputPath: '/tmp/out.mp4',
    );
    final call = log.firstWhere((c) => c.method == 'startDeviceRecording');
    expect(call.arguments['deviceId'], 'uid-1');
    expect(call.arguments['captureDeviceAudio'], true);
    expect(call.arguments['captureMic'], false);
    expect(call.arguments['outputPath'], '/tmp/out.mp4');
  });
}
```
> If the recording `MethodChannel` name differs, read the class's existing channel field and use that exact name in the test's `channel` constant.

- [ ] **Step 2: Run it, confirm fail** — `cd packages/screen_recorder_macos && flutter test test/method_channel_device_test.dart` → FAIL (methods missing).

- [ ] **Step 3: Add the method-name constants**

In the `ScreenRecorderMethods` constants, add (matching existing style):
```dart
static const String listDevices = 'listDevices';
static const String startDeviceRecording = 'startDeviceRecording';
```

- [ ] **Step 4: Implement the channel methods**

In `MethodChannelScreenRecorderMacos` (use the SAME `_recordingChannel` field `startLiveRecording` uses):
```dart
@override
Future<List<DeviceSource>> listDevices() async {
  final raw = await _recordingChannel
      .invokeListMethod<dynamic>(ScreenRecorderMethods.listDevices);
  if (raw == null) return const [];
  return raw
      .map((e) => DeviceSource.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
}

@override
Future<void> startDeviceRecording({
  required String deviceId,
  required bool captureDeviceAudio,
  required bool captureMic,
  required String outputPath,
}) async {
  await _recordingChannel.invokeMethod<void>(
    ScreenRecorderMethods.startDeviceRecording,
    {
      'deviceId': deviceId,
      'captureDeviceAudio': captureDeviceAudio,
      'captureMic': captureMic,
      'outputPath': outputPath,
    },
  );
}
```
Add `import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';` if not already imported (for `DeviceSource`).

- [ ] **Step 5: Run it, confirm pass** — 2 tests green.

- [ ] **Step 6: Analyze + commit**

```bash
cd packages/screen_recorder_macos && flutter analyze lib/screen_recorder_macos_method_channel.dart
git add packages/screen_recorder_macos/lib/ packages/screen_recorder_macos/test/method_channel_device_test.dart
git commit -m "feat(device): method-channel listDevices + startDeviceRecording"
```

---

### Task 3: Native `DeviceCatalog.swift` (enumerate + DAL enable) + plugin `listDevices`

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/DeviceCatalog.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (DAL enable at init; `case "listDevices"`)

**Interfaces:**
- Produces: `DeviceCatalog.enableScreenCaptureDevices()`, `DeviceCatalog.connectedDevices() -> [[String: String]]` (each `{"id","name","kind"}`).

- [ ] **Step 1: Implement `DeviceCatalog.swift`**

```swift
// packages/screen_recorder_macos/macos/Classes/DeviceCatalog.swift
import AVFoundation
import CoreMediaIO

/// Enumerates USB-connected iOS devices (iPhone/iPad) as AVFoundation capture
/// devices. iOS devices are screen-capture DAL devices that are HIDDEN by
/// default; `enableScreenCaptureDevices()` flips the CoreMediaIO property that
/// QuickTime sets so they become discoverable.
enum DeviceCatalog {
  /// Idempotent. Call once at plugin init, before discovery.
  static func enableScreenCaptureDevices() {
    var prop = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
      UInt32(MemoryLayout<UInt32>.size), &allow)
  }

  /// Connected iOS devices. iPhones/iPads show up as `.external` (macOS 14+)
  /// or `.externalUnknown` video devices once enabled + trusted + unlocked.
  static func connectedDevices() -> [[String: String]] {
    var types: [AVCaptureDevice.DeviceType] = []
    if #available(macOS 14.0, *) {
      types.append(.external)
    } else {
      types.append(.externalUnknown)
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .muxed, position: .unspecified)
    let discoveryVideo = AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: .unspecified)
    // iOS devices expose a muxed (audio+video) device; some macOS versions
    // surface them under .video. Union by uniqueID.
    var seen = Set<String>()
    let all = (discovery.devices + discoveryVideo.devices)
    return all.compactMap { d in
      guard seen.insert(d.uniqueID).inserted else { return nil }
      let lower = d.localizedName.lowercased()
      let kind = lower.contains("ipad") ? "tablet" : "phone"
      return ["id": d.uniqueID, "name": d.localizedName, "kind": kind]
    }
  }
}
```

- [ ] **Step 2: Enable DAL at plugin init + add the `listDevices` case**

In `ScreenRecorderMacosPlugin.swift`, in the plugin's `register`/`init` (where the instance is constructed — match where other one-time setup runs), call once:
```swift
DeviceCatalog.enableScreenCaptureDevices()
```
In `handle(_:result:)` add:
```swift
case "listDevices":
  result(DeviceCatalog.connectedDevices())
```

- [ ] **Step 3: Compile-check**

Run:
```bash
cd packages/screen_recorder_macos/example/macos 2>/dev/null || cd packages/screen_recorder_macos/macos
xcodebuild -workspace Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -20
```
> If there's no example app workspace, use the verify command from project memory: build the host app's `Runner.xcworkspace` with `-destination 'platform=macOS,arch=x86_64'`. Expected: BUILD SUCCEEDED (or at least no errors in the two changed Swift files). Fix any Swift errors.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/DeviceCatalog.swift \
  packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(device): DeviceCatalog enumerates iOS devices + DAL enable; listDevices handler"
```

---

### Task 4: Native `DeviceCaptureManager.swift` + plugin `startDeviceRecording`

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/DeviceCaptureManager.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (`case "startDeviceRecording"` + the setup method; reuse existing `stopLiveRecording`)

**Interfaces:**
- Consumes: existing `VideoToolboxEncoder(width:height:fps:)` with `onCompressedSample` + `encode(pixelBuffer:timestamp:)`; existing `LiveRecordingWriter(outputPath:width:height:fps:audioTracks:)` with `appendVideo`, `appendAudio(_:role:)`, `start()`, `stop(completion:)`; `AudioTrackRole` (reuse `.systemAudio` for device audio, `.microphone` for mic — match the enum's actual case names found in `LiveRecordingWriter.swift`).
- Produces: `DeviceCaptureManager` with `start(deviceUid:captureAudio:) throws`, `onVideoFrame: ((CMSampleBuffer) -> Void)?`, `onAudioSample: ((CMSampleBuffer) -> Void)?`, `onDisconnect: (() -> Void)?`, `dimensions -> (Int, Int)`, `nominalFps -> Int`, `stop()`.

- [ ] **Step 1: Implement `DeviceCaptureManager.swift`** (modeled on `CameraCaptureManager.swift:52-178`)

```swift
// packages/screen_recorder_macos/macos/Classes/DeviceCaptureManager.swift
import AVFoundation

/// Captures a USB iOS device's screen (+ optional audio) via AVCaptureSession.
/// Supplies RAW video frames and RAW audio sample buffers via callbacks; the
/// plugin wires those into the shared VideoToolboxEncoder + LiveRecordingWriter
/// (same path as screen capture), so output/recovery/finalize are identical.
final class DeviceCaptureManager: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate {

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private let videoQueue = DispatchQueue(label: "com.slipreel.device-capture.video")
  private let audioQueue = DispatchQueue(label: "com.slipreel.device-capture.audio")

  var onVideoFrame: ((CMSampleBuffer) -> Void)?
  var onAudioSample: ((CMSampleBuffer) -> Void)?
  var onDisconnect: (() -> Void)?

  private(set) var width = 0
  private(set) var height = 0
  private(set) var nominalFps = 30
  private var captureDevice: AVCaptureDevice?

  func start(deviceUid: String, captureAudio: Bool) throws {
    guard let device = AVCaptureDevice(uniqueID: deviceUid) else {
      throw NSError(domain: "DeviceCaptureManager", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Device not found (unplugged or untrusted)"])
    }
    captureDevice = device

    session.beginConfiguration()
    session.sessionPreset = .high

    let videoInput = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(videoInput) else {
      session.commitConfiguration()
      throw NSError(domain: "DeviceCaptureManager", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add device video input"])
    }
    session.addInput(videoInput)

    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(videoOutput) else {
      session.commitConfiguration()
      throw NSError(domain: "DeviceCaptureManager", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add device video output"])
    }
    session.addOutput(videoOutput)

    // Audio: the iOS device is a muxed device, so its audio rides on the same
    // AVCaptureDeviceInput. Add the audio data output when requested.
    if captureAudio, session.canAddOutput(audioOutput) {
      audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
      session.addOutput(audioOutput)
    }

    session.commitConfiguration()

    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    width = Int(dims.width)
    height = Int(dims.height)
    let fr = device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
    nominalFps = max(1, Int(fr.rounded()))

    NotificationCenter.default.addObserver(
      self, selector: #selector(deviceDisconnected(_:)),
      name: .AVCaptureDeviceWasDisconnected, object: device)

    session.startRunning()
  }

  @objc private func deviceDisconnected(_ note: Notification) {
    onDisconnect?()
  }

  func stop() {
    NotificationCenter.default.removeObserver(
      self, name: .AVCaptureDeviceWasDisconnected, object: captureDevice)
    session.stopRunning()
    videoQueue.sync {}
    audioQueue.sync {}
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    if output === videoOutput {
      onVideoFrame?(sampleBuffer)
    } else if output === audioOutput {
      onAudioSample?(sampleBuffer)
    }
  }
}
```

- [ ] **Step 2: Wire `startDeviceRecording` in the plugin** (model on the existing `startLiveRecording` setup at `ScreenRecorderMacosPlugin.swift:780-920`)

Add a `private var deviceManager: DeviceCaptureManager?` field next to `captureManager`/`liveEncoder`/`liveWriter`. Add the handler case + method:
```swift
case "startDeviceRecording":
  startDeviceRecording(call: call, result: result)
```
```swift
private func startDeviceRecording(call: FlutterMethodCall, result: @escaping FlutterResult) {
  guard let args = call.arguments as? [String: Any],
        let deviceId = args["deviceId"] as? String,
        let outputPath = args["outputPath"] as? String else {
    result(FlutterError(code: "BAD_ARGS", message: "startDeviceRecording missing args", details: nil))
    return
  }
  let captureDeviceAudio = (args["captureDeviceAudio"] as? Bool) ?? true
  // captureMic: device-mic narration is wired through the existing mic path if
  // already supported by your live setup; for v1 the device audio uses the
  // systemAudio role. If mic capture for device recordings is desired, reuse
  // the existing AudioCaptureManager + .microphone role exactly as the screen
  // path does. Keep parity with how startLiveRecording adds the mic track.

  let manager = DeviceCaptureManager()
  do {
    // Probe dimensions by starting; AVCaptureSession resolves activeFormat on input add.
    // Build encoder + writer AFTER start so width/height/fps are known.
    var started = false
    manager.onDisconnect = { [weak self] in
      guard let self = self else { return }
      // Finalize whatever we have, like a vanished device.
      self.stopLiveRecording(result: { _ in })
    }
    try manager.start(deviceUid: deviceId, captureAudio: captureDeviceAudio)
    started = true
    _ = started

    let w = manager.width > 0 ? manager.width : 1170
    let h = manager.height > 0 ? manager.height : 2532
    let fps = manager.nominalFps

    var roles: [AudioTrackRole] = []
    if captureDeviceAudio { roles.append(.systemAudio) }  // match enum case name

    let writer = LiveRecordingWriter(
      outputPath: outputPath, width: w, height: h, fps: fps, audioTracks: roles)
    try writer.start()

    let encoder = VideoToolboxEncoder(width: w, height: h, fps: fps)
    encoder.onCompressedSample = { [weak writer] sb in writer?.appendVideo(sb) }
    try encoder.initialize()

    manager.onVideoFrame = { [weak encoder] sb in
      guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
      let pts = CMSampleBufferGetPresentationTimeStamp(sb)
      try? encoder?.encode(pixelBuffer: pb, timestamp: pts)
    }
    if captureDeviceAudio {
      manager.onAudioSample = { [weak writer] sb in
        writer?.appendAudio(sb, role: .systemAudio)
      }
    }

    self.deviceManager = manager
    self.liveWriter = writer
    self.liveEncoder = encoder
    result(nil)
  } catch {
    manager.stop()
    result(FlutterError(code: "DEVICE_START_FAILED", message: error.localizedDescription, details: nil))
  }
}
```
> Reuse the EXISTING `stopLiveRecording` for stop — but make sure it also calls `deviceManager?.stop()` and nils it (add those two lines to `stopLiveRecording` alongside the existing `captureManager?` teardown). Match the exact field names (`liveWriter`, `liveEncoder`) and `VideoToolboxEncoder`/`LiveRecordingWriter` APIs found in the file; if `encode`/`onCompressedSample`/`initialize` signatures differ, mirror exactly what `startLiveRecording` does at lines 780-796.

- [ ] **Step 3: Compile-check** (same xcodebuild command as Task 3 Step 3). Fix Swift errors. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/DeviceCaptureManager.swift \
  packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(device): DeviceCaptureManager + startDeviceRecording wired to shared encoder/writer"
```

---

### Task 5: `RecordingController` device-recording branch (Dart)

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Test: `packages/screen_recorder/test/state/recording_device_test.dart`

**Interfaces:**
- Consumes: `ScreenRecorderPlatform.startDeviceRecording(...)`, `resolveSaveDirectory(...)`.
- Produces: `RecordingController.startDeviceRecording({required String deviceId, required bool captureDeviceAudio, MicrophoneConfig? microphone, String? defaultSaveLocation})` — resolves the output path, calls the platform, sets recording state, and on stop writes ONLY the metadata sidecar (no cursor/keystroke).

- [ ] **Step 1: Write the failing test** (fake platform captures the call; follow the existing `recording_bar_screen_test.dart` fake-controller / fake-platform pattern)

```dart
// packages/screen_recorder/test/state/recording_device_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform {
  String? startedDeviceId;
  bool? startedDeviceAudio;
  String? startedOutputPath;
  @override
  Future<void> startDeviceRecording({
    required String deviceId,
    required bool captureDeviceAudio,
    required bool captureMic,
    required String outputPath,
  }) async {
    startedDeviceId = deviceId;
    startedDeviceAudio = captureDeviceAudio;
    startedOutputPath = outputPath;
  }
}

void main() {
  // Build the RecordingController with the fake platform injected the SAME way
  // the existing recording_state tests do (check recording_state.dart's
  // constructor / how _videoEncoder is supplied; inject _FakePlatform there).
  test('startDeviceRecording resolves path under the save dir and forwards args',
      () async {
    final platform = _FakePlatform();
    // ... construct controller with platform, a temp save dir ...
    // await controller.startDeviceRecording(deviceId: 'uid-1', captureDeviceAudio: true);
    // expect(platform.startedDeviceId, 'uid-1');
    // expect(platform.startedDeviceAudio, true);
    // expect(platform.startedOutputPath, endsWith('.mp4'));
    // expect(platform.startedOutputPath, contains(saveDir));
  });
}
```
> Read `recording_state.dart`'s constructor and existing tests first to learn exactly how the platform/encoder is injected, then fill the `...` lines so the test compiles and the assertions run. The contract: `startDeviceRecording` forwards `deviceId`/`captureDeviceAudio` and writes the `.mp4` under the resolved save dir.

- [ ] **Step 2: Run it, confirm fail.**

- [ ] **Step 3: Implement `startDeviceRecording`** on `RecordingController`, mirroring the path-resolution + state transitions in the existing `startRecording` (recording_state.dart:133-287) but: source = `RecordingSource.device`, call `ScreenRecorderPlatform.instance.startDeviceRecording(...)`, and in the stop/finalize path skip the cursor + keystroke sidecars (guard those blocks on the source not being `device`, or on `_cursorRecording == null` which it already will be). Set `selectedSourceKind: RecordingSource.device` so the editor/metadata know.

- [ ] **Step 4: Run it, confirm pass.**

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze lib/state/recording_state.dart
git add packages/screen_recorder/lib/state/recording_state.dart packages/screen_recorder/test/state/recording_device_test.dart
git commit -m "feat(device): RecordingController.startDeviceRecording (skips cursor/keystroke sidecars)"
```

---

### Task 6: `DevicePickerOverlay` widget (Dart)

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/device_picker_overlay.dart`
- Test: `packages/screen_recorder/test/ui/bar/device_picker_overlay_test.dart`

**Interfaces:**
- Produces: `DevicePickerOverlay` — `static Future<DeviceSource?> show(BuildContext context, {required List<DeviceSource> devices})`; renders one row per device (phone/tablet icon + name); empty state shows the connect/trust hint; tapping a row pops with that `DeviceSource`.

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/bar/device_picker_overlay_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/device_picker_overlay.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  testWidgets('empty state shows the connect/trust hint', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => DevicePickerOverlay.show(context, devices: const []),
          child: const Text('open'),
        );
      })),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connect an iPhone or iPad'), findsOneWidget);
  });

  testWidgets('tapping a device returns it', (tester) async {
    DeviceSource? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () async {
            picked = await DevicePickerOverlay.show(context, devices: const [
              DeviceSource(id: 'uid-1', name: 'My iPhone', kind: DeviceKind.phone),
            ]);
          },
          child: const Text('open'),
        );
      })),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My iPhone'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'uid-1');
  });
}
```

- [ ] **Step 2: Run it, confirm fail.**

- [ ] **Step 3: Implement `DevicePickerOverlay`** as a simple modal (a `showDialog`/`showModalBottomSheet` returning `DeviceSource?`). Each device row: `Icons.smartphone` (phone) / `Icons.tablet_mac` (tablet) + name; `onTap` → `Navigator.pop(context, device)`. Empty state: an icon + "Connect an iPhone or iPad over USB and tap Trust This Computer." Style with `context.palette` tokens to match the app (see `settings_screen.dart` for palette usage).

- [ ] **Step 4: Run it, confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/device_picker_overlay.dart packages/screen_recorder/test/ui/bar/device_picker_overlay_test.dart
git commit -m "feat(device): DevicePickerOverlay (device list + empty connect/trust state)"
```

---

### Task 7: Wire the bar — enable Device chip, Device-mode controls, end-to-end flow

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart` (enable Device chip `onTap`; hide System-audio + show Device-audio toggle in Device mode)
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` (`_pickAndRecord` `device` case)
- Test: `packages/screen_recorder/test/ui/bar/recording_bar_device_mode_test.dart`

**Interfaces:**
- Consumes: `DevicePickerOverlay.show`, `ScreenRecorderPlatform.listDevices()`, `RecordingController.startDeviceRecording`, `recordingActionRouterRef`.

- [ ] **Step 1: Implement the `device` case in `_pickAndRecord`** (recording_bar_screen.dart, replacing `case BarSourceMode.device: break;`)

```dart
case BarSourceMode.device:
  final devices = await ScreenRecorderPlatform.instance.listDevices();
  if (!context.mounted) return;
  final picked = await DevicePickerOverlay.show(context, devices: devices);
  if (picked == null) return;
  controller.selectSource(kind: RecordingSource.device, id: picked.id);
  await recordingActionRouterRef?.start(context);
```
(Add the needed imports.) Then make the `recording_action_router` `start` / its `doStart` branch call `controller.startDeviceRecording(...)` when `selectedSourceKind == RecordingSource.device` (passing the device-audio flag from bar state + the resolved `defaultSaveLocation`), instead of the screen `startRecording`. Read `recording_action_router.dart:24-77` and branch on the selected source kind.

- [ ] **Step 2: Enable the Device chip + Device-mode controls** (recording_bar.dart)

- Give the Device `_Mode` an `onTap: () => onPickMode(BarSourceMode.device)` (remove the `const`/null).
- Add a `RecordingSource? activeSourceKind` (or a `bool deviceMode`) field to `RecordingBar` so it knows the armed source. When `deviceMode` is true: render a `_DeviceAudioControl` (toggle, default on) in place of `_SystemAudioControl`, keep `_MicControl`, and hide `_SystemAudioControl`. Thread the device-audio on/off + onToggle from `recording_bar_screen.dart` state (a simple `bool deviceAudio` in the screen's state + setter).

- [ ] **Step 3: Write the widget test**

```dart
// packages/screen_recorder/test/ui/bar/recording_bar_device_mode_test.dart
// Pump RecordingBar twice: once in screen/normal mode, once in device mode
// (deviceMode: true). Assert:
//  - normal mode: the System-audio control is present.
//  - device mode: System-audio control is ABSENT, Mic control present, and a
//    "Device audio" affordance is present.
//  - the Device _Mode chip is enabled (its onTap is non-null / tapping calls
//    onPickMode with BarSourceMode.device).
// Follow recording_bar's existing widget-test pattern (provide the required
// callbacks/configs; use find.byTooltip or a Key on the new control).
```
> Give the new `_DeviceAudioControl` a `Key('bar-device-audio')` and the System-audio control a findable key/tooltip so the test can assert presence/absence cleanly. Fill in the test body with real assertions before implementing.

- [ ] **Step 4: Run the test + analyze, confirm pass/clean.**

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
  packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
  packages/screen_recorder/lib/state/recording_action_router.dart \
  packages/screen_recorder/test/ui/bar/recording_bar_device_mode_test.dart
git commit -m "feat(device): enable Device chip + device-mode bar controls + pick→record flow"
```

---

### Task 8: Full-suite gate + native compile-check + runtime verify + finish

- [ ] **Step 1: Run all affected package suites**

```bash
cd packages/screen_recorder_platform_interface && flutter test
cd packages/screen_recorder_macos && flutter test
cd packages/screen_recorder && flutter test
```
Expected: all green (run the WHOLE suites — lesson: per-task tests miss cross-file breaks like fakes missing a new method).

- [ ] **Step 2: Native compile-check** — `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build` → BUILD SUCCEEDED.

- [ ] **Step 3: Runtime verify (user, physical device)** — plug in an iPhone/iPad, Trust; click Device → device appears in the picker; pick → record (3-2-1) → stop → editor opens the `.mp4`; device audio audible; toggle device-audio off → silent; unplug mid-record → partial file recovers. Use the verify skill; capture a screenshot of the picker + the resulting editor.

- [ ] **Step 4: Final review + finish** — dispatch a holistic code review over the branch diff, then `superpowers:finishing-a-development-branch`.
