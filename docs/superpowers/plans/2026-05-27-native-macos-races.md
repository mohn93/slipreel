# Native macOS Concurrency Fixes Implementation Plan (Workstream C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Eliminate the data races on the only shipping recording path — unsynchronized counter mutations in `VideoToolboxEncoder` and unserialized `AVAssetWriter` access in `LiveRecordingWriter` — and make plugin registration idiomatic via `dartPluginClass` (#7, #11).

**Architecture:** Guard `VideoToolboxEncoder`'s diagnostic counters with an `NSLock`. Serialize ALL `LiveRecordingWriter` writer/input/state access (start/appendVideo/appendAudio/stop) through one dedicated serial `DispatchQueue` (Apple requires serialized access to a single `AVAssetWriter`). Add `dartPluginClass: ScreenRecorderMacos` and drop the manual `registerWith()`.

**Tech Stack:** Swift (macOS, ScreenCaptureKit/AVFoundation/VideoToolbox), Flutter plugin federation.

**Spec:** `docs/superpowers/specs/2026-05-26-critical-major-remediation-design.md` (Workstream C: #7, #11)

**Branch:** `remediation/critical-major`

## VERIFICATION CONSTRAINTS (read first)
- `flutter build macos` is BROKEN in this environment (arm64 destination issue — see project memory). Native Swift is compile-checked with:
  ```
  xcodebuild -workspace packages/screen_recorder_macos/example/macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=x86_64' build
  ```
- There is NO `flutter test` coverage for native Swift. The automated gate for Tasks 1-2 is "xcodebuild build succeeds" + code reasoning.
- Full A/V-sync correctness (Tasks 1-2) and `dartPluginClass` auto-registration (Task 3) require a real macOS run/build — flag these as **pre-merge manual verification** items; they cannot be confirmed in this environment.

## Ground truth (from recon)
- `VideoToolboxEncoder.swift`: counters `droppedFrameCount`/`encodeCallCount`/`encodeSuccessCount`/`outputCallbackCount` are plain `private(set) var Int`, NO sync. `encode()` (105-121, capture queue) writes 3 of them; static `outputCallback` (134-145, VideoToolbox's own queue) writes `outputCallbackCount` and calls `onCompressedSample`. `droppedFrameCount` is read at `ScreenRecorderMacosPlugin.swift:924` from a `Task` thread. Only `droppedFrameCount` is ever read; the other three are write-only diagnostics.
- `LiveRecordingWriter.swift`: mutable state `assetWriter`/`videoInput`/`audioInputs`/`isStarted`/`sessionStartedAt`/`writerActive` + counters `appendVideoCallCount`/`appendVideoAcceptedCount`/`appendVideoNotReadyCount`, NO sync. `appendVideo()` (168-193, VideoToolbox queue) lazily calls private `addVideoInputAndStartSession()` (137-162) + appends to `videoInput`. `appendAudio()` (199-204, audio-engine/SCStream queues) appends to `audioInputs[role]`. `start()` (89-118) and `stop(completion:)` (207-233) called from `Task` threads. Video + audio target different inputs but share one `AVAssetWriter` + `isStarted`/`writerActive`; `stop()` races in-flight appends.
- `screen_recorder_macos/pubspec.yaml` plugin block: only `pluginClass: ScreenRecorderMacosPlugin` (no `dartPluginClass`). `screen_recorder_macos.dart` `registerWith()` sets `ScreenRecorderPlatform.instance = MethodChannelScreenRecorderMacos()`. `main.dart:44-46` calls it manually.

---

## Task 1: Synchronize VideoToolboxEncoder counters

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/VideoToolboxEncoder.swift`

- [ ] **Step 1: Add a counter lock + accessor helper**

In `VideoToolboxEncoder`, add a private lock field near the other properties:
```swift
  /// Guards the diagnostic counters below — `encode()` runs on the capture
  /// queue while the VideoToolbox `outputCallback` runs on VT's own queue, so
  /// the counter mutations/reads race without this.
  private let counterLock = NSLock()
```
Make the four counters PRIVATE stored fields renamed with a leading underscore (so the only externally-read one can be exposed via a locked accessor). Replace:
```swift
  private(set) var droppedFrameCount: Int = 0
  private(set) var encodeCallCount: Int = 0
  private(set) var encodeSuccessCount: Int = 0
  private(set) var outputCallbackCount: Int = 0
```
with:
```swift
  private var _droppedFrameCount = 0
  private var _encodeCallCount = 0
  private var _encodeSuccessCount = 0
  private var _outputCallbackCount = 0

  /// Frames the encoder reported dropped. Thread-safe read.
  var droppedFrameCount: Int {
    counterLock.lock(); defer { counterLock.unlock() }
    return _droppedFrameCount
  }
```

- [ ] **Step 2: Guard the writes in encode()**

In `encode()` (lines 105-121), wrap each counter mutation in the lock. Replace `encodeCallCount += 1` (line 106) with:
```swift
    counterLock.lock(); _encodeCallCount += 1; counterLock.unlock()
```
and replace the trailing `encodeSuccessCount += 1` (119) + `if flags.contains(.frameDropped) { droppedFrameCount += 1 }` (120) with:
```swift
    counterLock.lock()
    _encodeSuccessCount += 1
    if flags.contains(.frameDropped) { _droppedFrameCount += 1 }
    counterLock.unlock()
```
(Do NOT hold the lock across the `VTCompressionSessionEncodeFrame` call — only around the integer mutations.)

- [ ] **Step 3: Guard the write in outputCallback**

In the static `outputCallback` (line 143), replace `encoder.outputCallbackCount += 1` with:
```swift
    encoder.counterLock.lock(); encoder._outputCallbackCount += 1; encoder.counterLock.unlock()
```
(`counterLock` and `_outputCallbackCount` are private but accessible from the static callback since it's within the same type.)

- [ ] **Step 4: Fix the doc comment**

The old comment claimed `droppedFrameCount` was "Atomically" tracked (it wasn't). Ensure the new `_droppedFrameCount`/accessor comments are accurate (the accessor IS now lock-protected).

- [ ] **Step 5: Compile-check**

Run:
```
xcodebuild -workspace packages/screen_recorder_macos/example/macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=x86_64' build
```
Expected: `** BUILD SUCCEEDED **`. (If the example app's xcodebuild needs `pod install` first, run it in `packages/screen_recorder_macos/example/macos/`.) Confirm no references to the old counter names remain: `grep -rn "outputCallbackCount\|encodeCallCount\|encodeSuccessCount" packages/screen_recorder_macos` should show only the underscored fields + the accessor.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/VideoToolboxEncoder.swift
git commit -m "fix(macos): guard VideoToolboxEncoder counters with a lock (cross-queue race)"
```

---

## Task 2: Serialize LiveRecordingWriter access

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`

**Design:** One dedicated serial `DispatchQueue` owns ALL access to the writer/inputs/state. Each public entry point (`start`, `appendVideo`, `appendAudio`, `stop`) runs its body via `writerQueue.sync`. The private `addVideoInputAndStartSession` is called only from inside `appendVideo`'s synced body, so it must NOT re-enter the queue (that would deadlock a serial queue). Using `.sync` keeps each `CMSampleBuffer` valid for the duration of the append (no async retain needed).

- [ ] **Step 1: Add the serial queue**

Add near the properties:
```swift
  /// Serializes all access to the AVAssetWriter + inputs + state. appendVideo
  /// (VideoToolbox queue), appendAudio (audio queues), and start/stop (Task
  /// threads) all funnel through here — Apple requires serialized access to a
  /// single AVAssetWriter.
  private let writerQueue = DispatchQueue(label: "com.slipreel.screen_recorder.writer")
```

- [ ] **Step 2: Wrap start()**

Wrap the entire body of `start()` (lines 89-118) in `writerQueue.sync { ... }`. If `start()` is `throws`, use `try writerQueue.sync { try ... }` (DispatchQueue.sync rethrows). Preserve all existing logic verbatim inside the closure.

- [ ] **Step 3: Wrap appendVideo()**

Wrap the entire body of `appendVideo(_:)` (lines 168-193) in `writerQueue.sync { ... }`. The call to `addVideoInputAndStartSession(...)` stays inside (it's already on the queue — do NOT add a nested `writerQueue.sync` to that private method). Counters mutated inside are now queue-protected.

- [ ] **Step 4: Wrap appendAudio()**

Wrap the entire body of `appendAudio(_:role:)` (lines 199-204) in `writerQueue.sync { ... }`.

- [ ] **Step 5: Wrap stop()**

Wrap the body of `stop(completion:)` (lines 207-233) that touches inputs/writer/`isStarted` in `writerQueue.sync { ... }`. NOTE: `assetWriter.finishWriting { completion }` is itself async — initiate it INSIDE the synced block (so `markAsFinished()` + `finishWriting(...)` are serialized against appends), but the `completion` callback fires later on AVFoundation's thread (do NOT call `completion` inside the sync block / do not block on it). Ensure `isStarted = false` is set inside the synced block so subsequent appends short-circuit.

- [ ] **Step 6: Verify no nested sync / deadlock**

Confirm `addVideoInputAndStartSession` does NOT call `writerQueue.sync` (it runs within appendVideo's synced body). Confirm nothing the synced bodies call re-enters a public method of this writer (which would deadlock the serial queue). Grep: `grep -n "writerQueue" packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift` — sync should appear in start/appendVideo/appendAudio/stop only.

- [ ] **Step 7: Compile-check**

Run the xcodebuild command from Task 1 Step 5. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
git commit -m "fix(macos): serialize LiveRecordingWriter access through a writer queue"
```

---

## Task 3: Idiomatic plugin registration (dartPluginClass)

**Files:**
- Modify: `packages/screen_recorder_macos/pubspec.yaml`
- Modify: `packages/screen_recorder/lib/main.dart`

**⚠️ Verification gap:** the runtime effect (Flutter regenerating `GeneratedPluginRegistrant` to auto-call `registerWith()`) can only be confirmed by a real `flutter build macos` / run, which is broken in THIS environment. This task is correct per Flutter's federation docs but must be **verified on the next real macOS build before merge** (if auto-registration somehow doesn't engage, the app would fail to find the platform instance at startup — caught immediately on first real run).

- [ ] **Step 1: Add dartPluginClass to the macos plugin block**

In `packages/screen_recorder_macos/pubspec.yaml`, change:
```yaml
      macos:
        pluginClass: ScreenRecorderMacosPlugin
```
to:
```yaml
      macos:
        pluginClass: ScreenRecorderMacosPlugin
        dartPluginClass: ScreenRecorderMacos
```

- [ ] **Step 2: Remove the manual registerWith() from main.dart**

In `packages/screen_recorder/lib/main.dart`, remove lines 44-46:
```dart
  // Explicitly register the macOS platform implementation
  ScreenRecorderMacos.registerWith();
  AppLogger.platform.i('macOS platform registered');
```
Replace with a brief comment:
```dart
  // The macOS platform implementation auto-registers via GeneratedPluginRegistrant
  // (dartPluginClass in screen_recorder_macos/pubspec.yaml).
```
If the `import 'package:screen_recorder_macos/screen_recorder_macos.dart';` (line 10) becomes unused after removal, remove it too — BUT check first: `grep -n "ScreenRecorderMacos\b\|screen_recorder_macos" packages/screen_recorder/lib/main.dart`. If other symbols from that package are still used, keep the import.

- [ ] **Step 3: Verify analyze (app) + that nothing else referenced the manual call**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/main.dart`
Expected: no errors (no unused-import warning for a removed import; no undefined `ScreenRecorderMacos`).
Run: `cd packages/screen_recorder && flutter test`
Expected: PASS (220) — the test suite doesn't exercise startup registration, so it should be unaffected. If any test relied on the manual registration, investigate.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/pubspec.yaml packages/screen_recorder/lib/main.dart
git commit -m "refactor(macos): auto-register via dartPluginClass; drop manual registerWith"
```

---

## Self-Review

**Spec coverage (C):**
- #7 races → Task 1 (encoder counter lock) + Task 2 (writer serial queue). ✓
- #11 registration → Task 3 (dartPluginClass + drop manual call). ✓

**Placeholder scan:** No placeholders. Tasks 2 wraps existing method bodies in `writerQueue.sync` (the bodies exist verbatim in the file); the instruction is precise about which methods and the no-nested-sync constraint.

**Type consistency:** `counterLock`/`_droppedFrameCount`/`droppedFrameCount` accessor consistent within Task 1. `writerQueue` used in start/appendVideo/appendAudio/stop only (Task 2). `dartPluginClass: ScreenRecorderMacos` matches the Dart class name (Task 3).

**Risks / confirm during execution:**
- **`.sync` from the VideoToolbox + audio callback queues** briefly blocks those queues. This is acceptable (append work is short) and is the correct way to keep the `CMSampleBuffer` valid during append. The ONLY deadlock risk is a nested `writerQueue.sync` — explicitly guarded against in Task 2 Step 6.
- **xcodebuild may need `pod install`** in the example macos dir first; run it if the build complains about missing Pods.
- **Task 3 is unverifiable here** (see the verification gap). Flag it to the human; the race fixes (Tasks 1-2) are the high-value, compile-checkable core.
- A real macOS capture run (record → stop → confirm A/V sync + sane/zero dropped-frame stat) is the pre-merge behavioral check for Tasks 1-2.
