# Output Aspect Ratio — Design Spec

**Date:** 2026-05-31
**Status:** Approved, ready for implementation plan.

## Goal

Add an editor-side **output aspect ratio** picker that controls the shape of the rendered canvas (and, by extension, the exported video). The user picks one of seven options — Auto, Wide 16:9, Square 1:1, Classic 4:3, Vertical 9:16, Tall 3:4, Portrait 4:5 — and the editor preview + final export both reflow to match. The video is always letterbox-fit inside the chosen canvas (wallpaper fills any extra space).

## Non-Goals

- **No "Always keep zoomed in" toggle.** Cover-crop behavior is intentionally out of scope: if a user wants the video to fill a mismatched aspect, they use the existing manual zoom-region feature, which is more flexible than a single global toggle.
- **No custom W:H entry.** Seven fixed presets only.
- **No per-export override.** The aspect lives on the project and drives both preview and export from a single source of truth.
- **No keyboard shortcut for the picker.** Mouse-only for now.
- **No golden-image tests** for the new UI (codebase convention).

## Architecture Summary

One new enum, one new project-state field, one new pure resolver, one new UI widget. The resolver is the single source of truth for canvas dimensions, consumed by both the editor preview (`PlaybackCanvas`) and the export pipeline (`FrameCompositor`).

```
EditorProjectState.outputAspect: OutputAspect  (new field)
                       │
                       ▼
           OutputCanvasResolver.resolve()   ← pure helper, new file
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
  PlaybackCanvas                FrameCompositor
  (editor preview)               (export)
```

`WindowFrame` is untouched. Aspect-scaling of horizontal padding is removed from `FramePainter` — padding becomes uniform now that aspect is explicit.

## Model Layer

### `OutputAspect` enum

New file: `packages/slipreel_engine/lib/models/output_aspect.dart`.

```dart
enum OutputAspect {
  auto,
  wide16x9,
  square1x1,
  classic4x3,
  vertical9x16,
  tall3x4,
  portrait4x5;
}
```

Each variant exposes:
- `double? ratio` — `width / height`, or `null` for `auto` (resolved against the source video at render time).
- `String label` — the human-readable name shown in the picker (`"Auto"`, `"Wide 16:9"`, etc.).
- A serializable name (the enum `name` getter is sufficient — used in JSON).

### `EditorProjectState`

Add a new field `outputAspect: OutputAspect` with default `OutputAspect.auto`.

- Round-trips through `toJson` / `fromJson` as a string (the enum's `name`).
- Existing projects without the field deserialize to `auto` — preserves their current canvas shape.

### `EditorProjectController`

Add `setOutputAspect(OutputAspect value)` that calls `state = state.copyWith(outputAspect: value)`. Flows through the existing debounced project-save pipeline; no new persistence wiring.

## Renderer Layer

### `OutputCanvasResolver`

New file: `packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart`.

```dart
class ResolvedCanvas {
  final Size canvasSize;
  final Rect videoRect;   // where the video sits inside the canvas
}

class OutputCanvasResolver {
  static ResolvedCanvas resolve({
    required Size videoSize,
    required EdgeInsets padding,    // from WindowFrame.padding, applied uniformly
    required OutputAspect aspect,
  });
}
```

**Algorithm:**

1. **Resolve target aspect ratio.** `auto` → `videoSize.width / videoSize.height`. Otherwise the enum's numeric ratio.
2. **Compute padded inner region.** Apply `padding` as a uniform inset around the video. The result is a rect of size `(videoSize.width + padding.horizontal, videoSize.height + padding.vertical)`. This is where the video + its breathing room sit.
3. **Grow the outer canvas to match the target aspect.**
   - Inner region aspect = `paddedSize.width / paddedSize.height`.
   - If `targetAspect > innerAspect`: canvas needs to grow horizontally. Final canvas = `(paddedHeight * targetAspect, paddedHeight)`.
   - If `targetAspect < innerAspect`: canvas needs to grow vertically. Final canvas = `(paddedWidth, paddedWidth / targetAspect)`.
   - If equal: canvas = padded inner region.
4. **Place the inner region centered in the canvas.** Compute `innerOffset = ((canvas.width - paddedWidth) / 2, (canvas.height - paddedHeight) / 2)`.
5. **Place the video inside the inner region at the padding inset.** `videoRect = Rect.fromLTWH(innerOffset.dx + padding.left, innerOffset.dy + padding.top, videoSize.width, videoSize.height)`. The video itself is aspect-preserved — it never stretches.
6. Return `ResolvedCanvas(canvasSize, videoRect)`.

### `FramePainter`

`FramePainter.calculateTotalSize(frame, videoSize)` is refactored to delegate to `OutputCanvasResolver.resolve(...)`. It now also needs the `OutputAspect` — signature changes to `calculateTotalSize({frame, videoSize, aspect})`.

`FramePainter.effectivePadding(...)` (the aspect-scaling helper) is removed. Padding becomes uniform — the value stored on `WindowFrame.padding` is now interpreted as literal pixel insets on each side, not "vertical with implicit horizontal scaling."

**Behavior preservation:** for projects with `OutputAspect.auto` and zero-or-symmetric padding, the canvas shape stays equal to the video aspect. For projects with non-zero padding, existing projects will see horizontal padding shrink slightly on wide videos (aspect-scaling removed). This is an accepted minor visual regression; the model is cleaner and the gap is rarely noticed since most projects use small padding values.

## UI Layer

### `AspectRatioPicker` widget

New file: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart`.

A compact button styled like the reference screenshot:
- **Leading icon** — a rectangle glyph; rotates to portrait for vertical ratios (9:16, 3:4, 4:5). For `auto`, shows a neutral "aspect" icon.
- **Label** — the variant's display label (`"Auto"`, `"Wide 16:9"`, `"Vertical 9:16"`, …).
- **Trailing chevron** — ▼ to indicate a dropdown.
- **On tap** — opens a Material 3 `MenuAnchor` listing all 7 options with a checkmark next to the active one. Each `MenuItemButton` shows the icon, name, and ratio text (e.g., `"Wide 16:9"`).

The widget takes `(OutputAspect current, ValueChanged<OutputAspect> onChanged)` and is self-contained — no Riverpod or state inside; parent wires it.

### `CanvasToolbar` host

New file: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart`.

A centered horizontal `Row` that hosts `AspectRatioPicker`. Designed to fit future entries (Mask, Frame quick-pick, etc.) without restructuring. Visual budget ~36–40px tall, centered above the playback canvas.

### `PlaybackScreen` integration

- Reads `outputAspect` from `editorProjectStateProvider`.
- Inserts `CanvasToolbar` directly above the existing `PlaybackCanvas` area in the editor layout.
- On change: `ref.read(editorProjectControllerProvider.notifier).setOutputAspect(...)`. The existing debounced project-state push handles persistence.
- Passes `outputAspect` to `PlaybackCanvas` as a new prop. `PlaybackCanvas` forwards it to `OutputCanvasResolver.resolve(...)` when computing layout.

## Export Wiring

`FrameCompositor` (in `slipreel_engine/lib/export/frame_compositor.dart`):

1. Reads `projectState.outputAspect`.
2. Calls `OutputCanvasResolver.resolve(videoSize, padding, aspect)` — same call signature as the editor preview.
3. Uses `resolved.canvasSize` as the logical canvas dimensions (then scaled to `ExportSettings.resolution` for the final pixel size).
4. Draws the video into `resolved.videoRect` (centered, letterbox-fit). Wallpaper, shadows, inset ring continue to come from `FramePainter`, targeting `resolved.videoRect` instead of the old padding-derived rect.

**`ExportSettings.resolution` semantics stay unchanged:** `targetHeight` (720 / 1080 / 4K) sets the exported video's height; width scales from the canvas aspect ratio (instead of the source video aspect ratio, as today). 16:9 export at 1080p → 1920×1080; 9:16 export at 1080p → 608×1080. No new export-dialog control. The single behavior change is that `targetHeight`'s "source aspect" is now the resolver's canvas aspect, not the raw video aspect — invisible for `auto` projects (canvas aspect = video aspect), the expected behavior for explicit ratios.

**Single source of truth:** `OutputCanvasResolver.resolve(...)` is the only function in the codebase that knows how aspect + padding + video size combine into canvas dimensions. Preview and export call it identically; pixel results match (modulo the final resolution scale).

## Persistence

`EditorProjectState.outputAspect` round-trips through the existing `toJson` / `fromJson` mechanism:

- `toJson`: writes `'outputAspect': outputAspect.name`.
- `fromJson`: reads the string, defaults to `OutputAspect.auto` if missing or unrecognized — guarantees old project files open unchanged.

No migration script needed.

## Testing

### Model tests

`packages/slipreel_engine/test/models/output_aspect_test.dart`:
- `ratio` getter returns the correct `width / height` for each non-auto variant.
- `auto.ratio` returns `null`.
- Enum serializes via `name` and deserializes via `OutputAspect.values.byName` (round-trip).

`packages/slipreel_engine/test/state/editor_project_state_test.dart` (extend existing):
- `outputAspect` defaults to `auto`.
- JSON round-trip preserves `outputAspect` for each variant.
- JSON without `outputAspect` field deserializes to `auto`.

### Resolver tests

`packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart`:
- `auto` + 1000×1000 video + zero padding → canvas = 1000×1000, videoRect = (0,0,1000,1000).
- `auto` + 1920×1080 + uniform 50px padding → canvas = 2020×1180, videoRect = (50,50,1920,1080).
- `wide16x9` on 1000×1000 video, zero padding → canvas ≈ 1778×1000 (16:9), videoRect centered horizontally with wallpaper bars on left/right.
- `vertical9x16` on 1920×1080 video, zero padding → canvas = 1920×3413 (9:16), videoRect centered vertically.
- `square1x1` on 1920×1080 video, zero padding → canvas = 1920×1920, videoRect centered vertically.
- `vertical9x16` on 1920×1080 video + 50px padding → padded inner = 2020×1180; canvas grows to 9:16 around it; videoRect = (50, …, 1920, 1080).

### UI tests

`packages/screen_recorder/test/ui/widgets/canvas_toolbar/aspect_ratio_picker_test.dart`:
- Renders the current label and a chevron.
- Tap opens the menu with 7 entries.
- Active entry shows a checkmark.
- Tapping a different entry fires `onChanged` with the right enum value.

### Export integration test

Extend `packages/slipreel_engine/test/export/frame_compositor_test.dart` with one new case:
- Project with `outputAspect: OutputAspect.vertical9x16` and a 1920×1080 source — exported frame's logical dimensions match the resolver's expected canvas size (then verify pixel dimensions after `ExportSettings.resolution` scaling).

## Files Created / Modified

**Create:**
- `packages/slipreel_engine/lib/models/output_aspect.dart`
- `packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart`
- `packages/slipreel_engine/test/models/output_aspect_test.dart`
- `packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart`
- `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart`
- `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart`
- `packages/screen_recorder/test/ui/widgets/canvas_toolbar/aspect_ratio_picker_test.dart`

**Modify:**
- `packages/slipreel_engine/lib/state/editor_project_state.dart` — add `outputAspect` field + JSON round-trip.
- `packages/slipreel_engine/lib/state/editor_project_controller.dart` — add `setOutputAspect`.
- `packages/slipreel_engine/lib/rendering/frame_painter.dart` — refactor `calculateTotalSize` to use `OutputCanvasResolver`; remove `effectivePadding` aspect-scaling.
- `packages/slipreel_engine/lib/export/frame_compositor.dart` — call `OutputCanvasResolver.resolve` for canvas + video rect.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — accept `outputAspect`, route through resolver.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — insert `CanvasToolbar` above canvas, wire `setOutputAspect`.
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` — cover new field.
- `packages/slipreel_engine/test/export/frame_compositor_test.dart` — extend with vertical-aspect case.
- `packages/slipreel_engine/test/rendering/frame_painter_test.dart` — adjust to the new signature.

## Open Risks

- **Padding regression on existing projects.** Removing aspect-scaling shrinks horizontal padding on wide videos. Accepted; the trade-off buys a cleaner mental model.
- **Canvas resize on first pick.** Switching from `auto` to a different ratio visibly resizes the editor preview. This is the intended behavior, not a bug.
