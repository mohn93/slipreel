# Architecture Review — 2026-05

Multi-agent sweep covering: zoom/cursor motion pipeline, rendering pipeline,
export pipeline, state management, UI layer, and top-level package
architecture. Findings consolidated below; checkboxes track ongoing fixes.

---

## Cross-cutting themes

### 1. Duplicate "render the scene" pipelines — **critical**

Live preview (`PlaybackCanvas.build`) and export (`FrameCompositor.compose`)
are parallel implementations of the same scene-state plumbing. They have
already silently drifted:

- Export omits `cursorVelocity` → bounded gate releases too early →
  export camera path differs from preview (`frame_compositor.dart:148-153`).
- Export uses legacy `CursorOverlayPainter`; preview uses
  `AccumulationCursorPainter` → cursor blur is not WYSIWYG
  (`frame_compositor.dart:532-549`).
- Export omits `clickSpring` → press-pulse differs.
- Zoom-level `TweenAnimationBuilder` is widget-only → mid-region zoom
  tweens don't render in export.
- `PlaybackCanvas._subFrameTransformAt` / `_approxSceneSampleAt`
  (`playback_canvas.dart:954-1064`) re-implement focal math statelessly
  — third copy of "where is the camera at t".

### 2. God-objects — **critical**

- `_PlaybackScreenState`: 1374 lines, ~25 mutable fields, **42 `setState`
  calls**; every slider tick rebuilds the entire screen including the
  PlaybackCanvas.
- `MotionBlurPlaygroundScreen`: 1820 lines.
- `InspectorPanel`: 30+ constructor params (prop-drill at maximum).
- `screen_recorder` package: 105 Dart files mixing engine + shell.
- `FrameCompositor.compose()`: 180-line monolith.
- `_resolveTarget` mutates `_inFlight` (resolver with side effects).

### 3. State architecture half-finished — **critical**

- Recording uses Riverpod `StateNotifier` (clean).
- Editor uses raw `setState` god-object.
- `FrameSettingsProvider` uses `ChangeNotifier` per-screen.
- `UndoRedoController` exists but **only tracks trim** — Cmd-Z silently
  does nothing for zoom/animation/cursor edits. The undo UI is a lie.
- `_ClipLocalState` (playback speed, fade) is inspector-local — silently
  lost on rebuild.
- No timeline / multi-track model — captions, audio, multi-clip cannot
  be added without re-architecting.

### 4. Three cursor painters with diverged logic — **major**

`CursorRenderer` (export), `AccumulationCursorPainter` (preview blur),
`CursorOverlayPainter` (preview shader + legacy export). Ripple,
sprite baking, diameter math, coordinate mapping duplicated 3×.

- **Export ripple anchored to current cursor, not click position**
  (`cursor_renderer.dart:83-92`) — same bug already fixed in preview is
  still shipping in MP4 exports.
- **Accumulation press-pulse lost on cached sprites** — sprite cache key
  omits `microsSinceClick` (`accumulation_cursor_painter.dart:402-446`).
- `CursorOverlayPainter` re-bakes the sprite via `toImageSync` every
  frame on the motion-blur branch (`:249-276`).

### 5. Layer violation: export ↔ UI — **major**

`lib/export/frame_compositor.dart:20-22` imports
`ui/widgets/cursor_overlay_painter.dart` + `ui/widgets/zoom/*`. The
headless render pipeline depends on the widget tree. Blocks any future
headless CLI exporter, cloud worker, or engine extraction.

### 6. Performance hotpaths — **major**

- `mostRecentClickEvent` / `microsSinceRelease` walk the entire cursor
  recording every frame, per painter (`cursor_click_effect.dart:52-107`).
  O(N) × 3 painters × 60fps.
- `shouldRepaint` compares closures (`focalAt`, `scaleAt`) by identity →
  permanently true on every parent rebuild
  (`accumulation_cursor_painter.dart:82-84, 384-385`).
- `compose()` does 3× `PictureRecorder → toImage` per frame even when
  no scene blur is active.

### 7. Tuning buried — **major**

16+ hand-tuned magic numbers scattered across 4 files. Designer
iteration loop is "edit Dart → recompile → relaunch" for every tweak.
No JSON / preset profiles.

---

## Concrete bugs (verified by reviewers)

| # | Bug | File:line | Severity |
|---|---|---|---|
| 1 | Export ripple anchored to current cursor not click pos | `cursor_renderer.dart:83-92` | High — ships in MP4 |
| 2 | Export bounded-mode gate releases early (`cursorVelocity = 0`) | `frame_compositor.dart:148-153` | High — silent path divergence |
| 3 | Export uses legacy `CursorOverlayPainter` not `AccumulationCursorPainter` | `frame_compositor.dart:532-549` | High — WYSIWYG break |
| 4 | Accumulation press-pulse lost on cached sprites | `accumulation_cursor_painter.dart:402-446` | High |
| 5 | Undo only covers trim; zoom/anim/cursor edits silently ignored | `playback_screen.dart:70,158,233` | High — broken UI affordance |
| 6 | `_ClipLocalState` (speed/fade) never persists | `inspector_panel.dart:182,408-412` | Medium — silent data loss |
| 7 | Deadzone centered on lagging `currentFocal` not target → slow-cursor flap | `zoom_focal_controller.dart:484-489` | Medium |
| 8 | Hold detection by `Offset` equality → fp residual flips damping mid-frame | `zoom_focal_controller.dart:359` | Medium |
| 9 | `shouldRepaint` permanently true from lambda identity | `accumulation_cursor_painter.dart:82-84` | Medium |
| 10 | Scrub threshold mismatch: canvas 100 ms vs focal 200 ms | `playback_canvas.dart:367-375` vs `zoom_focal_controller.dart:93` | Low |

---

## Product / scalability risks

- **FFmpeg shelled out, not bundled** — every shipped build needs
  OS-specific binaries + correct licensing (pubspec.yaml has a TODO).
- **No auth/licensing, no crash reporting, no telemetry sink** —
  Sentry/Crashlytics/etc. all absent.
- **Windows/Linux platform packages exist but aren't wired** — only
  macOS is in `pubspec.yaml`, despite CI claiming to test all three
  on Flutter 3.16.0 (ancient).
- **No schema migration switchboard** — `EditorProjectState.fromJson`
  has a "throw if newer" guard and field-level defaults, no
  `_v1to2`/`_v2to3` chain. First rename breaks loads.
- **Stock `flutter_lints`, no import-boundary enforcement** — nothing
  prevents the export-imports-ui leak from recurring.
- **No timeline container** — `EditorProjectState` is a flat
  single-clip bag. Captions, audio tracks, multi-clip all blocked.

---

## Refactor roadmap

P0 = retires the largest class of bugs / unblocks future surfaces.
P1 = high-leverage but narrower. P2 = scaffolding for product growth.

### P0 — fixes recurring preview/export drift class of bugs

- [x] **P0-1 — Unified scene builder** (Task #239)
  `ScenePassBuilder` in `lib/rendering/scene_pass_builder.dart` owns
  the `CursorMotionController`, `ZoomFocalController`, and
  `EmaVelocityFilter`. Returns a `ScenePass` with `(motion, activeZoom,
  cursorForFocal, focalUpdate, rawCursorVelocity,
  filteredCursorVelocity)`. Both `FrameCompositor.compose()` and
  `PlaybackCanvas.build()` now call it. **Closes bug #2** (export was
  passing `cursorVelocity = 0` to the bounded gate). Bugs #1, #3, and
  the zoom-tween divergence are unblocked but not yet fixed — they
  live in the painter selection / TweenAnimationBuilder layer above
  the builder.

- [ ] **P0-2 — Editor state to Riverpod Notifier** (Task #240) — _foundation landed_
  Two foundation pieces are in:
  - `EditorProjectState.copyWith(...)` for immutable field-by-field
    updates (5 tests in `test/state/editor_project_state_test.dart`).
  - `EditorProjectController extends StateNotifier<EditorProjectState>`
    with per-field mutators + zoom-region list ops + Riverpod provider
    (5 tests in `test/state/editor_project_controller_test.dart`).

  **Still to do**: migrate `_PlaybackScreenState` to consume the
  controller (swap each `_field = ...; setState(...)` with
  `ref.read(editorProjectControllerProvider.notifier).setX(...)`);
  switch the InspectorPanel to read via `ref.watch(...select(...))`
  instead of taking 30 props. Big surface area; deferred to a
  follow-up commit so this branch can ship the foundation cleanly.

- [x] **P0-3 — Engine layer separation** (Task #241) — _phase 1_
  Within `screen_recorder`, the engine-layer directories
  (`models/`, `rendering/`, `effects/`, `export/`, `state/`) no longer
  import anything from `lib/ui/`. Three files moved out of
  `lib/ui/widgets/` into `lib/rendering/`:
  `cursor_motion_controller.dart`, `zoom_focal_controller.dart`,
  `cursor_overlay_painter.dart`. A boundary test
  (`test/architecture/engine_layer_boundary_test.dart`) fails CI if
  any engine file imports from `lib/ui/`. **Phase 2** (physical
  extraction into a sibling `slipreel_engine` package) is now
  mechanical — every engine import is portable — and will land as a
  follow-up.

### P1

- [ ] **P1-4 — Unified `paintCursor()` entry point** (Task #242) — _phase A landed (bug #1)_
  Phase A: introduced `CursorPaintRequest` + `paintCursorComposed(canvas, req)`
  in `lib/rendering/cursor_painter.dart`. Replaced the buggy
  `paintCursorWithEffects` convenience wrapper (which forced ripple
  and glyph to share one position). `CursorRenderer` now looks up the
  click event and passes `clickPosition` separately — **bug #1
  closed**. Phase B: fold accumulation press-pulse out of the sprite
  cache (bug #4) and add a sprite cache to the overlay painter to
  stop the per-frame `toImageSync` (bug #9).
- [ ] **P1-5 — `FollowStrategy` interface** (Task #243)
- [ ] **P1-6 — Cached cursor event lookups** (Task #244)
- [ ] **P1-7 — State-shaped undo/redo** (Task #245, blocked by P0-2)

### P2

- [ ] **P2-8 — Centralized tuning JSON + presets** (Task #246)
- [ ] **P2-9 — Schema migration switchboard** (Task #247)
- [ ] **P2-10 — Timeline container for multi-track** (Task #248)

---

## Progress log

(Append-only. Newest at top. Each entry: date — task ID — what changed
— commit SHA(s).)

- 2026-05-21 — review intake — created this doc + tasks #239–#248.
- 2026-05-21 — snapshot — committed ~7k-line in-flight focal/cursor iteration as `e88e593` to `main`; branched to `refactor/p0-1-unified-scene-builder`. Test baseline: 514 pass / 14 skip.
- 2026-05-21 — P0-1 landed — extracted `ScenePassBuilder` (new file `lib/rendering/scene_pass_builder.dart`, 7 new tests in `test/rendering/scene_pass_builder_test.dart`). Wired into `FrameCompositor` + `PlaybackCanvas`. **Bug #2 fixed**: export's bounded-mode gate now sees `cursorVelocity` and behaves identically to preview. Test result: 521 pass / 14 skip (+7 new, zero regressions).
- 2026-05-21 — P0-3 phase 1 — moved `cursor_motion_controller.dart`, `zoom_focal_controller.dart`, `cursor_overlay_painter.dart` from `lib/ui/widgets/` into `lib/rendering/`. Engine-layer directories (`models`, `rendering`, `effects`, `export`, `state`) are now UI-free. Added `test/architecture/engine_layer_boundary_test.dart` to enforce the boundary. Test result: 522 pass / 14 skip (+1 new). Phase 2 (sibling-package extraction) deferred to follow-up.
- 2026-05-21 — P0-2 foundation — added `EditorProjectState.copyWith` and `EditorProjectController` (StateNotifier) + `editorProjectControllerProvider` (Riverpod). 10 new tests in `test/state/editor_project_{state,controller}_test.dart`. Migration of `_PlaybackScreenState` and the inspector to consume the controller is deferred — that's a 1000-line touch on the largest screen and warrants its own dedicated session. Test result: 532 pass / 14 skip (+10 new).
- 2026-05-21 — P0-1 + P0-3 + P0-2 foundation merged to main; new working branch `refactor/p1-4-unified-cursor-painter`.
- 2026-05-21 — P1-4 phase A — added `CursorPaintRequest` + `paintCursorComposed` in `lib/rendering/cursor_painter.dart` (4 tests in `test/rendering/cursor_painter_test.dart`). Deleted the buggy `paintCursorWithEffects` wrapper. Updated `CursorRenderer` to look up the click event and pass `clickPosition` to the new API — **bug #1 closed** (exported MP4s no longer drag the ripple along with the cursor). Test result: 536 pass / 14 skip (+4 new).
