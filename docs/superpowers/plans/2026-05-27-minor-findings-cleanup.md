# Minor Findings Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Clear the deferred 🟡 Minor findings from the 2026-05-26 review (plus a few review-noted nits), per the user's decisions.

**Branch:** `cleanup/minor-findings` (off `main` after the Critical+Major remediation merged).

**Verification:** Engine/app via `flutter test` + `melos run analyze --no-select`. Native Swift via `xcodebuild -workspace packages/screen_recorder_macos/example/macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=x86_64' build` (no `flutter test` for Swift). `flutter build macos` is NOT broken (plain flutter 3.41.5) but isn't needed here.

## User decisions
- AudioTab background-music stub → **LEAVE AS-IS** (do not touch).
- motion_blur_playground → **gate behind kDebugMode** (unreachable/compiled-out in release).
- FrameSettingsProvider → **consolidate now** (Task 4).
- Legacy macOS spool path → **delete** (Task 5).

## Deliberately NOT changing (with rationale — these were review "minors" but fixing them is net-negative)
- **Model wire-key / toMap-vs-toJson naming** (e.g. `RegionSelection` emits `width`/`height`; `StockCursorImage` reads `hotX`): the Dart map KEYS must match what the native side sends/reads. Changing them risks breaking the Dart↔native contract for zero functional gain; method-name churn is cosmetic across many call sites. **Left unchanged.**
- **RecordingController wall-clock duration timer**: acknowledged "good enough" in code; reconciling against the encoder frame count is a behavior change, not cleanup. **Left.**
- **Podfile.lock tracking** / **wallpaper JPEG size**: intentional/inert. **Left.**
- **`os_unfair_lock` vs `NSLock`** (encoder): negligible uncontended overhead; plan mandated NSLock. **Left.**

---

## Task 1: Engine logic minors

**Files:** `packages/slipreel_engine/lib/export/bounded_async_queue.dart`, `lib/export/audio_mix_args.dart`, `lib/export/audio_streams.dart`, `lib/effects/ema_velocity_filter.dart`, `lib/export/frame_compositor.dart` (`_evenSize`), `lib/models/zoom_region.dart` + their tests.

- [ ] **Step 1: `BoundedAsyncQueue` O(1) dequeue.** Replace the `List` + `removeAt(0)` with `dart:collection`'s `Queue` (`removeFirst()`). Keep the public API + capacity/close semantics identical. Run `flutter test test/export/bounded_async_queue_test.dart` (existing edge-case tests must pass unchanged).

- [ ] **Step 2: `ZoomRegion.isActive` half-open interval.** Change `position >= startTime && position <= endTime` to `position >= startTime && position < endTime` (half-open `[start, end)`), removing the one-frame boundary ambiguity when two regions share an edge. Add a unit test asserting: active at `start`, inactive exactly at `end`, active just before `end`. Run the zoom_region tests + the export pipeline tests (confirm no zoom regression on the fixture).

- [ ] **Step 3: `AudioMix` filtergraph number formatting.** In `audio_mix_args.dart`, `_fracStr` currently uses `double.toString()` (can emit long decimals). Format to a stable short string (e.g. `toStringAsFixed(3)` then strip trailing zeros, or just `toStringAsFixed(3)`). Update the imprecise "200 = ~+6 dB" doc comment to be accurate (`volume=2.0` is +6.02 dB). Update `ffmpeg_encoder_args_test`/`audio_mix_args_test` expectations if the exact volume string changes (keep semantics; e.g. `1.0`, `1.5`, `2.0`).

- [ ] **Step 4: `inferAudioRoles` >2-stream guard.** In `audio_streams.dart`, when the fallback maps `streams[0]`→mic, `streams[1]`→system with >2 streams, add an `assert` (or a logged warning + comment) that >2 audio streams is unsupported/order-dependent. No behavior change for the 2-stream case.

- [ ] **Step 5: `_evenSize` centering + `EmaVelocityFilter` comment.** Fix `frame_compositor.dart` `_evenSize` so padding is computed from the rounded (even) size, keeping the video centered within the even canvas (no 1px offset). Add the one-line `EmaVelocityFilter` comment documenting that backward scrubs blend with `|dt|` (preview-only; export is monotonic) — comment only, no logic change.

- [ ] **Step 6:** Run `cd packages/slipreel_engine && flutter test` (full engine suite green) + `flutter analyze --no-fatal-infos`. Commit:
```bash
git commit -am "refactor(engine): minor cleanups (O(1) queue, half-open zoom, audio-arg formatting, guards)"
```

---

## Task 2: Engine — narrow flutter/material imports to dart:ui/painting

**Files:** the ~16 `packages/slipreel_engine/lib/**` files importing `package:flutter/material.dart`.

- [ ] **Step 1:** For each engine lib file that imports `package:flutter/material.dart`, determine what it actually uses (Color/Colors/Rect/Size/Offset/Canvas/Paint/CustomPainter/etc.) and replace the import with the narrowest that suffices — `dart:ui` and/or `package:flutter/painting.dart` (which re-exports `Colors`, painting primitives). Do NOT change any file that genuinely needs a widget-tree type (there should be none — confirm via the existing `test/architecture/engine_layer_boundary_test.dart`).
- [ ] **Step 2:** `cd packages/slipreel_engine && flutter analyze --no-fatal-infos` (no new errors; `unnecessary_import`/`depend_on_referenced_packages` infos for material should drop) + `flutter test` (full suite green, esp. the layer-boundary test). Update the engine `pubspec.yaml` description if it claims "zero Flutter widget-tree imports" — it's now literally true.
- [ ] **Step 3:** Commit:
```bash
git commit -am "refactor(engine): narrow flutter/material imports to dart:ui/painting (enforce headless)"
```

---

## Task 3: App lint config + recents parallelize + dev-screen gating

**Files:** `packages/screen_recorder/analysis_options.yaml`, `lib/ui/screens/recents_screen.dart`, `lib/ui/screens/recents/recording_card.dart` (the long-press entry), `lib/ui/screens/motion_blur_playground_screen.dart`.

- [ ] **Step 1: Lint rules.** Add a `linter: rules:` block to `analysis_options.yaml` enabling at least `unawaited_futures: true` (and `discarded_futures` if it stays quiet). Run `flutter analyze`. Fix the resulting violations (wrap fire-and-forget futures in `unawaited(...)` / await them). **If there are more than ~15 violations, STOP and report the count before mass-editing** (we may scope the rule to warning-not-error). Keep the analyzer green under `--no-fatal-infos`.

- [ ] **Step 2: `recents_screen._refresh` parallelize.** Replace the sequential `await File(...).exists()` loop with a `Future.wait` over the recordings (preserve ordering of the resulting list). Run the recents tests.

- [ ] **Step 3: Gate the dev playground behind `kDebugMode`.** The long-press entry that navigates to `MotionBlurPlaygroundScreen` (in the recents card / recents screen) must be wrapped so it only fires in debug: `if (kDebugMode) { ...navigate... }` (and remove/guard the gesture in release). The screen file can stay, but it must be unreachable in a release build. Confirm no release code path reaches it.

- [ ] **Step 4:** `cd packages/screen_recorder && flutter analyze --no-fatal-infos` + `flutter test` (full app suite green). Commit:
```bash
git commit -am "chore(app): enable unawaited_futures lint, parallelize recents refresh, gate dev playground to debug"
```

---

## Task 4: Consolidate FrameSettingsProvider (single source of truth for WindowFrame)

**Files:** `packages/screen_recorder/lib/state/frame_settings_provider.dart`, `lib/ui/screens/playback_screen.dart` (the mirror-to-editor `setState` block + the chrome reads), and any widget reading `FrameSettingsProvider`.

**Design:** Today `WindowFrame` lives in BOTH `FrameSettingsProvider` (a `ChangeNotifier`) and `EditorProjectState.windowFrame`, kept in sync by a listener that mirrors changes + kicks `setState`. Make `EditorProjectState.windowFrame` (via `editorProjectControllerProvider`) the SINGLE source of truth; drive all chrome reads from it; route chrome edits through the editor controller; delete `FrameSettingsProvider` (or reduce it to a thin pass-through if a non-Riverpod consumer requires it).

- [ ] **Step 1:** Map every read/write of `_frameSettings` / `FrameSettingsProvider` in the app (grep). Identify which widgets read chrome from the notifier vs from `EditorProjectState`.
- [ ] **Step 2:** Repoint all chrome READS to `ref.watch(editorProjectControllerProvider).windowFrame`. Repoint all chrome WRITES to the editor controller's `windowFrame` mutator (the one the mirror already calls). Remove the `FrameSettingsProvider` mirror listener + the redundant `setState` kick in `playback_screen`.
- [ ] **Step 3:** Delete `FrameSettingsProvider` and its provider/wiring (constructor passing, `dispose`, `_onFrameSettingsChanged` listener in `playback_screen`). If a leaf widget genuinely needs a `ValueListenable`-style handle, derive it from the editor controller instead.
- [ ] **Step 4:** This is BEHAVIOR-PRESERVING — the chrome must render and persist exactly as before. Run `cd packages/screen_recorder && flutter test` (full suite must stay green; the frame_settings_provider test will need deletion or rewrite against the new source of truth — update it). `flutter analyze --no-fatal-infos` clean (no dangling `FrameSettingsProvider`/`_frameSettings`).
- [ ] **Step 5:** Commit:
```bash
git commit -am "refactor(app): single source of truth for WindowFrame (remove FrameSettingsProvider double-bookkeeping)"
```

---

## Task 5: Native macOS — delete legacy spool path + tidy

**Files:** `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`, the macOS Dart channel impl, possibly `screen_recorder_platform_interface` (`FrameData`, `startRecording`/`pauseRecording`/`resumeRecording`/`stopRecording` interface methods + the frames/audio event channels IF they become unused), `lib/src/models/recording_settings.dart`.

⚠️ Native — compile-check via xcodebuild (no flutter test). Be conservative; if deleting touches more than the spool path, report before proceeding.

- [ ] **Step 1: Map the spool path.** Grep the app + macOS plugin for `startRecording`/`frameStream`/`audioStream`/`FrameData` to confirm the APP uses only `startLiveRecording`/`cursorStream` (not the spool path). The spool path = the native `startRecording` handler + its frame/audio EventChannel emitters + the `frameStream`/`audioStream` getters in the macOS Dart impl. Confirm `pauseRecording`/`resumeRecording` are already NOT_IMPLEMENTED on macOS (per review).
- [ ] **Step 2: Delete the macOS spool implementation** — the Swift `startRecording` case + its frame/audio channel-pushing code (NOT the live path, NOT the cursor channel, NOT the source/region/audio-menu/thumbnail methods). Remove the `frameStream`/`audioStream` overrides from the macOS Dart channel impl so they fall back to the interface defaults (UnimplementedError). Leave the interface's `startRecording`/`FrameData`/frames/audio channel CONSTANTS in place (other platforms + the contract still reference them) UNLESS grep proves them fully unused everywhere — if so, removing `FrameData` is in scope; otherwise leave the model and just stop macOS from using it.
- [ ] **Step 3: Native print() + stale comments.** Gate the chatty `print(...)` in `makeCursorTransform`/`[tearDown]` behind a debug flag or switch to `os_log` at debug level; refresh the stale `AudioCaptureManager` "system audio not yet supported" comment (system audio IS implemented via `SystemAudioCaptureManager`).
- [ ] **Step 4: Doc points-vs-pixels.** Add a comment to `getAvailableWindows`/`WindowInfo` (or the model) noting `WindowInfo` bounds are in points while capture dims are in pixels (Retina scale factor).
- [ ] **Step 5: `RecordingSettings.copyWith` optional-clearing.** In `recording_settings.dart`, make `copyWith` able to CLEAR the nullable fields (`microphone`/`systemAudio`/`sourceId`/`maxDurationSeconds`) — e.g. sentinel-based or `Object?`-with-`identical` pattern. Add/extend a unit test in `screen_recorder_platform_interface` asserting `copyWith(microphone: null)` clears. (This one IS verifiable via `flutter test` in the interface package.)
- [ ] **Step 6:** Compile-check Swift via xcodebuild (BUILD SUCCEEDED). Run `cd packages/screen_recorder_platform_interface && flutter test` (copyWith test). `cd packages/screen_recorder && flutter analyze --no-fatal-infos` (no dangling spool refs). Commit:
```bash
git commit -am "refactor(macos): delete legacy spool recording path; gate native logs; copyWith can clear optionals"
```

---

## Task 6: Documentation stubs

**Files:** `packages/screen_recorder/README.md`, `packages/screen_recorder_macos/CHANGELOG.md`, `packages/screen_recorder_linux/CHANGELOG.md` (Windows README is already substantive; Linux README already fixed in Workstream D).

- [ ] **Step 1:** Replace `screen_recorder/README.md` (currently the "A new Flutter project" template) with a real description: what Slipreel is (macOS-first screen recorder + editor), how to run (`flutter run -d macos` from this package; melos bootstrap from root), and a pointer to the platform-interface parity matrix.
- [ ] **Step 2:** Fill the macOS + Linux `CHANGELOG.md` stubs (`* TODO: Describe initial release.`) with a minimal real entry (e.g. `## 0.0.1 - Initial macOS implementation: ScreenCaptureKit live recording, audio capture, source/region pickers.`).
- [ ] **Step 3:** Commit:
```bash
git commit -am "docs: real README/CHANGELOG for screen_recorder + plugin packages"
```

---

## Self-Review
**Coverage:** every deferred Minor is either in a task above or in the explicit "Deliberately NOT changing" list with a rationale. AudioTab left as-is per decision; motion_blur gated (T3); FrameSettingsProvider consolidated (T4); spool path deleted (T5).
**Risk notes:** T2 (material narrowing) is wide but mechanical + guarded by the layer-boundary test. T3 lint additions may cascade — Step 1 caps at ~15 violations before escalating. T4 + T5 are the real refactors (behavior-preserving; full suite + xcodebuild are the gates). T1's ZoomRegion half-open and AudioMix formatting are subtle behavior/string changes — covered by tests.
**Verification per task:** engine/app → flutter test + analyze; native → xcodebuild + interface flutter test; docs → prose.
