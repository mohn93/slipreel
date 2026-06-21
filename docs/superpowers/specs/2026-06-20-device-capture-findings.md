# Device Capture (iPhone/iPad over USB) — Findings & Verdict

**Date:** 2026-06-20
**Branch:** `feat/device-capture` (NOT merged — work-in-progress)
**Related:** spec `2026-06-20-device-capture-design.md`, plan `2026-06-20-device-capture.md`

This document records what was built, what we learned at runtime with a real
iPhone, the bugs found, the fixes applied, and the honest verdict on the feature.
Written so the work can resume cold.

---

## 1. Goal

Make the recording bar's **Device** chip record a USB-connected iPhone/iPad screen
to an `.mp4` that opens in the existing editor. Brainstorm decisions: USB/AVFoundation
only, iPhone + iPad only, device audio (toggleable) + optional mic, no live preview.

## 2. What was built (DC1–DC7, all committed)

| Layer | Delivered | Status |
|---|---|---|
| Platform model | `RecordingSource.device` + `DeviceSource`/`DeviceKind` + JSON | ✅ tested |
| Method channel | `listDevices` + `startDeviceRecording` | ✅ tested |
| Native enumerate | `DeviceCatalog` (DAL enable + muxed-only filter, excludes Continuity Camera) | ✅ compiles, runtime-confirmed listing |
| Native capture | `DeviceCaptureManager` (AVCaptureSession) → existing `VideoToolboxEncoder` + `LiveRecordingWriter` | ⚠️ compiles; **frame delivery unverified** |
| Controller | `RecordingController.startDeviceRecording` (skips cursor/keystroke sidecars; camera-required + mic-optional permission gates) | ✅ tested |
| Picker UX | **Native `NSMenu` dropdown** anchored to the chip (replaced an earlier panel-screen attempt) | ✅ runtime-confirmed |
| Bar wiring | Device chip enabled; device-mode swaps System-audio → **Device audio** toggle | ✅ runtime-confirmed |

All Dart work is unit/widget-tested. Native is `xcodebuild` compile-checked only
(no iPhone on the build machine; `flutter build macos` is broken in this env).

## 3. Feasibility verdict — **POSSIBLE** (an earlier conclusion was wrong)

**The iPhone screen IS capturable over USB.** When the phone is connected + unlocked +
trusted, it exposes a **muxed** (audio+video) `AVCaptureDevice` named `"<name>"`
(no "Camera"). Our muxed-only filter lists exactly that, and selecting it starts a
recording.

**Important gotcha:** QuickTime Player's "New Movie Recording" source list hides this —
it shows the iPhone only as a **Camera** (Continuity Camera) and a **Microphone**, and
its "Screen" section lists Mac displays only. So QuickTime is **not** a reliable
feasibility probe; the device is there even though QuickTime's UI doesn't offer it.

(An earlier session step concluded "infeasible — even QuickTime can't" — that was
premature: the phone was locked / not yet cable-connected at that moment.)

## 4. What works at runtime (verified with a real iPhone 14 Pro Max)

- Device **detection + listing**: the muxed screen device appears in the dropdown.
- The **native dropdown** UX (no overflow; floats free of the 68px bar window).
- Recording **starts** (countdown runs, state flips to `recording`).

## 5. Bugs found at runtime + fixes applied

### 5a. Stop wedged the app — FIXED (high confidence) — commit `738bd887`
**Symptom:** after starting a device recording, ⌘⇧2 did nothing; the app froze and had
to be force-killed; no editor opened.
**Root cause:** the iPhone screen device delivered **zero video frames** (see 5c), so
`LiveRecordingWriter`'s lazy `AVAssetWriter` session never opened. The old `stop()`
returned a phantom *success* pointing at a missing/empty file, and the teardown could
block on a finalize that had nothing to finish.
**Fix:** zero-frame stop now returns a clear `WriterError.noFramesWritten` →
`"No frames captured from device"`, fully synchronous; `stopLiveRecording` always
reaches the `FlutterResult`, nils the device-manager callbacks before `stop()`, and the
Dart `_handleError` path leaves the UI in a clean **error** state instead of frozen.

### 5b. No recording UI during device recording — NOT A SEPARATE BUG
**Symptom:** during recording the bar was a dark overlay with only a drag-handle pill —
no timer/Stop/preview.
**Finding:** `startDeviceRecording` already sets `status: recording` identically to the
screen path, and the recording pill is driven purely by that status with no
source-kind gating. The "no UI" was a **consequence of the Stop wedge** (frozen app),
not a missing transition. Fixing 5a should restore the normal recording pill. (A
load-bearing comment was added to keep the status-flip parity.)

### 5c. Muxed video frames may not flow — **UNRESOLVED (the crux)** — best-effort only
**Hypothesis:** the iPhone screen device is **muxed**, but `DeviceCaptureManager` uses a
separate `AVCaptureVideoDataOutput`. AVFoundation may not deliver demuxed **video**
frames from a muxed device through that output → zero frames → everything downstream
(no preview, empty file, the old wedge).
**Best-effort changes (compile-only, NEED DEVICE VERIFICATION):**
- NSLog of the device's `hasMediaType(.muxed/.video/.audio)` + formats at `start()`.
- Loud WARNING log if `videoOutput.connection(with: .video) == nil` (would directly
  explain zero frames).
- Session preset now walks `[.high, .medium, .low]` guarded by `canSetSessionPreset`
  (note: `.inputPriority` is unavailable on macOS — compiler-rejected).
- NSLog on the **first** delivered video frame + a `deliveredVideoFrameCount` (also used
  by the zero-frame stop guard).
- Re-entrancy guard in `stop()`.

## 6. Remaining work (to make capture actually produce video)

1. **Solve muxed-device video delivery (blocking).** Run with a real iPhone and read the
   device logs:
   - If `NO .video connection` / `ZERO video frames` → `AVCaptureVideoDataOutput`
     doesn't demux this device. Likely answer: capture the muxed device with
     **`AVCaptureMovieFileOutput`** (writes the muxed stream straight to a file — no
     manual encode/writer), OR access the muxed connection differently. This would mean
     a device-specific writer path (the iPhone stream is already H.264-ish), bypassing
     `VideoToolboxEncoder`.
   - If `first VIDEO frame delivered` appears → frames DO flow; the bug is elsewhere
     (encoder/writer wiring), and the existing path may just work after 5a.
2. **Re-verify the recording pill + Stop** end-to-end once frames flow.
3. **Confirm captured `.mp4`** has real iPhone content (not black) and opens in the editor.
4. **iPad** parity check.

## 7. Branch state & recommendation

- `feat/device-capture` holds all of the above. **Do NOT merge as-is** — recording does
  not yet produce a valid video, and shipping an enabled Device chip that errors would
  regress UX.
- Options to leave it shippable in the meantime: re-disable the Device chip (one line in
  `recording_bar.dart`) behind a flag, OR keep it on the branch only.
- The non-device work on this branch is sound and reusable.

## 8. Verdicts

- **Feasibility:** ✅ iPhone screen capture over USB is possible (muxed AVCaptureDevice).
- **Detection + UX:** ✅ working (dropdown lists the screen device; device-mode controls).
- **Capture pipeline:** ⚠️ structurally sound but **does not yet deliver video frames**
  from the muxed device — this is the one real blocker.
- **Stability:** ✅ no longer wedges; fails cleanly with a clear error when no frames.
- **Effort to finish:** small-to-medium, but gated on a single native unknown (muxed
  video delivery), which needs a real device to resolve — most likely by switching the
  device path to `AVCaptureMovieFileOutput`.
- **Next session starting point:** connect iPhone → record → read native logs for the
  `.video connection` / first-frame markers → decide encoder-path vs `AVCaptureMovieFileOutput`.
