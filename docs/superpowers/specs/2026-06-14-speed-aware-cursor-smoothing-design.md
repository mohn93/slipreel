# Speed-aware cursor smoothing

GitHub issue #6 — "Cursor should retain smoothness when slice playback speed is increased."

## Problem (precise restatement)

The rendered cursor follows a spring chase over the recorded cursor path
(`packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart`). The
spring chases the recorded path **parametrized by source time**, so its
analytical settle-time `τ = 2ζ/ωₙ` (≈75–149 ms at the Smooth defaults) is fixed
*in source time*.

Playback speed does not change that source-time trajectory — it only changes how
fast we traverse it in **wall time**. At 2×, the same spatial easing plays in
half the wall time, so the cursor reaches its targets twice as fast and reads as
a tight snap. The lag is not growing; the **wall-time (perceived) softness is
shrinking by the speed factor**.

This affects both preview and export equally, because both consume the same
single `CursorMotionController.update()` call site
(`scene_pass_builder.dart:139`, shared by `PlaybackCanvas` preview and
`FrameCompositor` export), and both pass **source time** as `position`.

### Note on the issue's point #2 (feedforward "fades to full")

The velocity feedforward fades based on `_computeSceneVelocity`, which measures
px per **source** second — *not* inflated by playback speed in the current code.
So the fade band does not auto-snap the way the issue's point #2 describes. The
real lever there is to make the fade key off **perceived (wall) speed**, which
this design does.

## Goal

- Sped-up slices keep cursor smoothness/softness **comparable to 1×** in wall
  (perceived) time — **full linear** compensation (chosen).
- 1× playback bit-identical to today.
- Preview (play / scrub / paused) and export agree on the rendered cursor path.

## Core mechanism

Integrate the spring in **speed-normalized time**:

```
dtEffective = dt_source / playbackSpeed
```

At 2×, source advances 2× faster per wall frame, but the spring is integrated
half as far → it lags ~2× further in source space → played back at 2×, the
wall-time lag matches 1×. Generalizes to slow-mo (`speed < 1` tightens the
source trajectory, compensating the slower playback).

`playbackSpeed == 1.0` ⇒ `dtEffective == dt_source` ⇒ unchanged.

`playbackSpeed` is the speed of the slice covering the current **source**
position: `clipSliceAt(clips, position).playbackSpeed`. Clamp to a small floor
(e.g. ≥ 0.05) to avoid divide-by-zero / runaway on degenerate slices.

## Feedforward (both confirmed in brainstorming)

The velocity feedforward compensates the spring's lag, which under dt-scaling is
now `τ × playbackSpeed` in source time. To stay coherent:

- `leadSec = tauSec * playbackSpeed * strength * fadeScale`
- Fade band keys off **perceived (wall) speed**:
  `perceivedSpeed = sourceSpeed * playbackSpeed`, compared against the existing
  `cursorFeedforwardFadeStartPxPerSec` / `cursorFeedforwardFullSpeedPxPerSec`
  thresholds (smoothstep between them, as today).

Both expressions reduce to today's formula at `playbackSpeed == 1.0`.

## Plumbing (Approach A — chosen)

Thread the clip list into the **shared** `ScenePassBuilder.build()`; the builder
performs the single `clipSliceAt(clips, position).playbackSpeed` lookup and
passes one resolved `playbackSpeed` double into
`CursorMotionController.update()`.

- **Why the shared builder:** one lookup site, evaluated at the same source
  `position` both paths already pass → preview and export cannot resolve speed
  differently. This is the "single source of truth" the builder already exists
  to enforce.
- **Export caller** (`frame_compositor.dart:169`): `clips:
  projectState.timeline.clips`.
- **Preview caller** (`playback_canvas.dart:587`): a new `clips` widget param
  threaded from `playback_screen` (which owns `List<ClipSlice> clips`), mirroring
  how `sliceDisableSmoothMouse` is already threaded.
- **Defaults:** `clips` defaults to `const <ClipSlice>[]` in `build()`;
  `playbackSpeed` defaults to `1.0` in `update()`. With no clips / empty list,
  speed resolves to 1.0 ⇒ behavior unchanged. Keeps existing callers and tests
  compiling and behaviorally identical.

### Rejected alternatives

- **B — resolve `playbackSpeed` separately in each caller** and pass the double
  to `build()`. Two resolution sites ⇒ divergence risk against the "must agree"
  criterion. Rejected.
- **C — give `CursorMotionController` the clip list and let it look up speed.**
  Puts timeline data inside the controller, breaking its narrow per-axis-spring
  contract. Rejected.

## Untouched

- **Snap mode** (`disableSmoothMouse` / None preset): spring is bypassed, no
  speed-awareness needed.
- **Scrub reset** (`dtMicros < 0` sign test), **velocity lookback**, and
  **click-state lookup**: stay in source time, unaffected.
- The existing accepted "per-frame dt vs fixed-fps integration" discretization
  is unchanged in class. Between two source positions, the closed-form
  `SpringSimulation` integrates the same *total* scaled-time
  (`Δsource / playbackSpeed`) in both paths regardless of step granularity; the
  only difference remains the piecewise-constant-target hold, already bounded by
  the preview's sub-stepping.

## Testing

`CursorMotionController` unit tests:

1. **1× unchanged.** With `playbackSpeed = 1.0`, outputs are identical (within
   float tolerance) to the current implementation for a representative path.
2. **Wall-time softness preserved.** A 2× run stepping source-dt 2× larger lands
   the spring at the same *relative* lag that a 1× run reaches at half the
   source-dt.
3. **Feedforward fade keys off wall speed.** At `playbackSpeed = 2.0`, the fade
   reaches full at half the source-speed it would at 1×.

Builder / integration test:

4. **Preview vs export converge.** Export-style uniform source stepping and
   preview-style 2× source stepping reach the same spring state at matching
   source positions (modulo the documented discretization tolerance).

## Acceptance criteria (from the issue)

- A slice at increased speed shows visibly softer cursor motion than today,
  closer to the 1× feel, not a tight snap to the raw path.
- 1× playback is unchanged.
- Preview (play / scrub / paused) and export agree on the rendered cursor path.
