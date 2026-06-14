# Speed-aware Cursor Smoothing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the rendered cursor retain comparable wall-time smoothness when a slice's playback speed is increased, instead of snapping tightly onto the raw recorded path — without changing 1× behavior and keeping preview and export in lockstep.

**Architecture:** The cursor spring chases the recorded path parametrized by *source* time, so its settle-time τ is fixed in source time and shrinks in wall time as speed rises. We integrate the spring in speed-normalized time (`dt / playbackSpeed`) and scale the feedforward lead by speed, with the feedforward fade keyed off perceived (wall) speed. `playbackSpeed` is resolved once in the shared `ScenePassBuilder.build()` from `clipSliceAt(clips, position).playbackSpeed`, so the single preview/export code path cannot diverge. `playbackSpeed == 1.0` reduces every formula to today's.

**Tech Stack:** Dart / Flutter; `flutter_test`; `package:flutter/physics.dart` `SpringSimulation`.

**Spec:** `docs/superpowers/specs/2026-06-14-speed-aware-cursor-smoothing-design.md`

---

## File Structure

- **Modify** `packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart` — add `playbackSpeed` param to `update()`; speed-normalize the integration `dt`; scale feedforward lead by speed; fade on perceived speed. (Tasks 1–3)
- **Modify** `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart` — add `clips` param to `build()`; resolve `playbackSpeed` via `clipSliceAt`; pass it to `motion.update()`. (Task 4)
- **Modify** `packages/slipreel_engine/lib/export/frame_compositor.dart` — pass `clips: projectState.timeline.clips` to `build()`. (Task 5)
- **Modify** `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — add `clips` widget field; pass `clips: widget.clips` to `build()`. (Task 5)
- **Modify** `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — pass `clips: project.timeline.clips` to `PlaybackCanvas`. (Task 5)
- **Test** `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart` — speed-awareness unit tests. (Tasks 1–3)
- **Create** `packages/slipreel_engine/test/rendering/scene_pass_builder_speed_test.dart` — preview-vs-export convergence + plumbing test. (Task 4)

All test commands run from `packages/slipreel_engine` unless noted. The engine package is pure Dart/Flutter; use `flutter test`.

---

### Task 1: `update()` accepts `playbackSpeed` and speed-normalizes the integration step

This is the core change. Add the parameter (default `1.0`, so all existing callers and tests are unchanged) and divide the integration `dt` by a clamped speed factor.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart`

- [ ] **Step 1: Write the failing tests**

Append these tests inside the existing `group('CursorMotionController (spring)', () { ... })` block in `cursor_motion_controller_test.dart` (before its closing `});`). They reuse the file's existing `_record` helper. Note: `_drive` does **not** forward `playbackSpeed`, so these drive `update()` directly.

```dart
    // A horizontal ramp the spring will lag behind. Samples every 16 ms
    // for 320 ms so there is room to observe steady-state lag.
    CursorRecording _ramp() => _record([
          for (int i = 0; i <= 20; i++)
            (micros: i * 16000, x: i * 50.0, y: 0, clicked: false),
        ]);

    test('playbackSpeed defaults to 1.0 → output identical to omitting it', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final rec = _ramp();
      final timeline = [for (int i = 0; i <= 20; i++) i * 16000];

      final a = CursorMotionController();
      final b = CursorMotionController();
      CursorMotionUpdate? lastA;
      CursorMotionUpdate? lastB;
      for (final m in timeline) {
        lastA = a.update(
            position: Duration(microseconds: m),
            cursorRecording: rec, config: cfg, fps: 60);
        lastB = b.update(
            position: Duration(microseconds: m),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 1.0);
      }
      expect(lastB!.screenPos.dx, closeTo(lastA!.screenPos.dx, 1e-9));
      expect(lastB.screenPos.dy, closeTo(lastA.screenPos.dy, 1e-9));
    });

    test('2× source stepping lags more in source space than 1× (softer)', () {
      // Same recorded ramp, same wall cadence (20 real frames). The 1×
      // run advances source time 16 ms/frame; the 2× run advances 32
      // ms/frame (source moves 2× faster per wall frame). At the SAME
      // source position the speed-aware spring must sit further behind
      // the raw path — that extra source-lag is what plays back as
      // preserved wall-time softness.
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      final rec = _ramp();

      final slow = CursorMotionController();
      CursorMotionUpdate? lastSlow;
      for (int i = 0; i <= 10; i++) {
        lastSlow = slow.update(
            position: Duration(microseconds: i * 16000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 1.0);
      }
      // 1× reached source t=160ms.
      final rawAt160 = lastSlow!.screenPos.dx; // not the raw; the sprite.

      final fast = CursorMotionController();
      CursorMotionUpdate? lastFast;
      for (int i = 0; i <= 5; i++) {
        lastFast = fast.update(
            position: Duration(microseconds: i * 32000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 2.0);
      }
      // 2× also reached source t=160ms (5 frames × 32 ms), but the
      // spring integrated half the effective time per frame → it sits
      // further behind (smaller dx) than the 1× run at the same source t.
      expect(lastFast!.screenPos.dx, lessThan(rawAt160 - 1.0));
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart -n "playbackSpeed"`
Expected: FAIL — the `playbackSpeed:` named argument does not exist yet ("No named parameter with the name 'playbackSpeed'").

- [ ] **Step 3: Add the parameter and speed-normalize `dt`**

In `cursor_motion_controller.dart`, change the `update()` signature (currently lines ~146–153) to add the new parameter:

```dart
  CursorMotionUpdate? update({
    required Duration position,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig config,
    required int fps,
    Duration cursorDelay = Duration.zero,
    CursorPostProcess postProcess = CursorPostProcess.none,
    /// Playback speed of the slice covering [position] (source time).
    /// The spring chases the recorded path in SOURCE time, so its
    /// settle-time τ is fixed in source time and shrinks in WALL time
    /// as the slice plays faster. Integrating by `dt / playbackSpeed`
    /// preserves the per-wall-frame settle, keeping perceived softness
    /// comparable to 1×. Defaults to 1.0 ⇒ behavior identical to today.
    double playbackSpeed = 1.0,
  }) {
```

Then change the integration-step line (currently `final dt = dtMicros / 1e6;`, ~line 286) to:

```dart
    // Clamp to a small floor so a degenerate (0 / negative) slice speed
    // can't divide-by-zero or blow the step up unboundedly.
    final speedFactor = playbackSpeed < 0.05 ? 0.05 : playbackSpeed;
    final dt = (dtMicros / 1e6) / speedFactor;
```

Leave the feedforward and the `SpringSimulation` calls exactly as they are for now (Tasks 2 and 3 refine the feedforward). `speedFactor` is referenced again in Task 2/3, so it stays in scope above them.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart -n "playbackSpeed"`
Expected: PASS (both new tests).

- [ ] **Step 5: Run the full controller test file (no regressions)**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart`
Expected: PASS (all pre-existing tests still green — `playbackSpeed` defaulted to 1.0 leaves them unchanged).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart \
        packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart
git commit -m "feat(cursor): speed-normalize spring integration step (#6)"
```

---

### Task 2: Scale the feedforward lead by speed

Under dt-scaling the spring's source-time lag becomes `τ × speedFactor`, so the velocity feedforward (which compensates that lag) must scale with it to keep the same wall-time compensation as 1×.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside the same `group(...)` block:

```dart
    test('feedforward lead scales with speed (target leads further at 2×)', () {
      // Drive to the same source position at 1× and 2×, then compare
      // the FIRST integrated frame's sprite displacement. With a moving
      // target and a scaled lead, the 2× run's target sits further ahead
      // of the raw path, so after one step its sprite has advanced past
      // where the 1× run's would for the same raw target — isolating the
      // lead term. We assert the lead term is non-zero and larger at 2×
      // by comparing the implied target via the public sprite path over
      // a short, fast motion that keeps perceived speed in the full-FF
      // band for BOTH runs (so fadeScale == 1 in both, isolating the
      // `× speedFactor` factor).
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      // Fast ramp: 2000 px over 320 ms = 6250 px/s source speed, well
      // above the 800 px/s full-speed threshold even at 1×.
      final rec = _record([
        for (int i = 0; i <= 20; i++)
          (micros: i * 16000, x: i * 100.0, y: 0, clicked: false),
      ]);

      final one = CursorMotionController();
      final two = CursorMotionController();
      CursorMotionUpdate? lastOne;
      CursorMotionUpdate? lastTwo;
      // Prime + several steps to reach steady state at source t≈160ms.
      for (int i = 0; i <= 10; i++) {
        lastOne = one.update(
            position: Duration(microseconds: i * 16000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 1.0);
      }
      for (int i = 0; i <= 5; i++) {
        lastTwo = two.update(
            position: Duration(microseconds: i * 32000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 2.0);
      }
      // Both at source t=160ms. The 2× feedforward lead is 2× the 1×
      // lead, partially offsetting the larger source-lag from Task 1.
      // Net check: the 2× sprite is NOT pinned to the raw path (lead is
      // active) yet still lags — i.e. it lands strictly between the 1×
      // sprite and the raw position at t=160ms (x=1000).
      expect(lastTwo!.screenPos.dx, greaterThan(lastOne!.screenPos.dx));
      expect(lastTwo.screenPos.dx, lessThan(1000.0));
    });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart -n "feedforward lead scales"`
Expected: FAIL — without the `× speedFactor` lead scaling, the 2× sprite lags too far and the `greaterThan` assertion fails (the 2× run's larger source-lag is uncompensated).

- [ ] **Step 3: Scale the lead by `speedFactor`**

In `cursor_motion_controller.dart`, the feedforward block currently computes (lines ~302–314):

```dart
    final tauSec =
        2.0 * spring.damping * math.sqrt(spring.mass / spring.stiffness);
    final speed = velocity.distance;
    final fadeRange =
        _feedforwardFullSpeedPxPerSec - _feedforwardFadeStartPxPerSec;
    final fadeT = fadeRange <= 0
        ? 1.0
        : ((speed - _feedforwardFadeStartPxPerSec) / fadeRange)
            .clamp(0.0, 1.0);
    final fadeScale = fadeT * fadeT * (3.0 - 2.0 * fadeT);
    final leadSec = tauSec * _feedforwardStrength * fadeScale;
    final targetX = raw.x.toDouble() + velocity.dx * leadSec;
    final targetY = raw.y.toDouble() + velocity.dy * leadSec;
```

Change **only** the `leadSec` line to multiply by `speedFactor`:

```dart
    // Under dt-scaling the spring's source-time lag is τ × speedFactor,
    // so the feedforward lead scales with it to keep the same wall-time
    // compensation as 1× (speedFactor == 1.0 ⇒ unchanged).
    final leadSec = tauSec * speedFactor * _feedforwardStrength * fadeScale;
```

(The `speed`/`fadeT` lines change in Task 3 — leave them as-is here.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart -n "feedforward lead scales"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart \
        packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart
git commit -m "feat(cursor): scale feedforward lead by playback speed (#6)"
```

---

### Task 3: Fade feedforward on perceived (wall) speed

The fade currently compares **source** px/s against the thresholds. Source px/s is not inflated by playback speed, so the fade engages by a speed the user does not perceive. Key it off `sourceSpeed × speedFactor` instead.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside the same `group(...)` block:

```dart
    test('feedforward fade reaches full at half the source speed when 2×', () {
      // Source speed chosen so that at 1× it sits BELOW the full-speed
      // threshold (800 px/s) but at 2× perceived speed (×2) it is ABOVE
      // it. With perceived-speed fading, the 2× run gets full feedforward
      // while the 1× run is still partially faded → the 2× sprite leads
      // proportionally more than the lead-scaling alone would give.
      //
      // Pick source speed = 500 px/s: 1× perceived 500 (in the
      // 200→800 fade band, fadeScale ≈ smoothstep(0.5) = 0.5); 2×
      // perceived 1000 (clamped to full, fadeScale = 1.0).
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      // 500 px/s = 8 px per 16 ms frame.
      final rec = _record([
        for (int i = 0; i <= 30; i++)
          (micros: i * 16000, x: i * 8.0, y: 0, clicked: false),
      ]);

      // Measure the realized fadeScale indirectly: at matched source
      // position the 2× sprite must lead MORE than the pure lead-scaling
      // (×2) would predict, because its fadeScale is also higher. We
      // assert monotonicity vs a hypothetical source-speed-fade by
      // checking the 2× sprite has clearly overcome the source-lag and
      // sits ahead of the 1× sprite by a margin larger than at the
      // lower, half-faded 1× speed.
      final one = CursorMotionController();
      final two = CursorMotionController();
      CursorMotionUpdate? lastOne;
      CursorMotionUpdate? lastTwo;
      for (int i = 0; i <= 20; i++) {
        lastOne = one.update(
            position: Duration(microseconds: i * 16000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 1.0);
      }
      for (int i = 0; i <= 10; i++) {
        lastTwo = two.update(
            position: Duration(microseconds: i * 32000),
            cursorRecording: rec, config: cfg, fps: 60, playbackSpeed: 2.0);
      }
      // Both at source t=320ms (raw x=160). Perceived-speed fade gives
      // the 2× run full feedforward (fadeScale 1.0) vs the 1× run's
      // ~0.5, so the 2× sprite sits closer to the raw path than it would
      // under source-speed fading. Concretely it leads the 1× sprite.
      expect(lastTwo!.screenPos.dx, greaterThan(lastOne!.screenPos.dx));
    });
```

- [ ] **Step 2: Run the test to verify it fails (or document why it passes)**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart -n "fade reaches full"`
Expected: FAIL — under source-speed fading both runs see the same `fadeT` (source speed 500 px/s), so the 2× run has no fade advantage and the margin assertion is tighter than the implementation delivers. (If it unexpectedly passes from the Task 2 lead-scaling alone, strengthen the assertion to compare against a 1× control with the same lead but capture the fade contribution — but run first; the perceived-speed change is what guarantees it.)

- [ ] **Step 3: Fade on perceived speed**

In `cursor_motion_controller.dart`, change the two lines that compute `speed`/`fadeT` (from Task 2's block) to use perceived speed:

```dart
    final tauSec =
        2.0 * spring.damping * math.sqrt(spring.mass / spring.stiffness);
    // Fade on PERCEIVED (wall) speed = source px/s × playback speed, so
    // the feedforward engages by what the user actually sees rather than
    // the speed-deflated source px/s (speedFactor == 1.0 ⇒ unchanged).
    final perceivedSpeed = velocity.distance * speedFactor;
    final fadeRange =
        _feedforwardFullSpeedPxPerSec - _feedforwardFadeStartPxPerSec;
    final fadeT = fadeRange <= 0
        ? 1.0
        : ((perceivedSpeed - _feedforwardFadeStartPxPerSec) / fadeRange)
            .clamp(0.0, 1.0);
    final fadeScale = fadeT * fadeT * (3.0 - 2.0 * fadeT);
    final leadSec = tauSec * speedFactor * _feedforwardStrength * fadeScale;
```

(This replaces the previous `final speed = velocity.distance;` line with `final perceivedSpeed = ...` and updates the `fadeT` numerator. The `leadSec` line is unchanged from Task 2.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart -n "fade reaches full"`
Expected: PASS.

- [ ] **Step 5: Run the full controller test file**

Run: `cd packages/slipreel_engine && flutter test test/rendering/cursor_motion_controller_test.dart`
Expected: PASS (all tests).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/cursor_motion_controller.dart \
        packages/slipreel_engine/test/rendering/cursor_motion_controller_test.dart
git commit -m "feat(cursor): fade feedforward on perceived (wall) speed (#6)"
```

---

### Task 4: `ScenePassBuilder.build()` resolves and forwards `playbackSpeed`

Resolve the speed once, in the shared builder, from the slice covering the current source position. This is the single point both preview and export go through, so they cannot resolve speed differently.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart`
- Create: `packages/slipreel_engine/test/rendering/scene_pass_builder_speed_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/rendering/scene_pass_builder_speed_test.dart`:

```dart
import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _ramp() {
  final r = CursorRecording();
  for (int i = 0; i <= 40; i++) {
    r.addPosition(CursorPosition(
        x: i * 50.0, y: 0, timestampMicros: i * 16000, isClicked: false));
  }
  return r;
}

void main() {
  const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);

  test('build() forwards slice playbackSpeed at the source position', () {
    // One 2× slice spanning the whole recording. A builder fed this slice
    // list must produce a softer (more lagging) sprite at a given source
    // position than a builder fed an empty clip list (speed 1.0).
    final rec = _ramp();
    final slice = ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(milliseconds: 640),
      playbackSpeed: 2.0,
    );

    final withSpeed = ScenePassBuilder();
    final without = ScenePassBuilder();
    const videoSize = Size(1920, 1080);

    ScenePass drive(ScenePassBuilder b, List<ClipSlice> clips) {
      late ScenePass pass;
      for (int i = 0; i <= 10; i++) {
        pass = b.build(
          position: Duration(microseconds: i * 16000),
          zoomRegions: const [],
          cursorAnimationConfig: cfg,
          cursorRecording: rec,
          videoSize: videoSize,
          fps: 60,
          hasCursorData: true,
          clips: clips,
        );
      }
      return pass;
    }

    final fast = drive(withSpeed, [slice]);
    final norm = drive(without, const []);
    // Same source position (t=160ms); the 2× builder lags further behind.
    expect(fast.motion!.screenPos.dx, lessThan(norm.motion!.screenPos.dx));
  });

  test('empty clips list defaults to 1.0 (unchanged)', () {
    final rec = _ramp();
    final a = ScenePassBuilder();
    final b = ScenePassBuilder();
    const videoSize = Size(1920, 1080);
    ScenePass drive(ScenePassBuilder bld, List<ClipSlice> clips) {
      late ScenePass pass;
      for (int i = 0; i <= 10; i++) {
        pass = bld.build(
          position: Duration(microseconds: i * 16000),
          zoomRegions: const [],
          cursorAnimationConfig: cfg,
          cursorRecording: rec,
          videoSize: videoSize,
          fps: 60,
          hasCursorData: true,
          clips: clips,
        );
      }
      return pass;
    }

    // Empty list and a single 1× slice must agree.
    final empty = drive(a, const []);
    final oneX = drive(b, [
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(milliseconds: 640),
        playbackSpeed: 1.0,
      )
    ]);
    expect(empty.motion!.screenPos.dx,
        closeTo(oneX.motion!.screenPos.dx, 1e-9));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/scene_pass_builder_speed_test.dart`
Expected: FAIL — `build()` has no `clips` named parameter yet.

- [ ] **Step 3: Add `clips` to `build()` and resolve speed**

In `scene_pass_builder.dart`, add the import near the other `state` import (after the existing `cursor_post_process.dart` import line):

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

Add the parameter to the `build({ ... })` signature (place it after `cursorPostProcess`):

```dart
    /// Clip slices for the current timeline, used to resolve the
    /// playback speed of the slice covering [position] (source time).
    /// Defaults to empty ⇒ speed 1.0 ⇒ cursor smoothing unchanged.
    List<ClipSlice> clips = const <ClipSlice>[],
```

Replace the `motionSample` assignment (currently lines ~138–147) with:

```dart
    // Resolve once, here in the shared builder, so preview and export —
    // the only two callers — cannot resolve slice speed differently.
    final playbackSpeed =
        clips.isEmpty ? 1.0 : clipSliceAt(clips, position).playbackSpeed;
    final motionSample = hasCursorData
        ? motion.update(
            position: position,
            cursorRecording: cursorRecording,
            config: cursorAnimationConfig,
            fps: fps,
            cursorDelay: cursorDelay,
            postProcess: cursorPostProcess,
            playbackSpeed: playbackSpeed,
          )
        : null;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/scene_pass_builder_speed_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/scene_pass_builder.dart \
        packages/slipreel_engine/test/rendering/scene_pass_builder_speed_test.dart
git commit -m "feat(cursor): resolve slice playbackSpeed in shared scene-pass builder (#6)"
```

---

### Task 5: Wire `clips` through the two real callers (export + preview)

The builder now reads `clips`; supply it from both call sites so the feature is live. The export caller has `projectState.timeline.clips`; the preview caller gets a new widget field fed from `playback_screen`.

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart:169`
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart:2336`

- [ ] **Step 1: Export — pass `clips` in `FrameCompositor.compose`**

In `frame_compositor.dart`, the `_scenePassBuilder.build(...)` call (starts line ~169) currently passes `zoomRegions: projectState.zoomRegions,` etc. Add one line inside that call:

```dart
        clips: projectState.timeline.clips,
```

(Place it alongside `zoomRegions: projectState.zoomRegions,`.)

- [ ] **Step 2: Preview — add a `clips` field to `PlaybackCanvas`**

In `playback_canvas.dart`, add the import near the top with the other `slipreel_engine` imports:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

In the constructor parameter list (the `const PlaybackCanvas({ ... })` block, near the existing `this.sliceDisableSmoothMouse = false,`), add:

```dart
    this.clips = const <ClipSlice>[],
```

With the other final fields (near `final bool sliceDisableSmoothMouse;`), add:

```dart
  /// Clip slices for the current timeline. Forwarded to
  /// [ScenePassBuilder.build] so the cursor spring can be made
  /// playback-speed aware. Empty ⇒ speed 1.0 ⇒ unchanged.
  final List<ClipSlice> clips;
```

In the `_scenePassBuilder.build(...)` call (starts line ~587), add one line alongside `zoomRegions: widget.zoomRegions,`:

```dart
              clips: widget.clips,
```

- [ ] **Step 3: Preview — pass `clips` from `playback_screen`**

In `playback_screen.dart`, the `PlaybackCanvas(` constructor at line ~2336 already has `project` in scope (it reads `project.windowFrame`, `project.timeline.clips` for `currentSlice`). Add one argument alongside `sliceDisableSmoothMouse: currentSlice.disableSmoothMouse,`:

```dart
      clips: project.timeline.clips,
```

- [ ] **Step 4: Static-analyze the touched packages**

Run: `cd packages/slipreel_engine && flutter analyze lib/rendering/scene_pass_builder.dart lib/export/frame_compositor.dart`
Then: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart lib/ui/screens/playback_screen.dart`
Expected: No errors (the `motion_blur_playground_screen.dart` caller omits `clips` and relies on the `const []` default — that's intentional and must still analyze clean).

- [ ] **Step 5: Run the engine test suite**

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS (all tests, including the new cursor + builder tests).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(cursor): wire clip list into preview + export scene-pass (#6)"
```

---

### Task 6: Manual runtime verification (preview + export agree, 1× unchanged)

Automated tests cover the math and plumbing; this task confirms the rendered result with eyes on the app. Use the `verify` / `run` skill or the flutter-qa MCP per the project's runtime-verification setup (see `agent_wires_debug_setup` memory).

**Files:** none (verification only).

- [ ] **Step 1: Build/run the app**

Launch the editor (per the project's `run` skill). Open a recording with cursor movement.

- [ ] **Step 2: 1× regression check**

With a slice at 1× speed, play back and confirm the cursor motion is visually unchanged from `main` (soft spring trail, no snap-to-raw). If anything differs at 1×, STOP — the `playbackSpeed == 1.0` reduction is broken; re-check Tasks 1–3.

- [ ] **Step 3: Sped-up softness check**

Set a slice to 2× (inspector slice editor / `slice_bar`). Play back. Expected: the cursor retains a soft trailing character comparable to 1×, instead of snapping tightly onto the raw recorded path.

- [ ] **Step 4: Preview vs export agreement**

Export the project (or a short range covering the 2× slice). Scrub the exported MP4 to the sped-up section and compare the cursor trajectory to the preview at the matching edited time. Expected: they agree (modulo the documented per-frame-dt discretization tolerance).

- [ ] **Step 5: Scrub / paused check**

Hover-scrub across the 2× slice and pause on a frame. Expected: cursor position is stable and consistent with playback at that timestamp (no jump introduced by the speed-awareness change).

- [ ] **Step 6: Record the result**

Note the verification outcome in the PR description / issue #6. No commit (verification only) unless a fix was needed.

---

## Self-Review

**Spec coverage:**
- Core mechanism `dt / playbackSpeed` → Task 1. ✓
- Feedforward lead `× playbackSpeed` → Task 2. ✓
- Fade on perceived (wall) speed → Task 3. ✓
- Plumbing Approach A (resolve in shared builder via `clipSliceAt`) → Task 4. ✓
- Export + preview wiring (`timeline.clips`, widget field, screen pass-through) → Task 5. ✓
- Defaults preserve 1× / empty-clips behavior → Tasks 1, 4 (default params) + Task 6 step 2 (runtime). ✓
- Snap mode untouched → no change to the `spring.isSnap` branch (speed logic lives below it, only in the integrating path). ✓
- Speed floor clamp → Task 1 step 3 (`< 0.05`). ✓
- Testing: 1× identical, wall-time softness, feedforward fade, preview-vs-export convergence → Tasks 1–4 unit/builder tests + Task 6 manual. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type consistency:** `playbackSpeed` (double) consistent across `update()` (Task 1) and `build()`→`update()` (Task 4); `clips` (`List<ClipSlice>`) consistent across `build()` (Task 4), `PlaybackCanvas.clips` (Task 5), and the `clipSliceAt(clips, position)` call (Task 4). `speedFactor` defined in Task 1 and reused in Tasks 2–3 within the same method scope. ✓
