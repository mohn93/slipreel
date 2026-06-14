# Zoom Entry Pan Lock-Step Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a cursor-follow zoom's enter ramp, pan the focal `rect.center → cursor` in lock-step with the zoom-in scale (same duration + same resolved curve), so framing arrives at the cursor exactly when magnification hits full — then hand off to the existing spring unchanged.

**Architecture:** Add an enter-ramp branch to `ZoomFocalController.update`, symmetric to the existing exit-ramp branch. Thread the scale's resolved ramp curve (`region.rampCurveOverride ?? screenAnimationConfig.rampCurve`) into the focal pipeline via a new `screenRampCurve` parameter on `ZoomFocalController.update`, `ScenePassBuilder.build`, and `DeterministicFocalTrack.build`/`matches`. Two render call sites (`playback_canvas`, `frame_compositor`) pass `screenAnimationConfig.rampCurve`. Also fix the exit ramp to use the resolved curve instead of its hardcoded `easeInOutQuad`.

**Tech Stack:** Dart, Flutter, slipreel_engine package, flutter_test.

Spec: `docs/superpowers/specs/2026-06-14-zoom-entry-pan-lockstep-design.md`

---

## Task 1: Resolve ramp curve in the controller + apply it to the exit ramp

Add the `screenRampCurve` parameter and resolve the per-frame ramp curve. Use it in the existing exit ramp (replacing the hardcoded `Curves.easeInOutQuad`). This task changes exit-ramp behavior only for regions with a non-default resolved curve; the default keeps current behavior.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `zoom_focal_controller_test.dart` (inside `main()`):

```dart
  test('exit ramp honors the resolved screenRampCurve (not hardcoded)', () {
    // A region that is purely an exit ramp: enter=0, exit=full duration.
    // The focal lerps rect.center -> video center over the exit. With a
    // linear curve the focal is exactly halfway at the ramp midpoint;
    // with easeInOutQuad it is also 0.5 at the midpoint, so probe at the
    // quarter point where the two curves diverge measurably.
    final region = ZoomRegion(
      rect: const Rect.fromLTRB(0, 0, 400, 400), // center (200,200)
      startTime: Duration.zero,
      duration: const Duration(milliseconds: 1000),
      zoomLevel: 2.0,
      enterDuration: Duration.zero,
      exitDuration: const Duration(milliseconds: 1000),
      followCursor: true,
      followMode: FollowMode.centered,
    );
    final centre = Offset(_videoSize.width / 2, _videoSize.height / 2);

    Offset focalAtQuarter(Curve curve) {
      final c = ZoomFocalController();
      Offset last = Offset.zero;
      // Walk to 250ms (quarter of the 1000ms exit ramp) at 16ms steps,
      // cursor held far from centre so the pre-exit focal != centre.
      for (var ms = 0; ms <= 250; ms += 16) {
        final u = c.update(
          position: Duration(milliseconds: ms),
          zoomRegions: [region],
          cursor: const Offset(1900, 1060),
          videoSize: _videoSize,
          screenRampCurve: curve,
        );
        last = u!.focal;
      }
      return last;
    }

    final linear = focalAtQuarter(Curves.linear);
    final eased = focalAtQuarter(Curves.easeInOutQuad);
    // easeInOutQuad(0.25)=0.125 vs linear 0.25 → different lerp toward
    // centre, so the two focal points must differ.
    expect((linear - eased).distance, greaterThan(1.0),
        reason: 'exit ramp must follow screenRampCurve, not a hardcode');
    expect(linear, isNot(equals(centre)));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart -p vm --name "exit ramp honors"`
Expected: FAIL — `update` has no `screenRampCurve` named parameter (compile error).

- [ ] **Step 3: Implement**

In `zoom_focal_controller.dart`:

Change the import on line 1 to expose `Curve`:

```dart
import 'package:flutter/animation.dart' show Curve, Curves;
```

Add the parameter to `update` (in the parameter list, after `forceSnap`/`activeRegionOverride` — keep it before the closing `})`):

```dart
    bool forceSnap = false,
    ZoomRegion? activeRegionOverride,
    Curve screenRampCurve = Curves.easeInOutQuad,
  }) {
```

Immediately after `activeZoom` is resolved and the null-guard returns (i.e. right after the `if (activeZoom == null) { ... return null; }` block, before the `_smoothedFocal == null` init block), add:

```dart
    // Resolved ramp curve for this region's enter/exit focal lock-step.
    // Mirrors the scale's resolution at the render call sites:
    // per-region override wins, else the project's screen ramp curve.
    final rampCurve =
        activeZoom.rampCurveOverride?.toFlutterCurve() ?? screenRampCurve;
```

In the exit-ramp branch, replace:

```dart
        final eased = Curves.easeInOutQuad.transform(tNorm.toDouble());
```

with:

```dart
        final eased = rampCurve.transform(tNorm.toDouble());
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart -p vm --name "exit ramp honors"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart
git commit -m "feat(zoom): resolve ramp curve in focal controller; exit ramp uses it"
```

---

## Task 2: Add the enter-ramp lock-step branch

Pan `rect.center → cursor` over the squeezed enter window using `rampCurve`, then hand off to the spring.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart`

- [ ] **Step 1: Write the failing tests**

Add to `zoom_focal_controller_test.dart`:

```dart
  group('enter ramp lock-step', () {
    ZoomRegion enterRegion({
      bool followCursor = true,
      Duration enter = const Duration(milliseconds: 500),
    }) =>
        ZoomRegion(
          rect: const Rect.fromLTRB(0, 0, 400, 400), // center (200,200)
          startTime: Duration.zero,
          duration: const Duration(milliseconds: 3000),
          zoomLevel: 2.0,
          enterDuration: enter,
          exitDuration: Duration.zero,
          followCursor: followCursor,
          followMode: FollowMode.centered,
        );

    Offset walkTo(ZoomFocalController c, ZoomRegion r, int toMs,
        {required Offset cursor, Curve curve = Curves.easeInOutQuad}) {
      Offset last = Offset.zero;
      for (var ms = 0; ms <= toMs; ms += 16) {
        last = c
            .update(
              position: Duration(milliseconds: ms),
              zoomRegions: [r],
              cursor: cursor,
              videoSize: _videoSize,
              screenRampCurve: curve,
            )!
            .focal;
      }
      return last;
    }

    test('focal arrives at the cursor by the end of enterDuration', () {
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      final atEnd =
          walkTo(ZoomFocalController(), r, 500, cursor: cursor);
      // By the end of the 500ms enter ramp the focal should essentially
      // equal the cursor target (the lerp reaches eased(1)=1).
      expect((atEnd - cursor).distance, lessThan(2.0));
    });

    test('halfway through the ramp the focal is between center and cursor',
        () {
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      const centre = Offset(200, 200);
      final mid = walkTo(ZoomFocalController(), r, 250, cursor: cursor);
      // Strictly between the start (rect.center) and the cursor — proves
      // the pan is in progress, not snapped and not still parked.
      expect((mid - centre).distance, greaterThan(2.0));
      expect((mid - cursor).distance, greaterThan(2.0));
    });

    test('followCursor:false makes the enter ramp a no-op (stays center)',
        () {
      final r = enterRegion(followCursor: false);
      const cursor = Offset(1700, 950);
      const centre = Offset(200, 200);
      final mid = walkTo(ZoomFocalController(), r, 250, cursor: cursor);
      expect((mid - centre).distance, lessThan(1.0));
    });

    test('the resolved curve shapes the ramp (linear != easeInOutQuad)',
        () {
      final r = enterRegion();
      const cursor = Offset(1700, 950);
      final lin = walkTo(ZoomFocalController(), r, 250,
          cursor: cursor, curve: Curves.linear);
      final eas = walkTo(ZoomFocalController(), r, 250,
          cursor: cursor, curve: Curves.easeInOutQuad);
      expect((lin - eas).distance, greaterThan(1.0));
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart -p vm --name "enter ramp lock-step"`
Expected: FAIL — focal stays near center / springs slowly (arrives late), so `arrives at the cursor by the end` fails.

- [ ] **Step 3: Implement**

In `zoom_focal_controller.dart`:

Add a field next to `_exitRampStartFocal` (after its declaration around line 81):

```dart
  // Focal at the moment the enter ramp started (captured on the first
  // enter-ramp frame, = rect.center). Cleared when the controller leaves
  // the enter window so a re-entry re-captures.
  Offset? _enterRampStartFocal;
```

Set it to null everywhere `_exitRampStartFocal` is reset:
- In the `if (activeZoom == null)` block, add `_enterRampStartFocal = null;`.
- In the `if (_smoothedFocal == null)` init block, add `_enterRampStartFocal = null;` (before the `return`).
- In `reset()`, add `_enterRampStartFocal = null;`.

Insert the enter-ramp branch AFTER `final target = resolution.target;` / `final isHolding = resolution.isHolding;` and BEFORE the `// Step the spring.` comment:

```dart
    // Enter ramp: pan rect.center -> cursor in lock-step with the zoom-in
    // scale (same window, same resolved curve), symmetric to the exit
    // ramp above. The focal arrives at the cursor target exactly as
    // magnification reaches full, then the spring takes over for
    // steady-state follow. A finite-difference velocity is handed to the
    // spring so a cursor still moving at ramp end doesn't stall.
    final enter = _enterRampWindow(activeZoom);
    if (enter != null) {
      final tIntoRegionUs =
          position.inMicroseconds - activeZoom.startTime.inMicroseconds;
      if (tIntoRegionUs >= 0 && tIntoRegionUs < enter.enterUs) {
        _enterRampStartFocal ??= _smoothedFocal;
        final tNorm =
            (tIntoRegionUs / enter.enterUs).clamp(0.0, 1.0).toDouble();
        final eased = rampCurve.transform(tNorm);
        final prevFocal = _smoothedFocal!;
        final newFocal = Offset.lerp(_enterRampStartFocal, target, eased)!;
        final dtUs = prevPosition == null
            ? 0
            : position.inMicroseconds - prevPosition.inMicroseconds;
        if (dtUs > 0) {
          final dt = dtUs / 1e6;
          _focalVx = (newFocal.dx - prevFocal.dx) / dt;
          _focalVy = (newFocal.dy - prevFocal.dy) / dt;
        }
        _smoothedFocal = newFocal;
        return ZoomFocalUpdate(zoom: activeZoom, focal: newFocal);
      }
    }
    // Outside the enter window — clear the anchor so a re-entry into an
    // enter ramp re-captures from a fresh position.
    _enterRampStartFocal = null;
```

Add the `_enterRampWindow` helper next to `_exitRampWindow`:

```dart
  /// Enter ramp window for [zoom] in microseconds — the first
  /// [ZoomRegion.enterDuration], proportionally squeezed (matching
  /// [ZoomTransformer._calculateZoomFactor]) when enter+exit overflow the
  /// region. Returns null when there's no enter ramp (zero-length region
  /// or zero enter duration).
  static ({int enterUs})? _enterRampWindow(ZoomRegion zoom) {
    final regionUs = zoom.duration.inMicroseconds;
    if (regionUs <= 0) return null;
    var enterUs = zoom.enterDuration.inMicroseconds;
    final exitUs = zoom.exitDuration.inMicroseconds;
    final totalRamp = enterUs + exitUs;
    if (totalRamp > regionUs && totalRamp > 0) {
      final scale = regionUs / totalRamp;
      enterUs = (enterUs * scale).round();
    }
    if (enterUs <= 0) return null;
    return (enterUs: enterUs);
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart -p vm`
Expected: PASS (the new group + all existing tests — existing focal tests default `enterDuration: Duration.zero`, so the enter branch is a no-op for them).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart
git commit -m "feat(zoom): lock-step enter-ramp focal pan (rect.center->cursor over enterDuration)"
```

---

## Task 3: Thread `screenRampCurve` through `ScenePassBuilder.build`

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart`
- Test: `packages/slipreel_engine/test/rendering/scene_pass_builder_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `scene_pass_builder_test.dart` (inside `main()`; if helpers like a region/recording builder already exist in the file, reuse them — otherwise this self-contained test stands alone):

```dart
  test('build forwards screenRampCurve into the focal enter ramp', () {
    final region = ZoomRegion(
      rect: const Rect.fromLTRB(0, 0, 400, 400),
      startTime: Duration.zero,
      duration: const Duration(milliseconds: 3000),
      zoomLevel: 2.0,
      enterDuration: const Duration(milliseconds: 500),
      exitDuration: Duration.zero,
      followCursor: true,
      followMode: FollowMode.centered,
    );
    final recording = CursorRecording();
    for (var ms = 0; ms <= 3000; ms += 16) {
      recording.addPosition(
          CursorPosition(x: 1700, y: 950, timestampMicros: ms * 1000));
    }
    const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
    const videoSize = Size(1920, 1080);

    Offset focalAt250(Curve curve) {
      final b = ScenePassBuilder();
      Offset last = Offset.zero;
      for (var ms = 0; ms <= 250; ms += 16) {
        final p = b.build(
          position: Duration(milliseconds: ms),
          zoomRegions: [region],
          cursorAnimationConfig: cfg,
          cursorRecording: recording,
          videoSize: videoSize,
          fps: 60,
          hasCursorData: true,
          screenRampCurve: curve,
        );
        last = p.focalUpdate!.focal;
      }
      return last;
    }

    expect((focalAt250(Curves.linear) - focalAt250(Curves.easeInOutQuad))
            .distance,
        greaterThan(1.0));
  });
```

Ensure the test file imports `package:flutter/animation.dart` (for `Curve`/`Curves`), `package:flutter/painting.dart` (for `Size`/`Offset`/`Rect`), and the cursor-recording/animation-config/zoom-region models. Add any that are missing.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/scene_pass_builder_test.dart -p vm --name "screenRampCurve"`
Expected: FAIL — `build` has no `screenRampCurve` parameter (compile error).

- [ ] **Step 3: Implement**

In `scene_pass_builder.dart`:

Add an import for the curve types (after the existing imports):

```dart
import 'package:flutter/animation.dart' show Curve, Curves;
```

Add the parameter to `build` (after `cursorPostProcess`, before `forceSnap` — anywhere in the named list is fine):

```dart
    Duration cursorDelay = Duration.zero,
    CursorPostProcess cursorPostProcess = CursorPostProcess.none,
    Curve screenRampCurve = Curves.easeInOutQuad,
    bool forceSnap = false,
```

Pass it into the `focal.update(...)` call:

```dart
    final focalUpdate = focal.update(
      position: position,
      zoomRegions: zoomRegions,
      cursor: cursorForFocal,
      videoSize: videoSize,
      cursorVelocity: rawVelocity,
      forceSnap: forceSnap,
      activeRegionOverride: activeRegionOverride,
      screenRampCurve: screenRampCurve,
    );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/scene_pass_builder_test.dart -p vm`
Expected: PASS (new test + existing scene-pass tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/scene_pass_builder.dart packages/slipreel_engine/test/rendering/scene_pass_builder_test.dart
git commit -m "feat(zoom): thread screenRampCurve through ScenePassBuilder.build"
```

---

## Task 4: Thread `screenRampCurve` through `DeterministicFocalTrack`

The deterministic track (scrub/paused preview + export blur sampling) must replay the same enter ramp, and `matches` must be curve-sensitive so the cache rebuilds when the curve changes.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart`
- Test: `packages/slipreel_engine/test/rendering/deterministic_focal_track_test.dart`

- [ ] **Step 1: Write the failing tests**

Add to `deterministic_focal_track_test.dart`:

```dart
  test('screenRampCurve shapes the deterministic enter-ramp focal', () {
    final rec = sweep();
    const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
    // The shared [region] starts at 2542ms with a 500ms enter ramp, so
    // probe ~125ms into the ramp where curve shape matters.
    final probe = region.startTime + const Duration(milliseconds: 125);
    final linear = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: rec,
      cursorAnimationConfig: cfg,
      videoSize: videoSize,
      fps: 60,
      screenRampCurve: Curves.linear,
    ).focalAt(probe);
    final eased = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: rec,
      cursorAnimationConfig: cfg,
      videoSize: videoSize,
      fps: 60,
      screenRampCurve: Curves.easeInOutQuad,
    ).focalAt(probe);
    expect((linear - eased).distance, greaterThan(1.0));
  });

  test('changed screenRampCurve → matches() false', () {
    final recording = sweep();
    const config = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
    final track = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: recording,
      cursorAnimationConfig: config,
      videoSize: videoSize,
      fps: 60,
      screenRampCurve: Curves.easeInOutQuad,
    );
    expect(
      track.matches(
        region: region,
        cursorRecording: recording,
        cursorAnimationConfig: config,
        cursorPostProcess: CursorPostProcess.none,
        videoSize: videoSize,
        fps: 60,
        screenRampCurve: Curves.linear,
      ),
      isFalse,
    );
  });

  test('omitted screenRampCurve defaults to easeInOutQuad — back-compat', () {
    final recording = sweep();
    const config = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
    final track = DeterministicFocalTrack.build(
      region: region,
      cursorRecording: recording,
      cursorAnimationConfig: config,
      videoSize: videoSize,
      fps: 60,
    ); // no screenRampCurve
    expect(
      track.matches(
        region: region,
        cursorRecording: recording,
        cursorAnimationConfig: config,
        cursorPostProcess: CursorPostProcess.none,
        videoSize: videoSize,
        fps: 60,
      ), // no screenRampCurve
      isTrue,
    );
  });
```

Add `import 'package:flutter/animation.dart' show Curves;` to the test file if not already present (it imports `package:flutter/material.dart`, which re-exports `Curves`, so this may be unnecessary — only add if the analyzer complains).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/slipreel_engine && flutter test test/rendering/deterministic_focal_track_test.dart -p vm --name "screenRampCurve"`
Expected: FAIL — `build`/`matches` have no `screenRampCurve` parameter (compile error).

- [ ] **Step 3: Implement**

In `deterministic_focal_track.dart`:

Add an import:

```dart
import 'package:flutter/animation.dart' show Curve, Curves;
```

Add a field (next to `cursorDelay`):

```dart
  /// Screen ramp curve forwarded to the replayed [ScenePassBuilder] so the
  /// deterministic enter/exit focal ramps match the live camera's. Default
  /// [Curves.easeInOutQuad] keeps export (which omits it) unchanged.
  final Curve screenRampCurve;
```

Add it to the private constructor (`DeterministicFocalTrack._({...})`) as `required this.screenRampCurve,`.

Add the parameter to `build`:

```dart
    CursorPostProcess cursorPostProcess = CursorPostProcess.none,
    Duration cursorDelay = Duration.zero,
    Curve screenRampCurve = Curves.easeInOutQuad,
  }) {
```

Pass it into the replay `builder.build(...)`:

```dart
        cursorPostProcess: cursorPostProcess,
        cursorRecording: cursorRecording,
        videoSize: videoSize,
        fps: fps,
        hasCursorData: hasCursor,
        screenRampCurve: screenRampCurve,
      );
```

Pass it into the returned constructor:

```dart
      cursorDelay: cursorDelay,
      screenRampCurve: screenRampCurve,
      videoSize: videoSize,
```

Add it to `matches` (parameter + comparison):

```dart
    required int fps,
    Duration cursorDelay = Duration.zero,
    Curve screenRampCurve = Curves.easeInOutQuad,
  }) {
    return identical(this.cursorRecording, cursorRecording) &&
        this.cursorAnimationConfig == cursorAnimationConfig &&
        this.region == region &&
        this.cursorPostProcess == cursorPostProcess &&
        this.cursorDelay == cursorDelay &&
        this.screenRampCurve == screenRampCurve &&
        this.videoSize == videoSize &&
        this.fps == fps;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/rendering/deterministic_focal_track_test.dart -p vm`
Expected: PASS (new tests + the existing track tests — confirm the existing "no snap <40px in first 16ms" and "converges during hold" assertions still hold under the lock-step entry; if either now encodes the old slow-spring trajectory, update the assertion to preserve its INTENT, not its exact number, and note it in the commit).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart packages/slipreel_engine/test/rendering/deterministic_focal_track_test.dart
git commit -m "feat(zoom): thread screenRampCurve through DeterministicFocalTrack + cache key"
```

---

## Task 5: Update render call sites (preview + export)

Pass `screenAnimationConfig.rampCurve` at both `ScenePassBuilder.build` call sites and both `DeterministicFocalTrack` (build + matches) call sites, so preview and export use the same entry as the controller.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`

- [ ] **Step 1: Edit `playback_canvas.dart`**

In the `_scenePassBuilder.build(...)` call (around line 587), add:

```dart
              hasCursorData: hasCursorData,
              screenRampCurve: widget.screenAnimationConfig.rampCurve,
```

In `_focalTrackFor(...)` (around line 1275), add `screenRampCurve:` to BOTH the `cached.matches(...)` call and the `DeterministicFocalTrack.build(...)` call:

```dart
          fps: fps,
          cursorDelay: widget.cursorDelay,
          screenRampCurve: widget.screenAnimationConfig.rampCurve,
        )) {
```

```dart
      cursorPostProcess: widget.cursorPostProcess,
      cursorDelay: widget.cursorDelay,
      screenRampCurve: widget.screenAnimationConfig.rampCurve,
    );
```

- [ ] **Step 2: Edit `frame_compositor.dart`**

In the `_scenePassBuilder.build(...)` call (around line 169), add:

```dart
        hasCursorData: _hasCursorData,
        screenRampCurve: projectState.screenAnimationConfig.rampCurve,
      );
```

In the `_focalTrack` builder (around line 430), add `screenRampCurve:` to BOTH the `cached.matches(...)` and the `DeterministicFocalTrack.build(...)` calls:

```dart
          videoSize: videoSize,
          fps: fps,
          screenRampCurve: projectState.screenAnimationConfig.rampCurve,
        )) {
```

```dart
      cursorPostProcess: projectState.cursorPostProcess,
      videoSize: videoSize,
      fps: fps,
      screenRampCurve: projectState.screenAnimationConfig.rampCurve,
    );
```

- [ ] **Step 3: Analyze both packages**

Run: `cd packages/slipreel_engine && flutter analyze lib && cd ../screen_recorder && flutter analyze lib`
Expected: No new errors. (`ScreenAnimationConfig.rampCurve` returns a `Curve`, matching the parameter type.)

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart packages/slipreel_engine/lib/export/frame_compositor.dart
git commit -m "feat(zoom): pass screenAnimationConfig.rampCurve into focal entry at preview+export call sites"
```

---

## Task 6: Full-suite verification + reconciliation

**Files:**
- Possibly modify: any test whose assertion encoded the old slow-spring entry.

- [ ] **Step 1: Run both suites**

Run:
```bash
cd packages/slipreel_engine && flutter test -p vm
cd ../screen_recorder && flutter test -p vm
```
Expected: All green. Existing `screen_recorder` zoom/playback tests don't pass `screenRampCurve` (defaulted), so they keep compiling; the deterministic-track-driven preview tests will exercise the new entry.

- [ ] **Step 2: Reconcile any shifted assertions**

If a test fails because its expected focal value encoded the pre-change slow-spring entry trajectory, update it to preserve the test's INTENT (e.g. "focal moves smoothly from rect.center without snapping", "converges toward the cursor") rather than its exact pre-change number. Do NOT loosen a test to hide a real regression — if a failure indicates the camera no longer reaches the cursor or overshoots badly, stop and investigate.

- [ ] **Step 3: Commit any reconciliation**

```bash
git add -A
git commit -m "test(zoom): reconcile focal trajectory assertions with lock-step entry"
```

- [ ] **Step 4: Runtime verification (manual, by the operator)**

Run: `flutter run -d macos -t lib/main_dev.dart` from `packages/screen_recorder`. Open a clip whose cursor sits near a screen edge inside a cursor-follow zoom. Confirm in preview that the pan to the cursor and the zoom-in finish together (no late drift), and that play / scrub / paused all frame the same spot. This step is performed by the user; report results before merging.
