# Deterministic Focal Track for Scene Blur — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the scene-blur pan vector track the spring-damped camera focal (not the raw cursor) while staying a pure function of playhead position, so preview pause==play==export AND the smear matches on-screen motion (no "cursor-following crack" at zoom enter/exit).

**Architecture:** The visible camera focal is a stateful, path-dependent critically-damped spring (`ZoomFocalController`, driven through `ScenePassBuilder` which also feeds it the smoothed cursor sprite + velocity). Rather than re-implement that math, we **replay a fresh `ScenePassBuilder` from the active zoom region's start to its end at a fixed 16 ms dt**, cache the resulting per-step focal samples in a `DeterministicFocalTrack`, and expose `focalAt(t)` by interpolation. The scene-blur signal then samples this track at `t` and `t − exposure` (replacing the raw-cursor `_approxSampleAt` focal). This is pure (a function of region + cursor recording + config + tuning + videoSize + fps), reuses the entire tuned pipeline verbatim, and is computed once per region (cached), so per-frame lookups are O(log n).

**Scope — Phase 1 only:** The blur samples the track. The *visible* camera keeps its existing live controller. During 60fps playback the live controller (≈16 ms variable dt) and the track (16 ms fixed dt) are near-identical, so the smear matches the frame; the zoom-entry snap that caused the crack is gone because the track ramps. Unifying the visible camera onto the track (full rendered-frame determinism) is a deliberate **Phase 2 follow-up**, out of scope here to avoid changing the hand-tuned camera feel.

**Tech Stack:** Dart / Flutter, `slipreel_engine` package (engine), `screen_recorder` package (shell). Tests via `flutter test`. In-app verification via the agent-wires probe (`ext.slipreel.setSceneBlurTrace`, `ext.slipreel.seek/play/pause`).

---

## File Structure

- **Create** `packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart`
  — `DeterministicFocalTrack`: builds + caches the replayed focal trajectory for one zoom region; `focalAt(Duration)` interpolates. Owns no UI.
- **Create** `packages/slipreel_engine/test/rendering/deterministic_focal_track_test.dart`
  — determinism + correctness tests for the track.
- **Modify** `packages/screen_recorder/lib/ui/widgets/scene_blur_overlay.dart`
  — replace the raw-cursor focal in `_approxSampleAt` with a per-region `DeterministicFocalTrack` lookup (scale stays from the deterministic zoom ramp); cache the track; rebuild on input change.
- **Modify** `packages/slipreel_engine/lib/export/frame_compositor.dart`
  — same substitution in `_sceneSampleAt`, so export matches preview.
- **Modify** `packages/slipreel_engine/test/export/frame_compositor_test.dart`
  — add a regression test that export's scene signal uses the track (focal ramps, no snap).

---

## Task 1: `DeterministicFocalTrack` — replay + cache + interpolate

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart`
- Test: `packages/slipreel_engine/test/rendering/deterministic_focal_track_test.dart`

**Design notes (read before coding):**
- The track is built for ONE active `ZoomRegion`. Replay a fresh `ScenePassBuilder()` (so no shared state) by calling `.build(position: step, zoomRegions: [region], cursorAnimationConfig, cursorDelay, cursorPostProcess, cursorRecording, videoSize, fps, hasCursorData)` at `step = region.startTime, +16ms, … ≥ region.endTime`. Collect `pass.focalUpdate?.focal` per step. When `focalUpdate` is null (no active zoom at that step — only at the exclusive end), stop.
- Fixed sub-step = 16 ms (`_stepMicros = 16000`). Matches `ZoomFocalController._maxSubStepMicros` so the replay integrates identically to a 60fps live pass.
- `focalAt(t)`: clamp to `[start, lastSampleTime]`; binary-search the bracketing samples; linearly interpolate. Before `start` or with <2 samples, return the first sample (or `region.rect.center` if empty).
- Equality key for caching (Task 2 uses it): the track stores the `ZoomRegion`, `CursorRecording` identity, `CursorAnimationConfig`, `CursorPostProcess`, `MotionTuning`, `videoSize`, `fps` it was built from.

- [ ] **Step 1: Write the failing test**

```dart
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';

void main() {
  // A cursor that sits at (200,200) then sweeps to (1200,800).
  CursorRecording sweep() {
    final samples = <CursorSample>[];
    for (var ms = 0; ms <= 6000; ms += 16) {
      final t = (ms / 6000).clamp(0.0, 1.0);
      final x = ms < 2500 ? 200.0 : 200.0 + (1200 - 200) * ((ms - 2500) / 2000).clamp(0.0, 1.0);
      final y = ms < 2500 ? 200.0 : 200.0 + (800 - 200) * ((ms - 2500) / 2000).clamp(0.0, 1.0);
      samples.add(CursorSample(t: Duration(milliseconds: ms), x: x, y: y));
    }
    return CursorRecording(samples: samples);
  }

  final region = ZoomRegion(
    startTimeMicros: 2542000,
    durationMicros: 2000000,
    zoomLevel: 2.0,
    followCursor: true,
    followMode: FollowMode.bounded,
  );
  const videoSize = Size(1728, 1117);

  DeterministicFocalTrack buildTrack() => DeterministicFocalTrack.build(
        region: region,
        cursorRecording: sweep(),
        cursorAnimationConfig:
            const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        videoSize: videoSize,
        fps: 60,
      );

  test('focalAt is a pure function: same t → same focal, any call order', () {
    final track = buildTrack();
    final a = track.focalAt(const Duration(milliseconds: 3000));
    track.focalAt(const Duration(milliseconds: 4000)); // perturb call order
    final b = track.focalAt(const Duration(milliseconds: 3000));
    expect(a, b);
  });

  test('focal does NOT snap at region entry — moves <40px in the first 16ms',
      () {
    final track = buildTrack();
    final f0 = track.focalAt(const Duration(milliseconds: 2542));
    final f1 = track.focalAt(const Duration(milliseconds: 2558));
    expect((f1 - f0).distance, lessThan(40.0),
        reason: 'spring ramps from rect.center; it must not teleport to the '
            'cursor in one frame (that snap was the scene-blur crack)');
  });

  test('focal converges toward the cursor during the hold phase', () {
    final track = buildTrack();
    // By 1s into the 2s region the spring should have chased most of the
    // way to the cursor target (well away from the rect centre).
    final focal = track.focalAt(const Duration(milliseconds: 3600));
    expect(focal.dx, lessThan(700), reason: 'chased left toward cursor x=200');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/rendering/deterministic_focal_track_test.dart`
Expected: FAIL — `deterministic_focal_track.dart` / `DeterministicFocalTrack` does not exist (compile error).

- [ ] **Step 3: Write the implementation**

```dart
import 'dart:ui' show Offset;

import 'package:flutter/widgets.dart' show Size;
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';

/// Deterministic, position-pure camera-focal trajectory for one zoom
/// region. Replays a fresh [ScenePassBuilder] (which drives the same
/// smoothed-cursor + critically-damped-spring focal pipeline the live
/// camera uses) from the region's start to its end at a fixed 16 ms
/// step, caches the per-step focal, and answers [focalAt] by
/// interpolation.
///
/// Why this exists: the scene-blur pan vector must measure how the
/// *spring camera* moved across the exposure window, not how the raw
/// cursor moved — otherwise the smear diverges from on-screen motion at
/// zoom enter/exit (the cursor-follow "crack"). Sampling raw cursor was
/// also why a previous fix snapped the focal to the cursor in one frame.
/// Replaying the real pipeline keeps the blur matched to the camera, and
/// because the replay is a pure function of its inputs the signal is
/// identical for pause / play / scrub / export at the same playhead.
class DeterministicFocalTrack {
  DeterministicFocalTrack._({
    required this.region,
    required this.cursorRecording,
    required this.cursorAnimationConfig,
    required this.cursorPostProcess,
    required this.tuning,
    required this.videoSize,
    required this.fps,
    required List<Offset> samples,
    required int startMicros,
  })  : _samples = samples,
        _startMicros = startMicros;

  static const int _stepMicros = 16000;

  final ZoomRegion region;
  final CursorRecording cursorRecording;
  final CursorAnimationConfig cursorAnimationConfig;
  final CursorPostProcess cursorPostProcess;
  final MotionTuning? tuning;
  final Size videoSize;
  final int fps;

  final List<Offset> _samples; // focal per fixed step from _startMicros
  final int _startMicros;

  /// Builds (and integrates) the trajectory. Call once per region; reuse
  /// the instance for every per-frame lookup.
  static DeterministicFocalTrack build({
    required ZoomRegion region,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig cursorAnimationConfig,
    required Size videoSize,
    required int fps,
    CursorPostProcess cursorPostProcess = CursorPostProcess.none,
    MotionTuning? tuning,
  }) {
    final builder = ScenePassBuilder(
      focal: tuning == null ? null : null, // focal built internally
    );
    final regions = <ZoomRegion>[region];
    final startUs = region.startTime.inMicroseconds;
    final endUs = region.endTime.inMicroseconds;
    final samples = <Offset>[];
    for (var us = startUs; us <= endUs; us += _stepMicros) {
      final pass = builder.build(
        position: Duration(microseconds: us),
        zoomRegions: regions,
        cursorAnimationConfig: cursorAnimationConfig,
        cursorPostProcess: cursorPostProcess,
        cursorRecording: cursorRecording,
        videoSize: videoSize,
        fps: fps,
        hasCursorData: cursorRecording.count > 0,
      );
      final focal = pass.focalUpdate?.focal;
      if (focal == null) break;
      samples.add(focal);
    }
    return DeterministicFocalTrack._(
      region: region,
      cursorRecording: cursorRecording,
      cursorAnimationConfig: cursorAnimationConfig,
      cursorPostProcess: cursorPostProcess,
      tuning: tuning,
      videoSize: videoSize,
      fps: fps,
      samples: samples,
      startMicros: startUs,
    );
  }

  /// Focal at [t], interpolated from the cached trajectory. Clamps to
  /// the region's covered range. Returns the region centre when empty.
  Offset focalAt(Duration t) {
    if (_samples.isEmpty) return region.rect.center;
    if (_samples.length == 1) return _samples.first;
    final rel = t.inMicroseconds - _startMicros;
    if (rel <= 0) return _samples.first;
    final lastIdx = _samples.length - 1;
    final maxRel = lastIdx * _stepMicros;
    if (rel >= maxRel) return _samples[lastIdx];
    final i = rel ~/ _stepMicros;
    final f = (rel - i * _stepMicros) / _stepMicros;
    return Offset.lerp(_samples[i], _samples[i + 1], f)!;
  }

  /// True when this track was built from inputs equal to the given set
  /// — used by callers to decide whether to rebuild after a widget
  /// update. Cursor recording is compared by identity (the shell swaps
  /// the whole object when it changes).
  bool matches({
    required ZoomRegion region,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig cursorAnimationConfig,
    required CursorPostProcess cursorPostProcess,
    required Size videoSize,
    required int fps,
  }) {
    return identical(this.cursorRecording, cursorRecording) &&
        this.region == region &&
        this.cursorAnimationConfig == cursorAnimationConfig &&
        this.cursorPostProcess == cursorPostProcess &&
        this.videoSize == videoSize &&
        this.fps == fps;
  }
}
```

> NOTE for implementer: `ScenePassBuilder`'s constructor signature must be
> checked. If it does not accept a `focal:`/`tuning:` argument, construct it
> with no args (`ScenePassBuilder()`) — the focal controller is created
> internally with default tuning. Remove the bogus `focal:` line above; it
> is illustrative only. If `MotionTuning` needs to flow in, thread it through
> whatever constructor/parameter `ScenePassBuilder` actually exposes; if there
> is no such hook, drop the `tuning` field entirely and delete it from
> `matches`. Verify `ZoomRegion` exposes `startTime`, `endTime`, `rect.center`
> and value equality (`==`/`hashCode`); `CursorRecording.count`; and
> `CursorAnimationConfig`/`CursorPostProcess` value equality. Adjust the code
> to the real APIs — do not invent members.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/rendering/deterministic_focal_track_test.dart`
Expected: PASS (3 tests). If the "no snap" test fails, the replay is not seeing `followCursor` correctly — check the `ScenePassBuilder.build` argument names against the real signature.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart packages/slipreel_engine/test/rendering/deterministic_focal_track_test.dart
git commit -m "feat(rendering): DeterministicFocalTrack — position-pure spring focal replay"
```

---

## Task 2: Scene-blur overlay samples the track (preview)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/scene_blur_overlay.dart`

**Design notes:**
- Add a cached `DeterministicFocalTrack? _focalTrack` field.
- Add `DeterministicFocalTrack? _trackFor(ZoomRegion region)`: if `_focalTrack != null && _focalTrack!.matches(...)` return it; else rebuild, store, return. Only follow-cursor regions need a track; for non-follow regions return null (focal = `region.rect.center`, unchanged).
- In `_approxSampleAt(Duration t)`: after resolving the active `ZoomRegion`, for the `followCursor` branch replace the `cursorAtFiltered(...)` focal with `track.focalAt(t)` (fall back to `cursorAtFiltered` only if the track is null). **Leave the scale/matrix computation exactly as-is** — the zoom ramp is already deterministic and correct.

- [ ] **Step 1: Write the failing test** — structural (no widget harness needed for the math). Add to a new file:

`packages/screen_recorder/test/widgets/scene_blur_focal_track_test.dart`

```dart
@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SceneBlurOverlay samples DeterministicFocalTrack, not raw cursor, '
      'for the focal (cursor-follow crack regression)', () {
    final src = File('lib/ui/widgets/scene_blur_overlay.dart').readAsStringSync();
    expect(src.contains('DeterministicFocalTrack'), isTrue,
        reason: 'the pan vector must measure the spring camera focal via the '
            'deterministic track; sampling raw cursor made the smear diverge '
            'from on-screen motion at zoom enter/exit');
    expect(src.contains('.focalAt('), isTrue,
        reason: 'focal must come from track.focalAt(t)');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/widgets/scene_blur_focal_track_test.dart`
Expected: FAIL — overlay does not reference `DeterministicFocalTrack` yet.

- [ ] **Step 3: Implement.** Add the import, the cached field, `_trackFor`, and the `_approxSampleAt` substitution. Concrete edit for the follow-cursor branch of `_approxSampleAt` (the rest of the method is unchanged):

```dart
    // import at top:
    // import 'package:slipreel_engine/rendering/deterministic_focal_track.dart';

    Offset focal;
    if (!active.followCursor) {
      focal = active.rect.center;
    } else {
      final track = _trackFor(active);
      if (track != null) {
        // Spring-camera focal (matches the visible camera), evaluated
        // deterministically so pause == play == export at this playhead.
        focal = track.focalAt(t);
      } else {
        final s = cursorAtFiltered(
          widget.cursorRecording, t, widget.cursorPostProcess);
        focal = s == null
            ? active.rect.center
            : Offset(s.x.toDouble().clamp(0, widget.videoSize.width),
                     s.y.toDouble().clamp(0, widget.videoSize.height));
      }
    }
```

And the cache helper + field on `_SceneBlurOverlayState`:

```dart
  DeterministicFocalTrack? _focalTrack;

  DeterministicFocalTrack? _trackFor(ZoomRegion region) {
    if (!region.followCursor) return null;
    final cached = _focalTrack;
    if (cached != null &&
        cached.matches(
          region: region,
          cursorRecording: widget.cursorRecording,
          cursorAnimationConfig: widget.cursorAnimationConfig,
          cursorPostProcess: widget.cursorPostProcess,
          videoSize: widget.videoSize,
          fps: widget.fps,
        )) {
      return cached;
    }
    return _focalTrack = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: widget.cursorRecording,
      cursorAnimationConfig: widget.cursorAnimationConfig,
      cursorPostProcess: widget.cursorPostProcess,
      videoSize: widget.videoSize,
      fps: widget.fps,
    );
  }
```

> The implementer must confirm `widget.fps` exists on `SceneBlurOverlay`
> (it does — `final int fps`, default 60). `widget.cursorAnimationConfig`
> and `widget.cursorPostProcess` exist. Keep the per-frame `_trackFor`
> call cheap: build only fires when `matches` returns false.

- [ ] **Step 4: Run the structural test + full shell suite**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/widgets/scene_blur_focal_track_test.dart && ~/fvm/versions/3.41.5/bin/flutter test`
Expected: the new test PASSES; the full suite stays green (153 tests at time of writing).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/scene_blur_overlay.dart packages/screen_recorder/test/widgets/scene_blur_focal_track_test.dart
git commit -m "fix(scene-blur): pan vector tracks spring camera focal via DeterministicFocalTrack (bug: cursor-follow crack)"
```

---

## Task 3: Export pipeline samples the track (WYSIWYG)

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Test: `packages/slipreel_engine/test/export/frame_compositor_test.dart`

**Design notes:**
- `FrameCompositor._sceneSampleAt(Duration t)` currently uses `cursorAtFiltered` for the follow-cursor focal. Replace with a cached `DeterministicFocalTrack` keyed on the active region, exactly mirroring the overlay. The compositor already has `projectState` (zoomRegions, cursorAnimationConfig, cursorPostProcess), `cursorRecording`, `videoSize`, `fps`. Keep scale from `_zoomTransformer.getTransform` unchanged.
- Cache field: `DeterministicFocalTrack? _focalTrack;` rebuilt when the active region/inputs change (same `matches` guard). One compositor instance per export, monotonic positions, so the track for the active region is built once and reused across frames.

- [ ] **Step 1: Write the failing test**

```dart
// Add inside frame_compositor_test.dart's main():
test('scene-blur focal does not snap at zoom entry (tracks spring camera)',
    () async {
  // Build a project with a follow-cursor zoom + a cursor recording that
  // sits then sweeps. Render frames at region.start and start+16ms; the
  // scene signal focal must move <40px (ramp, not snap).
  // Use the existing test fixtures/builders in this file; assert on the
  // SceneMotionBlurSignal translation magnitude being bounded at entry.
});
```

> The implementer fills this in using the fixtures already present in
> `frame_compositor_test.dart` (it has a working `FrameCompositor` setup).
> The assertion: at the first two frames of the region, `|translation|`
> stays small (no 100+px capped spike from a center→cursor snap). If the
> file lacks a follow-cursor fixture, add one mirroring Task 1's `sweep()`
> + `region`. Keep it a behavioural test on the public `compose`/signal path.

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/export/frame_compositor_test.dart`
Expected: FAIL — focal still snaps (large entry translation) until the track is wired.

- [ ] **Step 3: Implement the substitution in `_sceneSampleAt`** (mirror Task 2's follow-cursor branch; add the cached `_focalTrack` + `matches` guard using `projectState` inputs).

- [ ] **Step 4: Run engine suite**

Run: `cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test`
Expected: all green (460 tests at time of writing) + the new test passes.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart packages/slipreel_engine/test/export/frame_compositor_test.dart
git commit -m "fix(export): scene-blur focal tracks spring camera via DeterministicFocalTrack (WYSIWYG with preview)"
```

---

## Task 4: In-app verification via agent-wires

**Files:** none (runtime verification).

- [ ] **Step 1:** `stop_app` + `boot_app` (device `macos`) to pick up the engine change.
- [ ] **Step 2:** Navigate history → `recording_1779215612620.mp4` (has a 2 s bounded follow-cursor zoom at 2.542 s, `screenMovementBlur` = 1.0).
- [ ] **Step 3:** Enable the trace: `dart run --packages=.dart_tool/package_config.json /tmp/slipreel_ext.dart <ws> ext.slipreel.setSceneBlurTrace enabled=true`.
- [ ] **Step 4:** `ext.slipreel.seek ms=2300`, `ext.slipreel.play`, wait ~2.6 s, `ext.slipreel.pause`.
- [ ] **Step 5:** `get_logs`, parse `[SceneBlur frame]`. **Pass criteria:** at the region entry (≈2542→2558 ms) the `cur` focal moves <40 px between consecutive frames (previously it jumped center (864,558) → cursor (639,753), ~298 px). Frame-to-frame `|trans|` is smooth (no center→cursor capped spike). Disable the trace afterward.
- [ ] **Step 6:** Report the before/after entry-frame focal delta to the user; if it still snaps, return to Task 1 (the replay is not reproducing the spring — check `ScenePassBuilder.build` arg names and that `followCursor`/`followMode` reach the focal controller).

---

## Phase 2 (follow-up, NOT in this plan)

Unify the *visible* camera on the same deterministic track (replace the live `ZoomFocalController` drive in `PlaybackCanvas`/`ScenePassBuilder` with track lookups) so the rendered frame itself is position-pure (scrub==play for camera position, not just blur). Higher risk — changes hand-tuned camera feel — so it gets its own spec, plan, and side-by-side feel review.

---

## Self-Review

- **Spec coverage:** Root cause (raw-cursor focal vs spring camera) → Task 1 builds the spring-faithful track; Tasks 2+3 wire preview & export; Task 4 verifies in-app. Determinism requirement preserved (track is a pure function; both blur sides sample it). ✓
- **Placeholders:** Task 1 ships complete code with an explicit "verify the real `ScenePassBuilder`/`ZoomRegion` API and adjust" note (the one unavoidable unknown — the implementer confirms signatures against the live source rather than guessing). Tasks 2/3 give concrete edits; Task 3's test body is intentionally delegated to existing fixtures with a precise assertion spec. ✓
- **Type consistency:** `DeterministicFocalTrack.build(...)` / `.focalAt(Duration)` / `.matches(...)` names are identical across Tasks 1–3. ✓
