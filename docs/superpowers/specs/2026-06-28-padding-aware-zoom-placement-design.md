# Padding-aware zoom placement (composed-canvas framing + picker)

Phase 2, builds on `2026-06-28-consistent-zoom-placement-framing-design.md`
(magnify-in-place for manual zooms, already merged onto this branch).

## Problem

A manual zoom's **placement** is authored and rendered in two inconsistent
coordinate spaces:

- The **render** frames the *composed canvas* (wallpaper + padding + bezel +
  screen) for DEVICE frames (PR #31) but the *bare video* for normal recordings
  (`ZoomFraming.identity(videoSize)` — ignores OutputAspect padding/wallpaper).
- The **placement picker** (`ZoomPlacementPicker`) is *always* bare-video: its
  aspect is `videoSize`, its background is the raw screen frame, and it clamps the
  focal to the video bounds. It knows nothing about bezel/padding/wallpaper.

So what you place ≠ what you get (the reported "placement sits outside the edge by
a big margin"), and you cannot position a zoom relative to the padded composition
— it is "confined to the device recording view."

## Decision

Make the zoom frame the **composed canvas** everywhere, for ALL recordings, and
rebuild the picker to author placement against that same composed canvas.

Two coordinate facts make this clean (from the codebase map):
- `ZoomRegion.rect` is **center-only** in every consumer (the rect size is never
  read; `rect.center` is the focal). So placement = a focal point.
- `ZoomFraming.device(videoSize, videoRect=(0,0,W,H), canvasSize=(W,H))` is
  **byte-identical** to `ZoomFraming.identity(videoSize)` (toCanvas = identity,
  canvasCenter = videoCenter). So "always device-style framing" degrades exactly
  to today's behavior when there is no padding and no bezel.

### Part A — Unify render framing (composed canvas for all)

Both `ZoomFraming` construction sites stop branching identity-vs-device and always
build a canvas-aware framing from the geometry they *already compute*:

- `playback_canvas.dart` (~line 748): replace
  ```dart
  deviceLayout != null
    ? ZoomFraming.device(videoSize, deviceLayout.videoRect, effTotalSize)
    : ZoomFraming.identity(videoSize)
  ```
  with
  ```dart
  ZoomFraming.device(
    videoSize: videoSize,
    videoRect: deviceLayout?.videoRect ?? resolved.videoRect,
    canvasSize: effTotalSize,            // = deviceLayout?.canvasSize ?? totalSize
  )
  ```
- `frame_compositor.dart` (~line 196): same shape, using the compositor's own
  even-rounded `totalSize` and `_videoRect` (so the framing matches the actually
  rendered composition pixel-for-pixel). For the non-device path `_videoRect` is
  the centered video rect in the padded canvas.
- `SceneBlurOverlay` already receives `framing` from `playback_canvas`; fixing the
  construction site fixes it. The controller's `framing ?? identity(videoSize)`
  fallback stays (only hit when a caller passes none).

Result: normal recordings with **zero** padding are byte-identical to today;
normal recordings **with** padding/wallpaper become canvas-aware (manual =
magnify-in-place over the composed canvas; follow-cursor = center-and-clamp over
the composed canvas), consistent with device frames. Preview and export both use
the same framing → they stay byte-identical to each other.

### Part B — Allow the focal to roam the composed canvas

Today the manual placement focal is clamped to the video bounds
(`_onPlacementPreview`/`_onPlacementCommit` pass `videoBounds`, and
`ZoomRegion._constrainRect` clamps to `[0,videoSize]`). To position a zoom over the
padded/bezel region ("not confined to the recording view"), a manual placement's
focal may sit anywhere that keeps the **viewport inside the canvas**.

- For a **manual** placement commit/preview, do NOT clamp the focal to the video
  bounds. The picker is the single clamp authority: it constrains the focal so the
  magnify-in-place viewport (`canvasSize/z`) stays within the canvas (this maps to
  focal canvas-fraction `∈ [0,1]`, i.e. `rect.center` may fall outside
  `[0,videoSize]` — into the padding — but never further).
- Concretely: in `playback_screen` manual preview/commit, pass `videoBounds: null`
  (or a dedicated "no video clamp" path) so `_constrainRect` doesn't pull the focal
  back onto the screen. Follow-cursor and all other ZoomRegion construction keep
  passing `videoBounds` unchanged.
- Center-only consumers already tolerate an out-of-video focal (verified: every
  read is `rect.center` used directly as a focal; `ZoomFraming`/magnify-in-place
  map it through `toCanvas`). Serialization (`toJson`/`fromJson` LTWH) is unaffected.

### Part C — Rebuild `ZoomPlacementPicker` to author against the composed canvas

The picker renders the *composed canvas* and a draggable **viewport box** that is
exactly what the render frames.

New inputs (passed by `ZoomContextInspector`, sourced in `playback_screen`):
- `canvasSize` (composed canvas px), `videoRect` (video's rect within the canvas).
- Wallpaper: `category`, `index`, `solidColor?` (for `wallpaperDecoration`).
- Optional device: `DeviceFrameLayout layout` + bezel `ImageProvider`
  (`AssetImage(asset.asset)`); null for normal recordings.
- `screenFrame` (`ui.Image?`, the existing extracted frame), drawn into `videoRect`.
- `zoomLevel`, current `rect` (focal), `onPreview`/`onCommit`.

Rendering (mini-frame at `miniScale = miniWidth / canvasSize.width`,
aspect = `canvasSize` aspect):
1. Background = `Container(decoration: wallpaperDecoration(category, index,
   solidColor: solidColor))` sized to the scaled canvas.
2. The video: device → `DeviceFrameComposition(layout, video: RawImage(screenFrame,
   fit cover), bezel)`; normal → `Positioned.fromRect(videoRect*scale,
   RawImage(screenFrame))`.
3. **Viewport box** (the framing indicator) = the magnify-in-place viewport in
   canvas coords:
   - `canvasFocal = toCanvas(rect.center)` (videoRect affine).
   - `vc = canvasCenter + (1 − 1/z)·(canvasFocal − canvasCenter)`, `z = zoomLevel`.
   - `boxCanvas = Rect.fromCenter(vc, canvasW/z, canvasH/z)`; draw at `*scale`.
   - Spotlight dims outside `boxCanvas` (reuse `_SpotlightPainter`).
4. Drag: `vc' = vc + dragDelta/scale`, clamp `vc'` so `boxCanvas ⊆ canvas`
   (`vc'.dx ∈ [canvasW/(2z), canvasW − canvasW/(2z)]`, same y). Invert to focal:
   `canvasFocal' = canvasCenter + (vc' − canvasCenter)/(1 − 1/z)`;
   `rect.center' = fromCanvas(canvasFocal')`; emit `Rect.fromCenter(center',
   videoSize/z)` (size kept for continuity; unused downstream).
   - `z == 1`: `(1 − 1/z) = 0` ⇒ viewport = whole canvas, focal indeterminate;
     box fills the canvas and drag is disabled (no division). Picker guards this.

`videoSize` stays a picker input (for the affine + emitted rect size). The
follow-cursor path does not use this picker (placement shown only for manual /
device).

## Data flow

`playback_screen` resolves canvas geometry (`OutputCanvasResolver` /
`resolveDeviceFrameLayout`, same as the render), wallpaper from the current frame,
and the device layout/bezel; passes them to `ZoomContextInspector` →
`ZoomPlacementPicker`. Drag → `onPreview` (canvas-clamped focal, video coords) →
`_zoomPreviewOverride` (manual, `videoBounds: null`) → live canvas renders the real
magnify-in-place framing. Release → `onCommit` → `updateZoomAt` (manual,
`videoBounds: null`).

## Error handling / edge cases

- Zero padding + no device: framing reduces to identity (byte-identical). Picker
  canvas == video, behaves like today plus magnify-in-place box.
- `zoomLevel == 1`: box = whole canvas, drag disabled.
- Degenerate sizes: `ZoomFraming.device` already falls back to identity.
- Missing `screenFrame` (still loading): picker shows wallpaper + bezel + box over
  a placeholder for the video region (existing null-background behavior, adapted).

## Testing

- `zoom_framing_test`: explicit "device framing with videoRect=(0,0,W,H),
  canvas=(W,H) == identity" byte-identical guard (clampFocal, centerOffset,
  centerOffsetInPlace across z) — locks Part A's safety.
- Render unification: a normal recording WITH padding now frames the composed
  canvas — assert (via getTransform or the pipeline test) that a manual edge
  placement's on-screen position uses canvas geometry, not video geometry; and
  zero-padding stays byte-identical. Preview==export parity stays green.
- `zoom_placement_picker` widget tests: box position equals the magnify-in-place
  viewport for a known canvas/videoRect/zoom; drag maps screen delta → focal
  correctly and clamps the box to the canvas; `z==1` disables drag; device vs
  normal background composition builds without throwing.
- Model/wiring: manual commit/preview no longer clamps the focal to video bounds
  (focal may land in padding); follow-cursor still clamps. A focal in the padding
  round-trips through serialization.
- Full `slipreel_engine` + `screen_recorder` suites green; regenerate + visually
  review any changed goldens (normal+padding zoom transforms may shift — expected).

## Constraints

- Do NOT run `dart format` on existing files; match style by hand.
- Zero-padding non-device behavior must stay byte-identical (the identity-reduction
  guard proves it).
- Preview and export stay byte-identical to each other (one framing feeds both).
- Keep `ZoomRegion.manualPanBackload` (serialization compat; inert for manual).
- Follow-cursor framing behavior unchanged except that it now clamps to the
  composed canvas instead of the bare video for padded recordings (intended, part
  of "all padded recordings").
