# Device Capture — Design (iPhone / iPad over USB)

**Status:** Design — pending user review
**Date:** 2026-06-20
**Sub-project:** A of 2 (this = capture; B = device mockup frames, separate spec later)

## Problem

The recording bar has a **Device** chip (smartphone icon) but it's a disabled stub
(`onTap == null`). Users want to record a connected iPhone/iPad screen the way they
record a display/window/area today, and then edit/export it in the same editor.

## Scope (decided in brainstorming)

- **Connection:** USB cable, via AVFoundation external capture device (the mechanism
  QuickTime "New Movie Recording" uses). No AirPlay/wireless in v1.
- **Devices:** Apple only — iPhone + iPad over USB. Android is explicitly out of scope
  (it needs a separate ADB/scrcpy stack).
- **Audio:** capture the device's own audio by default (toggleable) + optional Mic
  narration via the existing Mic control. The bar's System-audio control is hidden in
  Device mode (irrelevant to a device recording).
- **Preview:** none in v1 — pick a device by name, then record (with the existing
  3-2-1 countdown). A live preview can be added later.

## Non-goals (v1)

- Live preview of the device screen before recording.
- AirPlay / wireless capture.
- Android.
- Device-specific editor features beyond what device recordings naturally use
  (cursor/click/keystroke features are inert — see Editor behavior).
- Device mockup frames — that's sub-project B.

## Approach

**Dedicated capture manager, reuse the existing recording orchestration.** A new
native `DeviceCaptureManager` drives an `AVCaptureSession` over the external iOS
device and feeds the *existing* writer/encoder to produce a `.mp4`. A new
`RecordingSource.device` flows through the **same** start → countdown → stop →
recovery path as screen sources, and the editor opens the result like any other
recording.

Rejected alternatives:
- *Standalone QuickTime-style capture window + import* — bolt-on; discards the
  integrated recording UX.
- *Unify SCStream + AVCaptureSession behind one `VideoCaptureSource` protocol* —
  cleaner long-term but an upfront refactor of working screen capture; over-engineered
  for v1. (Left as a future refactor if a 3rd source type appears.)

## Architecture

### Native (Swift — `packages/screen_recorder_macos/macos/Classes`)

- **`DeviceCatalog.swift`** — enumerate connected iOS capture devices via
  `AVCaptureDevice.DiscoverySession` (external + muxed device types). Returns
  `[{id, name, kind: phone|tablet}]`. **Critical enabler:** call
  `CMIOObjectSetPropertyData` with `kCMIOHardwarePropertyAllowScreenCaptureDevices = 1`
  once at startup so iOS screen-capture DAL devices become visible (QuickTime relies on
  this; without it the discovery session won't list iPhones).
- **`DeviceCaptureManager.swift`** — owns an `AVCaptureSession`:
  - `AVCaptureDeviceInput` for the chosen external video device.
  - `AVCaptureDeviceInput` for its audio (when device-audio enabled).
  - `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput` → `CMSampleBuffer`s.
  - Routes sample buffers into the existing `LiveRecordingWriter` /
    `VideoToolboxEncoder` so output format, fragmented-MP4 crash recovery
    (`movieFragmentInterval`), and finalize logic are shared with screen capture.
  - Handles device-disconnect (`AVCaptureDeviceWasDisconnected`) → stop + finalize +
    surface a "device vanished" signal (reuse the existing vanished-device pattern).
- **Plugin (`ScreenRecorderMacosPlugin.swift`)** new methods:
  - `listDevices()` → JSON list from `DeviceCatalog`.
  - `startDeviceRecording({deviceId, captureDeviceAudio, outputPath, ...})`.
  - reuse existing `stopRecording` / pause / resume.

### Platform interface (`screen_recorder_platform_interface`)

- `DeviceSource` model: `{ String id, String name, DeviceKind kind }`,
  `DeviceKind { phone, tablet }`, with JSON.
- Methods: `Future<List<DeviceSource>> listDevices()`,
  `Future<void> startDeviceRecording({required String deviceId, required bool captureDeviceAudio, required String outputPath, ...})`.

### Dart (`screen_recorder`)

- **`RecordingSource.device`** added to the source enum; a recording's source kind is
  persisted so the editor knows it's a device recording.
- **Bar:** enable the Device chip (`onTap` → open the device picker). New
  `DevicePickerOverlay`/sheet listing `DeviceSource`s (name + phone/tablet icon);
  empty state = "Connect an iPhone or iPad over USB and tap Trust This Computer."
  Selecting a device arms Device mode (bar shows the device name), mirroring how the
  window picker arms a window.
- **Bar controls in Device mode:** hide the System-audio control; keep the Mic
  control; add a **Device audio** toggle (default on).
- **`recording_state.startRecording`** gains a device branch that calls
  `startDeviceRecording` with the selected `deviceId` + the Device-audio flag, writing
  to the resolved save directory (reusing `resolveSaveDirectory` / global prefs).
- **`recording_action_router`** routes Device-mode start/stop through the same flow as
  screen sources (countdown, hotkeys, long-recording watcher all reuse).

### Editor behavior

Device `.mp4` opens in the existing editor. Device recordings produce **no `.cursor`
sidecar**, so the `hasCursorData == false` path (already present in `ScenePassBuilder`
/ playback) makes cursor smoothing, click-driven auto-zoom, and the keystroke overlay
simply inert. What still works: trim/cut/speed, **manual zoom**, frames (incl. device
mockups in sub-project B), camera PiP, and mic/device-audio mixing.

## Permissions & error handling

- **Camera permission** gates device capture (an iOS device is a video
  `AVCaptureDevice`). Reuse `PermissionsController` camera; denied → existing grant
  prompt / deny sheet.
- **Not trusted / locked / unplugged** → device doesn't enumerate (empty picker) or
  `startDeviceRecording` fails → clear inline message via `AppAlerts`; no crash.
- **Disconnect mid-recording** → `DeviceCaptureManager` stops, finalizes the partial
  `.mp4` (fragmented-MP4 means it's playable), and warns — reusing the vanished-device
  + crash-recovery patterns.
- **DAL enable failure** (`kCMIOHardwarePropertyAllowScreenCaptureDevices`) → log +
  empty picker with the connect/trust hint.

## Data flow

```
Device chip → listDevices() → DevicePickerOverlay → pick DeviceSource
   → arm Device mode (bar shows name; Mic + Device-audio toggles)
   → Record → 3-2-1 countdown → startDeviceRecording(deviceId, captureDeviceAudio, path)
   → DeviceCaptureManager(AVCaptureSession) → CMSampleBuffers → LiveRecordingWriter → .mp4
   → Stop → editor opens .mp4 (no .cursor sidecar)
```

## Testing

- **Dart unit/widget:**
  - `DeviceSource` model + JSON round-trip; `DeviceKind` parse.
  - `RecordingSource.device` added; source persists/loads.
  - `recording_action_router` device branch calls `startDeviceRecording` with correct
    args (fake platform captures the call).
  - `startRecording` device branch resolves the output path via `resolveSaveDirectory`.
  - Bar Device-mode widget state: System-audio control hidden, Mic + Device-audio
    toggle present; Device chip enabled.
  - `DevicePickerOverlay` widget: renders a list of fake `DeviceSource`s; empty state
    shows the connect/trust hint.
- **Native:** compile-check via
  `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build`. `DeviceCatalog`
  enumeration + `DeviceCaptureManager` capture need a real device, so they're verified
  at runtime, not unit-tested; keep their Swift surface thin.
- **Runtime (user):** physical iPhone/iPad — enumerate, record, device audio on/off,
  mic narration, mid-record disconnect → partial file recovers.

## Files (anticipated)

- Create: `screen_recorder_macos/macos/Classes/DeviceCatalog.swift`,
  `DeviceCaptureManager.swift`.
- Modify: `screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
  (+`listDevices`/`startDeviceRecording`; DAL enable at startup).
- Create: `screen_recorder_platform_interface/lib/src/models/device_source.dart`.
- Modify: platform interface (method-channel + interface methods).
- Modify (Dart): recording source enum, `recording_state.dart`,
  `recording_action_router.dart`, `recording_bar.dart` / `recording_bar_screen.dart`
  (enable Device chip + Device-mode controls), new `DevicePickerOverlay`.
- Tests as listed above.

## Open risks (acknowledged, not blockers)

1. iOS devices only appear when **plugged in, unlocked, and trusted** — enumeration is
   inherently conditional.
2. No physical device on the build machine → **capture is user-verified**, not
   automated.
3. `kCMIOHardwarePropertyAllowScreenCaptureDevices` is the linchpin; if Apple changes
   DAL behavior on a future macOS, enumeration could regress.
