# Zoom Manual Placement — Design

**Status:** brainstormed 2026-05-31, awaiting user review before plan.
**Scope:** Editor-side feature. Adds a visual placement picker to the zoom
inspector so users can position the focal point of a manual zoom region.
No native code, no model changes, no migrations.

## Motivation

`ZoomRegion` already supports a `followCursor: false` mode where the camera
locks onto `rect.center` for the whole region. There is currently **no UI
to set that center directly** — the rect is either auto-derived by
`AutoZoomDetector` from click locations (sub-project D) or stays at
whatever value the region was created with. Users who want
ScreenStudio-style "zoom into this part of the screen" workflows have to
edit project JSON by hand.

This sub-project closes that gap by adding a small mini-frame placement
picker to the zoom inspector that lives next to the existing zoom
properties.

## Non-goals

- New region creation flows. Regions are still added via timeline tap
  (existing); the placement picker only edits the rect of a selected,
  already-existing region.
- Auto-flow tuning. The picker is hidden when `followCursor: true`.
  Adjusting the bounding area of auto-flow zooms is deferred.
- Resize / zoomLevel coupling. Rect size stays derived from
  `videoSize / zoomLevel`; the existing slider is the single control for
  zoom strength.
- Thumbnail backgrounds. The mini-frame is a neutral fill in v1. A
  video-frame snapshot is a possible follow-up.
- Snapping to cursor positions, gridlines, or other anchors. Free
  movement only.
- Creating manual regions by drag-on-canvas. Reserved for future work.
- Touch / iOS support. Editor is macOS-only today; mouse / trackpad
  gestures only.

## Decisions

The brainstorm settled the following before this spec was written:

- **Modes covered:** placement picker is shown only when the selected
  region has `followCursor: false`. Auto-flow regions are unchanged.
- **Resize:** none. Rect size is derived from `videoSize / zoomLevel`.
  The existing slider remains the sole zoom-strength control.
- **When interactive:** any time a manual region is selected, including
  during playback. No pause-gating.
- **Live preview:** while the user drags, the main playback canvas
  zooms into the framing at the dragged center in real time.
- **Initial rect on `followCursor` toggle:** unchanged. We do not
  reset, re-center, or snap to the recorded cursor.

## User flow

1. User selects a zoom region on the editor timeline (existing).
2. The right-side inspector shows `ZoomContextInspector` (existing).
3. The inspector reads `selectedRegion.followCursor`:
   - **true** — no change. Existing follow-mode controls are shown.
   - **false** — a new **"Placement"** section is rendered above
     "Zoom level", containing the picker.
4. The picker shows a 16:9 mini-frame; inside it, a smaller inner
   rectangle represents the framing (size = mini-frame ×
   `1 / zoomLevel`).
5. User drags the inner rectangle inside the mini-frame. While the drag
   is in flight, the main playback canvas live-previews the framing.
6. On drag release, the new rect is committed via
   `EditorProjectController.updateZoomAt`.

## Architecture

Three new units, each independently testable:

### 1. `ZoomPlacementPicker` — pure widget

Path: `packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart`

```dart
class ZoomPlacementPicker extends StatefulWidget {
  final Size videoSize;          // e.g. 1920×1080
  final Rect rect;               // current focal rect in video coords
  final double zoomLevel;        // for inner-rect size derivation
  final ValueChanged<Rect> onPreview;   // fires on each drag move
  final ValueChanged<Rect> onCommit;    // fires once on drag end
}
```

Responsibilities:
- Render a mini-frame whose aspect ratio matches `videoSize`
  (`videoSize.width / videoSize.height` — not assumed 16:9, so
  vertical recordings render correctly). Max width 280 logical px;
  height derived from aspect.
- Render an inner rectangle proportional to the framing area
  (`videoSize / zoomLevel`), positioned at `rect.center` mapped to
  mini-frame coordinates.
- Convert pan-gesture deltas (Flutter logical pixels in mini-frame
  space) into video-coordinate deltas via the mini-frame's local scale
  factor.
- Compute a new `Rect.fromCenter(center: dragged, size: videoSize / zoomLevel)`
  on each pan update, clamp it so the rect lies fully within `videoSize`,
  emit `onPreview(newRect)`.
- On pan end, emit `onCommit(finalRect)` exactly once.

Has no Riverpod, no async, no platform calls. Test with `WidgetTester`
alone.

### 2. `ZoomPreviewOverride` — small in-memory state

Path: `packages/screen_recorder/lib/state/zoom_preview_override.dart`

```dart
class ZoomPreviewOverride extends ValueNotifier<ZoomRegion?> {
  ZoomPreviewOverride() : super(null);
}
```

A single `ValueNotifier<ZoomRegion?>` owned by `_PlaybackScreenState`.
Semantics: when non-null, this region replaces the result of
`ZoomRegion.activeAt(playhead, regions)` for canvas rendering. Cleared
on commit and on selection change.

### 3. Integration in `playback_screen.dart` + `playback_canvas.dart`

- `_PlaybackScreenState` constructs and owns a `ZoomPreviewOverride`.
- The inspector receives two callbacks from the screen:
  - `onPlacementPreview(Rect newRect)` — builds a transient
    `ZoomRegion` matching the selected region but with the new
    `rect`, writes it to the override notifier.
  - `onPlacementCommit(Rect newRect)` — calls
    `_projectController.updateZoomAt(index, region.copyWith(rect: newRect))`
    and clears the override.
- `PlaybackCanvas` receives the override notifier as an optional param.
  In its existing "find active region" lookup it checks the override
  first; if non-null, that region is used as the active region for
  this frame. Otherwise the normal `activeAt` path runs.
- `_PlaybackScreenState` clears the override whenever
  `_selectedZoomIndex` changes (covers "user deselects mid-drag" and
  "user clicks a different region while dragging").

The existing `ZoomFocalController` already spring-damps focal target
changes, so the in/out tween when the override is set / cleared comes
for free — no extra animation code.

### Coordinate model

The picker works in three spaces; all conversions live inside the picker
widget:

- **Video space** — `Rect` and `Size` in pixels, e.g. 1920×1080.
  `ZoomRegion.rect` is in video space.
- **Mini-frame space** — Flutter logical pixels inside the picker
  widget's `RenderBox`. Since the mini-frame matches the video's
  aspect ratio, a single scale factor
  `s = miniFrameWidth / videoSize.width`
  (equivalently `miniFrameHeight / videoSize.height`) converts both
  axes uniformly. Holds for any aspect (16:9, 9:16, ultrawide).
- **Inner rect size** — `videoSize / zoomLevel`, then × `s` for display.

Pan-gesture `localPosition` is in mini-frame space; multiplying by
`1/s` recovers video coordinates for the new rect center.

## Failure modes & edge cases

| Case | Behaviour |
|------|-----------|
| `zoomLevel == 1.0` | Inner rect fills the mini-frame; drag emits no-op rects (clamp keeps center anchored). UI still renders the picker. |
| `videoSize.isEmpty` (video not yet measured) | Picker section is hidden until dimensions are known. Inspector logs one debug message at `AppLogger.ui.d`. |
| Drag during video buffering / seek | Override is set in memory; canvas applies it on next paint. No special-casing needed. |
| Region deleted / deselected mid-drag | Picker widget unmounts → Flutter cancels its pan recogniser. Override is cleared by the selection-change listener. |
| Window resize during drag | Picker re-measures its `RenderBox` on the next frame; subsequent drag math uses the new scale. No state to invalidate. |
| Rect would leave video bounds | Picker clamps before emit. `ZoomRegion` constructor's `_constrainRect(rect, videoBounds)` clamps again at commit. |
| Stale rect after `followCursor` toggle (e.g. rect was sized for 1.5× when slider now reads 3×) | Picker renders the rect at its stored size. First drag normalises it to `videoSize / zoomLevel`. We do **not** auto-normalise on toggle. |

## Test plan

Pure-Dart / Flutter widget tests only — no integration, no native.

1. **`ZoomPlacementPicker` coordinate mapping**
   - Given videoSize 1920×1080, zoomLevel 2×, pan to mini-frame
     center → emitted rect center ≈ (960, 540).
   - Same setup, pan to mini-frame top-left → emitted center clamps to
     (480, 270) (half-size in each dimension).

2. **`ZoomPlacementPicker` clamping**
   - Pan past the mini-frame edge → emitted rect stays inside video
     bounds.

3. **`ZoomPlacementPicker` emit cadence**
   - Three pan updates + one pan end → `onPreview` fires 3 times,
     `onCommit` fires once.

4. **`ZoomPreviewOverride` short-circuit**
   - Unit test on the canvas's active-region lookup helper: with
     override set, it returns the override regardless of playhead.

5. **Inspector visibility gating**
   - `ZoomContextInspector` widget test: with `followCursor: true`, no
     placement section. With `followCursor: false`, section present.

6. **Inspector handles missing videoSize**
   - With `videoSize == Size.zero`, no placement section. With a
     non-empty size, section appears.

7. **`_PlaybackScreenState` integration**
   - On `onPlacementCommit`, the project controller's
     `updateZoomAt` is called with the expected (`copyWith(rect:)`).
   - On selection change while override is set, override clears.

No new file system access, no network, no async beyond what existing
tests already use. Total new test count: ~10.

## Files changed

**Created:**
- `packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart`
- `packages/screen_recorder/lib/state/zoom_preview_override.dart`
- `packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart`
- `packages/screen_recorder/test/state/zoom_preview_override_test.dart`

**Modified:**
- `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`
  — adds the "Placement" section when `followCursor: false`.
- `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
  — threads two new callbacks (`onPlacementPreview`, `onPlacementCommit`)
  and `videoSize` down to `ZoomContextInspector`.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
  — constructs the override notifier, wires the two callbacks, clears
  on selection change.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
  — accepts the override notifier as an optional param, consults it
  before `ZoomRegion.activeAt(playhead, ...)`.

No model changes. `ZoomRegion`, `EditorProjectController`,
`ZoomFocalController` untouched.

## Risks & mitigations

- **Override + selection race.** If selection changes while a pan is
  in flight, we could leave the override set. Mitigation: explicit
  `selectedZoomIndex` listener in `_PlaybackScreenState` that clears
  the override on any change. Test 7 covers this.
- **Coordinate-mapping bugs.** Easy to get scale factors wrong in
  either direction. Mitigation: tests 1–2 pin both directions
  (mini-frame → video and clamp).
- **Live preview flicker on heavy frames.** The override is read once
  per frame by the canvas; no flicker risk above the existing
  rendering pipeline's normal behaviour.

## v2 candidates (out of scope here)

- Mini-frame thumbnail using the existing thumbnail capture pipeline.
- Drag-on-canvas to create a new manual zoom region directly.
- Auto-flow rect-area editing (the bounding area within which the
  camera roams).
- Numeric input for the focal coordinates.
- Snap-to-cursor when dragging (snap to nearest recorded cursor
  position at the region's startTime).
