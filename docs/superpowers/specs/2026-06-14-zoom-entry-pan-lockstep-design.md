# Zoom Entry Pan Lock-Step — Design

**Date:** 2026-06-14
**Status:** Approved (design), pending implementation
**Area:** `slipreel_engine` focal pipeline + preview/export call sites

## Problem

When a cursor-follow zoom region activates, two independent animations run on
two separate clocks:

| Motion | Driver | Default timing | Curve |
|---|---|---|---|
| Scale ("make it bigger") | `ZoomTransformer._calculateZoomFactor` | `enterDuration` = 500 ms, fixed-duration tween | resolved `rampCurve` (per-region override, else `screenAnimationConfig.rampCurve`) |
| Focal pan ("move to the cursor") | `ZoomFocalController` critically-damped spring | `followDuration` = 700 ms settle (~95% @ 700 ms, fully ≈2100 ms) | n/a (spring) |

The scale reaches full magnification at 500 ms, but on entry the focal is merely
*parked at `rect.center`* and the spring chases the cursor on its own ~700 ms+
clock. So when the cursor is far from `rect.center` (e.g. cursor near a screen
edge, or a large rect), the camera keeps drifting toward the cursor for ~1.5 s
*after* the zoom has visibly finished. The user reads this as "the move to the
cursor isn't synced with the zoom."

The **exit** ramp already solves the mirror-image problem: it lerps the focal to
video-center in lock-step with the zoom-out curve/duration
(`ZoomFocalController.update`, exit-ramp branch) precisely so the recenter "feels
like part of the zoom-out instead of a separate motion." The **entry** has no
such lock-step. That asymmetry is the root cause.

## Decision

Give the **entry** the same lock-step treatment the exit already has: during the
enter ramp, pan the focal `rect.center → cursor` over the (squeezed) `enterUs`
window using the **same resolved ramp curve as the scale**, so framing arrives at
the cursor exactly when magnification hits full. Then hand off to the existing
spring for steady-state follow. `followDuration` is **not** changed, so
mid-hold cursor-follow feel (and the historic 400→700 ms anti-jolt tuning) is
preserved.

User-selected entry feel (confirmed): **"Arrive at cursor on zoom-complete."**

## Mechanism

In `ZoomFocalController.update`, after the strategy resolves the frame's `target`
and before the spring step, insert an enter-ramp branch symmetric to the exit
branch:

1. Compute the squeezed enter window via a new `_enterRampWindow(zoom)` that
   reuses the same proportional-squeeze logic as `_exitRampWindow` /
   `_calculateZoomFactor` (so overflowing `enter+exit` stays consistent with the
   scale). Returns `null` when `enterUs <= 0`.
2. While `tIntoRegionUs < enterUs`:
   - Capture `_enterRampStartFocal ??= _smoothedFocal` (this is `rect.center`,
     set by the init branch on the region's first frame), cleared whenever the
     controller leaves the enter window (mirrors `_exitRampStartFocal`).
   - `eased = curve.transform(tIntoEnter / enterUs)` where `curve` is the
     resolved ramp curve (see Curve threading).
   - `newFocal = Offset.lerp(_enterRampStartFocal, target, eased)`, where `target`
     is the **strategy-resolved** target. This makes `followCursor:false`
     (target = `rect.center`) a clean no-op, and respects bounded/centered/
     predictive modes. As `eased → 1`, focal → live cursor.
   - Hand off velocity to the spring as a finite difference
     `(_focalVx, _focalVy) = (newFocal - _smoothedFocal) / dtSeconds`, so a cursor
     still in motion at handoff doesn't stall. (easeInOutQuad has ~zero slope at
     `t=1`, so the eased component contributes ~zero; the finite diff captures any
     residual target motion.)
   - `_smoothedFocal = newFocal`; return `ZoomFocalUpdate(zoom, newFocal)`.
3. Outside the enter window, clear `_enterRampStartFocal` and fall through to the
   existing spring step unchanged.

The frame-render `_clampFocal` (in `ZoomTransformer`) is unchanged: at low zoom
early in the ramp it still keeps the focal framed; as zoom rises it admits the
focal further out, arriving at the cursor as zoom completes. Lerping toward the
unclamped `target` is consistent with how the spring already targets the
unclamped cursor (clamping is a render-time concern).

### Strategy interaction

`strategy.resolve(...)` is still called every enter-ramp frame (the existing call
already sits before the spring step), so the bounded gate's `_inFlight` stays
live and is in the correct state at handoff. No gate reset is introduced.

### First-frame / seek interaction

On the region's first frame `_smoothedFocal == null` → the init branch parks at
`rect.center` and returns (unchanged). The enter-ramp lerp begins on the next
frame with `_enterRampStartFocal = rect.center`. A seek *into* the middle of an
enter ramp lands via the existing forceSnap/reverseScrub paths during scrub;
continuous playback enters at `t ≈ 0`.

## Curve threading

The scale's resolved curve is `region.rampCurveOverride?.toFlutterCurve() ??
screenAnimationConfig.rampCurve`. `screenAnimationConfig` is a **different** config
than the `cursorAnimationConfig` already flowing into `ScenePassBuilder.build`, and
the focal controller currently receives neither curve. So we thread the **fallback
screen ramp curve** into the focal pipeline; the controller combines it with the
active region's `rampCurveOverride` (which it already holds), exactly as the
transform does.

Add a `Curve screenRampCurve` parameter (default `Curves.easeInOutQuad`, matching
the historic hardcode) to:

- `ZoomFocalController.update(...)` — resolves
  `activeZoom.rampCurveOverride?.toFlutterCurve() ?? screenRampCurve` for the
  enter ramp **and** the exit ramp (see Bonus).
- `ScenePassBuilder.build(...)` — passes through to `focal.update`.
- `DeterministicFocalTrack.build(...)` and `matches(...)` — passes through to the
  internal builder, stored, and cache-keyed (so scrub/paused preview replays the
  same entry).

Callers pass `screenAnimationConfig.rampCurve`:

- `playback_canvas.dart`: `_scenePassBuilder.build(...)` and `_focalTrackFor(...)`
  / its `DeterministicFocalTrack.build` + `matches`.
- `frame_compositor.dart`: `_scenePassBuilder.build(...)` and the blur-sampling
  `_focalTrack` build + `matches`.

Export's real focal comes from the live controller via `scenePass.build`, so
threading the curve there makes export's entry identical to preview's.

## Bonus consistency fix

The exit ramp currently hardcodes `Curves.easeInOutQuad` instead of the resolved
curve — a latent mismatch for any region with a custom `rampCurveOverride` or a
non-default `screenAnimationConfig.rampCurve`. With the resolved curve now in
hand, switch the exit ramp to use it too, making enter/exit symmetric.

## Scope

**Engine:** `zoom_focal_controller.dart`, `scene_pass_builder.dart`,
`deterministic_focal_track.dart`.
**Call sites:** `playback_canvas.dart`, `frame_compositor.dart`.
**Tests:** `zoom_focal_controller_test.dart`, `deterministic_focal_track_test.dart`.

No new `ZoomRegion` fields; JSON untouched. `followDuration` semantics unchanged.

## Risks

- **Default behavior changes for every region.** The default `easeInOutQuad`
  keeps existing tests *compiling*, but the entry trajectory now differs (arrives
  faster, in lock-step). Some `DeterministicFocalTrack` trajectory assertions that
  encode the old slow-spring entry may shift — reconcile by running the full
  `slipreel_engine` and `screen_recorder` suites and updating intent-preserving
  assertions (e.g. the "<40px in first 16 ms, no snap" test must still hold; it
  does, because the lerp also starts at `rect.center` with ~zero initial slope).
- **Velocity handoff spike** if the cursor flicks exactly at handoff. Bounded by
  the same clamps the spring already tolerates; at low-zoom entry the render
  clamp dominates anyway.
- **Curve param fan-out** touches two render call sites + the deterministic track
  cache key; a missed site would desync entry between preview and export. Mitigated
  by threading a single `screenRampCurve` and resolving identically everywhere.

## Verification

- Unit: enter ramp arrives at cursor by `enterDuration` end; non-follow region is
  a no-op; custom curve is honored; exit ramp honors the resolved curve;
  `DeterministicFocalTrack.matches` is curve-sensitive.
- Full `slipreel_engine` + `screen_recorder` suites green.
- Runtime probe (`flutter run -d macos -t lib/main_dev.dart`): record/select a clip
  with the cursor near a screen edge, confirm the pan and the zoom finish together
  in preview, and that play/scrub/paused all agree.
