# Audio Capture — Sub-project 1: Foundation + Microphone (Design)

**Date:** 2026-05-25
**Status:** Approved — ready for implementation plan
**Part of:** the 3-part Audio Capture effort (mic + system audio). See
`2026-05-25-audio-capture-roadmap.md` for Sub-projects 2 & 3.

---

## 1. Goal

Let the user record from a **chosen microphone** (or none) with optional
**noise reduction** and **disable-auto-gain-control**, muxed as its own audio
track into the recorded MP4. The recording bar's microphone control becomes
live (currently a disabled placeholder), and edited exports preserve the mic
track. The microphone is **off by default** on each launch.

This is the first of three slices. It also lays the **two-track-capable
writer** foundation that Sub-project 2 (system audio) builds on.

### Out of scope (this sub-project)
- System audio capture (Sub-project 2).
- Editor per-track volume UI and export downmix (Sub-project 3).
- Camera/webcam (the bar's "No camera" placeholder stays disabled).
- Persisting the mic selection across launches (starts off each launch; noted
  as an optional later tweak).

---

## 2. Current state (what already exists)

- `LiveRecordingWriter` already writes a real H.264 + AAC `.mp4` with **one**
  optional audio `AVAssetWriterInput` (AAC, 48 kHz, mono, 128 kbps), added
  eagerly in `start()`; `appendAudio(_:)` feeds it.
  (`packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`)
- `AudioCaptureManager` captures the **default** input via
  `AVAudioEngine.inputNode` + a tap, converts to PCM, and emits
  `CMSampleBuffer`s via `onSampleBufferReceived`. It has mic permission
  check/request. `includeSystem` is accepted but ignored.
  (`.../macos/Classes/AudioCaptureManager.swift`)
- `startLiveRecording` (plugin) already wires `captureAudio` → `AudioCaptureManager`
  → `writer.appendAudio`. (`.../macos/Classes/ScreenRecorderMacosPlugin.swift`)
- `RecordingSettings.captureAudio` defaults to `true`; `audioDeviceIds` is an
  unused `List<String>`.
  (`packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart`)
- `getAudioDevices()` is a stub returning `[]`.
- `AudioDeviceInfo { id, name, type }` + `AudioDeviceType { system, microphone, unknown }`
  already exist. (`.../models/audio_device_info.dart`)
- The bar's mic control is a disabled `_AvPlaceholder(icon: micOff, label: 'No microphone')`
  with `onTap: null`. (`packages/screen_recorder/lib/ui/bar/recording_bar.dart`)
- Native dropdowns must be **native `NSMenu`** — Flutter overlays get clipped
  by the tiny floating bar window (same reason the gear menu is native). Reuse
  the `showGearMenu` `GearMenuTarget` + `menu.popUp(...)` pattern.
  (`packages/screen_recorder/macos/Runner/MainFlutterWindow.swift`)
- Export muxes audio via ffmpeg `-map 0:v -map 1:a:0 -c:a copy` — copies only
  the **first** audio stream. (`packages/slipreel_engine/lib/export/ffmpeg_encoder.dart:95,118`)
  With one mic track this is correct and unchanged; multi-track downmix is
  Sub-project 3.
- **macOS deployment target is 12.3** (podspecs + Podfiles + pbxproj).

---

## 3. Architecture & data flow

```
Bar mic control (Flutter, recording_bar.dart)
   │ tap → ScreenRecorderPlatform.showMicrophoneMenu(currentConfig)
   ▼                                  (native NSMenu, returns new config)
MicrophoneController (Riverpod StateNotifier<MicrophoneConfig?>)  ── in-memory, default null (off)
   │ startRecording → RecordingSettings.microphone
   ▼
startLiveRecording channel args:
   'microphone': null | { deviceUid, reduceNoise, disableAgc }
   ▼
AudioCaptureManager (select device by UID + apply DSP)
   │  CMSampleBuffer
   ▼
LiveRecordingWriter.appendAudio(buf, role: .microphone)
   ▼
MP4: video track + 1 audio track (mic)
```

The two boundaries that matter:
- **Plugin owns all mic-native logic** (enumeration, the NSMenu, capture). The
  bar/state call `getAudioDevices()` and `showMicrophoneMenu(...)` through the
  platform interface — same shape as the existing `pickSource` / `selectRegion`
  native-UI methods.
- **`MicrophoneController` is the single source of truth** for the current
  selection; the bar renders from it and `RecordingController` reads it at start.

---

## 4. Writer generalization (the Sub-2 seam)

`LiveRecordingWriter` moves from one hard-coded audio input to **track-keyed**
inputs, so Sub-project 2 only has to add a `.system` role.

```swift
enum AudioTrackRole { case microphone, system }

// start() now takes the set of audio tracks to create up front:
func start(audioTracks: [AudioTrackRole]) throws
// Sub-1 passes [.microphone] when mic is on, [] when off.

// route a buffer to the matching input:
func appendAudio(_ sampleBuffer: CMSampleBuffer, role: AudioTrackRole)
```

Internally: `private var audioInputs: [AudioTrackRole: AVAssetWriterInput]`.
Each input keeps today's settings (AAC, 48 kHz, mono, 128 kbps). The mic input
is added eagerly in `start()` exactly as today; only the keying changes. Video
input stays lazily added on first compressed sample (unchanged — that fix is
load-bearing for `LIVE_START_FAILED`). `stop()` marks every audio input
finished.

**Behavioral invariant preserved:** audio arriving before the writer session is
active (first video PTS) is still dropped — keep the `writerActive` guard.

---

## 5. Data models & state (Dart)

### New: `MicrophoneConfig`
`packages/screen_recorder_platform_interface/lib/src/models/microphone_config.dart`
```dart
class MicrophoneConfig {
  final String deviceUid;   // stable CoreAudio device UID
  final String deviceLabel; // human-readable name, for the bar label
  final bool reduceNoise;   // voice processing (noise suppression + normalize)
  final bool disableAgc;    // only honored on macOS 14+

  const MicrophoneConfig({
    required this.deviceUid,
    required this.deviceLabel,
    this.reduceNoise = false,
    this.disableAgc = false,
  });

  Map<String, dynamic> toJson();          // for channel args
  factory MicrophoneConfig.fromJson(...); // for the menu result
  MicrophoneConfig copyWith({...});
  // value equality (== / hashCode) so the controller can no-op on no change
}
```

### `RecordingSettings` — replace the audio fields
- **Remove** `captureAudio: bool` and `audioDeviceIds: List<String>`.
- **Add** `final MicrophoneConfig? microphone;` (null = don't record mic).
- `toJson()` emits `'microphone': microphone?.toJson()` (null when off).
- Update `copyWith`, `toString`, and every reference (tests included).

### `AudioDeviceInfo` — add default flag
- Add `final bool isDefault;` (+ JSON, default false). `id` is the device UID.

### New: `MicrophoneController` + provider
`packages/screen_recorder/lib/state/microphone_controller.dart`
```dart
class MicrophoneController extends StateNotifier<MicrophoneConfig?> {
  MicrophoneController() : super(null); // off each launch
  void set(MicrophoneConfig? config) { if (config != state) state = config; }
}
final microphoneControllerProvider =
    StateNotifierProvider<MicrophoneController, MicrophoneConfig?>(...);
```

### `RecordingController.startRecording`
Reads `microphoneControllerProvider` and sets
`RecordingSettings(microphone: <current config or null>, ...)`. Removes the
hard-coded `captureAudio: true`.

---

## 6. Platform interface additions

`packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Implement `Future<List<AudioDeviceInfo>> getAudioDevices()` (was a stub).
- **New** `Future<MicrophoneMenuResult> showMicrophoneMenu(MicrophoneConfig? current)`
  — opens the native menu, always returns a (non-null) result. `cancelled`
  distinguishes a dismissal (Esc / click-away → caller leaves state untouched)
  from an explicit "Don't record microphone" (`cancelled == false`,
  `config == null`).

```dart
class MicrophoneMenuResult {
  final bool cancelled;           // true = dismissed, no change
  final MicrophoneConfig? config; // when !cancelled: new selection; null = "Don't record"
}
```
Channel method names go in `screen_recorder_platform_interface/lib/src/constants.dart`
(`getAudioDevices` already exists; add `showMicrophoneMenu`).

---

## 7. Native (Swift, `screen_recorder_macos`)

### 7.1 Device enumeration — `getAudioDevices`
New helper (e.g. `AudioDeviceCatalog.swift`) using **CoreAudio** (not
`AVCaptureDevice`, which misses virtual/aggregate devices):
- `kAudioHardwarePropertyDevices` → all `AudioDeviceID`s.
- Keep those with input streams (`kAudioDevicePropertyStreams`, input scope).
- Per device: name (`kAudioObjectPropertyName`), UID
  (`kAudioDevicePropertyDeviceUID`).
- Default input: `kAudioHardwarePropertyDefaultInputDevice` → mark `isDefault`.
- Return `[{ id: UID, name, type: "microphone", isDefault }]`. This lists
  built-in, USB, virtual (VB-Cable), and continuity (iPhone) inputs.

### 7.2 Device selection — `AudioCaptureManager`
- New entry point `startCapture(microphone: MicSpec)` where
  `MicSpec = (deviceUid, reduceNoise, disableAgc)`.
- Resolve UID → `AudioDeviceID` via `kAudioHardwarePropertyTranslateUIDToDevice`.
- Set the input device **before** tapping:
  `engine.inputNode.auAudioUnit.deviceID = audioDeviceID`.
- If the UID no longer resolves (device unplugged), fall back to the system
  default input; if there is none, fail soft (record with no mic track).
- Tap → `CMSampleBuffer` (existing `makeSampleBuffer`) → `onSampleBufferReceived`.

### 7.3 DSP — voice processing
- `reduceNoise == true` → `try engine.inputNode.setVoiceProcessingEnabled(true)`
  before `engine.start()` (macOS 10.15+ — fine on 12.3). This gives noise
  suppression + level normalization.
- `disableAgc`:
  ```swift
  if #available(macOS 14.0, *) {
    engine.inputNode.isVoiceProcessingAGCEnabled = !disableAgc
  } // else: no-op; the menu hides the row on < 14.
  ```
- Voice processing reconfigures the input format; `makeSampleBuffer` already
  derives format from the buffer, so the writer's AAC encoder handles it.

### 7.4 The microphone NSMenu — `showMicrophoneMenu`
Reuse the `GearMenuTarget` + `menu.popUp(positioning: nil, at:
NSEvent.mouseLocation, in: nil)` pattern (works process-wide from the plugin).
Menu structure:
```
✓ MacBook Pro Microphone (default)   ← radio; ✓ when current.deviceUid matches
  EShareAudio
  VB-Cable
  ──────────
☑ Reduce noise and normalize volume  ← state from current.reduceNoise; enabled only when a device is selected
☐ Disable auto gain control          ← state from current.disableAgc; hidden on macOS < 14
  ──────────
  Don't record microphone            ← ✓ when current == nil
```
- Standard NSMenu behavior: a click **applies and closes**; reopening reflects
  updated ✓/☑. (Keeping checkboxes "live without closing" would need custom
  views — out of scope.)
- Native computes the new `MicrophoneConfig` from the clicked item + the passed
  current config:
  - device row → config with that device's UID/label, preserving
    `reduceNoise`/`disableAgc` (defaults when coming from off).
  - "Reduce noise" → toggle `reduceNoise`.
  - "Disable AGC" → toggle `disableAgc`.
  - "Don't record" → result config = nil.
  - dismissed → `cancelled = true`.
- Returns the result map to Dart; `MicrophoneController.set(...)` applies it
  unless cancelled.

### 7.5 Permission
- When a **device row** is chosen and `AVCaptureDevice.authorizationStatus(for:
  .audio)` is `.notDetermined`, request access inside the handler; if denied,
  return "Don't record" (nil).
- When status is `.denied`/`.restricted`, the menu shows a **disabled info row**
  at top: "Microphone access denied — enable in System Settings ▸ Privacy".
- `NSMicrophoneUsageDescription` already exists in Info.plist.

### 7.6 startLiveRecording wiring
- Replace the `captureAudio` arg with `microphone` (map or null).
- If present: `writer.start(audioTracks: [.microphone])`, configure
  `AudioCaptureManager` with the mic spec, route `onSampleBufferReceived` →
  `writer.appendAudio(buf, role: .microphone)`.
- If null: `writer.start(audioTracks: [])`, don't start audio capture.

---

## 8. Bar microphone control (Flutter)

`packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Replace the disabled mic `_AvPlaceholder` with a live `_MicControl`
  (`ConsumerWidget` or fed the current config + an `onTap`).
- Layout mirrors the existing controls: `SpringHoverButton` → icon + label +
  small chevron (consistent with the gear's chevron).
  - **On:** `LucideIcons.mic` (white `0xFFE9E9EC`) + device label + `chevronDown`.
  - **Off:** `LucideIcons.micOff` (grey `0xFF6E6E76`) + "No microphone" + chevron.
- **Label truncation:** wrap the label in a `ConstrainedBox(maxWidth: ~120)`
  with `Text(..., maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false)`
  so a long device name can't reintroduce bar overflow.
- Tap (both states) → `await ScreenRecorderPlatform.instance.showMicrophoneMenu(current)`
  → if not cancelled, `microphoneControllerProvider.notifier.set(result.config)`.
- `recording_bar_screen.dart` passes the current config + tap handler into the bar.

---

## 9. Edge cases

- **Permission denied** → menu shows the disabled "access denied" row; control
  stays off.
- **Selected device unplugged before record** → native falls back to system
  default input (or no mic track if none); no intrusive UI.
- **macOS < 14** → "Disable auto gain control" row hidden; `disableAgc` stays
  false and is a no-op natively.
- **No input devices at all** → menu shows only "Don't record microphone".
- **reduceNoise on but no device** → not possible: the noise/AGC rows are only
  enabled once a device is selected.

---

## 10. Testing

**Dart / unit**
- `MicrophoneConfig` JSON round-trip + equality.
- `RecordingSettings` channel encoding emits `microphone` (and null when off);
  `fromJson` parses it. Update existing tests that reference `captureAudio`.
- `AudioDeviceInfo` JSON incl. `isDefault`.
- `MicrophoneController`: set device / toggle flags / set null; no-op on equal.
- `RecordingController.startRecording` puts the current `MicrophoneConfig` into
  `RecordingSettings.microphone` (and null when controller is off).

**Channel (mock `MethodChannel`)**
- `getAudioDevices` decodes a list of `AudioDeviceInfo` (incl. isDefault).
- `showMicrophoneMenu` sends `current` and decodes a `MicrophoneMenuResult`
  (config / null / cancelled).

**Widget (`flutter_test`, fake platform + `_wide` surface)**
- Bar mic control renders off state ("No microphone", micOff, grey).
- Renders on state (device label, mic icon, white) given a config.
- Long device label truncates without overflow (pump at bar width).
- Tap calls `showMicrophoneMenu`; a returned config updates the control;
  a cancelled result leaves it unchanged.

**Manual (flutter-qa harness + ffprobe)** — native audio (CoreAudio /
AVAudioEngine / NSMenu) isn't unit-testable in this repo (consistent with the
existing native code having no Swift unit tests):
- Enumerate devices → menu lists real inputs incl. default marker.
- Select a device → record a few seconds → `ffprobe` shows one audio track with
  audible content; "Don't record" → no audio track.
- Toggle "Reduce noise" → recording still has audio (DSP path doesn't crash).
- On macOS < 14, the AGC row is absent.

---

## 11. File map (created / modified)

**Created**
- `screen_recorder_platform_interface/lib/src/models/microphone_config.dart`
- `screen_recorder/lib/state/microphone_controller.dart`
- `screen_recorder_macos/macos/Classes/AudioDeviceCatalog.swift`
- Tests for each of the above + the changes below.

**Modified**
- `screen_recorder_platform_interface`: `recording_settings.dart` (audio fields),
  `audio_device_info.dart` (isDefault), `screen_recorder_platform_interface.dart`
  + `method_channel` impl (getAudioDevices, showMicrophoneMenu, MicrophoneMenuResult),
  `constants.dart`.
- `screen_recorder_macos`: `LiveRecordingWriter.swift` (track-keyed audio),
  `AudioCaptureManager.swift` (device selection + DSP), `ScreenRecorderMacosPlugin.swift`
  (getAudioDevices, showMicrophoneMenu, startLiveRecording wiring),
  `screen_recorder_macos_method_channel.dart`.
- `screen_recorder`: `recording_bar.dart` (`_MicControl`),
  `recording_bar_screen.dart` (wire config + tap), `recording_state.dart`
  (startRecording reads the controller).

---

## 12. Deferred — Sub-projects 2 & 3

Full detail in `2026-05-25-audio-capture-roadmap.md`. Summary:

- **Sub-project 2 — System audio.** ScreenCaptureKit `SCStreamConfiguration.capturesAudio`
  → a `.system` track (uses Sub-1's track-keyed writer). Menu: all apps /
  selected apps / off; "selected apps" needs a per-app `SCContentFilter` + an
  app picker. Bar's "No system audio" control goes live.
- **Sub-project 3 — Editor mixing + export downmix.** Per-track volume controls
  in the editor; export replaces `-map 1:a:0 -c:a copy` with an `amix` graph
  applying per-track gain.
