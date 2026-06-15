# Padding-preserving zoom (fixed frame, content magnifies inside)

GitHub follow-up to the zoom/composition behavior noticed after #6.

## Problem

When a zoom is active, the padding (the wallpaper border around the rounded
screen window) shrinks — at high zoom it disappears entirely and the window
runs off the canvas edges.

Cause (confirmed in code): the zoom matrix is applied around the **whole framed
window**. In export ([frame_compositor.dart](../../../packages/slipreel_engine/lib/export/frame_compositor.dart))
`applyZoom` is applied to BOTH the foreground (video + cursor) AND the chrome
(shadow/ring/border) around the canvas center; in preview
([playback_canvas.dart](../../../packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart))
a single `Transform` wraps the entire composition. The wallpaper is "sticky"
(un-zoomed) in both. So the framed window scales up against the fixed wallpaper,
its edges move past the canvas edges, and the visible padding band is eaten.

## Desired behavior

Treat the **padded window as a fixed stage**. The wallpaper border (padding),
the rounded window frame, the shadow, and the border all stay exactly as they
are at 1× for every zoom level. The zoom magnifies and pans the **recording
content (video + cursor) inside that fixed window**, clipped to the rounded
corners. The camera pushes into the *content*, not the *frame*.

Accepted consequence: the rounded corners and shadow no longer grow during a
zoom (only the footage inside magnifies). This is the unavoidable trade for
"padding never shrinks + background stays sticky."

## Core insight — no math changes

`ZoomTransformer.getTransform` ([effects/zoom_transformer.dart](../../../packages/slipreel_engine/lib/effects/zoom_transformer.dart))
already builds a matrix that scales by `z` around the **video's center** and
translates the (bounds-clamped) focal point to that center. Applied to a
`videoSize`-sized child with `alignment: center`, it magnifies the focal region
of the recording and centers it within the video box — exactly the new model.
`clampFocalToBounds` (keeps the visible window inside the recording) is also
unchanged: the "visible window" is now the fixed video rect, same math.

So **the matrix, focal resolution, and clamp are untouched.** The change is
purely (a) *where* the transform is applied (content only, not the whole
window), (b) clipping the magnified content to the fixed un-zoomed rounded video
rect, and (c) not zooming the chrome.

## Edit sites

### Export — `frame_compositor.dart`
1. **Stop zooming the chrome.** Remove the `applyZoom(chromeCanvas)` call (~line
   248) so `FramePainter` draws the shadow/ring/border/background crisp at the
   fixed padded rect. Chrome is already composited un-blurred; it should also be
   un-zoomed.
2. **Clip-then-zoom the content.** The video+cursor (`fgCanvas`) must be clipped
   to the **fixed, un-zoomed** rounded `_videoRect` BEFORE the zoom is applied,
   so the magnified content stays within the fixed window. Today the rounded
   clip lives *inside* `_paintVideoFrame` and therefore runs in already-zoomed
   space (the clip scales with the content). Restructure so the order is:
   `save → clipRRect(_videoRect, cornerRadius) [device space] → applyZoom →
   draw video + cursor → restore`.
   - The wallpaper stays sticky (unchanged).
   - The scene-motion-blur already smears ONLY the foreground content layer
     (chrome and wallpaper are composited un-smeared) — correct for this model,
     no change.

### Preview — `playback_canvas.dart`
3. **Move the `Transform` inward.** Instead of wrapping the whole `composition`
   Stack (~line 1052), wrap only the video+cursor content that sits inside the
   fixed `ClipRRect` + `SizedBox(videoSize)` positioned at the padded
   `videoRect`. The frame chrome (`FramePainter`) stays in the composition Stack
   **un-zoomed**; the wallpaper stays sticky (already outside the transform).
4. **Cursor into the clipped+zoomed content.** The cursor overlay moves into the
   same clipped+zoomed subtree (painted in video-rect space, i.e.
   `videoRect = Offset.zero & videoSize`) so it magnifies with the footage and
   is clipped to the rounded window.

## Behavior at 1×

Zoom-identity (`z == 1`, the common case and every frame outside a zoom region)
must render exactly as today. The fixed content clip + inward transform only
engage when a zoom is active (`z > 1`); at `z == 1` we keep the current path,
including the cursor's current ability to bleed slightly onto the padding near a
screen edge.

Accepted minor transition: at the very start of a zoom-in, a cursor that was
bleeding onto the padding gets clipped to the window as the content clip
engages. Rare and subtle (the content edge is essentially at the window edge at
`z ≈ 1`).

## Known interaction to verify (do NOT expand scope here)

The **screen/scene motion blur**:
- Export already smears only the content layer → correct under the new model.
- Preview's external `SceneBlurOverlay`
  ([scene_blur_overlay.dart](../../../packages/screen_recorder/lib/ui/widgets/scene_blur_overlay.dart))
  captures and smears the *whole* composited frame. With a now-static frame, a
  zoom ramp could smear the fixed border/shadow. This is already a flagged
  "accepted divergence" area (preview smears the shadow during ramps). Verify
  during testing; if it's a visible regression, confine the smear to the content
  layer as a **follow-up**, not part of this change.

## Testing

- **Geometry (compositor-level, export):** at `z > 1`, assert the framed window
  (chrome rect / rounded clip) stays at the fixed `_videoRect` and the padding
  width (canvas edge → window edge) is constant across zoom levels, while the
  drawn video content is magnified within that rect. A no-zoom (`z == 1`) case
  must match the pre-change geometry.
- **Preview ↔ export parity:** the clipped-content geometry agrees between the
  two paths (window rect fixed, content magnified) at representative zoom levels
  and focal points.
- **1× unchanged:** the identity path renders as before (chrome position, cursor
  bleed).
- **Manual:** reproduce the original report — a 4.3× zoom on the top-right; the
  padding band must be visually identical to the 1× padding.

## Acceptance criteria

- During any zoom, the wallpaper padding border is the same width as at 1× (it
  does not shrink).
- The recording content magnifies and pans inside the fixed rounded window,
  clipped to the corners.
- 1× playback is visually unchanged.
- Preview and export agree on the new geometry.
