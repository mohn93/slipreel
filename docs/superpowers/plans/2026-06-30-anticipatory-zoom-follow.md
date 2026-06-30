# Anticipatory Zoom Follow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the zoom camera's "Predictive" follow mode actually anticipate the cursor (velocity look-ahead + deadzone) and add a universal keep-in-view guarantee so the cursor never leaves the zoomed frame.

**Architecture:** Three layers in the focal pipeline. (1) Predictive's follow strategy aims at the velocity-led cursor (`cursor + velocity·leadTime`) through the existing deadzone gate — calm, but starts panning before the cursor reaches an edge. (2) A new pure `ZoomFraming` helper clamps the settled focal so the live cursor stays inside the viewport minus an edge margin, wired into `ZoomFocalController.update()` for ALL modes. (3) The old trailing-median plumbing is removed. All three are pure functions of `(cursor, velocity, focal, zoom, framing)`, so live play / scrub-paused / export stay byte-identical via the single `update()` path replayed by `DeterministicFocalTrack`.

**Tech Stack:** Dart / Flutter; melos monorepo. Engine logic in `packages/slipreel_engine`, editor UI in `packages/screen_recorder`. Tests are `flutter test` (`@TestOn` guards exist for goldens; these tasks add plain VM tests).

## Global Constraints

- **Determinism:** every focal-path change must be a pure function of `(cursor, cursorVelocity, focal, zoom, framing)`. No wall-clock, no `Math.random`. `DeterministicFocalTrack.build` → `ScenePassBuilder.build` → `ZoomFocalController.update` is the single replay path; keep-in-view and lead must live inside it so play == scrub == export.
- **Do NOT run `dart format`** on existing files — the pinned formatter reflows ~50+ unrelated lines and CI does not enforce it. Match surrounding style by hand. Verify with analyze + test only.
- **Field name stays `predictiveWindow`.** Its *meaning* changes to the look-ahead lead duration (documented), its clamp becomes `[80ms, 250ms]`, default `150ms`. The JSON key `predictiveWindowMicros` is retained for file compatibility. Do NOT rename the Dart field (avoids a cross-file compile cascade and merge conflicts with open branches).
- **Bounded and Centered behavior must not change** except for the added keep-in-view clamp. The existing `follow_strategy_test.dart` Bounded/Centered cases must stay green verbatim.
- **Test/verify per package:** run engine tests with
  `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test <path>`.
- Lead math uses seconds: `leadSec = zoom.predictiveWindow.inMicroseconds / 1e6`.

---

### Task 1: Add `keepInViewEdgeMargin` to MotionTuning

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/motion_tuning.dart`
- Test: `packages/slipreel_engine/test/rendering/motion_tuning_test.dart` (create if absent; otherwise add cases)

**Interfaces:**
- Produces: `MotionTuning.keepInViewEdgeMargin` (`double`, default `0.1`) — fraction of the canvas short side kept between the live cursor and the viewport edge. Flows through `copyWith` / `toJson` (key `keepInViewEdgeMargin`) / `fromJson`.

- [ ] **Step 1: Write the failing test**

Create/append `packages/slipreel_engine/test/rendering/motion_tuning_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';

void main() {
  test('keepInViewEdgeMargin defaults to 0.1', () {
    expect(MotionTuning.defaults.keepInViewEdgeMargin, 0.1);
  });

  test('keepInViewEdgeMargin round-trips through JSON', () {
    const t = MotionTuning(keepInViewEdgeMargin: 0.18);
    final restored = MotionTuning.fromJson(t.toJson());
    expect(restored.keepInViewEdgeMargin, 0.18);
  });

  test('copyWith overrides keepInViewEdgeMargin', () {
    final t = MotionTuning.defaults.copyWith(keepInViewEdgeMargin: 0.2);
    expect(t.keepInViewEdgeMargin, 0.2);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/motion_tuning_test.dart`
Expected: FAIL — `keepInViewEdgeMargin` is not defined on `MotionTuning`.

- [ ] **Step 3: Add the field**

In `motion_tuning.dart`, add the constructor param (after `cursorFeedforwardFullSpeedPxPerSec` on line 28):

```dart
    this.cursorFeedforwardFullSpeedPxPerSec = 800.0,
    this.keepInViewEdgeMargin = 0.1,
```

Add the field with a doc comment (after the `cursorFeedforwardFullSpeedPxPerSec` field, ~line 76):

```dart
  /// Fraction of the canvas short side kept between the live cursor and the
  /// zoomed viewport edge by the keep-in-view safety clamp. 0.1 = the cursor
  /// is held at least 10% of the short side in from any edge (when geometry
  /// allows). Applies to every follow mode.
  final double keepInViewEdgeMargin;
```

Add to `copyWith` params (after `cursorFeedforwardFullSpeedPxPerSec`):

```dart
    double? keepInViewEdgeMargin,
```

and the body assignment:

```dart
      keepInViewEdgeMargin:
          keepInViewEdgeMargin ?? this.keepInViewEdgeMargin,
```

Add to `toJson` (after the `cursorFeedforwardFullSpeedPxPerSec` entry):

```dart
        'keepInViewEdgeMargin': keepInViewEdgeMargin,
```

Add to `fromJson` (after `cursorFeedforwardFullSpeedPxPerSec`):

```dart
      keepInViewEdgeMargin:
          doubleOr('keepInViewEdgeMargin', d.keepInViewEdgeMargin),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/motion_tuning_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/motion_tuning.dart packages/slipreel_engine/test/rendering/motion_tuning_test.dart
git commit -m "feat(zoom): add keepInViewEdgeMargin tuning constant"
```

---

### Task 2: `ZoomFraming.clampFocalKeepCursorInView`

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/zoom_framing.dart`
- Test: `packages/slipreel_engine/test/rendering/zoom_framing_keep_in_view_test.dart` (create)

**Interfaces:**
- Consumes: existing `clampFocal(Offset, double)`, `toCanvas`/`fromCanvas`, `canvasSize`.
- Produces: `Offset clampFocalKeepCursorInView(Offset focal, Offset cursor, double z, double edgeMarginFraction)` — pulls `focal` the minimum amount so `cursor` stays `edgeMarginFraction × min(canvasW, canvasH)` inside the viewport (size `canvasSize / z`), then re-imposes `clampFocal` so the viewport never leaves the canvas (graceful degradation near true edges). At `z <= 1` returns `clampFocal(focal, z)` unchanged.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/rendering/zoom_framing_keep_in_view_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

const _video = Size(1920, 1080);

void main() {
  final fr = ZoomFraming.identity(_video);

  test('cursor already centered: focal unchanged (no-op)', () {
    const focal = Offset(960, 540);
    final out = fr.clampFocalKeepCursorInView(focal, focal, 2.0, 0.1);
    expect((out - focal).distance, lessThan(0.001));
  });

  test('cursor well inside margin: focal unchanged', () {
    // z=2 viewport is 960x540, half = 480x270. margin = 0.1*1080 = 108.
    // allowed = 480-108 = 372 (x). Cursor 100px from focal is inside.
    const focal = Offset(960, 540);
    final cursor = focal + const Offset(100, 0);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.1);
    expect((out - focal).distance, lessThan(0.001));
  });

  test('cursor beyond margin: focal pulled minimally toward cursor', () {
    // allowedX = 372. Cursor 500px right of focal => focal must move so
    // it is within 372px of the cursor: focal.x = cursor.x - 372.
    const focal = Offset(960, 540);
    final cursor = focal + const Offset(500, 0);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.1);
    expect(out.dx, closeTo(cursor.dx - 372, 0.5));
    expect(out.dy, closeTo(540, 0.5));
    // Cursor is now exactly at the margin edge inside the viewport.
    expect((cursor.dx - out.dx).abs(), closeTo(372, 0.5));
  });

  test('near the true canvas edge: reachable clamp wins (degrades)', () {
    // Cursor hard against the right edge; keep-in-view wants focal further
    // right than reachable, so clampFocal pins the viewport on-canvas.
    const focal = Offset(960, 540);
    const cursor = Offset(1915, 540);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 2.0, 0.1);
    // Reachable focal max at z=2 is 1920 - 1920/(2*2) = 1440.
    expect(out.dx, closeTo(1440, 0.5));
  });

  test('z <= 1: returns clampFocal unchanged', () {
    const focal = Offset(960, 540);
    const cursor = Offset(100, 100);
    final out = fr.clampFocalKeepCursorInView(focal, cursor, 1.0, 0.1);
    expect(out, fr.clampFocal(focal, 1.0));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/zoom_framing_keep_in_view_test.dart`
Expected: FAIL — method `clampFocalKeepCursorInView` not defined.

- [ ] **Step 3: Implement the helper**

In `zoom_framing.dart`, add at the top with the other imports:

```dart
import 'dart:math' as math;
```

Add the method inside the class (e.g. after `clampFocalRadial`, ~line 111):

```dart
  /// Pulls [focal] the minimum amount so the live [cursor] stays at least
  /// [edgeMarginFraction] of the canvas short side inside the zoomed viewport
  /// (size `canvasSize / z`), then re-imposes [clampFocal] so the viewport
  /// never leaves the canvas. Near a true canvas edge the reachable clamp
  /// wins and the cursor may approach the edge — graceful degradation.
  ///
  /// Pure function of (focal, cursor, z, margin) — identical for identity and
  /// device framing because the math runs in canvas space. Used by
  /// [ZoomFocalController] as a per-frame safety after the spring step.
  Offset clampFocalKeepCursorInView(
    Offset focal,
    Offset cursor,
    double z,
    double edgeMarginFraction,
  ) {
    if (z <= 1.0) return clampFocal(focal, z);
    final cf = toCanvas(focal);
    final cc = toCanvas(cursor);
    final halfW = canvasSize.width / (2 * z);
    final halfH = canvasSize.height / (2 * z);
    final marginPx = edgeMarginFraction.clamp(0.0, 0.49) *
        math.min(canvasSize.width, canvasSize.height);
    final allowedX = math.max(0.0, halfW - marginPx);
    final allowedY = math.max(0.0, halfH - marginPx);
    final nx = cf.dx.clamp(cc.dx - allowedX, cc.dx + allowedX);
    final ny = cf.dy.clamp(cc.dy - allowedY, cc.dy + allowedY);
    return clampFocal(fromCanvas(Offset(nx, ny)), z);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/zoom_framing_keep_in_view_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/zoom_framing.dart packages/slipreel_engine/test/rendering/zoom_framing_keep_in_view_test.dart
git commit -m "feat(zoom): ZoomFraming.clampFocalKeepCursorInView keep-in-view clamp"
```

---

### Task 3: Wire keep-in-view into `ZoomFocalController.update()`

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart` (final hold-phase return, ~line 796)
- Test: `packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart` (add cases)

**Interfaces:**
- Consumes: `tuning.keepInViewEdgeMargin` (Task 1), `fr.clampFocalKeepCursorInView` (Task 2), the in-scope `cursor` (already off-screen-frozen), `fr` (the resolved `ZoomFraming`), `activeZoom.zoomLevel`.
- Produces: no signature change — the steady-state `ZoomFocalUpdate.focal` is now keep-in-view-clamped for every follow mode.

- [ ] **Step 1: Write the failing test**

Append to `packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart` (inside `void main()`; reuse the file's existing helpers/imports — it already imports the controller, `ZoomRegion`, `Offset`, `Size`). Add a self-contained group:

```dart
  group('keep-in-view safety', () {
    test('steady-state focal keeps a far cursor inside the viewport margin',
        () {
      const videoSize = Size(1920, 1080);
      final controller = ZoomFocalController(); // defaults: margin 0.1
      final zoom = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 0, 0),
        startTime: Duration.zero,
        duration: const Duration(seconds: 4),
        zoomLevel: 2.0,
        enterDuration: Duration.zero,
        exitDuration: Duration.zero,
        followCursor: true,
        followMode: FollowMode.centered, // simplest: springs toward cursor
        followDuration: const Duration(milliseconds: 850),
      );

      // Prime the spring at center, then jump the cursor far right and step
      // a single small frame so the spring lags well behind the cursor.
      controller.update(
        position: const Duration(milliseconds: 1000),
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: videoSize,
      );
      final out = controller.update(
        position: const Duration(milliseconds: 1016),
        zoomRegions: [zoom],
        cursor: const Offset(1700, 540),
        videoSize: videoSize,
      );

      // Viewport half-width at z=2 is 480; margin 0.1*1080 = 108; allowed 372.
      // The cursor must be within 372px of the returned focal on x.
      expect(out, isNotNull);
      expect((1700 - out!.focal.dx).abs(), lessThanOrEqualTo(372 + 0.5),
          reason: 'keep-in-view must pull the lagging focal toward the cursor');
    });

    test('cursor near canvas edge: focal pinned to reachable bound', () {
      const videoSize = Size(1920, 1080);
      final controller = ZoomFocalController();
      final zoom = ZoomRegion(
        rect: const Rect.fromLTRB(0, 0, 0, 0),
        startTime: Duration.zero,
        duration: const Duration(seconds: 4),
        zoomLevel: 2.0,
        enterDuration: Duration.zero,
        exitDuration: Duration.zero,
        followCursor: true,
        followMode: FollowMode.centered,
      );
      controller.update(
        position: const Duration(milliseconds: 1000),
        zoomRegions: [zoom],
        cursor: const Offset(960, 540),
        videoSize: videoSize,
      );
      final out = controller.update(
        position: const Duration(milliseconds: 1016),
        zoomRegions: [zoom],
        cursor: const Offset(1915, 540),
        videoSize: videoSize,
      );
      // Reachable focal max at z=2 == 1440; keep-in-view cannot exceed it.
      expect(out!.focal.dx, lessThanOrEqualTo(1440 + 0.5));
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart --plain-name "keep-in-view safety"`
Expected: FAIL — the first test's `(1700 - focal.dx)` exceeds 372 because nothing clamps the lagging focal yet.

- [ ] **Step 3: Add the clamp at the steady-state return**

In `zoom_focal_controller.dart`, replace the final return of `update()` (currently line ~796):

```dart
    return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
  }
```

with:

```dart
    // Keep-in-view safety: ensure the live cursor never leaves the framed
    // viewport (minus an edge margin), regardless of follow mode. Runs only
    // in the steady-state hold phase (enter/exit ramps return earlier with
    // their own framing). Pure function of (cursor, focal, zoom, framing) so
    // the live spring, the DeterministicFocalTrack replay, and export stay
    // byte-identical.
    if (cursor != null) {
      _smoothedFocal = fr.clampFocalKeepCursorInView(
        _smoothedFocal!,
        cursor,
        activeZoom.zoomLevel,
        tuning.keepInViewEdgeMargin,
      );
    }
    return ZoomFocalUpdate(zoom: activeZoom, focal: _smoothedFocal!);
  }
```

Note: `_focalVx`/`_focalVy` are intentionally left untouched — zeroing them on the clamp would stutter; the spring re-converges naturally from the constrained position next frame.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart`
Expected: PASS — the new group passes AND every pre-existing controller test stays green (the clamp is a no-op whenever the cursor is already inside the margin, which the existing interior-cursor cases are).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart
git commit -m "feat(zoom): keep-in-view clamp on steady-state focal (all modes)"
```

---

### Task 4: Remove the trailing-median plumbing

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart:176-190`
- Modify: `packages/slipreel_engine/lib/rendering/cursor_geometry.dart` (remove `medianCursorOver`, ~lines 215-251)
- Modify: `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart:514-521`
- Delete: `packages/slipreel_engine/test/rendering/cursor_geometry_median_test.dart`
- Modify: `packages/slipreel_engine/test/rendering/scene_pass_builder_test.dart` (rewrite the predictive test, ~lines 235-275)

**Interfaces:**
- Produces: predictive mode now receives the spring-smoothed sprite cursor for the focal (same as bounded/centered); the look-ahead lives entirely in the strategy (Task 6). `medianCursorOver` no longer exists.

- [ ] **Step 1: Rewrite the predictive scene-builder test to expect equality**

In `scene_pass_builder_test.dart`, replace the body of the `'uses median cursor for predictive follow mode'` test (lines ~235-275) with a test that asserts predictive now tracks the sprite (rename the test too):

```dart
    test('predictive follow mode focals on the sprite cursor (no median)', () {
      // Predictive no longer diverges from the sprite at the scene-builder
      // level — the look-ahead now lives in PredictiveFollowStrategy. So the
      // focal cursor handed to the controller equals the sprite position.
      final builder = ScenePassBuilder();
      final project = _projectWith(
        zooms: [
          _predictive(
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            rect: const Rect.fromLTWH(960, 540, 0, 0),
          ),
        ],
      );
      final recording = _eastBoundRecording(durationMs: 1000);

      final pass = _drive(
        builder,
        project: project,
        recording: recording,
        from: Duration.zero,
        to: const Duration(milliseconds: 600),
      );

      expect(pass.activeZoom, isNotNull);
      expect(pass.activeZoom!.followMode, FollowMode.predictive);
      expect(pass.motion, isNotNull);
      expect(pass.cursorForFocal, isNotNull);
      expect(
        (pass.cursorForFocal! - pass.motion!.screenPos).distance,
        lessThan(0.001),
        reason: 'predictive focal cursor == sprite once median is removed',
      );
    });
```

Also simplify the `_predictive` helper (lines ~75-93): drop the `predictiveWindow` parameter so it uses the model default (the helper no longer needs to vary it):

```dart
ZoomRegion _predictive({
  required Duration startTime,
  required Duration duration,
  Rect rect = const Rect.fromLTRB(0, 0, 0, 0),
}) {
  return ZoomRegion(
    rect: rect,
    startTime: startTime,
    duration: duration,
    zoomLevel: 2.0,
    enterDuration: Duration.zero,
    exitDuration: Duration.zero,
    followCursor: true,
    followMode: FollowMode.predictive,
    followDuration: const Duration(milliseconds: 400),
  );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/scene_pass_builder_test.dart --plain-name "predictive follow mode focals on the sprite cursor"`
Expected: FAIL — scene builder still substitutes the median, so `cursorForFocal != sprite`.

- [ ] **Step 3: Remove the median branch in the scene builder**

In `scene_pass_builder.dart`, replace lines 176-190 (the comment + `cursorForFocal` ternary) with:

```dart
    final activeZoom =
        activeRegionOverride ?? _activeZoomAt(position, zoomRegions);
    // Every follow mode (including predictive) tracks the spring-smoothed
    // sprite cursor so the camera and the visible cursor never disagree.
    // Predictive's look-ahead is applied inside PredictiveFollowStrategy.
    final Offset? cursorForFocal = motionSample?.screenPos;
```

If `medianCursorOver` was imported via a now-unused import in this file, remove that import line (run analyze in Step 6 to confirm).

- [ ] **Step 4: Remove `medianCursorOver` and its plumbing in the playground**

In `cursor_geometry.dart`, delete the entire `medianCursorOver(...)` function (~lines 215-251).

In `motion_blur_playground_screen.dart`, replace lines 514-521 with:

```dart
    final cursorForFocal = motion?.screenPos;
```

Remove the now-unused `medianCursorOver` import in the playground file if analyze flags it.

Delete the median test file:

```bash
git rm packages/slipreel_engine/test/rendering/cursor_geometry_median_test.dart
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/scene_pass_builder_test.dart && flutter test test/rendering/cursor_geometry_test.dart
```
Expected: PASS — the rewritten predictive test passes; remaining cursor-geometry tests are unaffected.

- [ ] **Step 6: Analyze to catch dangling imports**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos analyze` (or `flutter analyze` in each of the two packages).
Expected: no errors. Remove any "unused import" for `cursor_geometry`/`medianCursorOver` it reports.

- [ ] **Step 7: Commit**

```bash
git add -A packages/slipreel_engine/lib/rendering/scene_pass_builder.dart packages/slipreel_engine/lib/rendering/cursor_geometry.dart packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart packages/slipreel_engine/test/rendering/scene_pass_builder_test.dart packages/slipreel_engine/test/rendering/cursor_geometry_median_test.dart
git commit -m "refactor(zoom): remove trailing-median predictive plumbing"
```

---

### Task 5: Repurpose `predictiveWindow` as the look-ahead lead time

**Files:**
- Modify: `packages/slipreel_engine/lib/models/zoom_region.dart` (clamp, default, docs)
- Modify: `packages/slipreel_engine/test/models/zoom_region_json_test.dart` (lines ~25, ~86)
- Modify: `packages/slipreel_engine/test/state/editor_project_store_test.dart` (line ~38, if it asserts the value)
- Test: `packages/slipreel_engine/test/models/zoom_region_test.dart` (add clamp/default cases; create if absent)

**Interfaces:**
- Produces: `ZoomRegion.predictiveWindow` now means the predictive look-ahead lead duration. Default `150ms`. Construction clamps to `[80ms, 250ms]`. JSON key unchanged (`predictiveWindowMicros`).

- [ ] **Step 1: Write the failing tests**

Create/append `packages/slipreel_engine/test/models/zoom_region_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

ZoomRegion _z({Duration? predictiveWindow}) => ZoomRegion(
      rect: const Rect.fromLTRB(0, 0, 0, 0),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2.0,
      predictiveWindow: predictiveWindow,
    );

void main() {
  test('predictiveWindow (lead time) defaults to 150ms', () {
    expect(_z().predictiveWindow, const Duration(milliseconds: 150));
  });

  test('predictiveWindow clamps above 250ms down to 250ms', () {
    expect(
      _z(predictiveWindow: const Duration(milliseconds: 1500)).predictiveWindow,
      const Duration(milliseconds: 250),
    );
  });

  test('predictiveWindow clamps below 80ms up to 80ms', () {
    expect(
      _z(predictiveWindow: const Duration(milliseconds: 10)).predictiveWindow,
      const Duration(milliseconds: 80),
    );
  });

  test('predictiveWindow in range is preserved', () {
    expect(
      _z(predictiveWindow: const Duration(milliseconds: 150)).predictiveWindow,
      const Duration(milliseconds: 150),
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/models/zoom_region_test.dart`
Expected: FAIL — default is still 1500ms and there is no clamp.

- [ ] **Step 3: Change default, clamp, and docs in the model**

In `zoom_region.dart`:

Replace the default constant (lines 50-51):

```dart
  // Predictive look-ahead lead time: how far ahead the predictive follow
  // strategy aims (cursor + velocity·leadTime). 150 ms leads enough to cancel
  // the spring's settle lag without overshooting on click landings (velocity
  // ≈ 0 at rest ⇒ no lead). Clamped to [80, 250] ms.
  static const Duration _defaultLeadTime = Duration(milliseconds: 150);
  static const Duration _minLeadTime = Duration(milliseconds: 80);
  static const Duration _maxLeadTime = Duration(milliseconds: 250);
```

Update the `FollowMode.predictive` doc comment (lines 24-27) to:

```dart
  /// The camera follows the cursor's *anticipated* position
  /// (`cursor + velocity·leadTime`) through a deadzone gate — it holds steady
  /// while the cursor works in a centered safe-zone and pans early, before the
  /// cursor reaches an edge. See [predictiveWindow] for the lead time.
  predictive,
```

Update the `predictiveWindow` field doc (lines 94-99) to:

```dart
  /// Predictive look-ahead lead time: how far ahead [FollowMode.predictive]
  /// aims along the cursor's velocity. Clamped to [80, 250] ms; default 150 ms.
  /// (Field name retained for JSON back-compat — see `predictiveWindowMicros`.)
  final Duration predictiveWindow;
```

Replace the initializer (lines 145-148) so it clamps instead of only guarding negatives:

```dart
        predictiveWindow = _clampLeadTime(predictiveWindow ?? _defaultLeadTime);
```

Add the static clamp helper (near `_constrainRect`, ~line 330):

```dart
  static Duration _clampLeadTime(Duration d) {
    if (d < _minLeadTime) return _minLeadTime;
    if (d > _maxLeadTime) return _maxLeadTime;
    return d;
  }
```

Note: `fromJson` already routes a missing key to `null` → the constructor applies `_defaultLeadTime`; a present-but-out-of-range stored value is clamped by the same path. No `fromJson` edit needed.

- [ ] **Step 4: Update the JSON + store tests for the new default/clamp**

In `zoom_region_json_test.dart`:
- Line ~25: change `predictiveWindow: const Duration(milliseconds: 2200)` to an in-range value `const Duration(milliseconds: 200)` (otherwise the round-trip clamps 2200→250 and the equality assert fails). If the test asserts the round-tripped value, it now expects `200ms`.
- Line ~86: the "older project files predate predictiveWindow" case — change the expectation from `const Duration(milliseconds: 1500)` to `const Duration(milliseconds: 150)`.

In `editor_project_store_test.dart` line ~38: `predictiveWindow: const Duration(milliseconds: 1200)` clamps to `250ms`. If any assertion downstream checks this value, update it to `250ms`; if it only constructs the region, leave it (the clamp is harmless).

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/models/zoom_region_test.dart test/models/zoom_region_json_test.dart test/state/editor_project_store_test.dart
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/models/zoom_region.dart packages/slipreel_engine/test/models/zoom_region_test.dart packages/slipreel_engine/test/models/zoom_region_json_test.dart packages/slipreel_engine/test/state/editor_project_store_test.dart
git commit -m "feat(zoom): predictiveWindow becomes look-ahead lead time (80-250ms, default 150ms)"
```

---

### Task 6: Predictive = anticipatory deadzone follow

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/follow_strategy.dart`
- Test: `packages/slipreel_engine/test/rendering/follow_strategy_test.dart` (add a predictive group)

**Interfaces:**
- Consumes: `zoom.predictiveWindow` (lead time, Task 5), `zoom.deadzoneRatio`, `tuning.cursorAtRestPxPerSec`.
- Produces: `BoundedFollowStrategy` and `PredictiveFollowStrategy` both extend a shared `_DeadzoneFollowStrategy` whose abstract `aimPoint(zoom, cursor, cursorVelocity)` hook returns the raw cursor (bounded) or the velocity-led cursor (predictive). `followStrategyFor(FollowMode.predictive)` still returns `PredictiveFollowStrategy()`.

- [ ] **Step 1: Write the failing tests**

Append a predictive group to `follow_strategy_test.dart` (the file's helpers/imports already exist; add a predictive helper near `_bounded`):

```dart
ZoomRegion _predictive({
  double deadzoneRatio = 0.4,
  Duration lead = const Duration(milliseconds: 150),
}) {
  return ZoomRegion(
    rect: const Rect.fromLTRB(0, 0, 0, 0),
    startTime: Duration.zero,
    duration: const Duration(seconds: 2),
    zoomLevel: 2.0,
    deadzoneRatio: deadzoneRatio,
    followCursor: true,
    followMode: FollowMode.predictive,
    predictiveWindow: lead,
  );
}
```

```dart
  group('PredictiveFollowStrategy anticipation', () {
    test('zero velocity behaves like bounded: inside dz holds', () {
      final s = PredictiveFollowStrategy();
      final focal = const Offset(960, 540);
      // dz half-width = 1920/2 * 0.4 / 2 = 192; cursor +100 is inside.
      final r = s.resolve(
        zoom: _predictive(),
        cursor: focal + const Offset(100, 0),
        cursorVelocity: Offset.zero,
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isTrue);
      expect(s.inFlight, isFalse);
    });

    test('velocity lead engages the chase earlier than the raw cursor would',
        () {
      final s = PredictiveFollowStrategy();
      final focal = const Offset(960, 540);
      // Cursor still inside dz (+150 < 192 half-width) but moving fast right.
      // Lead = 0.15s * 500px/s = +75 => aim at +225, outside the dz.
      final r = s.resolve(
        zoom: _predictive(),
        cursor: focal + const Offset(150, 0),
        cursorVelocity: const Offset(500, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isFalse,
          reason: 'anticipated position is past the deadzone edge');
      expect(s.inFlight, isTrue);
      expect(r.target.dx, closeTo(focal.dx + 225, 0.5),
          reason: 'target is the velocity-led cursor');
    });

    test('bounded with the same cursor/velocity still holds (no lead)', () {
      final s = BoundedFollowStrategy();
      final focal = const Offset(960, 540);
      final r = s.resolve(
        zoom: _bounded(),
        cursor: focal + const Offset(150, 0),
        cursorVelocity: const Offset(500, 0),
        currentFocal: focal,
        videoSize: _videoSize,
        tuning: MotionTuning.defaults,
      );
      expect(r.isHolding, isTrue,
          reason: 'bounded aims at the raw cursor (+150, inside dz)');
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/follow_strategy_test.dart --plain-name "PredictiveFollowStrategy anticipation"`
Expected: FAIL — `PredictiveFollowStrategy` still extends `CenteredFollowStrategy` (no deadzone, no lead), so the "engages earlier" case reports `isHolding == false` for the wrong reason / wrong target, and the "inside dz holds" case fails (centered never holds on a moving cursor).

- [ ] **Step 3: Extract the deadzone base and add the lead hook**

In `follow_strategy.dart`, replace the `BoundedFollowStrategy` class (lines 101-164) and the `PredictiveFollowStrategy` class (lines 166-171) with:

```dart
/// Cursor-follow with a deadzone gate, parameterized by the AIM point each
/// subclass chooses (raw cursor for bounded; velocity-led cursor for
/// predictive). The cursor pins the focal while the aim point is inside the
/// deadzone; crossing the boundary starts a chase that releases only when the
/// cursor comes to rest inside the dz again.
///
/// **Engage-positional, release-velocity-aware.** Engagement is purely
/// positional (aim outside dz ⇒ chase) so hover jitter inside the dz never
/// starts a chase from noise. Release requires BOTH the aim inside the dz AND
/// the cursor's intrinsic scene velocity below
/// [MotionTuning.cursorAtRestPxPerSec].
abstract class _DeadzoneFollowStrategy extends FollowStrategy {
  bool _inFlight = false;

  @override
  bool get inFlight => _inFlight;

  @override
  void reset() {
    _inFlight = false;
  }

  /// The point the camera aims at this frame.
  Offset aimPoint(ZoomRegion zoom, Offset cursor, Offset cursorVelocity);

  @override
  FollowResolution resolve({
    required ZoomRegion zoom,
    required Offset? cursor,
    required Offset cursorVelocity,
    required Offset currentFocal,
    required Size videoSize,
    required MotionTuning tuning,
  }) {
    final boundsActive = zoom.followCursor &&
        cursor != null &&
        zoom.deadzoneRatio > 0 &&
        videoSize.width > 0 &&
        videoSize.height > 0;
    if (!boundsActive) {
      _inFlight = false;
      if (!zoom.followCursor) {
        return _fixedTarget(zoom.rect.center, currentFocal);
      }
      if (cursor == null) {
        return _fixedTarget(_baseFocalForFollow(zoom, videoSize), currentFocal);
      }
      return FollowResolution(target: cursor, isHolding: false);
    }

    final aim = aimPoint(zoom, cursor!, cursorVelocity);
    final z = zoom.zoomLevel;
    final dzW = (videoSize.width / z) * zoom.deadzoneRatio;
    final dzH = (videoSize.height / z) * zoom.deadzoneRatio;
    final dz = Rect.fromCenter(center: currentFocal, width: dzW, height: dzH);

    if (_inFlight) {
      final cursorAtRest =
          cursorVelocity.distance < tuning.cursorAtRestPxPerSec;
      if (cursorAtRest && dz.contains(aim)) {
        _inFlight = false;
        return FollowResolution(target: currentFocal, isHolding: true);
      }
      return FollowResolution(target: aim, isHolding: false);
    }

    if (dz.contains(aim)) {
      return FollowResolution(target: currentFocal, isHolding: true);
    }
    _inFlight = true;
    return FollowResolution(target: aim, isHolding: false);
  }
}

/// Reactive deadzone follow: aims at the raw cursor (no look-ahead).
class BoundedFollowStrategy extends _DeadzoneFollowStrategy {
  @override
  Offset aimPoint(ZoomRegion zoom, Offset cursor, Offset cursorVelocity) =>
      cursor;
}

/// Anticipatory deadzone follow: aims at the velocity-led cursor
/// (`cursor + velocity·leadTime`) so the camera starts panning before the
/// cursor reaches the deadzone edge. Lead time is [ZoomRegion.predictiveWindow].
/// At rest velocity ≈ 0 ⇒ aim ≈ cursor ⇒ no overshoot on click landings.
class PredictiveFollowStrategy extends _DeadzoneFollowStrategy {
  @override
  Offset aimPoint(ZoomRegion zoom, Offset cursor, Offset cursorVelocity) {
    final leadSec = zoom.predictiveWindow.inMicroseconds / 1e6;
    return cursor + cursorVelocity * leadSec;
  }
}
```

Leave `CenteredFollowStrategy`, `followStrategyFor`, `_baseFocalForFollow`, and `_fixedTarget` unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test test/rendering/follow_strategy_test.dart`
Expected: PASS — the new predictive group passes AND all existing Bounded/Centered cases stay green (bounded's `aimPoint` returns the raw cursor, so its behavior is byte-identical).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/follow_strategy.dart packages/slipreel_engine/test/rendering/follow_strategy_test.dart
git commit -m "feat(zoom): predictive follow = anticipatory deadzone (velocity lead)"
```

---

### Task 7: Inspector UI — relabel slider, show deadzone + lead for predictive

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` (~lines 260-302)

**Interfaces:**
- Consumes: `zoom.deadzoneRatio`, `zoom.predictiveWindow` (lead time), `ZoomRegion.copyWith`.
- Produces: the Deadzone slider shows for `bounded` AND `predictive`; the predictive slider is relabeled "Look-ahead time" with an 80–250 ms range and 150 ms reset.

This task is UI-only (no unit test); verify by `flutter analyze` + manual run.

- [ ] **Step 1: Show the deadzone slider for predictive too**

Change the guard on line 260 from:

```dart
                if (zoom.followMode == FollowMode.bounded) ...[
```

to:

```dart
                if (zoom.followMode == FollowMode.bounded ||
                    zoom.followMode == FollowMode.predictive) ...[
```

- [ ] **Step 2: Relabel the predictive slider to lead-time semantics**

Replace the predictive `InspectorSlider` block (lines 282-303) with:

```dart
                if (zoom.followMode == FollowMode.predictive) ...[
                  const SizedBox(height: 16),
                  InspectorSlider(
                    label: 'Look-ahead time',
                    subtitle:
                        '${zoom.predictiveWindow.inMilliseconds} ms. The '
                        'camera aims this far ahead along the cursor\'s '
                        'motion, so it leads the pointer instead of '
                        'trailing it.',
                    value:
                        zoom.predictiveWindow.inMilliseconds.toDouble(),
                    min: 80,
                    max: 250,
                    onChanged: (v) => onChanged(zoom.copyWith(
                        predictiveWindow:
                            Duration(milliseconds: v.toInt()))),
                    onReset: () => onChanged(zoom.copyWith(
                        predictiveWindow:
                            const Duration(milliseconds: 150))),
                    canReset: zoom.predictiveWindow !=
                        const Duration(milliseconds: 150),
                  ),
                ],
```

- [ ] **Step 3: Analyze**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos analyze`
Expected: no errors/warnings in `zoom_context_inspector.dart`.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart
git commit -m "feat(zoom): inspector — Look-ahead time slider + deadzone for predictive"
```

---

### Task 8: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Analyze the whole workspace**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos analyze`
Expected: clean (no new issues).

- [ ] **Step 2: Run the full engine + editor test suites**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos test`
Expected: all green. Pay attention to `scene_pass_builder_test`, `zoom_focal_controller_test`, `follow_strategy_test`, `zoom_region_json_test`, `editor_project_store_test`, and any zoom golden tests (the keep-in-view clamp is a no-op for interior-cursor goldens, so they should not shift; if a golden moves, confirm the new focal is correct and regenerate only that golden).

- [ ] **Step 3: Manual runtime verification (record evidence)**

Build/launch the editor and drive a fast-cursor recording (flutter-qa MCP + `ext.slipreel` hooks). Confirm, on a Predictive zoom region: (a) the cursor stays inside the frame during fast moves, (b) the camera leads rather than trails, (c) bounded/centered are unchanged. Spot-check an export of one Predictive region for play-vs-export parity (determinism).

- [ ] **Step 4: Final no-op commit guard**

Run: `git status` — confirm the tree is clean and every task is committed. Nothing to commit here; this step is the completion gate.
