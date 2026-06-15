# Padding-preserving zoom (hybrid: clamped card push-in + content magnification)

GitHub follow-up to the zoom/composition behavior noticed after #6.

> **Supersedes an earlier draft of this spec** that proposed a *fixed-frame*
> model (card frozen, content zooms inside). That was built and rejected on
> runtime review — the user wants the card to visibly push in, just without the
> padding vanishing. This spec is the corrected design.

## Problem

When a zoom is active, the framed window (recording + rounded border + shadow)
scales as a whole against the sticky wallpaper and runs off the canvas edges, so
the wallpaper padding band shrinks — at high zoom it disappears entirely.

## Desired behavior

Keep the **push-in feel** (the card visibly scales up during a zoom) **but never
let the padding drop to zero** — the padding shrinks only down to a floor and
then holds. Because the output frame is a fixed size, the card can only grow by
~the padding's worth before its edges reach that floor (growth headroom ≈
`2·padding / card_size`, typically ~10–20%). So a meaningful 2×/4× zoom cannot
come from the card growing alone; the card growth supplies a push-in *nudge* and
a **content magnification inside the card** supplies the rest. This is a
**hybrid**.

## The model

Driven by the same zoom factor `z` (the ramped zoom level at this frame) and
focal `f` (video coords). Let:

- `R0` = the fixed 1× card rect (`OutputCanvasResolver` videoRect — the video,
  centered in the canvas, inset by the configured padding `P`). `R0.size ==
  videoSize`.
- `F` = padding floor = `paddingFloorFraction · P` (default
  `paddingFloorFraction = 0.4`, tunable). `F ≤ P`.
- `Rmax` = canvas inset by `F`, centered (the largest the card may grow to).
- `zCardMax` = `min` over axes of `(C_axis − 2F) / (C_axis − 2P)` (= `Rmax.size /
  R0.size`). `≥ 1` since `F ≤ P`.
- `zCard` = `clamp(z, 1, zCardMax)`.

**Stage 1 — card push-in (chrome):** the card frame (shadow/ring/border, and
the rounded window outline) scales by `zCard`, **centered** on the canvas. Its
rect is `cardRect = Rect.fromCenter(canvasCenter, R0.size · zCard)` (≤ `Rmax`).
Padding each side = `(C − cardRect.size)/2 ≥ F` by construction. The rounded
corner radius scales by `zCard` too (the frame grows as a unit).

**Stage 2 — content magnification (video + cursor):** the content gets the
**full** zoom transform (the existing `ZoomTransformer.getTransform(z, f)`,
unchanged — scale `z` about the video center, pan focal→center, `clampFocalToBounds`
unchanged) and is **clipped to the centered `cardRect`** (rounded, radius
`cornerRadius · zCard`). Because both the card and the content transform are
centered on the canvas, the focal (which the content transform places at the
canvas center) sits at the card's center — they stay aligned, no coupling.

Net effect: the card pushes in by up to ~`zCardMax` (a nudge), the padding
shrinks to the floor and holds, and the focal region is magnified by the full
`z` inside the (slightly larger) rounded window.

### Why centered card growth (not focal-leaning)

The card frame scales **centered**; the directional "toward the focal" sense
comes from the *content* panning to the focal inside it. A focal-leaning card
(translating the frame toward the focal) was considered and rejected: with the
clamp, the lean would have to unwind as the card grows (less pan room at larger
sizes), producing a visible drift/wobble. Centered growth is artifact-free and
simpler. (If a leaning frame is wanted later, it's an additive enhancement, not
part of this change.)

### Reduces cleanly to the bookend behaviors

- `paddingFloorFraction = 1.0` (floor = full padding) ⇒ `zCardMax = 1` ⇒ card
  never grows ⇒ the fixed-frame model (content zooms inside a frozen window).
- `paddingFloorFraction → 0` ⇒ card may grow until padding ≈ 0 ⇒ approaches the
  original whole-window scaling.

## Edit sites (extends the current branch, which already does the fixed-frame clip)

The current branch already (a) clips the content to a rounded rect and (b)
applies the full zoom to the content. The hybrid adds the **clamped centered
card scale** and makes the **clip rect follow the grown card**.

### Shared geometry — `ZoomTransformer` (`effects/zoom_transformer.dart`)
Add a small pure helper that, given `videoSize`, `canvasSize`, `padding`,
`cornerRadius`, `z`, and `paddingFloorFraction`, returns the **card scale**
`zCard` and the **centered `cardRect`** (+ effective corner radius `cornerRadius
· zCard`). This is the single source of truth both paths use, mirroring how
`getTransform`/`clampFocalToBounds` are already shared. The content transform
stays `getTransform(z, f)` unchanged.

### Export — `frame_compositor.dart`
- **Chrome:** instead of leaving the chrome un-zoomed (current branch) or
  zooming it by the full `z` (original), apply a **centered scale by `zCard`**
  to the chrome canvas (scale about `totalSize/2`). The frame/shadow grow by the
  push-in amount and no more.
- **Content clip:** clip the (full-zoom) video+cursor to the centered
  **`cardRect`** rounded by `cornerRadius · zCard` (instead of the fixed `R0`).
  Still gated on `zoomActive = !zoomTransform.isIdentity()`; at identity
  everything is `R0`/`zCard==1` ⇒ unchanged.

### Preview — `playback_canvas.dart`
- **Chrome:** wrap `framePainterLayer` in a `Transform(scale zCard, alignment:
  center)` (was: left un-zoomed in the current branch).
- **Content clip:** the `_VideoWindowClipper` uses the centered `cardRect` and
  `cornerRadius · zCard` (was: fixed `R0` + `cornerRadius`). The content/cursor
  zoom transform stays the full `getTransform`.
- The `transform.isIdentity()` short-circuit (z==1 ramp endpoints render exactly
  like the no-zoom path) stays.

## Untouched / preserved

- Wallpaper stays sticky (un-zoomed) in both paths.
- `getTransform`, focal resolution, `clampFocalToBounds`, `DeterministicFocalTrack`
  — unchanged (content still uses the full zoom + focal).
- 1× / no-active-zoom renders exactly as today (gated on identity).

## Known interaction to verify (do NOT expand scope)

Scene/screen motion blur: export smears only the content layer (correct). The
preview `SceneBlurOverlay` captures and smears the whole frame; with the chrome
now *scaling* during a ramp, smearing it is no worse than (arguably more
justified than) the fixed-frame case, but still the flagged follow-up. Verify at
runtime; confine to the content layer later if objectionable.

## Testing

- **Export pixel test — padding floor holds at high zoom.** With `padding=40`,
  `paddingFloorFraction=0.4` (floor `F=16`), a 2× (and a 4×) centered zoom: a
  pixel in the padding band *inside* `F` (e.g. `x < 16`) stays clear of the
  video, AND a pixel *between the floor and the 1× padding* (e.g. `16 < x < 40`)
  is now covered by the **grown card** (chrome/video) — proving the card pushed
  in (padding shrank from 40→~16) but did not vanish. (Discriminates both
  against the original — which would clear nothing — and against the fixed-frame
  model — which would leave the whole 0–40 band clear.)
- **Card-scale clamp unit test** on the shared helper: `zCard == z` for
  `z ≤ zCardMax`; `zCard == zCardMax` for `z > zCardMax`; `cardRect` inset
  `≥ F`; `zCard == 1` when `paddingFloorFraction == 1.0`.
- **1× unchanged** (identity path).
- **Manual:** the original 4.3× top-right repro — the card visibly larger than
  1× with a clear padding margin (≈ floor) that does NOT vanish; content shows
  the top-right magnified.

## Acceptance criteria

- During a zoom the card visibly pushes in (scales up toward `zCardMax`).
- The wallpaper padding shrinks only to the floor (`paddingFloorFraction · P`)
  and never to zero.
- The focal region is magnified by the full zoom level inside the rounded window.
- 1× playback is visually unchanged.
- Preview and export agree on the geometry.
