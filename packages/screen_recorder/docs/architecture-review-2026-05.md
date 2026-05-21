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

- [x] **P0-2 — Editor state to Riverpod Notifier** (Tasks #240, #251) — _steps 2 + 3 landed_
  Foundation (commit `23a544a`): `EditorProjectState.copyWith` +
  `EditorProjectController` + provider.
  Step 2: `_PlaybackScreenState` is now a `ConsumerStatefulWidget`
  that reads editor state from the notifier in `build()` (single
  `ref.watch`) and routes every inspector callback to a notifier
  mutator. The `ref.listen` auto-fires `_persistProject()` on every
  publish, replacing ~30 inline `_persistProject()` calls. 14
  editor-state private fields drained; `_captureProjectState` deleted
  (the notifier's state *is* the captured form). 6 setState calls
  removed; the remaining ones are for non-editor session UI
  (`_isHovering`, `_selectedZoomIndex`, etc.).
  Step 3: `CursorTab` and `AnimationTab` are now
  `ConsumerStatefulWidget`s that read directly from the notifier and
  mutate via tear-off references to the controller's setters.
  `InspectorPanel`'s constructor shrank from 30+ params to 8.

- [x] **P0-3 — Engine layer extraction** (Tasks #241, #249) — _both phases done_
  Phase 1 (commit `b6834a2`): within `screen_recorder`, the
  engine-layer directories stopped importing from `lib/ui/`. Three
  files moved out of `lib/ui/widgets/` into `lib/rendering/`.
  Phase 2: physical extraction. `packages/slipreel_engine` now owns
  `models/`, `rendering/`, `effects/`, `export/`, `utils/`, the
  engine subset of `state/`, and the shader assets.
  `screen_recorder` depends on it as a path package and contains only
  the app shell + recording control state + frame settings UI state.
  The boundary test moved to the engine package itself and now
  enforces "no `package:screen_recorder/*` imports from inside
  slipreel_engine" — a stricter rule than phase 1's "no
  `lib/ui/*` imports". Test split: slipreel_engine 381 pass,
  screen_recorder 164 pass / 14 skip (= 546 total, +1 new boundary test).

### P1

- [ ] **P1-4 — Unified `paintCursor()` entry point** (Task #242) — _phases A+B landed, C deferred_
  Phase A (commit `27de5c6`): `CursorPaintRequest` +
  `paintCursorComposed` in `lib/rendering/cursor_painter.dart`,
  replacing the buggy `paintCursorWithEffects` wrapper. `CursorRenderer`
  threads click position separately — **bug #1 closed**.
  Phase B (commit `f966371`): `AccumulationCursorPainter` applies
  press-pulse per-stamp as a destination-rect scale instead of trying
  to bake it into the cached sprite. `clickSpring` parameter added
  and wired from `PlaybackCanvas` — **bug #4 closed**.
  Phase C (deferred): bug #9 — `CursorOverlayPainter` re-bakes its
  sprite every frame on the motion-blur branch. Requires factoring
  the shadow rendering out of `paintCursorGlyphWithPulse` so the
  bake-once-stamp-many pattern can be applied here too. More invasive
  than #1/#4 and only matters when motion-blur is active. Tracked as
  a follow-up.
- [x] **P1-5 — `FollowStrategy` interface** (Task #243)
  `FollowStrategy` abstract class in `lib/rendering/follow_strategy.dart`
  with `resolve({zoom, cursor, cursorVelocity, currentFocal,
  videoSize, tuning}) → FollowResolution(target, isHolding)` plus a
  `reset()` hook for stateful strategies and an `inFlight` getter for
  the debug HUD. Three concretes: `BoundedFollowStrategy` (owns the
  gate state), `CenteredFollowStrategy` (stateless pass-through),
  `PredictiveFollowStrategy` (reuses centered logic). 10 tests in
  `test/rendering/follow_strategy_test.dart`.
  `ZoomFocalController` now caches strategies in a
  `Map<FollowMode, FollowStrategy>`, delegates per-frame target
  resolution to the active strategy, and reads `isHolding` from the
  strategy's explicit flag instead of `target == _smoothedFocal`
  (closes review bug #8). The `_inFlight` field on the controller
  is gone — gate state lives on `BoundedFollowStrategy`. `inFlight`
  getter for the HUD now delegates to the active strategy.
  Existing 50+ controller tests still pass with no changes
  (behavior preserved by construction).
- [x] **P1-6 — Cached cursor event lookups** (Task #244)
  Added `CursorEventIndex` on `CursorRecording`: lazy, version-keyed,
  rebuilds only after `addPosition`/`clear`. Exposes
  `lastClickAtOrBefore(t)` and `lastReleaseAtOrBefore(t)` via O(log N)
  binary search over pre-sorted timestamp lists.
  `mostRecentClickEvent`, `microsSinceClick`, `microsSinceRelease` now
  delegate to the index — same public API, no more O(N) walks per
  painter per frame. 7 tests in
  `test/models/cursor_event_index_test.dart` (empty recording, no
  click yet, multiple clicks, release sequence, cache invalidation,
  long recording binary-search correctness).
- [x] **P1-7 — State-shaped undo/redo** (Task #245)
  `EditorHistoryController` (new file
  `lib/state/editor_history_controller.dart` in slipreel_engine)
  subscribes to `EditorProjectController` and debounces mutations
  into a single history entry per `coalesceWindow` (500 ms default).
  `undo()`/`redo()` flush any pending coalesced edit, pop/push the
  generic `UndoRedoController<EditorProjectState>`, then apply the
  chosen entry via `controller.replace(...)` with an
  `_applyingHistory` guard so the resulting publish doesn't push
  recursively. Extends `ChangeNotifier` so toolbar buttons rebuild on
  history mutations even when a debounced push fires without a
  coincident editor publish. 8 tests in
  `test/state/editor_history_controller_test.dart` cover the floor
  semantics, coalescing, undo/redo round-trip, redo-stack clear on
  branched history, no-recursive-push during apply, pre-undo flush of
  pending edits, and the `ChangeNotifier` notify pattern.
  PlaybackScreen now uses this controller; the legacy
  `UndoRedoController&lt;TrimSelection&gt;` plumbing is gone. Trim
  selection rejoins undo when trim moves into `EditorProjectState`
  (P2-10).
  **Closes review bug #5** — the undo UI is no longer a lie.

### P2

- [x] **P2-8 — Centralized tuning JSON + presets** (Task #246) — _phases A+B landed_
  New `MotionTuning` immutable record in
  `slipreel_engine/lib/rendering/motion_tuning.dart` collects 8
  motion-feel knobs from across `ZoomFocalController` and
  `CursorMotionController` (reverse-scrub floor, sub-step caps,
  cursor-at-rest threshold, velocity lookback, feedforward strength
  + fade band). Named presets: `defaults` (historic production set
  — behavior-neutral), `snappy` (lower at-rest threshold + higher
  feedforward), `cinematic` (lower feedforward, more film-y lag).
  `toJson`/`fromJson` round-trip with partial-JSON fallbacks. Both
  controllers expose `tuning` via a constructor param defaulting to
  `MotionTuning.defaults`. 8 tests in
  `test/rendering/motion_tuning_test.dart`. **Phase B** (wire scene
  blur + zoom-region defaults), **Phase C** (JSON file load + hot-
  reload + UI preset picker) deferred.
- [x] **P2-9 — Schema migration switchboard** (Task #247)
  `EditorProjectState.fromJson` now routes through
  `migrateEditorProjectJson()` before reading fields. The migration
  chain is an ordered list (`_schemaMigrations`) of
  `Map<String, dynamic> Function(Map<String, dynamic>)` steps, one
  per `vN→vN+1` hop. Adding a new schema version: bump
  `currentSchemaVersion`, append a step, write a migration test.
  Today's chain has a no-op v0→v1 and a v1→v2 step that fills in the
  `schemaVersion: 2` marker for legacy sidecars that pre-date it.
  5 tests in `test/state/editor_project_state_migration_test.dart`
  cover missing-version, current-version pass-through, future-version
  refusal, chain composability, and explicit-v1 round-trip.
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
- 2026-05-21 — P1-4 phase B — fixed **bug #4** (accumulation press-pulse lost on cached sprites): `AccumulationCursorPainter` now applies the per-stamp press-pulse as a scale on the destination rect instead of trying to bake it into the cached sprite. Added `clickSpring` parameter to the painter, wired through `PlaybackCanvas`. 2 new tests in `test/effects/accumulation_cursor_painter_test.dart` (538 pass total).
- 2026-05-21 — P1-4 merged to main; new branch `refactor/p1-6-cached-cursor-events`.
- 2026-05-21 — P1-6 landed — replaced O(N) cursor-event walks with O(log N) indexed lookups. `CursorRecording` now exposes a lazily-built `CursorEventIndex` (version-keyed, rebuilds on mutation). 7 new tests in `test/models/cursor_event_index_test.dart`. Test result: 545 pass / 14 skip (+7 new, 0 regressions).
- 2026-05-21 — P0-3 phase 2 landed — extracted `packages/slipreel_engine`. Moved `models/`, `rendering/`, `effects/`, `export/`, `utils/`, the engine subset of `state/`, and shader assets out of `screen_recorder` into the new package. `screen_recorder` now depends on it via a path import. The boundary test moved to the engine package and was tightened to ban any `package:screen_recorder/*` import. Test result: slipreel_engine 381 pass / 0 skip; screen_recorder 164 pass / 14 skip (= 546 total).
- 2026-05-21 — P2-9 landed — schema migration switchboard. `EditorProjectState.fromJson` runs `migrateEditorProjectJson(...)` before field decoding. Chain has v0→v1 (no-op) and v1→v2 (insert schemaVersion marker). 5 tests in `test/state/editor_project_state_migration_test.dart`. Test result: 550 pass / 14 skip (+4 net new; one test was a clamp-bound correction).
- 2026-05-21 — P0-2 step 2 landed — `_PlaybackScreenState` converted to `ConsumerStatefulWidget`. 14 editor-state private fields drained into the Riverpod notifier; `_captureProjectState` deleted (notifier state IS the captured form); `_persistProject` now wired via `ref.listen` (replaces ~30 inline calls); ~6 setStates removed; InspectorPanel callbacks rewired to notifier mutators directly. Frame chrome mirrored from `FrameSettingsProvider` into the notifier on every change so persistence captures it. Test result: 550 pass / 14 skip across both packages (0 net new tests, 0 regressions). UI verification deferred to running the app.
- 2026-05-21 — P0-2 step 3 landed — `CursorTab` and `AnimationTab` converted to `ConsumerStatefulWidget`s reading editor state directly via `ref.watch(editorProjectControllerProvider)` and mutating via the notifier. `InspectorPanel` constructor shrank from 30+ params (state + callbacks) to 8 (frameSettings, width, initialTab, selection, zoomRegions, clipDuration, canHideCursor, curveLibrary + selection callbacks). Each tab now owns its own provider subscription, so a slider drag in the cursor tab no longer rebuilds the animation tab. Test result: 550 pass / 14 skip (0 net new, 0 regressions).
- 2026-05-21 — runtime verification — launched app on macOS arm64 (had to bypass FVM's x86_64 wrapper); first launch crashed at scene-blur frame because shader assets had moved with P0-3 phase 2 but the loaders still used bare paths. Three fixes landed in commit `9d9f1c3`: shader loaders now use `packages/slipreel_engine/shaders/...` with a bare-path fallback for the engine's own tests. App ran clean after that.
- 2026-05-21 — P1-7 landed — `EditorHistoryController` in slipreel_engine: ChangeNotifier wrapping `UndoRedoController<EditorProjectState>` with debounced coalescing (one history entry per slider drag, not per tick). 8 tests in `test/state/editor_history_controller_test.dart`. Wired into PlaybackScreen, replacing the broken trim-only undo. Test result: 558 pass / 14 skip across both packages (+8 new). **Bug #5 closed**.
- 2026-05-21 — P2-8 phase A landed — `MotionTuning` immutable record collects 8 spring/follow/feedforward constants from `ZoomFocalController` + `CursorMotionController` into one place. Named presets (`defaults`, `snappy`, `cinematic`) + JSON round-trip + per-field copyWith. Both controllers expose `tuning` via constructor param; `defaults` is the historic production set, so landing this is behavior-neutral. 8 tests. Test result: 566 pass / 14 skip across both packages (+8 new).
- 2026-05-21 — P1-5 landed — `FollowStrategy` pluggable interface (Bounded / Centered / Predictive) lifts per-mode logic out of `ZoomFocalController`. The controller becomes a pure spring integrator + strategy cache; the bounded gate's `_inFlight` field moves onto `BoundedFollowStrategy` (was inline on the controller). Hold detection now reads from the strategy's explicit `isHolding` flag instead of a fragile `target == _smoothedFocal` compare — **bug #8 closed**. 10 tests in `test/rendering/follow_strategy_test.dart`. Test result: 576 pass / 14 skip across both packages (+10 new).
- 2026-05-21 — P2-8 phase B landed — extended `MotionTuning` with 6 more fields: 5 scene-blur knobs (`sceneBlurExposureMs`, `sceneBlurMaxTranslation`, `sceneBlurSampleCount`, `sceneBlurSpeedCurveExp`, `sceneBlurSpeedCurveRefPx`) and `pauseStabilizeThreshold`. Replaced duplicated `static const _sceneBlur*` in both `FrameCompositor` (engine) and `PlaybackCanvas` (shell) with reads from `MotionTuning.defaults` — single source of truth, no duplicated tuning between preview and export. Same JSON / copyWith / defaults pattern as phase A. Behavior preserved. Test result: 576 pass / 14 skip (no net new tests, the existing tuning suite was extended).
