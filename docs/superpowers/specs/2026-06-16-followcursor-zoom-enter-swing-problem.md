# Problem: cursor-following zoom "swings to the wrong spot then to the cursor" on zoom-in

## One-line
On a **cursor-following** zoom (`ZoomRegion.followCursor == true`), the zoom-IN (enter ramp)
moves the camera to a WRONG intermediate spot first (e.g. "left, below center") and only then
slides to where the cursor actually is (e.g. top-left) — all while the zoom is still ramping in.
It reads as a swing/detour. **Manual placements (`followCursor: false`) were fixed and feel correct;
this bug is specific to `followCursor: true`** (the "Auto-zoom on cursor" toggle, which is the
default for UI-added zooms).

## Repro (runtime, in-app)
1. Open a recording in the editor.
2. Add a zoom region (default is `followCursor: true`, full-frame rect → `rect.center == videoCenter`).
3. Park the real cursor near a corner/edge of the content (user used **top-left**) before/at the zoom start.
4. Play across the zoom-in. Observed: the camera first frames a different area (down/left of center),
   then transitions to the cursor's spot during the ~`enterDuration` (~500 ms) zoom-in.

Expected: the camera pans smoothly and directly toward where the cursor is, with no detour to an
unrelated spot, matching the now-correct manual-placement zooms.

## Architecture / key files (engine is pure Dart in `packages/slipreel_engine`)
The camera focal for both PREVIEW and EXPORT (and scrub/paused via `DeterministicFocalTrack`) is
produced by ONE shared path so they can't diverge:

- `lib/rendering/scene_pass_builder.dart` — `ScenePassBuilder.build()`. Computes the cursor and calls
  the focal controller. **The camera follows the SMOOTHED cursor**: `cursorForFocal = motionSample.screenPos`
  (the spring-smoothed sprite position from `CursorMotionController`), NOT the raw recorded cursor.
  Predictive mode instead uses a rolling median.
- `lib/rendering/cursor_motion_controller.dart` — `CursorMotionController`: the per-axis spring that
  smooths the cursor sprite. Settle time τ ≈ 75–149 ms, plus velocity feedforward. **This is why the
  smoothed cursor LAGS the raw cursor right after a move.**
- `lib/rendering/zoom_focal_controller.dart` — `ZoomFocalController.update()`: the camera focal.
  Three phases: ENTER ramp (deterministic eased pan center→target), HOLD (per-`FollowMode` strategy
  target + critically-damped spring), EXIT ramp (eased pan back to center).
- `lib/rendering/follow_strategy.dart` — `FollowStrategy` (bounded / centered / predictive). `resolve()`
  returns the HOLD target each frame (for followCursor the live cursor, gated by a deadzone in bounded).
- `lib/effects/zoom_transformer.dart` — `getTransform()` applies the zoom matrix and, at paint, a
  PER-AXIS rectangular clamp `clampFocalToBounds` (keeps the viewport inside the video). Also a
  `clampFocalToBoundsRadial` (added for the manual fix; scales the offset from videoCenter so the
  focal stays collinear + in-box). **The radial clamp is gated to manual placements only.**
- Preview render: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` (~line 1040)
  feeds `focalUpdate.focal` into `getTransform`, but with a `TweenAnimationBuilder`-interpolated
  `animatedZoom` zoom factor (badge tween) that can transiently differ from `activeZoom.zoomLevel`.
  There are also `_approxSceneSampleAt` / `_subFrameTransformAt` paths used for scene-blur sampling
  that use `rect.center` / raw cursor directly (NOT the controller) — secondary, but they bypass the
  fixes.

## Hard constraints
- Preview == export == scrub focal (the single `ScenePassBuilder` enforces this; any fix must keep it).
- Determinism: anything sampled must be a pure function of (recording, region, videoSize, source time).
- The camera and the drawn cursor sprite should track the SAME cursor during the HOLD (else the sprite
  visibly drifts off the camera center). This is why the camera uses the smoothed cursor.

## What has already been tried (commits on branch `fix/manual-zoom-pan-sync`)
The manual-placement geometry bugs were fully fixed (radial clamp + reachable→lock-step). For
**followCursor specifically**, two attempts that did NOT fully resolve it:

1. `87786241` — capture the enter pan target ONCE on the first enter frame (`_enterRampTarget`) instead
   of aiming at the live cursor every frame. Goal: stop the camera chasing a cursor that moves DURING
   the enter. (Unit trace with a darting cursor confirmed the swing went away in that synthetic case.)
2. `5455b88a` — "look-ahead settle target": `ScenePassBuilder` samples the **raw** cursor at
   `activeZoom.startTime + activeZoom.enterDuration` (where the cursor will be when the zoom-in
   completes) and passes it as `ZoomFocalController.update(enterCursorTarget:)`. The enter pans
   straight to that settle point instead of the lagging smoothed cursor. (NOTE: "look-ahead" here is
   just reading the recording forward by `enterDuration`; it is NOT the predictive FollowMode.)

**The user reports the swing STILL persists after both.**

## The crux / leading hypothesis (UNVERIFIED at runtime)
Every UNIT trace I write (synthetic cursor inputs, stepping the controller) comes out clean — the
focal pans monotonically to the target with no swing. Yet the runtime still shows the swing. So the
bug is in a gap my synthetic traces don't reproduce. Strongest hypotheses, roughly in order:

1. **Enter→hold handoff mismatch (most likely).** The ENTER now targets the RAW settle cursor
   (`enterCursorTarget`), but the HOLD immediately tracks the SMOOTHED cursor. If the smoothed cursor
   has NOT caught up by the end of the enter ramp (it lags τ≈75–149 ms; if the cursor moved right at
   the zoom start, 3τ can approach the ~500 ms enter), then at the handoff the hold target is still the
   lagging spot → the spring pulls the camera BACK toward it, then forward as it catches up. Net: enter
   to (correct-ish) → yank toward lagging spot → settle. A real swing the unit traces miss because they
   feed a clean/instant cursor.
2. **Preview `animatedZoom` divergence.** Preview `getTransform` uses the badge-tweened `animatedZoom`,
   not `activeZoom.zoomLevel`. If that differs during the enter, the per-axis `clampFocalToBounds` at
   paint can re-bend the (otherwise-clean) controller focal — and the radial clamp is gated OFF for
   followCursor. Export/scrub (which use `zoomLevel`) might be clean while PREVIEW bends.
3. **Fix not actually active on the path the user sees.** Confirm the preview main render truly consumes
   `ScenePassBuilder`'s `focalUpdate.focal` with the new `enterCursorTarget`, and that `hasCursorData`
   is true and the `enterEnd` sample is correct (source-time, not edited-time; squeeze of enter+exit
   not handled).
4. **Cursor-smoothing lag itself.** If the smoothed cursor's lag at zoom start is the root, the camera
   following it will always start at the lagging spot regardless of enter-target tricks.

## FIRST STEP: get the runtime focal trace (close the unit-vs-runtime gap)
There is a per-frame focal trace hook: `ext.slipreel.setCameraFocalTrace` (registered in
`packages/screen_recorder/lib/main.dart`; logs the painted focal each frame). Enable it, reproduce the
exact case, and capture the actual focal (x,y) + zoom factor per frame across the enter ramp. Compare
the controller `focalUpdate.focal`, the `enterCursorTarget` value, the smoothed `cursorForFocal`, and
the painted (post-`getTransform`) focal. This will show definitively WHERE the detour enters (enter
ramp vs hold handoff vs preview clamp) — do not trust synthetic traces alone, they have been clean
throughout while the runtime is not.

## Acceptance criteria
- A `followCursor` zoom-in with the cursor parked off-center (incl. corners/edges) pans the camera
  directly toward the cursor's settled spot — no detour to an unrelated area, no yank-back at the
  enter→hold handoff.
- Manual placements unchanged (still correct). Preview == export == scrub. Cursor sprite stays on the
  camera center during the hold.
- Add a regression test that reproduces the RUNTIME condition (lagging smoothed cursor at zoom start),
  not just an instant/clean cursor.

## Useful context
- Branch: `fix/manual-zoom-pan-sync`. Engine tests: `cd packages/slipreel_engine && flutter test`.
- Manual-placement fix history + rationale: memory `manual_zoom_pan_sync.md`.
- The app can be driven via the flutter-qa MCP (`boot_app device=macos`) and `ext.slipreel.*` hooks.
- Lesson learned here repeatedly: for these perceptual/geometric zoom bugs, a clean unit trace does
  NOT mean the bug is gone — verify against the actual rendered frames / runtime focal trace.
