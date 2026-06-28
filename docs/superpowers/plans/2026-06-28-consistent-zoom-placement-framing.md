# Plan: consistent (magnify-in-place) framing for manual zoom placements

Design: `docs/superpowers/specs/2026-06-28-consistent-zoom-placement-framing-design.md`

## Global constraints (bind every task)

- Manual placement framing becomes **magnify-in-place**:
  `centerOffset = (1 − 1/z)·(toCanvas(focal) − canvasCenter)`. No clamp.
- **Follow-cursor** (`ZoomRegion.followCursor == true`) keeps today's
  center-and-clamp behavior EXACTLY (`centerOffset`/`clampFocal`/
  `clampFocalRadial` unchanged for that path).
- **z-identity** (no active zoom / `z == 1.0`) behavior must not change —
  `getTransform` keeps its `z == 1.0 ⇒ Matrix4.identity()` short-circuit.
- Preview and export stay byte-identical to each other (same framing + same
  manual-vs-follow branch fed to both).
- Do NOT run `dart format` on existing files (pinned formatter reflows unrelated
  lines). Match surrounding style by hand; verify via `analyze` + `test`.
- Do NOT delete `ZoomRegion.manualPanBackload` (serialization compat). It becomes
  inert for manual placements — note only.
- Scope is **all manual zooms** (device + normal). This intentionally changes
  normal-recording manual-zoom output (PR #31's byte-identical guarantee applied
  to the follow/identity paths; manual is now magnify-in-place by user choice).

## Task 1 — `ZoomFraming.centerOffsetInPlace` (+ unit tests)

**Files:** `packages/slipreel_engine/lib/rendering/zoom_framing.dart`,
`packages/slipreel_engine/test/zoom_framing_test.dart`

Add the method (exact body in the spec, "Components → ZoomFraming"):

```dart
Offset centerOffsetInPlace(Offset focal, double z) {
  final canvasFocal = _toCanvas(focal);
  final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
  final k = 1.0 - 1.0 / z;
  return (canvasFocal - center) * k;
}
```

Leave `centerOffset`, `clampFocal`, `clampFocalRadial` untouched.

Tests:
- Identity flavor: `centerOffsetInPlace(f, z)` equals `(f − videoCenter)·(1−1/z)`
  for a few `(f, z)`.
- Device flavor (use a real-ish `videoRect`/`canvasSize`): equals
  `(toCanvas(f) − canvasCenter)·(1−1/z)` via `debugToCanvas`.
- Centered focal ⇒ `Offset.zero` for `z ∈ {1.5, 2, 3, 5}`.
- **Void-free property:** for several near-edge focals and `z ∈ {1.5,2,3,5}`,
  reconstruct the viewport `[c − canvasSize/(2z), c + canvasSize/(2z)]` where
  `c = canvasCenter + centerOffsetInPlace(...)` and assert it lies within
  `[0, canvasSize]` per axis (small epsilon).

Model: cheapest (isolated pure function, complete spec).

## Task 2 — Manual magnify-in-place behavior (transform + controller)

**This is one coherent behavioral change — transform branch and controller manual
path must land together (either alone leaves a broken intermediate: double-pan or
a snap with no enter ramp).**

**Files:**
- `packages/slipreel_engine/lib/effects/zoom_transformer.dart`
- `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`
- `packages/slipreel_engine/test/zoom_transformer_test.dart`
- `packages/slipreel_engine/test/zoom_focal_controller_test.dart`

### 2a. `getTransform` branch

Replace `final pCenterRel = f.centerOffset(focal, z);` with:

```dart
final pCenterRel = zoomRegion.followCursor
    ? f.centerOffset(focal, z)
    : f.centerOffsetInPlace(focal, z);
```

Nothing else in `getTransform` changes (scale, center pivot, ramp factor).

### 2b. Controller manual path

Add the early manual branch from the spec ("Components → ZoomFocalController")
**after** the off-screen-cursor freeze and the `_smoothedFocal == null` init,
**before** the reverse-scrub / forceSnap / exit / enter / spring logic. It
returns `_baseFocal(activeZoom, videoSize)` (== `rect.center`) and resets the
ramp/spring anchors.

Then make the remaining enter/exit/spring logic follow-cursor-only:
- Remove the `!activeZoom.followCursor` arms of the **exit** ramp
  (`manualExitReachable`, the manual `exitBackload` selection) — that block now
  only runs for follow, so `exitReachable` reduces to the follow branch.
- Remove the `!activeZoom.followCursor` arms of the **enter** ramp (the manual
  `entryTarget`/`reachable`/`_manualStyleBackload` selection collapses to the
  follow-cursor target).
- Remove the manual-only `forceSnap && activeRegionOverride != null` teleport IF
  it is unreachable for follow (the manual branch above now handles paused
  placement-picker drags). If follow can still reach it, keep it.
- Keep `_manualStyleBackload` / `manualBackloadForZoom` / `_manualBackloadPoints`
  (still used by the follow-cursor ramps).
- Do not touch `ZoomRegion.manualPanBackload`.

Keep diffs minimal and matched to surrounding style. If collapsing a branch would
balloon the diff, leaving a now-constant condition is acceptable as long as it is
provably follow-only and commented — prefer clarity over churn, but do not leave
genuinely dead `!followCursor` arms that a reviewer would flag.

### Tests

`zoom_transformer_test.dart`:
- **Core regression guard:** for a manual region with an edge `rect.center`,
  apply `getTransform` at `z`-factor for `zoomLevel = 5` and again for
  `zoomLevel = 2` (hold phase), map `toCanvas(rect.center)` through each matrix,
  and assert the resulting screen position is **identical** (same frame fraction)
  — this fails on `main`.
- Manual centered placement: matrix centers it at all levels (unchanged).
- Follow-cursor region: `getTransform` output unchanged (retain existing
  assertions; adjust only if they assumed manual).

`zoom_focal_controller_test.dart`:
- Manual placement returns `rect.center` for **enter, hold, and exit** frames
  (no ramp pan, no exit recenter, constant focal).
- Manual placement-picker (`activeRegionOverride` + paused) returns the
  override's `rect.center`.
- Follow-cursor tests unchanged.
- Remove/convert existing manual back-load / edge-reachability tests that encoded
  the old manual ramp (they assert behavior this task deletes). Converting to
  follow-cursor coverage is preferred over deletion where the scenario still
  applies to follow.

Model: most capable (touches the shared transform + the controller's core
state machine; judgment needed to collapse the ramps safely).

## Task 3 — Integration, goldens, full-suite verification

**Files (verify / regenerate, not necessarily edit):**
- `packages/slipreel_engine/test/...` (full engine suite incl.
  `frame_compositor_device_parity_test`)
- `packages/screen_recorder/...` (playback_canvas, scene_blur_overlay,
  motion_blur_playground_screen consume `getTransform`)
- any golden fixtures capturing manual-zoom transforms

Steps:
1. Run the full `slipreel_engine` test suite; fix any non-golden fallout.
2. Identify goldens that changed because of the new manual framing. Regenerate
   them, then **review each changed golden image** (open/diff) to confirm the new
   framing is the intended magnify-in-place result — do NOT blanket-accept. List
   every regenerated golden in the task report.
3. Confirm `frame_compositor_device_parity_test` (preview == export) stays green —
   it proves the manual branch is fed identically to both.
4. Confirm `scene_blur_overlay` and `playback_canvas` still compile and their
   tests pass (they call `getTransform` with the real region; the badge-tween
   `tweenedRegion` preserves `followCursor` via `copyWith` — verify).
5. `motion_blur_playground_screen.dart` calls `getTransform` (debug playground).
   Verify it passes a real region; if it synthesizes one, ensure `followCursor`
   is set sensibly. Playground-only — minimal effort.
6. Run `screen_recorder` tests + `flutter analyze` across both packages.

Model: standard (verification + golden review, broad but mechanical).

## After all tasks

- Whole-branch review on the most capable model (review-package over
  `merge-base main HEAD`).
- Runtime verify on a dev-signed Release build: open the 1170×2532 device
  recording, place a manual zoom at the portrait edge, drag the level 5×→2× →
  placement stays put (no inward lurch), padding preserved, no void; play through
  the region (enter/exit pan synced). Also spot-check a normal recording's manual
  zoom (off-center placement now magnifies in place).
- `superpowers:finishing-a-development-branch` → PR → merge on green CI.
- Update memory: `device_frame_zoom_geometry.md` (retire the pending follow-up,
  record magnify-in-place decision + scope) and the MEMORY.md line.
