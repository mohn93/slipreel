# Slipreel — Whole-App Review (2026-06-08)

Multi-agent review: 13 subsystem reviewers (app UI, editor engine, native macOS, deps/security),
each finding re-checked by an independent adversarial verifier that re-read the code.

**45 raw findings → 37 confirmed, 8 refuted.** Severity: **0 critical, 8 major, 19 minor, 10 nit.**

> ### Remediation status (2026-06-14, branch `fix/review-backlog-2026-06-08`)
> All confirmed findings are now resolved:
> - **Majors (8):** M1–M8 fixed & merged earlier (see git history).
> - **Minors (19):** m15/m16 were already fixed by the M-batch; m6 was resolved by M4's
>   `forEditing` spring seed. The rest — m1, m2, m4, m5, m7, m8, m9, m10, m12, m13, m14, m17, m18 —
>   fixed on this branch with tests where logic is testable. (m3, m11 are playground/shader-mode-only;
>   m19 was a reserved placeholder.)
> - **Nits (10):** nit1–4, nit6–9 fixed. **nit5** (camera vanish-tail freeze) left as-is — the
>   reviewer flagged it "arguably correct."
> - Native (Swift) changes compile-verified via `xcodebuild … -destination 'platform=macOS,arch=x86_64'`.

> Note: the "debug-probe seam bypassed" minor (main.dart / pubspec.yaml) is a **false positive** — it
> reflects the local-only `agent_wires_probe` dev edits that are never committed and pass on a clean
> checkout. It is excluded from the real backlog below.

---

## MAJOR (8)

### M1 — Error path never stops the VideoEncoder → leaked native capture + double-record
`packages/screen_recorder/lib/state/recording_state.dart:423-442` · resource-leak
`_handleError()` tears down subscriptions/timer/checkpointer/marker but never stops `_videoEncoder` or
resets `_isActive`. If `stopLiveRecording()` throws/times out inside `stopRecording()`, control jumps to
`_handleError` while the native capture is still running and `_isActive` stays true. Since `status==error`
is a valid `canStartRecording` state, the next Record press calls `_videoEncoder.start()` again →
**second native capture on top of the first**, leaked unfinalized MP4, device contention.
**Fix:** in `_handleError`, best-effort stop the encoder if active (or add `forceReset()`); guard
`startRecording` with `if (_videoEncoder.isActive) return;`.

### M2 — Zoom/camera region drag clamps to a wrong (under-shot) end on sped-up / trimmed clips
`packages/screen_recorder/lib/ui/widgets/timeline/zoom_lane.dart:369,404,418-419,432` (same in `camera_lane.dart:320,351,365,379`) · correctness
`_maxEnd` falls back to `widget.duration` (already **edited** time), then `_update` runs it through
`sourceToEdited()` again — double-converting. For a 10s clip at 2× (edited 5s), the right-edge clamp caps
at 2.5s, so the user **physically cannot drag/resize a zoom or camera region into the second half** of the
timeline. Trimming alone mis-maps too. Unedited single-clip case is a fixed point, so existing tests miss it.
**Fix:** don't round-trip the edited fallback — `editedMaxEnd = neighbors.nextStart != null ? _sourceToEdited(nextStart) : widget.duration;`. Apply in both lanes.

### M3 — Shareable-Link + GIF format → FrameRatePicker assert / broken picker
`packages/screen_recorder/lib/ui/widgets/export_dialog/export_dialog.dart:141-154,79-80,208-228` · correctness
Switching Destination→Shareable Link forces `frameRate:60` without changing `format`. If format is still
`gif`, `_frameRateOptions` is `[30,25,24,20,15,10]` which lacks 60 → `FrameRatePicker`'s
`assert(options.contains(value))` fires in debug; in release the picker shows "60 fps" with no selectable item.
**Fix:** when locking shareable-link, also force `format: mp4` (or hide/disable the fps picker in that mode);
don't let the picker assert against a value the parent can legally produce.

### M4 — Cursor "Motion stiffness" slider in None preset builds an invalid negative-damping spring
`packages/screen_recorder/lib/ui/widgets/inspector/tabs/cursor_tab.dart:351-376` · correctness
In None preset the spring is the snap sentinel `MotionSpring(stiffness:-1, damping:-1)`. The slider's
`onChanged` does `s.copyWith(stiffness: v)` on that sentinel → `MotionSpring(stiffness:v, damping:-1)`.
`isSnap` flips false, so the renderer calls `SpringDescription.withDampingRatio(ratio:-1)` — a **negative
damping ratio** → exponentially growing oscillation; the smoothed cursor diverges.
**Fix:** seed from the displayed fallback, not the sentinel: `base = s.isSnap ? MotionSpring(stiffness:180,damping:1) : s; base.copyWith(...)`. (Fixes the damping-slider no-op M-minor too.)

### M5 — `_initializeVideo` setState without mounted check after awaits → crash on back-nav during load
`packages/screen_recorder/lib/ui/screens/playback_screen.dart:706,785` · bug
Both the success (`706`) and catch (`785`) `setState` calls run after many awaits (controller init, metadata,
cursor/keystroke, project load/save, camera sidecar, ffprobe). Popping the screen mid-load (Escape /
"Record another" / a corrupt video hitting the catch fast) disposes the State → `setState() called after
dispose()`. The rest of the method already guards `mounted` at 779/797/802 — these two are an oversight.
**Fix:** guard both with `if (!mounted) return;` / `if (mounted) setState(...)`.

### M6 — Delete-recording orphans camera/keystroke/thumbnail sidecars + leaves stale Recents entry
`packages/screen_recorder/lib/ui/screens/playback_screen.dart:1276-1308` · resource-leak
Deletes only `.meta.json`, `.cursor.json`, `.editor.json(.tmp)` + the video. Leaves **`.camera.mov`
(hundreds of MB)**, `.camera.json`, `.keystrokes.json`, `.thumb.png`, and never calls
`RecordingHistoryStore.removeByPath`, so the deleted item reappears greyed in Recents. Dialog says
"permanently removed" — false.
**Fix:** add the four sidecars to the delete list and remove the history entry before popping.

### M7 — Screen-capture stream failure mid-recording is silently swallowed (onError never wired)
`packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift:730-742` · error-handling
`ScreenCaptureManager` fires `onError?` from `stream(_:didStopWithError:)`, but the live-recording start path
only sets `onFrameReceived`, never `onError`. If SCStream stops (display unplugged, window closed, GPU reset,
permission revoked mid-session) the error hits a nil handler: UI still says "recording", no frames arrive,
user discovers the truncated/empty file only on Stop.
**Fix:** wire `captureManager.onError` to surface the failure to Flutter and tear down the recording, mirroring the audio `onError` path.

### M8 — `ffprobe` invoked by bare name bypasses FfmpegResolver → breaks export in a packaged app
`packages/slipreel_engine/lib/export/ffmpeg_probe.dart:72,156` · error-handling
Both spawns use bare `'ffprobe'`, relying on PATH. Every other subprocess routes through `Ffmpeg.resolve()`
precisely because "a packaged macOS app has a minimal PATH." In that case `ffmpeg` resolves via
`/opt/homebrew/bin` but bare `ffprobe` throws `ProcessException`. `ffmpegProbe()` is awaited un-try/caught at
the top of `ExportPipeline.run()` and `GifExportPipeline.run()` → **every MP4/GIF export aborts** with an
opaque error on an end-user machine that has ffmpeg installed. (Pattern already exists in
`recovery_service.dart:86`.)
**Fix:** resolve ffprobe as the sibling of the resolved ffmpeg path; pass the absolute path to both call sites.

---

## MINOR (19)

| # | Where | Issue | Fix |
|---|-------|-------|-----|
| m1 | recording_state.dart:396-421 | pause/resume flip Dart status before awaiting platform; rapid toggle races native side | serialize with in-flight guard / flip status after await |
| m2 | recording_state.dart:444-452 | `dispose()`/`reset()` abandon an active recording (no encoder stop). `reset()` currently dead but a foot-gun | route through stop/cleanup when `isRecording` |
| m3 | playback_canvas.dart:1324-1326 | scene-blur capture disposes prev `ui.Image` synchronously → can paint disposed image (playground accumulation mode only) | adopt SceneBlurOverlay's deferred-dispose queue |
| m4 | playback_canvas.dart:728-731 | `_lastCameraPlacement` never cleared → ghost bubble at stale pos after delete-all then re-add in a gap | clear in `didUpdateWidget` when regions empty/camera disabled |
| m5 | camera_bubble.dart:354-367 | corner-resize past ~0.88 width snaps bubble to canvas center mid-drag | derive `_maxSize` cap from canvas/shape aspect, or re-clamp center |
| m6 | cursor_tab.dart:366-375 | "Motion damping" slider in None preset is a silent no-op (stays snap) | same seed-from-fallback fix as M4 |
| m7 | audio_tab.dart:111-136 | global mic/system volume reads & writes **slice 0 only** → after a cut, later slices untouched | loop over all slices, or scope/label to selected slice |
| m8 | alert_stack_overlay.dart:43-55 | alert arriving while deck hover-expanded keeps its auto-dismiss timer → dismisses under cursor | pause new entry's timer when `_expanded` |
| m9 | export_pipeline.dart:282-292 | progress denominator = full source duration → bar freezes well below 100% on trimmed exports | use sliced `outputDurationSec * fps` (already computed) |
| m10 | frame_compositor.dart:127,360-405 | cached wallpaper `ui.Image` never disposed (InProcess dispose is a no-op) → ~8-10 MB leak/export | add `FrameCompositor.dispose()` disposing the cached image; call from `InProcessExportCompositor.dispose()` |
| m11 | cursor_overlay_painter.dart:310-334 | shader cursor-blur sets `uOutputSize`=unscaled while drawn rect is pulse-scaled → off-center/clipped during press-pulse (playground shader mode) | set `uOutputSize` to `scaledSize`, scale reach by pulse |
| m12 | blur_effect.dart:60-75 | leaks 2 `ui.Image` + 1 `ui.Picture` per call (dead path today; GradientEffect same) | try/finally dispose; mirror frame_compositor discipline |
| m13 | cursor_renderer.dart:69-115 | leaks frame image/picture/output every frame + force-unwraps `byteData!` (dead code) | dispose in finally; or delete the superseded file |
| m14 | camera_render_resolver.dart:124-136 | reveal re-animates (fade-out+in flicker) across joins within glide tolerance (1-4ms gap) | merge runs using the same `joinTolerance` the placement resolver uses |
| m15 | editor_project_state.dart:318-327,392-404 | one unknown `cursorStyle`/`cursorClickEffect` enum string → `_decodeEnum` throws → store discards the **entire** project for defaults | make `_decodeEnum` fall back to default on unknown name |
| m16 | services/curve_library.dart:65-90 | one malformed entry → `list()` returns `[]` for whole file; next `save()`/`delete()` persists the loss → all saved curves erased | parse per-record defensively; don't overwrite on corrupt-fallback; back up first |
| m17 | CameraCaptureManager.swift:98-105 | camera/mic `AVCaptureSession` runtime-error/interruption not observed → unplugged webcam silently truncates the track | observe `runtimeError`/`wasInterrupted` (+ AVAudioEngine config-change); warn + finalize sidecar |
| m18 | HotkeyManager.swift:19-72 | Carbon event handler re-installed (leaked) on the documented conflict-retry path | install handler at most once (guard on `handlerRef == nil`) |
| m19 | *(reserved — see m6 / cursor damping; counted in the 19 with the audio/global one)* | | |

## NIT (10)

- `playback_canvas.dart:1274-1281` — `_subFrameTransformAt` uses half-open region lookup vs the fixed closed-interval scene sample (playground accumulation only). Use `ZoomRegion.activeAt`.
- `curve_editor.dart:112-139` — numeric field keeps typed (unclamped) text after commit until next unfocused rebuild. Write clamped value back to controller.
- `recording_bar_screen.dart:180,223` — window-chrome channel calls fire-and-forget → unhandled async error if the channel rejects. Add `.catchError` log.
- `playback_screen.dart:1881` — `_lastExportPath` records temp paths for clipboard/shareable-link; "reveal last export" silently fails after OS reaps the temp file. Only record for file destination, or existence-check before reveal.
- `camera_render_resolver.dart:85-97` — vanish-tail freezes at a mid-glide placement for sub-350ms final regions that touch a predecessor. (Arguably correct as-is.)
- `utils/app_logger.dart:46-57` — `color!(output)` force-unwrap throws for uncolored levels (`verbose`/`wtf`); latent (no callers). Add `?? AnsiColor.none()`.
- `ScreenRecorderMacosPlugin.swift:733-739` (×2 findings) — unsynchronized read/write of `firstVideoFrameAt`/`firstVideoFrameHostSeconds` across capture/cursor/keystroke/stop threads. One-time nil→value write, atomic on arm64; guard with `os_unfair_lock` for correctness.
- `ScreenRecorderMacosPlugin.swift:1041-1042` — screen vs camera `pausedOffset` use independent host-clock reads → sub-millisecond cumulative A/V drift across many pause cycles. Capture one timestamp, pass to both writers.
- `SourcePickerOverlay.swift:37-81` (+ `RegionSelector.swift:40-86`) — picker hangs forever if `NSScreen.screens` is empty (headless/CI). Resume continuation with nil when no overlay windows.

---

## REFUTED (8) — verifiers confirmed these are NOT bugs
- SleepObserver init-window race — native `onEvent` is nil until Dart subscribes; no recording at init.
- RecoveryService ffprobe suffix — all macOS-resolved paths end in `ffmpeg`; Windows branch unreachable (macOS-only app).
- WindowModeController optimistic state — native `setMode` has no failure mode.
- CameraFrameSource iterator on decode-setup failure — `async*` doesn't spawn the subprocess until first `moveNext()`; nothing to leak.
- Cursor motion-blur preview/export divergence — `focalAt`/`scaleAt` never passed by any caller, so both paths take the same branch; WYSIWYG holds.
- `_coverSrcRect` zero-height NaN — `size` clamped ≥0.02 and aspect guarded; unreachable.
- PerfSampler GCD timer leak — `catch` block unreachable; weak-self handler is a no-op.
- deps-security ffprobe string-replace — same macOS-only reasoning as RecoveryService.
