# Consistent (magnify-in-place) framing for manual zoom placements

## Problem

A manual zoom placed near an edge **re-frames by a large, zoom-dependent margin**
when its zoom level changes (the user's report: place a zoom at a portrait
phone's edge, set it to 5× — frames the edge; drag it back to 2× — the placement
"sits outside the edge by a big margin").

Root cause (confirmed by exercising the real engine code on the iphone-14
portrait layout): the focal is **clamped** so the zoomed viewport stays inside
the canvas — `ZoomFraming.centerOffset` clamps the canvas-space focal to a box
with half-extent `canvasSize/(2z)` from each edge. As `z` shrinks, that
half-extent **grows**, so a near-edge point that is reachable at 5× is pushed far
toward canvas center at 2×. Measured drift for an edge placement (point ~6% from
the top of a 2732px canvas):

| Zoom | drift @ pad 0 | drift @ pad 160 |
|------|--------------|-----------------|
| 5× | 107 px | 0 px |
| 3× | 290 px | 183 px |
| 2× | 517 px | 437 px |
| 1.5× | 745 px | 692 px |

So 5×→2× moves the placement inward by ~410 px (~16% of the phone's height). This
is **geometrically forced** by "keep the whole framed canvas in view": at 2× the
viewport is half the canvas tall, so its center physically cannot sit closer than
`canvasH/(2z)` to any edge without spilling past the canvas into empty space.
Nothing is miscomputed — the clamp boundary simply depends on `z`.

This is the follow-up flagged after PR #31 (which fixed device-frame padding +
focal/scale sync via canvas-space centering). PR #31 made the *clamp* correct;
this spec changes *the framing model itself* for manual placements.

## Decision

For **manual placements** (`ZoomRegion.followCursor == false`), replace
center-and-clamp with **magnify-in-place**: the camera offset is

```
centerOffset = (1 − 1/z) · (toCanvas(focal) − canvasCenter)
```

Properties (all proven, see Testing):
- **Placement is stable across zoom level.** The placed point sits at the exact
  same fraction of the frame at every `z` — changing 5×→2× only magnifies around
  the same framing, no lurch.
- **Never shows void.** Viewport top `= fp·canvasSize·(1 − 1/z) ≥ 0` and bottom
  `= fp·canvasSize + (1−fp)·canvasSize/z ≤ canvasSize` for all `z ≥ 1` (per
  axis, `fp = canvasFocal/canvasSize`). Padding/bezel always preserved.
- **Centered placements stay centered.** `fp = 0.5 ⇒ offset 0` at every `z`,
  identical to today.
- **Enter/exit pan is structurally synced and self-simplifying.** At `z = 1`,
  `offset = 0` (full canvas, centered); as the scale ramps `1 → zoomLevel`,
  `centerOffset` ramps `0 → full` *driven by the same `z`*. The pan therefore
  needs no separate ramp interpolation, no back-load curve, and no exit-recenter
  lerp on the manual path — it falls out of the zoom factor.

**Trade-off (accepted by the user):** an off-center *interior* placement is no
longer pulled to dead-center at high zoom — it stays at its frame position and
magnifies in place. This is the price of "never lurches" and was chosen
deliberately ("consistent framing", scope "all manual zooms").

**Scope:** all manual placements — device frames AND normal recordings. This
intentionally supersedes PR #31's byte-identical guarantee for normal-recording
*manual* zooms (the user chose app-wide consistency). Identity vs device framing
still differ only in the `toCanvas`/`canvasCenter` mapping — the magnify-in-place
formula is the same for both.

**Unchanged:** follow-cursor zooms keep center-and-clamp (they must bring the
moving cursor to center; magnify-in-place would pin the cursor wherever it sits).
All existing `clampFocal`/`clampFocalRadial`/`centerOffset` behavior is retained
for the follow-cursor path.

## Components

### `ZoomFraming` — add `centerOffsetInPlace`

`packages/slipreel_engine/lib/rendering/zoom_framing.dart`

```dart
/// Magnify-in-place camera translation (canvas px) for a MANUAL placement:
/// (1 − 1/z)·(toCanvas(focal) − canvasCenter). No clamp — void-free by
/// construction for z ≥ 1. Identity and device flavors differ only in the
/// toCanvas/canvasCenter mapping.
Offset centerOffsetInPlace(Offset focal, double z) {
  final canvasFocal = _toCanvas(focal);
  final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
  final k = 1.0 - 1.0 / z;
  return (canvasFocal - center) * k;
}
```

`centerOffset`, `clampFocal`, `clampFocalRadial` are **unchanged** (still used by
the follow-cursor path).

### `ZoomTransformer.getTransform` — branch manual vs follow

`packages/slipreel_engine/lib/effects/zoom_transformer.dart`

The method already has `zoomRegion`. Select the translation:

```dart
final pCenterRel = zoomRegion.followCursor
    ? f.centerOffset(focal, z)            // center-and-clamp (unchanged)
    : f.centerOffsetInPlace(focal, z);    // magnify-in-place (new)
```

Scale `z`, the `alignment: center` pivot, and `_calculateZoomFactor` are
untouched. For a manual placement the `focal` arriving here is the placement
center (see controller change), so this is a pure function of
`(rect.center, videoSize/framing, z)` → play == scrub == export byte-identical.

### `ZoomFocalController.update` — manual path returns the placement center

`packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`

Add an early manual branch (after the off-screen-cursor freeze and the
`_smoothedFocal == null` init, before the reverse-scrub / enter / exit / spring
logic):

```dart
if (!activeZoom.followCursor) {
  // Manual placement: magnify-in-place. The focal is the placement center for
  // the entire region; the zoom transform's (1 − 1/z) translation produces the
  // enter/exit pan from the scale ramp, so the pan is structurally synced and
  // the placement never lurches across zoom-level changes. No spring, no clamp,
  // no back-load. activeZoom is the override when one is supplied (placement
  // picker drag), so this also keeps the camera glued to the dragged rect while
  // paused — subsuming the old forceSnap+override manual case.
  final focal = _baseFocal(activeZoom, videoSize); // == rect.center
  _smoothedFocal = focal;
  _focalVx = 0;
  _focalVy = 0;
  _resetStrategies();
  _exitRampStartFocal = null;
  _exitRampStartReachable = null;
  _enterRampStartFocal = null;
  _enterRampTarget = null;
  _enterRampFocalTarget = null;
  _postEnterHoldTarget = null;
  _lastUpdatePosition = position;
  return ZoomFocalUpdate(zoom: activeZoom, focal: focal);
}
```

Consequences (the enter/exit/spring code below this branch is now
**follow-cursor-only**):
- The manual-specific arms of the enter ramp (`_manualStyleBackload`,
  `reachable`/`entryTarget` for non-follow), the exit-ramp manual recenter
  (`manualExitReachable`, manual `exitBackload`), and the manual placement-picker
  `forceSnap && activeRegionOverride != null` teleport become dead for manual.
  **Simplify:** drop the `!followCursor` arms from the enter/exit ramps (they are
  now unreachable), keeping the follow-cursor logic intact. The
  `forceSnap+override` teleport stays only if still reachable for follow; if it
  was manual-only, remove it.
- `_manualStyleBackload` / `manualBackloadForZoom` / `_manualBackloadPoints` are
  still referenced by the **follow-cursor** enter/exit ramps — keep them.
- `ZoomRegion.manualPanBackload` (per-region override) and its debug slider no
  longer affect manual placements (manual no longer ramps a back-load). Leave the
  model field for serialization compat; the UI slider becomes inert for manual.
  **Flag for review** — do not delete the model field in this change.

### Threading — no signature changes

`ScenePassBuilder.build`, `DeterministicFocalTrack.build`/`.matches`,
`FrameCompositor`, `PlaybackCanvas`, and `SceneBlurOverlay` already pass the
`ZoomFraming` and call `getTransform` with the `zoomRegion`. The manual-vs-follow
branch lives entirely inside `getTransform` and the controller, so no call site
signatures change. Verify each `getTransform` call site forwards the real
`zoomRegion` (so `followCursor` is correct) — they do today.

## Data flow

Manual placement, per frame: controller returns `rect.center` (constant for the
region) → `getTransform` sees `!followCursor` → `centerOffsetInPlace(rect.center,
z)` where `z` is the per-frame zoom factor (ramped on enter/exit, full on hold) →
`translate(−z·offset)·scale(z)` about canvas center. Enter pan, hold, and exit
all emerge from `z`. Follow-cursor: unchanged (spring → clamped focal →
`centerOffset`).

## Error handling / edge cases

- `z ≤ 1`: `centerOffsetInPlace` → `(1−1/z)·d`; at `z = 1`, `0` (identity frame).
  `getTransform` already short-circuits `z == 1.0 ⇒ Matrix4.identity()`, so the
  `z < 1` regime is never reached in practice.
- Degenerate framing (zero-area videoRect/canvas): `ZoomFraming.device` already
  falls back to identity; `_toCanvas` then identity, formula reduces to
  `(1−1/z)(focal − videoCenter)`.
- Off-screen cursor freeze: only the follow path uses cursor; manual ignores it.
- Placement-picker drag while paused: handled by the manual branch via
  `activeRegionOverride` (it becomes `activeZoom`).

## Testing

- `zoom_framing_test.dart`: `centerOffsetInPlace` — identity reduces to
  `(1−1/z)(focal − videoCenter)`; device maps through `toCanvas`; **void-free**
  property (computed viewport stays within `[0, canvasSize]` per axis for a set of
  edge focals and `z ∈ {1.5,2,3,5}`); centered focal ⇒ `Offset.zero` at all `z`.
- `zoom_transformer_test.dart`: for a manual region, the placed point lands at the
  **same frame fraction** at `z = 2` and `z = 5` (the core regression guard:
  apply the returned matrix to `toCanvas(rect.center)` and assert equal screen
  position across levels). Follow-cursor region: `getTransform` output unchanged
  (keep/adjust existing assertions).
- `zoom_focal_controller_test.dart`: a manual placement returns `rect.center` for
  enter, hold, AND exit frames (no ramp pan, no exit recenter). Follow-cursor
  tests unchanged. Existing manual back-load / edge-reachability assertions that
  encoded the old ramp are removed or converted to follow-cursor.
- New guard (controller or transformer level): "manual edge placement framing is
  identical across zoom-level change" — the on-screen position of `rect.center` at
  `z = 2` equals that at `z = 5` (would fail on `main`).
- Existing engine suite + `frame_compositor_device_parity_test` (preview ==
  export) stay green. **Goldens / parity fixtures** that captured the old
  normal-recording or device manual-zoom transform must be regenerated — list and
  review each changed golden (do not blanket-accept).

## Constraints

- Do NOT run `dart format` on existing files (pinned formatter reflows unrelated
  lines); match surrounding style by hand. Verify via analyze + test.
- Follow-cursor and z-identity (no zoom) behavior must not change.
- Preview and export must stay byte-identical to each other (same framing +
  branch fed to both).
- Do not delete `ZoomRegion.manualPanBackload` (serialization compat); only note
  it is inert for manual.
