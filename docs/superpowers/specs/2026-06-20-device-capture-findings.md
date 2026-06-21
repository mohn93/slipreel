# Device Capture (iPhone/iPad over USB) — Findings & Verdict

**Date:** 2026-06-20 (updated 2026-06-21 with off-main-fix runtime re-test)
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
| Native capture | `DeviceCaptureManager` (AVCaptureSession) → existing `VideoToolboxEncoder` + `LiveRecordingWriter` | ❓ session setup off-main works; **frame delivery still UNTESTED** — the camera gate (§5d) blocks before native capture runs |
| Controller | `RecordingController.startDeviceRecording` (skips cursor/keystroke sidecars; camera-required + mic-optional permission gates) | ⚠️ logic tested, but the camera gate fires post-countdown + shows the deny sheet in the bar (§5d) — the actual current blocker |
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

## 4. What works at runtime (verified with a real iPhone over USB)

> ### ✅ BREAKTHROUGH 2026-06-21 — END-TO-END CAPTURE WORKS (the core unknown is resolved)
> A real device recording produced a valid file: `~/Documents/recording_1782030881275.mp4`
> — **`h264`, 1170×2532 (iPhone portrait), 215 frames over ~4.0s** (`ffprobe`-verified).
> **The muxed iPhone device DOES deliver video frames through the EXISTING
> `AVCaptureVideoDataOutput` → `VideoToolboxEncoder` → `LiveRecordingWriter` pipeline.**
> The §5c hypothesis (muxed frames won't flow) is **DISPROVEN**, and the
> `AVCaptureMovieFileOutput` rewrite floated in §6.1 is **NOT needed**. The recording
> opened in the editor. Capture is viable as-built.
>
> **What it took to get here (all dev-build/env, NOT product issues):** the feature needs
> **Camera AND Screen Recording** permission (an iOS screen device is a video
> `AVCaptureDevice` *and* enumerating it via `AVCaptureDevice.DiscoverySession` is gated by
> Screen Recording). The ad-hoc-signed debug build couldn't hold TCC grants (cdhash changes
> each rebuild) and—when launched by `flutter run`—attributed camera to the harness, so the
> app never registered in the permission lists. Fix that unblocked it: **(a)** sign the
> Debug build with a stable Apple Development cert (local-only pbxproj edit, team
> `799PAFQLNK`, do NOT commit), **(b)** launch the built `.app` **standalone** (parent =
> `launchd`) so it's its own TCC responsible process. Then grant Camera (inline prompt) +
> Screen Recording (Settings toggle + app restart). In a shipped/notarized build none of
> this friction exists (permissions persist + already granted for normal recording).

- Device **detection + listing**: the muxed screen device appears in the dropdown.
- The **native dropdown** UX (no overflow; floats free of the 68px bar window).
- Recording **starts** (countdown runs, state flips to `recording`).
- **Full capture → valid `.mp4` → editor** (see breakthrough box above).

### 4b. Off-main-thread fix — RUNTIME-VERIFIED 2026-06-21 — commits `bfc0df2c` → `27edecb5`
**Earlier symptom (pre-fix):** starting a device recording froze the whole Flutter UI
mid-morph — the bar showed a dark "empty modal" overlay with no Stop/Pause pill, and the
app had to be force-killed. **Root cause:** the entire `AVCaptureSession` setup
(`AVCaptureDeviceInput(device:)`, `commitConfiguration()`, `device.activeFormat` reads,
`session.startRunning()`) **blocks** for an external/muxed device; it was running on the
main thread.
**Fix:** the plugin now wraps the whole `DeviceCaptureManager.start()` in
`withCheckedThrowingContinuation` + `DispatchQueue.global(qos:.userInitiated).async`, so
all blocking AVFoundation calls run off-main.
**Verified 2026-06-21 with the iPhone connected:** after a record attempt the app is
**not wedged** — `app_status` reports `state: ready` with the VM service responsive, and
the recording bar **cleanly returns to its idle state** (Display/Window/Area/Device +
"Device audio"). The main-thread freeze is gone. ✅

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

### 5c. Muxed video frames — **STILL UNVERIFIED** (a 2026-06-21 over-claim was retracted)
**Hypothesis:** the iPhone screen device is **muxed**, but `DeviceCaptureManager` uses a
separate `AVCaptureVideoDataOutput`. AVFoundation may not deliver demuxed **video** frames
from a muxed device through that output → zero frames downstream.
**RETRACTION:** an earlier 2026-06-21 note claimed today's "no output file" *confirmed*
zero-frame delivery. **That was wrong.** The record attempt never reached native capture
at all — it bails in Dart at the **Camera-permission gate** (see §5d) and shows the deny
sheet *before* `_videoEncoder.startDevice(...)` is called. So "no file" is fully explained
by the permission gate; it says **nothing** about muxed frame delivery, which remains
untested. The hypothesis stands but is unproven.
**Tooling limit (why no literal native log line):** under a debug `flutter run`, native
`NSLog` goes to the Flutter console's stderr, **not** the unified log store — so
`log show --predicate '...DeviceCaptureManager...'` returns nothing, and flutter-qa
`get_logs` only captures Dart `debugPrint`. The diagnostic NSLogs (`.video connection
nil`, first-frame, frame count) are therefore **unreadable through the agent's tools** in
this build mode. To read them: run a **release/profile build** (NSLog → unified store), or
route the diagnostic back over the method channel as a Dart `debugPrint`. But first the
camera gate (§5d) must be cleared, or native capture never runs.

### 5d. Camera-permission gate fires after the countdown + renders the deny sheet IN the bar — **NEW (the actual current blocker)** 2026-06-21
**Symptom (user-reported):** after the 3-2-1 countdown, the bar shows an "empty modal" and
**never morphs to the recording pill**.
**Root cause:** an iPhone-over-USB is a *video* `AVCaptureDevice`, so
`startDeviceRecording` requires **Camera** permission and gates on it
(`recording_state.dart` ~L320). Camera is **not granted** to Slipreel, so it calls
`onDenied(PermissionKind.camera)` → `PermissionDeniedSheet.show(context, …)`, which is a
`showModalBottomSheet` rendered into the **bar window's** context
(`recording_action_router.dart` ~L66). Two consequences:
  1. **No pill** — the gate `return`s *before* the `status: recording` flip
     (`recording_state.dart` ~L349) that drives the pill, so the recording never starts.
  2. **"Empty modal"** — the sheet (~150px: title + body + 2 buttons) is clipped inside the
     68px bar window down to a dark scrim + drag handle. A modal bottom sheet has no business
     rendering in the bar at all.
**Fixes needed (independent of muxed delivery):**
  - Grant Slipreel **Camera** access (System Settings → Privacy & Security → Camera) to get
    past the gate at all. Better: trigger the **system camera prompt**
    (`AVCaptureDevice.requestAccess(for: .video)`) on first device use instead of only
    showing a go-to-Settings sheet on `notDetermined`.
  - **Check camera permission BEFORE the countdown**, not after (don't waste a countdown
    then deny).
  - **Don't render the deny sheet in the bar** — show it as a panel screen / proper dialog
    window (same lesson as the device-picker overflow fix, 0811f010 → 44018c2f).
**Best-effort changes (compile-only, NEED DEVICE VERIFICATION):**
- NSLog of the device's `hasMediaType(.muxed/.video/.audio)` + formats at `start()`.
- Loud WARNING log if `videoOutput.connection(with: .video) == nil` (would directly
  explain zero frames).
- Session preset now walks `[.high, .medium, .low]` guarded by `canSetSessionPreset`
  (note: `.inputPriority` is unavailable on macOS — compiler-rejected).
- NSLog on the **first** delivered video frame + a `deliveredVideoFrameCount` (also used
  by the zero-frame stop guard).
- Re-entrancy guard in `stop()`.

**STATUS 2026-06-21:** all three §5d fixes are **implemented** (commit `cf03a3a2`) and the
camera gate is cleared — capture then works end-to-end (§4 breakthrough). §5d is RESOLVED.

### 5e. Device capture needs Screen Recording too + repeated prompt — **NEW, polish** 2026-06-21
**Finding:** capturing an iPhone screen needs **Screen Recording** permission in addition to
Camera, because `DeviceCatalog.connectedDevices()` runs an `AVCaptureDevice.DiscoverySession`
over `.external`/`.externalUnknown` **screen-capture** devices, which macOS gates behind
Screen Recording. The pre-flight (`cf03a3a2`) only checks **Camera** — a gap.
**Symptom (user-reported, non-blocking):** the macOS Screen-Recording prompt re-appears on
**every Device-chip click**, even after the user granted it. Two compounding causes:
  1. Screen Recording permission only takes effect after an **app restart**; granting it
     mid-session leaves the running process re-checking on each enumeration.
  2. `connectedDevices()` re-enumerates screen-capture devices on every `showDeviceMenu`
     (plugin L670), and each enumeration re-triggers the gate until the restart lands.
**Fixes (follow-up, not blocking — capture works):**
  - Restart resolves it immediately for the user.
  - Pre-flight should ensure **Screen Recording** (not just Camera) for a device source.
  - Consider caching the device list / not re-enumerating on every chip click.

## 6. Remaining work (to make capture actually produce video)

**Do these in order — the camera gate (§5d) blocks everything else.**

0. **Clear the Camera-permission gate (§5d) — do this FIRST.** Until it's cleared, native
   capture never runs and nothing below is testable.
   - Grant Slipreel Camera access (or, better, trigger `AVCaptureDevice.requestAccess`
     on first device use).
   - Move the camera check **before** the countdown.
   - Render the deny sheet as a **panel/dialog**, not `showModalBottomSheet` into the bar.

1. **THEN diagnose muxed delivery (§5c) — the real unknown.** With native capture finally
   running, on a release/profile build read the `.video connection` / first-frame NSLogs.
   - If frames flow → the existing `VideoToolboxEncoder`/`LiveRecordingWriter` path may
     just work; verify a file is produced.
   - If zero frames → switch the device path to **`AVCaptureMovieFileOutput`** (writes the
     muxed H.264 stream straight to a `.mov`; bypasses the manual encoder/writer). Keep the
     session setup **off-main** (§4b — already correct and verified).
   Add the muxed device's `AVCaptureDeviceInput` to the session and attach an
   `AVCaptureMovieFileOutput`; call `startRecording(to:recordingDelegate:)` to write the
   muxed stream straight to a `.mov`/`.mp4` (the iPhone stream is already H.264 — no
   manual `VideoToolboxEncoder`/`LiveRecordingWriter` needed for the device path). This is
   a **device-specific writer branch**, parallel to (not replacing) the screen path.
   - Keep the session setup **off-main** (§4b) — that part is already correct and verified.
   - Capture the native `.video connection` / first-frame markers while iterating by
     running a **release/profile build** or routing the diagnostic to Dart (see §5c).
2. **Re-verify the recording pill + Stop** end-to-end once a file is produced (the pill
   transition itself is already wired and un-gated — §5b).
3. **Confirm captured file** has real iPhone content (not black) and opens in the editor.
4. **iPad** parity check.

## 7. Branch state & recommendation

- `feat/device-capture` holds all of the above. **Do NOT merge as-is** — recording does
  not yet produce a valid video, and shipping an enabled Device chip that errors would
  regress UX.
- Options to leave it shippable in the meantime: re-disable the Device chip (one line in
  `recording_bar.dart`) behind a flag, OR keep it on the branch only.
- The non-device work on this branch is sound and reusable.

## 8. Verdicts (updated 2026-06-21 — END-TO-END CAPTURE CONFIRMED WORKING)

- **Feasibility:** ✅ iPhone screen capture over USB works — muxed `AVCaptureDevice`.
- **Capture pipeline (muxed delivery):** ✅ **WORKS as-built** — the muxed device delivers
  frames through the existing `AVCaptureVideoDataOutput` → `VideoToolboxEncoder` →
  `LiveRecordingWriter` path. Verified file: 1170×2532 h264, 215 frames (§4 breakthrough).
  No `AVCaptureMovieFileOutput` rewrite needed.
- **Detection + UX:** ✅ working (dropdown lists the screen device; device-mode controls).
- **Permission UX fix:** ✅ camera pre-flight before the countdown + deny UI as a full
  panel (not a clipped bar sheet) — committed `cf03a3a2`, runtime-confirmed (the panel
  renders full-screen).
- **UI no longer freezes:** ✅ off-main session setup (§4b) — verified.
- **Permissions required:** ⚠️ device capture needs **BOTH Camera and Screen Recording**.
  The pre-flight currently only gates **Camera** — it should also ensure Screen Recording
  (gap; see §5e). In a shipped build Screen Recording is already granted (normal recording),
  so this rarely bites in production, but the flow should handle it.
- **Stability:** ✅ no wedge; clean failure when permissions/ frames are missing.
- **Branch recommendation:** capture is proven; the remaining work to ship is **polish**
  (§5e repeated Screen-Recording prompt + Screen-Recording pre-flight, iPad parity). The
  **signing pbxproj edit is LOCAL-ONLY — must NOT be committed** (hardcodes a personal cert;
  would break other machines/CI). Revert it before merging device work.
- **Next session starting point (revised):** address §5e (cache device enumeration / ensure
  Screen Recording in the pre-flight so the prompt doesn't repeat), iPad parity check, then
  the mockup-frames sub-project B.
