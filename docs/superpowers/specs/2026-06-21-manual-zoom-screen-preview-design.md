# Manual Zoom Screen Preview — Design

> Sub-project B of the 2026-06-21 editor-polish pair. Sibling: `2026-06-21-device-recording-editor-handling-design.md`.

**Goal:** When placing a manual zoom region, show the actual screen (a video frame at the zoom's start time) inside the inspector's placement box, with the selected region spotlighted — so the user can see what they're framing instead of dragging a box over a blank area.

**Status:** Approved design (frame + spotlight), pending spec review.

---

## Background / Why

Manual zoom placement uses `ZoomPlacementPicker` (`packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart`) — a mini-frame in the zoom context inspector (`zoom_context_inspector.dart:76-100`) that matches the video aspect ratio. It renders only when `!zoom.followCursor` (manual placement). Today its background is a flat dark fill (`Color(0xFF1A1A22)`) with a draggable purple rect representing the zoom focal — **no screen content**, so the user frames blind: *"so users know what the zoom region to select."*

This is especially painful for device recordings (sub-project A), where auto-zoom is unavailable and manual zoom is the only path.

The picker is a pure UI widget: it receives `videoSize`, `rect` (focal, in video pixel coords), `zoomLevel`, and `onPreview`/`onCommit` callbacks, and maps everything proportionally inside the mini-frame. It has no Riverpod / async today.

## Design

### 1. Frame extractor provider (new)
New file `packages/screen_recorder/lib/state/frame_extractor_provider.dart`:

`FutureProvider.autoDispose.family<ui.Image?, FrameKey>` where `FrameKey` carries `(videoPath, atMicros, targetW, targetH)` (a small value type with `==`/`hashCode`).

- Runs ffmpeg via **`Ffmpeg.resolve()`** (`packages/slipreel_engine/lib/export/ffmpeg_resolver.dart` — never a bare `'ffmpeg'`, because the sandbox minimizes PATH):
  `-loglevel error -ss <t> -i <path> -frames:v 1 -vf scale=W:H -f rawvideo -pix_fmt rgba -` → RGBA bytes → `ui.decodeImageFromPixels(bytes, W, H, ui.PixelFormat.rgba8888, …)`.
- **Use `rgba` + `rgba8888` consistently.** The existing thumbnail extractor (`recording_thumbnail_service.dart:188-234`) extracts `bgra` but decodes as `rgba8888` (a latent red/blue channel swap) — we do **not** copy that. The `-vf scale=W:H` is required so the raw byte count equals `W*H*4`.
- **Target size:** the mini-frame's pixel size — `min(280pt, actual)` × `devicePixelRatio`, capped (e.g. longest side ≤ ~640px), preserving the video aspect ratio. Small frame → cheap extract.
- **Caching:** in-memory only via `autoDispose` (no sidecar). A single ffmpeg seek+extract is fast; the provider de-dupes by key while the inspector is open and frees the image when the zoom is deselected.
- Returns `null` on any failure (bad path, decode error) — never throws.

Mirrors the `waveform_provider.dart` `FutureProvider.autoDispose.family` shape and the `recording_thumbnail_service` decode (minus the channel swap).

### 2. Thread `videoPath` + frame into the picker
- Pass `videoPath` from `PlaybackScreen` (`widget.videoPath`, `playback_screen.dart:228`) → `InspectorPanel` (`:2193`) → `ZoomContextInspector`.
- In `ZoomContextInspector`, watch `frameExtractorProvider((videoPath, zoom.startTime.inMicroseconds, w, h))` and pass the resulting `ui.Image?` to `ZoomPlacementPicker` as a new `backgroundImage` param. `videoSize` is already available there.
- Keying on `zoom.startTime` means selecting a different zoom (or changing its start) refreshes the frame.

### 3. Render frame + spotlight in `ZoomPlacementPicker`
Add `final ui.Image? backgroundImage;`. Inside the mini-frame box, paint in this order:
1. **Frame** — `CustomPaint` `drawImageRect` filling the mini-frame (`FilterQuality.medium`). While `null`/loading, fall back to the existing dark fill (`0xFF1A1A22`).
2. **Spotlight** — fill the mini-frame with ~54% black, then punch out the selection rect (saveLayer + `BlendMode.clear`, or `Path.combine(PathOperation.difference, fullRect, selectionRect)`), so the chosen region stays bright and everything outside dims.
3. **Selection rect** — the existing draggable purple border on top (gesture handling unchanged).

The frame is static during a drag; only the selection rect + spotlight cutout move with the user's finger.

## Components / Files
- **Create** `packages/screen_recorder/lib/state/frame_extractor_provider.dart`.
- **Modify** `zoom_placement_picker.dart` — `backgroundImage` param + frame + spotlight painters.
- **Modify** `zoom_context_inspector.dart` — watch provider, pass image (+ receive `videoPath`).
- **Modify** `inspector_panel.dart` + `playback_screen.dart` — thread `videoPath` down.

## Testing
- **Unit:** `frame_extractor_provider` against a tiny fixture video → non-null `ui.Image` with the requested dims; bad path → `null` (no throw).
- **Widget:** `ZoomPlacementPicker` given a `backgroundImage` paints a frame layer + spotlight; given `null` shows the dark fallback. (Golden or paint-call assertion.)
- **Runtime verify:** open any recording → add/select a manual zoom → the placement box shows the screen frame with the selected region spotlighted, and the box drags over it correctly.

## Out of scope
- Live per-frame video texture under the box (we use a single extracted frame at the zoom's start, refreshed on change — not a moving video).
- Disk caching of extracted frames.
- Changing the placement geometry / drag behavior (only the *background* of the existing box changes).

## Open default
- Frame sampled at the **zoom's start time** (chosen). Could later switch to the current playhead; not now.
