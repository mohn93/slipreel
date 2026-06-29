# 3D Zoom Tilt — Phase 1 Design (the depth engine)

**Date:** 2026-06-29
**Status:** Design — pending user review
**Issue:** #12 (3D zoom effect: perspective/parallax "3D movement" zoom)
**Branch:** `feat/3d-zoom-tilt`

## Summary

Give zooms depth. Today a zoom is a flat magnify (scale + pan). This adds a 3D
perspective **tilt**: as a zoom plays, a floating **content panel** (device
frame + screen + cursor) leans in 3D over a **static background** (wallpaper),
producing the "launch video" look used to showcase an app's UI.

This is **Phase 1** of a two-phase feature:

- **Phase 1 (this spec):** the 3D perspective transform engine + tilt-on-zoom.
  Auto-derived tilt direction, style presets, manual override; applies to
  follow-cursor *and* manual zooms; preview + export parity.
- **Phase 2 (later spec):** a "Movements" library — named cinematic camera
  moves (push-in+tilt, orbit/pan, parallax reveal, hero spin) choreographed on
  the timeline. Phase 2 is *sequences/keyframes of the same 3D matrix* Phase 1
  produces, so this spec's matrix builder is its foundation. Out of scope here.

## Goals

- Zooms can be **2D** (flat, today's behavior) or **3D** (tilted), chosen per
  zoom via a simple inspector toggle.
- **New** zooms (manual placements + auto-detected click zooms) default to
  **3D / Subtle**. **Existing** projects' zooms load as **2D / flat** — no
  surprise changes to saved work.
- The 3D tilt is **automatic** by default (direction derived from where the
  zoom lands), with **style presets** (Subtle / Dramatic) for intensity and an
  **advanced manual override** for explicit angles.
- Tilt and zoom move in **lock-step** (tilt ramps with the zoom factor) — no
  separate animation that can desync.
- **Preview and export render identically.**
- **Zero regression** for flat/2D zooms: the flat path is byte-identical to
  today.

## Non-goals (Phase 1)

- Phase 2 movements/camera-path keyframes, orbit, parallax background drift.
- Parallax/independent background motion (background is **fully static** under
  a 3D tilt this phase).
- Tilting captions (captions stay a flat, readable top overlay — see below).
- A project-wide default-style setting (per-zoom default is enough for now).

## Decisions (resolved in brainstorming)

| Question | Decision |
| --- | --- |
| Phasing | Engine + tilt-on-zoom now; movements library later |
| Tilt control | All three: auto direction + style presets + manual override |
| What tilts | Content panel (device frame + screen + cursor) over a flat background |
| Background under 3D tilt | **Fully static** (locked; max foreground separation) |
| Default style for new zooms | **3D / Subtle** (existing projects load as 2D/flat) |
| Zoom types affected | **Both** follow-cursor and manual |
| 2D vs 3D modeling | **One model, type toggle** — single `ZoomRegion` + `tilt` config; flat = 2D. One matrix path; UI exposes a 2D/3D toggle. |

## Architecture

### Layering: engine vs model vs UI

- **Engine (rendering):** exactly **one** type-agnostic code path. The matrix
  builder takes a tilt config; **flat is the zero case** (0° → identity
  perspective → byte-identical to today). No "2D vs 3D" branch in the transform
  math — that is where parity bugs hide.
- **Model:** a single `ZoomRegion` carrying a `tilt` config. "2D" is `flat`;
  "3D" is `subtle` / `dramatic` / manual. Trivial migration (missing → flat).
- **UI:** the inspector presents a **2D / 3D segmented toggle**. Choosing 3D
  reveals style + manual controls; choosing 2D sets `flat`. The "type" is a
  presentation of the same continuum, not a separate class — cheap to promote
  to a real discriminant later if Phase 2 movements demand divergent params.

### The transform matrix

One `Matrix4`, built in `ZoomTransformer.getTransform`, consumed identically by
preview (`Transform(alignment: .center)`) and export
(`c.translate(center)·c.transform(m.storage)·c.translate(-center)` —
`frame_compositor.dart:305-307`). Both already pivot about the **canvas
center**, so the tilt rides on top of the existing 2D zoom without disturbing
focal-centering.

```
M = perspective · rotateX(θx) · rotateY(θy) · [existing scale + centerOffset 2D zoom]
```

- The existing 2D zoom (scale + `ZoomFraming.centerOffset` /
  `centerOffsetInPlace`) is applied **first** (innermost), bringing the focal to
  the canvas center for follow-cursor or holding the placed point in place for
  manual. Rotation + perspective then pivot about the canvas center.
- **Perspective strength scales with canvas height**: `setEntry(3, 2,
  -1 / focalLengthPx)`, `focalLengthPx = canvasHeight * kPerspective`
  (`kPerspective` ≈ 1.6, tunable). Because both pipelines compute it from their
  own canvas size, 1080p preview and 4K export produce an identical normalized
  look — **the parity-critical detail.**
- **Flat (θx = θy = 0):** the rotation rows are identity and perspective is
  applied to a zero-depth plane → the matrix reduces to today's scale+translate
  **byte-identically**. (A flat zoom skips the perspective entry entirely; see
  rendering modes below.)

### Tilt angle derivation

**Direction (auto):** from the focal's position in the *composed frame*, not its
post-centering screen position (so a centered follow-cursor zoom still tilts
toward the part of the UI it framed).

```
cf = framing.toCanvas(focal)                       // focal in canvas coords, pre-zoom
n  = clamp( ((cf.dx - W/2)/(W/2), (cf.dy - H/2)/(H/2)), -1, 1 )
θy =  n.dx * maxAngle                               // sign: focal side leans toward viewer
θx = -n.dy * maxAngle                               // (exact signs pinned by golden test)
```

**Magnitude (ramp):** scaled by the live zoom progress so tilt grows in on
enter, holds at full zoom, and recedes on exit — automatically synced to the
zoom factor with no separate animation:

```
p     = clamp( (z - 1) / (zoomLevel - 1), 0, 1 )    // 0 at rest, 1 at full zoom
θ    *= p
```

**Style → maxAngle:** `flat → 0°`, `subtle → 4°`, `dramatic → 11°` (tunable).

**Manual override:** when `manualAngleX` / `manualAngleY` are set, they replace
the auto-derived angles but are **still multiplied by `p`** so the tilt ramps in
and out with the zoom (no pop at the region edges).

### Rendering modes (the layer split)

Two composition modes, selected by whether the active zoom's tilt is flat:

- **Flat / 2D (unchanged):** the whole composed canvas — wallpaper, device
  frame, screen, cursor — transforms together exactly as today. The flat path
  is left untouched to guarantee zero regression.
- **3D (tilt active):** the composition splits into two layers:
  - **Background** = wallpaper / solid color. Drawn **static** (no transform).
  - **Content panel** = device frame + screen video + cursor. Gets the full 3D
    matrix and floats in front.

  - Export (`frame_compositor.dart`): the per-layer `applyZoom` closure skips
    the wallpaper layer and applies the 3D matrix to the panel layers.
  - Preview (`playback_screen.dart` / `composed_canvas.dart`): restructure so
    the wallpaper sits **outside** the `Transform` and the panel **inside** it
    (`Stack[ background, Transform(M)[ panel ], captions ]`).

- **Captions** remain a **flat top overlay** (untilted, readable) in both
  pipelines — not part of the tilting panel.
- **Scene blur** (`SceneBlurOverlay` / compositor scene-motion blur) follows the
  **content panel** (the moving layer), using the same focal it does today; the
  static background is not blurred. Covered by an integration test.
- **Full-bleed recordings** (no padding, no device frame — content fills the
  canvas): a Subtle ≈4° tilt reveals a thin sliver of the **project background
  color** at the two receding edges. Acceptable and documented; 3D is most
  effective with padding. Not blocked.

### Clamping / framing interaction

The 2D portion keeps its existing `ZoomFraming` behavior unchanged
(follow-cursor center-and-clamp via `centerOffset`; manual magnify-in-place via
`centerOffsetInPlace`, `videoBounds: null`). The tilt is a separable rotation
about the canvas center layered on top — with a static background behind, the
panel may reveal background at its edges by design (the floating look), so the
tilt adds no new clamp requirements.

## Data model

```dart
enum ZoomTiltStyle { flat, subtle, dramatic }

class Tilt3D {
  final ZoomTiltStyle style;     // flat == 2D
  final double? manualAngleX;    // degrees; null => auto-derive
  final double? manualAngleY;    // degrees; null => auto-derive
  const Tilt3D({this.style = ZoomTiltStyle.flat, this.manualAngleX, this.manualAngleY});

  bool get is3D => style != ZoomTiltStyle.flat;
}
```

- `ZoomRegion` gains a `tilt` field.
- **Serialization:** `tilt` serializes nested. **Missing field on
  deserialize → `Tilt3D(style: flat)`** (old projects load as 2D — no surprise).
- **Construction defaults:** newly created zooms — manual placements **and**
  `AutoZoomDetector` click zooms — default to `Tilt3D(style: subtle)`.
- **Cache key:** `tilt` must be part of `ZoomRegion` equality and of
  `DeterministicFocalTrack`'s cache key so cached frames invalidate when tilt
  changes.

## Inspector UI

- A **2D / 3D segmented toggle** is the primary control for a selected zoom.
  - **2D** → sets `style: flat`, hides 3D sub-controls.
  - **3D** → sets `style: subtle` (if coming from flat) and reveals:
    - a **Subtle / Dramatic** style segmented control;
    - an **"Advanced"** disclosure with manual X / Y angle sliders (sets the
      override) and a **"reset to auto"** affordance (clears the overrides).
- Follows existing inspector patterns and palette tokens
  (`context.palette.*`, springy controls where they fit).

## Testing & verification

- **Matrix builder unit tests:** flat == today's matrix (identity perspective);
  angle/ramp scaling; perspective resolution-independence (same normalized
  projection at 1080p vs 4K); manual override replaces auto angles and still
  ramps; tilt-direction sign (top-right focal → expected lean) via a small
  geometric golden.
- **Preview ↔ export parity golden** on a tilted zoom (the discipline from the
  device-frame work — the `SceneBlurOverlay` / compositor split is exactly where
  parity bugs hide).
- **Serialization/migration tests:** old JSON (no `tilt`) → flat; round-trip of
  each style + manual angles; new-zoom construction defaults to subtle.
- **Scene-blur integration test:** blur follows the panel, background unblurred.
- **Flat regression guard:** a flat 3D-capable zoom renders byte-identically to
  the pre-change pipeline (golden).
- Full `melos` analyze + test green; runtime verification on a dev-signed
  Release build (visual check of the tilt in preview and an exported clip).

## Risks & mitigations

- **Preview/export divergence** (perspective handled differently by the
  `Transform` widget vs `Canvas.transform`): mitigated by deriving perspective
  strength from canvas height in both and a dedicated parity golden.
- **Preview layer-split refactor** (separating background from panel in the
  widget tree) is the largest surface; isolate it as its own task with the flat
  path untouched.
- **Scene-blur + tilt interaction**: scope blur to the panel layer; integration
  test guards it.
- **Tilt jitter on follow-cursor** (moving focal): direction comes from the
  already-smoothed focal track and magnitude ramps with zoom, so it settles
  rather than snaps.

## Open tunables (set in spec, adjustable at review)

- `subtle` = 4°, `dramatic` = 11°, `kPerspective` ≈ 1.6.
- Captions stay flat (untilted).
- Background fully static under tilt (no parallax drift this phase).
