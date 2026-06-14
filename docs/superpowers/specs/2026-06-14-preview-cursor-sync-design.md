# Preview cursor sync (frame-exact) + cursor-track capture fixes — Design

**Date:** 2026-06-14
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

In the editor preview, the synthetic cursor overlay **leads** the recorded video
by a roughly constant amount ("the mouse moves too early"). The user observes it
in the editor preview (has not compared the exported MP4) and reports the offset
as roughly constant.

### Root cause (established by investigation)

The lead is a **preview-rendering** artifact, not a capture/export defect:

- Cursor samples are timestamped in the native plugin as
  `Date.now − firstVideoFrameAt`, where `firstVideoFrameAt`
  (`FirstFrameTiming.captureInstant`) is back-computed from the **first SCStream
  frame**. The live writer zeroes the video timeline to that **same first frame**
  (`startSession(atSourceTime: pts)`). So cursor-time 0 == video-time 0. The only
  residual capture error possible is the encoder dropping warmup frames, which
  can only make the cursor render *late* (lag) or leave a head/tail gap — it is
  mathematically incapable of producing a forward *lead*. A forward lead can only
  originate in the preview.
- In the editor the cursor overlay is drawn at `smoothPlayhead.position`
  (`playback_canvas.dart:507`), which tracks the AVPlayer **playback clock**
  (`smooth_playhead_controller.dart` extrapolates `base + elapsedWallClock ×
  speed`). The on-screen `VideoPlayer` **texture** shows whatever frame AVPlayer
  has actually decoded/presented. Under 60 fps HD preview load,
  `hasNewPixelBufferForItemTime:` returns false and the texture **holds an older
  frame**, so the picture trails the clock by a **load-dependent** latency.
- The export pipeline drives the *same* cursor renderer but feeds each frame's
  **exact** source timestamp, so the MP4 is frame-aligned and unaffected.

There is already a `cursorDelay` knob (default 50 ms; this project has exactly
that) that renders the cursor slightly *behind* the playhead. It is a creative
"align the cursor to the app's UI redraw" control applied to **both** preview and
export. The machine's true display latency exceeds 50 ms, so a lead remains. The
display latency must therefore be a **separate, preview-only** compensation,
layered on top of `cursorDelay` — not a change to `cursorDelay` itself (which
would wrongly shift the exported cursor backward).

### Two adjacent capture bugs found in the user's real recordings

These *do* affect the exported MP4 and are bundled into this effort:

1. **Cursor track starts ~473 ms late.** Recording 1's first cursor sample is at
   `timestampMicros: 473025`. `cursorTracker.startTracking()` runs *after*
   `await captureManager.startCapture()` + audio/system/camera init
   (`plugin:808 → ~895`), so the first video frame latches `firstVideoFrameAt`
   long before cursor sampling begins. Effect: the cursor is frozen at its first
   position for the first ~½ second of every recording.
2. **Stale `firstVideoFrameAt` leaks between recordings.** Recording 2's first
   cursor sample is `timestampMicros: 94599124` (≈ recording 1's 94.1 s duration)
   at off-screen coords. `resetFirstFrameTiming()` runs only on **stop**
   (`plugin:1001`), never on **start**, so a new session's first cursor sample
   can be stamped against the previous session's frame origin.

## Goal

Make the editor preview cursor sit on the actually-displayed video frame
(frame-exact), by measuring the true display latency natively and applying it as
a preview-only term. Fix the two capture-side cursor-track bugs in the same pass.
Leave the export path's cursor timing exactly as-is.

## Non-goals

- No change to the exported MP4's cursor timing (it is already correct).
- No change to the `cursorDelay` creative knob's semantics or default.
- No attempt to make the preview *pixel*-exact at very high playback speeds —
  only the cursor time-alignment is in scope.
- No change to the spatial cursor coordinate mapping (confirmed correct).

## Feasibility constraints (from investigation)

- `video_player: ^2.9.2` is a normal pub.dev dependency (resolves to 2.10.1;
  macOS impl `video_player_avfoundation` 2.9.3). It is **not** patchable in place.
- The macOS plugin already computes the presented-frame `CMTime` but discards it:
  `FVPTextureBasedVideoPlayer.m` calls
  `copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL`. The `NULL`
  is exactly the value we need.
- `VideoPlayerValue.position` is purely `AVPlayer.currentTime` (the clock), never
  the displayed frame.
- `screen_recorder_macos` has **no** seam to video_player's `AVPlayer` instance —
  so a separate video output tap is not viable; we must patch the plugin.

Therefore: vendor `video_player_avfoundation` behind a `dependency_overrides`
path and apply a small documented ObjC patch.

## Design

### Component A — Native: measure true display latency

Vendor the matching `video_player_avfoundation` (v2.9.3) into the repo under
`third_party/video_player_avfoundation/` and override it via
`dependency_overrides` (path) in `packages/screen_recorder/pubspec.yaml`. Apply a
small ObjC patch, shipped alongside as a `.patch` file + `README.md` so
re-applying after a `video_player` upgrade is mechanical:

- In `FVPTextureBasedVideoPlayer.m`'s frame-copy path, replace
  `itemTimeForDisplay:NULL` with a real `CMTime out` and store it as
  `_lastPresentedItemTime`. When `hasNewPixelBufferForItemTime:` is false (no new
  frame), `_lastPresentedItemTime` is left unchanged — so it reflects the frame
  actually on the texture, capturing decode lag.
- Compute the instantaneous lag `L = player.currentTime − _lastPresentedItemTime`
  and feed it through an **EMA smoother**. The smoothing math lives in a small
  pure helper (mirroring `FirstFrameTiming`) so it can be unit-tested with
  synthetic inputs. Clamp negatives to zero (clock can briefly read a presented
  time slightly ahead on rebase).
- Expose `getDisplayLatencyMicros(playerId)` on a dedicated side
  `FlutterMethodChannel` (e.g. `slipreel/video_sync`) registered by the patched
  plugin, keyed by the existing player/texture id. Returns the smoothed `L` in
  microseconds, or nil if not yet known.
- Polling is **low-frequency** (≈8 Hz from Dart), NOT per-vsync — `L` is
  slowly-varying, so this adds negligible message-pump load and no per-frame
  channel round-trips.

### Component B — Dart: apply it, preview-only

- `DisplayLatencyProbe` (new, `packages/screen_recorder/lib/state/`): given a
  player/texture id, polls `getDisplayLatencyMicros` on a ~125 ms timer, applies
  a light additional smoothing, and exposes the current display latency as a
  `Duration` (default `Duration.zero` until first reading; `Duration.zero` if the
  channel is unavailable). Disposable; owns its timer.
- **Important — avoid double-counting `cursorDelay`.** `cursorDelay` is already
  subtracted *inside* the scene-pass builder (`cursor_motion_controller.dart`
  queries `position − cursorDelay`). So the preview path subtracts **only**
  `displayLatency` from the playhead before the builder; `cursorDelay` keeps being
  applied downstream exactly as today. Net preview lookup is therefore
  `smoothPlayhead − displayLatency − cursorDelay`, but the two terms are applied
  in two different places (latency here, cursorDelay in the builder).
- The latency subtraction is expressed as a **pure helper** (e.g.
  `previewPlayheadWithLatency({required Duration playhead, required Duration
  displayLatency})` returning `playhead − displayLatency` clamped to `>= 0`) so
  the arithmetic is unit-tested in isolation. It does **not** touch `cursorDelay`.
- Wiring: `playback_screen.dart` owns a `DisplayLatencyProbe` for the main
  controller and threads its value into `PlaybackCanvas`. `PlaybackCanvas`
  applies the helper to the `pos` it currently derives from `smoothPlayhead`
  before passing `position:` into the scene-pass builder. `cursorDelay` continues
  to be applied inside the builder exactly as today.
- **Export untouched:** `FrameCompositor` / `export` keep feeding each frame's
  source timestamp and `cursorDelay`; they never see `displayLatency`. The new
  term is added only on the preview code path.
- Per-frame motion still comes from `smoothPlayhead`; `displayLatency` only
  shifts the *lookup time*, so the cursor stays smooth. Fallback: if the probe
  has no value, the term is `Duration.zero` and behaviour matches today.

### Component C — Two capture fixes (affect the exported MP4)

Both in `ScreenRecorderMacosPlugin.swift`:

1. **Late cursor start:** build the cursor transform and call
   `cursorTracker.startTracking()` **before** `await captureManager.startCapture(
   …)` rather than after. The cursor transform inputs (region, capture width /
   height) are all known before `startCapture`. The cursor callback already
   guards on `currentFirstVideoFrameAt()` (nil until the first frame), so samples
   captured during warmup are dropped and the first surviving sample lands at
   ~0 ms instead of ~473 ms.
2. **Stale `firstVideoFrameAt`:** call `resetFirstFrameTiming()` at the **start**
   of the recording (before cursor tracking begins), in addition to the existing
   stop-path reset. With (1), early warmup samples are dropped against a *nil*
   origin instead of a stale one, eliminating the off-screen garbage first
   sample.

These two are independent of A/B and can land first (smaller, lower risk).

## Data flow

```
AVPlayerItemVideoOutput presented CMTime  (native, per texture copy)
  → L = currentTime − presentedItemTime → EMA smooth   (native)
  → getDisplayLatencyMicros(playerId)   (8 Hz method channel)
  → DisplayLatencyProbe (Dart, smoothed Duration)
  → pos' = smoothPlayhead − L            (preview only, in PlaybackCanvas)
  → scene-pass builder applies − cursorDelay → cursor lookup  (as today)

Export: frameTime → scene-pass builder applies − cursorDelay  (unchanged)
```

## Error handling / edge cases

- Channel missing / older plugin / nil reading → `displayLatency = 0`; preview
  behaves exactly as today (no regression, just the pre-existing lead).
- Negative instantaneous lag (rebase/seek transient) → clamped to zero before
  smoothing.
- Seeks/pauses: `L` is computed continuously and smoothed; a transient spike
  decays. The cursor lookup clamps to `>= 0` and `<= duration` like today.
- Multiple players (main + camera sidecar): probe is keyed by player/texture id;
  only the main preview controller drives the cursor, so only it is probed.

## Testing

- **Native EMA/latency helper** (Swift unit, like `FirstFrameTimingTests`):
  monotonic smoothing, negative-clamp, nil-before-first-sample.
- **Native build**: compile-verify via
  `xcodebuild … -destination 'platform=macOS,arch=x86_64' build` (the
  `flutter build macos` arm64 path is broken in this env).
- **`previewPlayheadWithLatency`** (Dart unit): subtracts `displayLatency`;
  clamps at 0; does not touch `cursorDelay`; zero-latency reduces to today's
  behaviour.
- **`DisplayLatencyProbe`** (Dart unit): smoothing, default-zero, dispose stops
  the timer, nil channel → zero.
- **Preview widget test**: with a stubbed latency value, the cursor lookup time
  shifts by `L` (cursor renders an earlier sample than playhead).
- **Capture fixes**: assert (where the `FirstFrameTiming` seam allows) that a
  reset precedes cursor sampling; verify the reorder keeps the transform built
  before `startTracking`. Native ordering is also covered by compile + a manual
  re-record check (first cursor sample ≈ 0 ms; no off-screen first sample).

## Affected files (anticipated)

- `third_party/video_player_avfoundation/**` — vendored copy + `*.patch` +
  `README.md` (re-apply instructions).
- `packages/screen_recorder/pubspec.yaml` — `dependency_overrides` path.
- `packages/screen_recorder/lib/state/display_latency_probe.dart` — new probe.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — own the probe,
  thread the value down.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — subtract
  `displayLatency` from the preview `pos`.
- `packages/slipreel_engine/lib/rendering/...` — `previewCursorQueryTime` pure
  helper (or co-located in screen_recorder if it has no engine dependency).
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
  — reorder cursor-tracking start; reset first-frame timing on start.
- Tests alongside each.
