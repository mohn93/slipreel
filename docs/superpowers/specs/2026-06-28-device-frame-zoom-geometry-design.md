# Framing-aware zoom geometry for device frames

## Problem

When a device frame (bezel) is active, the zoom transform — scale, focal
translation, and the reachable-bounds **clamp** — is computed in **source-video
coordinates**, assuming the video is rendered 1:1 and centered in the canvas. The
export compositor documents this assumption directly
(`frame_compositor.dart:261-264`): the matrix translation is built against
`videoSize/2` and only lands the focal at the alignment origin "because
`_videoRect.left − totalSize.width/2 = −videoSize.width/2`".

A device frame **violates** that assumption: the source video is rendered into the
bezel cutout (`deviceLayout.videoRect`) — offset by the bezel border + the user's
padding, and slightly scaled. Two user-visible symptoms result, both for the
device-frame path (worst in portrait, where tall framing makes edge-zoom common):

- **A — padding lost at the edge.** `clampFocalToBounds(focal, videoSize, z)` keeps
  the viewport inside the **screen-content** bounds, not the padded device canvas.
  Panning a zoom to the phone's edge snaps the viewport edge to the screen-content
  edge, pushing the bezel border and the selected padding off-screen.
- **B — focus and zoom desynced (one faster).** The focal translation uses
  `videoSize/2` and the raw video-space focal instead of the focal's actual rendered
  position (`videoRect.topLeft + focal·scale`), so the pan covers the wrong on-screen
  distance relative to the scale ramp. Compounding it, the controller's
  reachability test (`entryTarget == clampFocalToBounds(rawTarget, videoSize, z)`)
  treats an edge-of-screen cursor as *unreachable* in video bounds and applies a
  leading enter-pan (`backload < 1`); in the larger canvas bounds that same point is
  reachable and should be lock-step.

This is distinct from the earlier (reverted) padding-preserving-zoom work for
**normal** recordings — it is a device-frame-specific geometry bug.

## Decision

Introduce one value type, `ZoomFraming`, that owns the "where is the video drawn,
and what bounds must the zoomed viewport stay within" math. All zoom clamp /
reachability / centering routes through it. Two flavors:

- **Identity** (normal recordings): video fills the canvas 1:1, centered; clamp to
  **video** bounds. Reproduces today's behavior byte-for-byte.
- **Device** (bezel active): video rendered into `videoRect` (offset + scaled)
  inside `canvasSize`; clamp to the **padded canvas** bounds.

The focal that the controller integrates stays in **source-video coordinates**
everywhere (springs, deterministic track, transform input). `ZoomFraming` only
changes *which space the clamps and the transform-centering are computed in*.

## Components

### `ZoomFraming` (new) — `packages/slipreel_engine/lib/rendering/zoom_framing.dart`

A small immutable type. Construction:
- `ZoomFraming.identity(Size videoSize)` — render rect = `(0,0,videoW,videoH)`,
  canvas = videoSize, clamp space = video.
- `ZoomFraming.device({required Size videoSize, required Rect videoRect, required Size canvasSize})`.

Internal mapping (source-video → canvas px), affine and invertible:
- `sx = videoRect.width / videoSize.width`, `sy = videoRect.height / videoSize.height`
- `toCanvas(p) = videoRect.topLeft + Offset(p.dx*sx, p.dy*sy)`
- `fromCanvas(q) = Offset((q.dx - videoRect.left)/sx, (q.dy - videoRect.top)/sy)`

Operations (all take/return **source-video** focal points so call sites are
unchanged in type):
- `Offset clampFocal(Offset focal, double z)` — identity: `clampFocalToBounds(focal, videoSize, z)`
  (today's exact call). device: `fromCanvas(clampFocalToBounds(toCanvas(focal), canvasSize, z))`.
- `Offset clampFocalRadial(Offset focal, double z)` — identity:
  `clampFocalToBoundsRadial(focal, videoSize, z)`. device:
  `fromCanvas(clampFocalToBoundsRadial(toCanvas(focal), canvasSize, z))`.
- `Offset centerOffset(Offset focal, double z)` — the `pCenterRel` the transform
  translates by (canvas px). **Unified formula:** `toCanvas(clampInCanvas(focal, z))
  − canvasSize.center`, where `clampInCanvas` is the canvas-space per-axis clamp
  (`clampFocalToBounds(toCanvas(focal), canvasSize, z)`). For the identity flavor
  `toCanvas` is the identity map and `canvasSize == videoSize`, so this reduces
  exactly to today's `clampFocalToBounds(focal, videoSize, z) − videoSize/2` (note:
  the current transform clamps before computing `pCenterRel`, so the clamp is part
  of the formula in both flavors).

`clampFocalToBounds` / `clampFocalToBoundsRadial` remain the low-level statics on
`ZoomTransformer` (the framing delegates to them); they are unchanged.

### `ZoomTransformer.getTransform` — add optional `ZoomFraming? framing`

When `framing == null`, behavior is exactly as today (defaults to identity math
inline — no change). When provided, the clamp + the `pCenterRel` translation go
through `framing.clampFocal` / `framing.centerOffset`. The scale `z` and
`alignment: center` pivot are unchanged (the whole canvas still scales about its
center). The `_calculateZoomFactor` ramp math is untouched.

### `ZoomFocalController.update` — add optional `ZoomFraming? framing`

Default null ⇒ identity ⇒ unchanged. When provided, the 7 clamp/radial call sites
(enter target + reachability, exit anchors + radial, post-enter handoff clamp)
route through `framing.clampFocal` / `framing.clampFocalRadial` instead of the
direct `ZoomTransformer.clampFocal*` statics. This is what makes an edge-of-screen
cursor reachable in canvas bounds (fixes B's false lead) and keeps the enter/exit
pan inside the padded canvas (consistent with the transform).

### Threading

- `ScenePassBuilder.build` gains `ZoomFraming? framing`, forwarded to
  `focal.update`.
- `DeterministicFocalTrack` gains `ZoomFraming? framing`, passed to the
  `ScenePassBuilder` it builds internally (so scrub/paused/scene-blur replay matches).
- `FrameCompositor` (export): build a device `ZoomFraming` from its
  `deviceFramePlan.layout` (`videoRect`, `canvasSize == totalSize`) when a frame is
  active; pass it to the scene builder, the focal track, and `getTransform`.
- `PlaybackCanvas` (preview): build the same device `ZoomFraming` from `deviceLayout`
  (when non-null) and pass it to `_scenePassBuilder.build`, `_focalTrackFor`, and
  `_zoomTransformer.getTransform`. When `deviceLayout == null`, pass null (identity).

## Data flow

Per frame, device path: video-space cursor/rect → controller (clamps via device
framing in canvas space, integrates spring in video space) → video-space focal →
`getTransform(framing: device)` maps+clamps to canvas px and centers → Transform
scales the whole composition about canvas center. Normal path: framing null ⇒
identical to today.

## Error handling / edge cases

- Degenerate sizes (zero w/h) — `ZoomFraming.device` falls back to identity-like
  behavior (guard `videoRect`/`canvasSize` > 0); `clampFocalToBounds` already
  handles the `z ≤ 1` / collapsed-box degenerate by returning the center.
- `deviceFrameCompatible == false` (kind mismatch) — no device layout is built
  (existing guard), so framing is null ⇒ identity. No change.
- Non-device recordings — framing null everywhere ⇒ byte-identical output.

## Testing

- `zoom_framing_test.dart` (new): identity framing reproduces
  `clampFocalToBounds`/`Radial` exactly; device framing maps a known
  `videoRect`/`canvasSize` correctly (toCanvas/fromCanvas round-trip; an edge
  video focal clamps to the canvas-padded bounds, NOT the video bounds; centerOffset
  matches a hand-computed value).
- `zoom_focal_controller` test: with a device framing, an edge-of-screen cursor is
  treated as reachable (enter pan uses lock-step backload, no lead) and the enter
  pan stays within the canvas box.
- `zoom_transformer` test: `getTransform(framing: device)` centers a cutout-edge
  focal without clamping away padding; `framing: null` unchanged.
- Existing engine suite + `frame_compositor_device_parity_test` (preview==export)
  must stay green; they guard the normal path and device parity.
- Runtime: dev-signed Release build, open the 1170×2532 recording, zoom to the
  portrait edge → padding/bezel preserved (A) and focal tracks the scale in
  lock-step (B).

## Constraints

- Do NOT run `dart format` on existing files (pinned formatter reflows unrelated
  lines); match style by hand.
- Normal-recording zoom behavior must not change (identity framing / null default).
- Preview and export must stay in lock-step (same framing fed to both).
