# Plan: padding-aware zoom placement (composed-canvas framing + picker)

Design: `docs/superpowers/specs/2026-06-28-padding-aware-zoom-placement-design.md`
Branch: `fix/zoom-placement-magnify-in-place` (continues Phase 1 work already on it).

## Global constraints (bind every task)

- Zero-padding, non-device behavior must stay BYTE-IDENTICAL (proved by the
  identity-reduction guard: `ZoomFraming.device(videoSize, (0,0,W,H), (W,H))` ==
  `ZoomFraming.identity(videoSize)`).
- Preview and export stay byte-identical to EACH OTHER (one framing feeds both;
  use the compositor's own even-rounded `totalSize`/`_videoRect` on the export
  side so framing matches the rendered composition).
- Manual placements use magnify-in-place (Phase 1); follow-cursor uses
  center-and-clamp. Both now operate over the COMPOSED canvas for padded
  recordings.
- A MANUAL placement focal may roam the composed canvas (clamped so the viewport
  stays in-canvas → `rect.center` may fall into the padding). Follow-cursor and
  all other ZoomRegion construction keep clamping to video bounds.
- Do NOT run `dart format` on existing files; match style by hand.
- Keep `ZoomRegion.manualPanBackload` (serialization compat).
- `ZoomRegion.rect` is center-only downstream — do not start reading rect.size.

## Task 1 — Unify render framing to the composed canvas

**Files:** `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`,
`packages/slipreel_engine/lib/export/frame_compositor.dart`,
`packages/slipreel_engine/test/rendering/zoom_framing_test.dart`,
plus any test asserting normal+padding identity framing.

- Replace the device-vs-identity branch at both `ZoomFraming` construction sites
  with a single `ZoomFraming.device(videoSize: videoSize, videoRect: <device or
  resolved videoRect>, canvasSize: <device or total canvas>)` (spec Part A). On the
  export side use the compositor's even-rounded `totalSize`/`_videoRect`.
- Add the **identity-reduction guard** to `zoom_framing_test`: for
  `videoRect=(0,0,W,H)`, `canvas=(W,H)`, assert `device` flavor returns the same
  `clampFocal`, `clampFocalRadial`, `centerOffset`, and `centerOffsetInPlace` as
  `identity(videoSize)` across `z ∈ {1.5,2,3,5}` (and a centered + an edge focal).
- Run the full engine suite; update any test that asserted normal+padding used
  identity framing (those now legitimately change to canvas-aware). Confirm
  `frame_compositor_device_parity_test` and the Phase-1
  `manual_magnify_in_place_pipeline_test` stay green.
- Verify `analyze` clean. Commit.

Model: most capable (touches preview + export framing; correctness-critical).

## Task 2 — Rebuild `ZoomPlacementPicker` (composed-canvas, viewport box)

**Files:** `packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart`,
`packages/screen_recorder/test/...zoom_placement_picker_test.dart` (new or existing).

Pure widget with the new API (spec Part C): inputs `videoSize`, `canvasSize`,
`videoRect`, wallpaper (`category`, `index`, `solidColor?`), optional
`DeviceFrameLayout layout` + bezel `ImageProvider`, `screenFrame` (`ui.Image?`),
`zoomLevel`, `rect`, `onPreview`, `onCommit`.

- Render: scaled composed canvas (wallpaperDecoration background; device →
  `DeviceFrameComposition`, normal → `Positioned.fromRect(videoRect)` screen frame)
  + magnify-in-place viewport box + spotlight.
- Box math + drag inversion + canvas clamp + `z==1` drag-disable exactly per spec
  Part C. Keep emitting a `Rect` in video coords (`Rect.fromCenter(center',
  videoSize/z)`); size is vestigial but preserved.
- Widget tests: box equals the magnify-in-place viewport for a known
  canvas/videoRect/zoom (device AND normal-padded); drag delta → focal mapping +
  canvas clamp; `z==1` disables drag; builds without throwing for both device and
  normal inputs (provide a tiny test `ui.Image`/placeholder).

Model: standard (self-contained widget against a defined API + math).

## Task 3 — Wire the picker host + relax the manual focal clamp

**Files:**
`packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`,
`packages/screen_recorder/lib/ui/screens/playback_screen.dart`,
(`packages/slipreel_engine/lib/models/zoom_region.dart` only if a "no video clamp"
path is needed), plus their tests.

- `ZoomContextInspector`: thread the new picker inputs through (canvasSize,
  videoRect, wallpaper category/index/solidColor, optional device layout + bezel
  provider). Source them where `videoSize`/`videoPath` are sourced today.
- `playback_screen`: compute the composed-canvas geometry for the selected zoom
  the SAME way the render does (`OutputCanvasResolver` / `resolveDeviceFrameLayout`
  with the current frame's padding/aspect/wallpaper/device catalog) and pass to the
  inspector. Ensure it stays in sync with the canvas the user sees.
- Relax the manual focal clamp (spec Part B): `_onPlacementPreview` /
  `_onPlacementCommit` build the override/commit region with `videoBounds: null`
  (manual only) so the focal isn't pulled back onto the screen; the picker is the
  clamp authority. Leave follow-cursor / other construction unchanged.
- Tests: manual commit/preview keeps a padding focal (no video clamp);
  follow-cursor still clamps; inspector passes correct geometry. Run recorder
  suite + analyze. Commit.

Model: standard (integration/wiring).

## Task 4 — Integration, goldens, full-suite + runtime verify

- Full `slipreel_engine` + `screen_recorder` test suites green; `analyze` clean in
  both.
- Add/extend an integration guard: a normal recording WITH padding, manual edge
  placement — assert the framed point uses canvas geometry (fails if it reverted to
  bare-video identity). Confirm preview==export parity for the padded normal case.
- Regenerate + visually review any changed goldens (normal+padding zoom transforms
  may shift). List each.
- Whole-branch review (most capable model) over `merge-base main HEAD`.
- Runtime verify on a dev-signed Release build:
  * Device portrait recording: open the placement picker → it shows phone + bezel +
    padding + wallpaper; the viewport box matches the live canvas framing; drag near
    the edge → what you place is what renders; 5×→2× no lurch.
  * Normal recording WITH padding/wallpaper: picker shows the padded canvas; manual
    zoom frames the composed view.
  * Zero-padding normal recording: unchanged from before.

Model: standard (verification + golden review).

## After all tasks

- `superpowers:finishing-a-development-branch` → PR → merge on green CI.
- Update memory: fold Phase 2 into `device_frame_zoom_geometry.md` (or a new
  entry) — composed-canvas framing for all recordings + padding-aware picker;
  retire the placement follow-up as DONE.
