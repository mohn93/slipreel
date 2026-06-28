# Framing-Aware Device-Frame Zoom Geometry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make device-frame zoom preserve the selected padding at the edge and keep the focal pan in lock-step with the scale, by computing the zoom clamp/centering in the padded-canvas space instead of source-video space.

**Architecture:** A new `ZoomFraming` value type owns the video↔canvas mapping + bounds clamp. It is threaded (optional, identity default) through `ZoomTransformer.getTransform`, `ZoomFocalController.update`, `ScenePassBuilder.build`, and `DeterministicFocalTrack.build`; preview (`PlaybackCanvas`) and export (`FrameCompositor`) build a device framing when a bezel is active. Identity framing reproduces today's behavior byte-for-byte.

**Tech Stack:** Dart / Flutter; `slipreel_engine` (rendering/effects/export) + `screen_recorder` (preview).

## Global Constraints

- Normal-recording zoom behavior must NOT change: `ZoomFraming?` params default to null → identity framing → byte-identical output (guarded by existing tests + the preview↔export parity test).
- Preview and export must stay in lock-step: the SAME framing is fed to both.
- The focal the controller integrates stays in SOURCE-VIDEO coordinates; framing only changes which space clamps/centering compute in.
- Do NOT run `dart format` on existing files; match surrounding style by hand.
- Verify with `flutter analyze` + `flutter test` per package; no `dart format`.

---

### Task 1: `ZoomFraming` value type + unit tests

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/zoom_framing.dart`
- Test: `packages/slipreel_engine/test/rendering/zoom_framing_test.dart`

**Interfaces:**
- Consumes: `ZoomTransformer.clampFocalToBounds`, `ZoomTransformer.clampFocalToBoundsRadial` (existing statics in `package:slipreel_engine/effects/zoom_transformer.dart`).
- Produces: `class ZoomFraming` with `ZoomFraming.identity(Size videoSize)`, `ZoomFraming.device({required Size videoSize, required Rect videoRect, required Size canvasSize})`, and methods `Offset clampFocal(Offset focal, double z)`, `Offset clampFocalRadial(Offset focal, double z)`, `Offset centerOffset(Offset focal, double z)`. All focal args/returns are SOURCE-VIDEO coordinates (except `centerOffset` which returns canvas-px translation).

- [ ] **Step 1: Write the failing tests**

Create `packages/slipreel_engine/test/rendering/zoom_framing_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  const videoSize = Size(1170, 2532);

  group('identity framing == today\'s ZoomTransformer math', () {
    final f = ZoomFraming.identity(videoSize);
    test('clampFocal delegates to clampFocalToBounds', () {
      for (final z in [1.0, 1.5, 2.5, 5.0]) {
        for (final p in [const Offset(0, 0), const Offset(1170, 2532),
            const Offset(585, 1266), const Offset(50, 2400)]) {
          expect(f.clampFocal(p, z),
              ZoomTransformer.clampFocalToBounds(p, videoSize, z));
        }
      }
    });
    test('clampFocalRadial delegates to clampFocalToBoundsRadial', () {
      for (final z in [1.5, 2.5]) {
        const p = Offset(50, 2400);
        expect(f.clampFocalRadial(p, z),
            ZoomTransformer.clampFocalToBoundsRadial(p, videoSize, z));
      }
    });
    test('centerOffset == clampFocalToBounds(focal) - videoCenter', () {
      const p = Offset(50, 2400);
      const z = 2.0;
      final expected = ZoomTransformer.clampFocalToBounds(p, videoSize, z) -
          Offset(videoSize.width / 2, videoSize.height / 2);
      final actual = f.centerOffset(p, z);
      expect(actual.dx, closeTo(expected.dx, 1e-9));
      expect(actual.dy, closeTo(expected.dy, 1e-9));
    });
  });

  group('device framing maps + clamps in canvas space', () {
    // Video drawn into a cutout offset (100,120) and ~1:1 inside a larger
    // padded canvas (1400x2900). Cutout size 1200x2596 (slight scale).
    const canvasSize = Size(1400, 2900);
    final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
    final f = ZoomFraming.device(
        videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);

    test('toCanvas/fromCanvas round-trip is identity', () {
      const p = Offset(300, 800);
      final back = f.debugFromCanvas(f.debugToCanvas(p));
      expect(back.dx, closeTo(p.dx, 1e-6));
      expect(back.dy, closeTo(p.dy, 1e-6));
    });

    test('an edge video focal clamps to the PADDED CANVAS, not the video', () {
      // Cursor at the right screen edge.
      const edge = Offset(1170, 1266);
      const z = 2.0;
      // Canvas-space clamp: map -> clamp to canvasSize -> map back.
      final canvasFocal = f.debugToCanvas(edge);
      final canvasClamped =
          ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
      final expected = f.debugFromCanvas(canvasClamped);
      final actual = f.clampFocal(edge, z);
      expect(actual.dx, closeTo(expected.dx, 1e-6));
      expect(actual.dy, closeTo(expected.dy, 1e-6));
      // And it must differ from the (wrong) video-bounds clamp at the edge.
      expect((actual - ZoomTransformer.clampFocalToBounds(edge, videoSize, z))
          .distance, greaterThan(1.0));
    });

    test('centerOffset = toCanvas(canvasClamp(focal)) - canvasCenter', () {
      const p = Offset(900, 2000);
      const z = 2.5;
      final canvasFocal = f.debugToCanvas(p);
      final canvasClamped =
          ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
      final expected =
          canvasClamped - Offset(canvasSize.width / 2, canvasSize.height / 2);
      final actual = f.centerOffset(p, z);
      expect(actual.dx, closeTo(expected.dx, 1e-6));
      expect(actual.dy, closeTo(expected.dy, 1e-6));
    });
  });
}
```

- [ ] **Step 2: Run the tests to confirm they fail (no `ZoomFraming` yet)**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_framing_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'zoom_framing'` / undefined `ZoomFraming`.

- [ ] **Step 3: Implement `ZoomFraming`**

Create `packages/slipreel_engine/lib/rendering/zoom_framing.dart`:

```dart
import 'package:flutter/painting.dart' show Offset, Rect, Size;

import 'package:slipreel_engine/effects/zoom_transformer.dart';

/// Owns the "where is the source video drawn, and what bounds must the zoomed
/// viewport stay within" math for the zoom pipeline.
///
/// All public focal arguments and results are in SOURCE-VIDEO coordinates (the
/// space [ZoomFocalController] integrates in) EXCEPT [centerOffset], which
/// returns the canvas-pixel translation the zoom matrix applies.
///
/// [ZoomFraming.identity] reproduces the legacy behavior exactly: the video
/// fills the canvas 1:1 and centered, and clamps stay inside the VIDEO bounds.
/// [ZoomFraming.device] is for an active device bezel: the video is rendered
/// into [videoRect] (offset + scaled) inside [canvasSize], and clamps stay
/// inside the PADDED CANVAS so the bezel + selected padding are preserved.
class ZoomFraming {
  const ZoomFraming._({
    required this.videoSize,
    required this.videoRect,
    required this.canvasSize,
    required this.isIdentity,
  });

  factory ZoomFraming.identity(Size videoSize) => ZoomFraming._(
        videoSize: videoSize,
        videoRect: Rect.fromLTWH(0, 0, videoSize.width, videoSize.height),
        canvasSize: videoSize,
        isIdentity: true,
      );

  /// Device-bezel framing. Falls back to identity when the inputs are
  /// degenerate (zero-area videoRect/canvas) so callers never divide by zero.
  factory ZoomFraming.device({
    required Size videoSize,
    required Rect videoRect,
    required Size canvasSize,
  }) {
    if (videoSize.width <= 0 ||
        videoSize.height <= 0 ||
        videoRect.width <= 0 ||
        videoRect.height <= 0 ||
        canvasSize.width <= 0 ||
        canvasSize.height <= 0) {
      return ZoomFraming.identity(videoSize);
    }
    return ZoomFraming._(
      videoSize: videoSize,
      videoRect: videoRect,
      canvasSize: canvasSize,
      isIdentity: false,
    );
  }

  final Size videoSize;
  final Rect videoRect;
  final Size canvasSize;
  final bool isIdentity;

  double get _sx => videoRect.width / videoSize.width;
  double get _sy => videoRect.height / videoSize.height;

  Offset _toCanvas(Offset p) =>
      Offset(videoRect.left + p.dx * _sx, videoRect.top + p.dy * _sy);

  Offset _fromCanvas(Offset q) => Offset(
        (q.dx - videoRect.left) / _sx,
        (q.dy - videoRect.top) / _sy,
      );

  /// Per-axis reachable-bounds clamp, returned in source-video coordinates.
  Offset clampFocal(Offset focal, double z) {
    if (isIdentity) {
      return ZoomTransformer.clampFocalToBounds(focal, videoSize, z);
    }
    final clamped =
        ZoomTransformer.clampFocalToBounds(_toCanvas(focal), canvasSize, z);
    return _fromCanvas(clamped);
  }

  /// Radial reachable-bounds clamp (used by the manual enter/exit pan),
  /// returned in source-video coordinates.
  Offset clampFocalRadial(Offset focal, double z) {
    if (isIdentity) {
      return ZoomTransformer.clampFocalToBoundsRadial(focal, videoSize, z);
    }
    final clamped = ZoomTransformer.clampFocalToBoundsRadial(
        _toCanvas(focal), canvasSize, z);
    return _fromCanvas(clamped);
  }

  /// The `pCenterRel` the zoom matrix translates by, in CANVAS pixels:
  /// the clamped focal's canvas position minus the canvas center. The matrix
  /// then applies `translate(-z * centerOffset) * scale(z)` about the canvas
  /// center so the focal lands at the viewport center.
  Offset centerOffset(Offset focal, double z) {
    final canvasFocal = _toCanvas(focal);
    final clamped =
        ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
    return clamped - Offset(canvasSize.width / 2, canvasSize.height / 2);
  }

  // Test-only accessors for the affine map.
  Offset debugToCanvas(Offset p) => _toCanvas(p);
  Offset debugFromCanvas(Offset q) => _fromCanvas(q);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_framing_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/rendering/zoom_framing.dart \
        packages/slipreel_engine/test/rendering/zoom_framing_test.dart
git commit -m "feat(zoom): add ZoomFraming (video<->canvas clamp/centering)"
```

---

### Task 2: Thread `ZoomFraming` into `ZoomTransformer.getTransform`

**Files:**
- Modify: `packages/slipreel_engine/lib/effects/zoom_transformer.dart`
- Test: `packages/slipreel_engine/test/effects/zoom_transformer_test.dart` (append; create if absent)

**Interfaces:**
- Consumes: `ZoomFraming` from Task 1.
- Produces: `getTransform(..., ZoomFraming? framing)`. When null, identical to today.

- [ ] **Step 1: Write the failing test**

Append to `packages/slipreel_engine/test/effects/zoom_transformer_test.dart` (create the file with the imports below if it does not exist):

```dart
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  final t = ZoomTransformer();
  final region = ZoomRegion(
    startTime: Duration.zero,
    endTime: const Duration(seconds: 3),
    rect: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
    zoomLevel: 2.0,
    enterDuration: const Duration(milliseconds: 1),
    exitDuration: const Duration(milliseconds: 1),
  );
  const videoSize = Size(1170, 2532);
  // Mid-hold so z == zoomLevel (2.0).
  const pos = Duration(milliseconds: 1500);

  test('framing:null is identical to legacy getTransform', () {
    final a = t.getTransform(
        position: pos, zoomRegion: region, videoSize: videoSize,
        focalPoint: const Offset(900, 1800));
    final b = t.getTransform(
        position: pos, zoomRegion: region, videoSize: videoSize,
        focalPoint: const Offset(900, 1800),
        framing: ZoomFraming.identity(videoSize));
    expect(a.storage, b.storage);
  });

  test('device framing translates by canvas centerOffset', () {
    const canvasSize = Size(1400, 2900);
    final videoRect = const Rect.fromLTWH(100, 120, 1200, 2596);
    final framing = ZoomFraming.device(
        videoSize: videoSize, videoRect: videoRect, canvasSize: canvasSize);
    const focal = Offset(1170, 1266); // right edge
    final m = t.getTransform(
        position: pos, zoomRegion: region, videoSize: videoSize,
        focalPoint: focal, framing: framing);
    final z = m.storage[0];
    final pcr = framing.centerOffset(focal, z);
    // matrix = translate(-z*pcr) * scale(z): storage[12]/[13] hold translation.
    expect(m.storage[12], closeTo(-z * pcr.dx, 1e-6));
    expect(m.storage[13], closeTo(-z * pcr.dy, 1e-6));
  });
}
```

- [ ] **Step 2: Run to confirm it fails**

Run: `cd packages/slipreel_engine && flutter test test/effects/zoom_transformer_test.dart`
Expected: FAIL — `getTransform` has no `framing` named parameter (compile error).

- [ ] **Step 3: Add the param and route the clamp/translation**

In `packages/slipreel_engine/lib/effects/zoom_transformer.dart`:

Add the import near the top:
```dart
import 'package:slipreel_engine/rendering/zoom_framing.dart';
```

Add `ZoomFraming? framing,` to the `getTransform` named params (after `rampDurationScale`). Then replace the clamp+translation block:
```dart
    final focal = focalPoint ?? zoomRegion.rect.center;
    final clamped = clampFocalToBounds(focal, videoSize, z);
    final pCenterRel = clamped -
        Offset(videoSize.width / 2, videoSize.height / 2);
```
with:
```dart
    final focal = focalPoint ?? zoomRegion.rect.center;
    final f = framing ?? ZoomFraming.identity(videoSize);
    // pCenterRel is in canvas px; for identity framing it equals the legacy
    // `clampFocalToBounds(focal, videoSize, z) - videoCenter`.
    final pCenterRel = f.centerOffset(focal, z);
```
(The `Matrix4` build below using `pCenterRel` is unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/effects/zoom_transformer_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/effects/zoom_transformer.dart \
        packages/slipreel_engine/test/effects/zoom_transformer_test.dart
git commit -m "feat(zoom): getTransform accepts ZoomFraming (canvas-space centering)"
```

---

### Task 3: Route `ZoomFocalController.update` clamps through `ZoomFraming`

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart` (append)

**Interfaces:**
- Consumes: `ZoomFraming` (Task 1).
- Produces: `ZoomFocalController.update(..., ZoomFraming? framing)`. Null ⇒ identity ⇒ unchanged. All 7 internal `ZoomTransformer.clampFocalToBounds`/`clampFocalToBoundsRadial` sites route through the framing.

- [ ] **Step 1: Write the failing test**

Append to `packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart` a test proving an edge-of-screen cursor is treated as reachable under device framing (lock-step enter pan, no leading overshoot). Use the public `update` with `followCursor` and a device framing whose canvas is larger than the video:

```dart
  test('device framing: edge cursor enter-pan is lock-step (no leading overshoot)',
      () {
    const videoSize = Size(1170, 2532);
    final framing = ZoomFraming.device(
      videoSize: videoSize,
      videoRect: const Rect.fromLTWH(100, 120, 1200, 2596),
      canvasSize: const Size(1400, 2900),
    );
    final region = ZoomRegion(
      startTime: Duration.zero,
      endTime: const Duration(seconds: 3),
      rect: const Rect.fromLTWH(0, 0, 1, 1),
      zoomLevel: 2.0,
      enterDuration: const Duration(milliseconds: 600),
      exitDuration: const Duration(milliseconds: 600),
      followCursor: true,
    );
    const edgeCursor = Offset(1160, 1266); // near right screen edge
    final ctrl = ZoomFocalController();
    // Prime (first frame parks the spring).
    ctrl.update(position: Duration.zero, zoomRegions: [region],
        cursor: edgeCursor, videoSize: videoSize, framing: framing);
    // Halfway through the enter ramp.
    final mid = ctrl.update(
        position: const Duration(milliseconds: 300), zoomRegions: [region],
        cursor: edgeCursor, videoSize: videoSize, framing: framing,
        enterCursorTarget: edgeCursor)!;
    // Lock-step (backload 1.0) means the focal at the eased-50% point sits
    // BETWEEN the video center and the (canvas-)clamped target — it must NOT
    // have overshot past the canvas-clamped target (which a leading pan does).
    final target = framing.clampFocal(edgeCursor, region.zoomLevel);
    final centre = Offset(videoSize.width / 2, videoSize.height / 2);
    // mid focal.dx is between centre and target (inclusive), not beyond target.
    expect(mid.focal.dx, lessThanOrEqualTo(target.dx + 0.5));
    expect(mid.focal.dx, greaterThanOrEqualTo(centre.dx - 0.5));
  });
```

Ensure the test file imports `package:slipreel_engine/rendering/zoom_framing.dart` and `dart:ui`/`painting` `Offset,Rect,Size` (add if missing).

- [ ] **Step 2: Run to confirm it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart`
Expected: FAIL — `update` has no `framing` param (compile error).

- [ ] **Step 3: Add the param and resolve a framing at the top of `update`**

In `zoom_focal_controller.dart`:

Add the import:
```dart
import 'package:slipreel_engine/rendering/zoom_framing.dart';
```

Add `ZoomFraming? framing,` to `update`'s named params (e.g. after `enterCursorTarget`). Immediately after the `activeZoom` is resolved and the early-null-return block, introduce a local resolved framing (place it right after the `if (activeZoom == null) { ... return null; }` block, before first use):
```dart
    final fr = framing ?? ZoomFraming.identity(videoSize);
```

Then replace each of the 7 clamp call sites:
- `ZoomTransformer.clampFocalToBounds(X, videoSize, Y)` → `fr.clampFocal(X, Y)`
- `ZoomTransformer.clampFocalToBoundsRadial(X, videoSize, Y)` → `fr.clampFocalRadial(X, Y)`

The specific sites (by current line/role):
1. exit anchor capture (`_exitRampStartFocal ??= clampFocalToBounds(_smoothedFocal!, videoSize, zoomLevel)`).
2. exit reachable test (`clampFocalToBounds(_smoothedFocal!, videoSize, zoomLevel)`).
3. manual exit reachable test (`clampFocalToBounds(activeZoom.rect.center, videoSize, zoomLevel)`).
4. exit radial clamp (`_smoothedFocal = clampFocalToBoundsRadial(lerped, videoSize, z)`).
5. enter target clamp (`entryTarget = clampFocalToBounds(rawTarget, videoSize, zoomLevel)`).
6. enter radial clamp (`clampedFocal = clampFocalToBoundsRadial(newFocal, videoSize, z)`).
7. post-enter handoff clamp (`cursorClamped = clampFocalToBounds(cursor, videoSize, zoomLevel)`).

Leave the `ZoomTransformer` import in place (still used elsewhere / by other files). Do not change the spring math, ramp windows, or `_baseFocal`.

- [ ] **Step 4: Run the controller suite to verify pass + no regressions**

Run: `cd packages/slipreel_engine && flutter test test/rendering/zoom_focal_controller_test.dart`
Expected: `All tests passed!` (the new test plus all existing ones — existing tests pass `framing: null` implicitly ⇒ identity ⇒ unchanged).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart \
        packages/slipreel_engine/test/rendering/zoom_focal_controller_test.dart
git commit -m "feat(zoom): route focal-controller clamps through ZoomFraming"
```

---

### Task 4: Thread `ZoomFraming` through `ScenePassBuilder` + `DeterministicFocalTrack`

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart`
- Modify: `packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart`

**Interfaces:**
- Consumes: `ZoomFocalController.update(framing:)` (Task 3).
- Produces: `ScenePassBuilder.build(..., ZoomFraming? framing)` (forwarded to `focal.update`); `DeterministicFocalTrack.build(..., ZoomFraming? framing)` + `matches(..., ZoomFraming? framing)` (passed to the internal `ScenePassBuilder`).

- [ ] **Step 1: Add `framing` to `ScenePassBuilder.build` and forward it**

In `scene_pass_builder.dart`:
Add the import `import 'package:slipreel_engine/rendering/zoom_framing.dart';`.
Add `ZoomFraming? framing,` to `build`'s named params. In the `focal.update(...)` call, add `framing: framing,`.

- [ ] **Step 2: Add `framing` to `DeterministicFocalTrack.build` and forward it**

In `deterministic_focal_track.dart`:
Add the import. Add `ZoomFraming? framing,` to `build`'s named params and store it on the instance if `matches` needs it (see Step 3). In the internal `builder.build(...)` loop call, add `framing: framing,`.

- [ ] **Step 3: Include `framing` in the track's identity (`matches`)**

`DeterministicFocalTrack` is cached and reused when `matches(...)` returns true. Add a `final ZoomFraming? framing;` field (set from `build`), and in `matches(...)` add a `ZoomFraming? framing` param compared via an identity-aware equality. Because `ZoomFraming` has no `==`, compare structurally with a small helper inside `matches`:
```dart
    bool sameFraming(ZoomFraming? a, ZoomFraming? b) {
      if (a == null || b == null) return (a == null) == (b == null);
      return a.isIdentity == b.isIdentity &&
          a.videoSize == b.videoSize &&
          a.videoRect == b.videoRect &&
          a.canvasSize == b.canvasSize;
    }
```
and `&& sameFraming(this.framing, framing)` in the boolean result. (Add `final ZoomFraming? framing;` to the constructor and assign it in `build`.)

- [ ] **Step 4: Analyze (no dedicated unit test; covered by Task 6 integration + existing track tests)**

Run: `cd packages/slipreel_engine && flutter analyze lib/rendering/scene_pass_builder.dart lib/rendering/deterministic_focal_track.dart`
Expected: `No issues found!`

- [ ] **Step 5: Run engine suite to confirm no regressions (null framing ⇒ unchanged)**

Run: `cd packages/slipreel_engine && flutter test 2>&1 | tail -3`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/rendering/scene_pass_builder.dart \
        packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart
git commit -m "feat(zoom): thread ZoomFraming through scene builder + focal track"
```

---

### Task 5: Wire device framing into export (`FrameCompositor`) and preview (`PlaybackCanvas`)

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`

**Interfaces:**
- Consumes: `ZoomFraming` (Task 1), `ScenePassBuilder.build(framing:)`, `getTransform(framing:)`, `DeterministicFocalTrack.build(framing:)`.
- Produces: a device `ZoomFraming` built from the active device layout, fed to BOTH pipelines.

- [ ] **Step 1: Export — build and pass the device framing**

In `frame_compositor.dart`:
Add the import `import 'package:slipreel_engine/rendering/zoom_framing.dart';`.

Add a memoized framing alongside the existing `_videoRect`/`totalSize` getters:
```dart
  late final ZoomFraming _framing = deviceFramePlan != null
      ? ZoomFraming.device(
          videoSize: videoSize,
          videoRect: _videoRect,
          canvasSize: totalSize,
        )
      : ZoomFraming.identity(videoSize);
```
Pass `framing: _framing` to:
- the `scenePass` build call (`_scenePassBuilder.build(...)`),
- the `_zoomTransformer.getTransform(...)` call,
- the `_approxSceneSampleAt` visible-focal clamp: replace
  `ZoomTransformer.clampFocalToBounds(focal, videoSize, scale)` with
  `_framing.clampFocal(focal, scale)`.
Update the stale comment at `frame_compositor.dart:261-264` to note the matrix
translation now goes through `_framing.centerOffset` (canvas-space), so the
device path no longer relies on the "video centered 1:1" assumption.

- [ ] **Step 2: Preview — build and pass the device framing**

In `playback_canvas.dart`, after `deviceLayout` / `effTotalSize` are resolved (around line 740), add:
```dart
    final ZoomFraming zoomFraming = deviceLayout != null
        ? ZoomFraming.device(
            videoSize: videoSize,
            videoRect: deviceLayout.videoRect,
            canvasSize: effTotalSize,
          )
        : ZoomFraming.identity(videoSize);
```
Add the import `import 'package:slipreel_engine/rendering/zoom_framing.dart';`.
Pass `framing: zoomFraming` to:
- `_scenePassBuilder.build(...)` (around line 834),
- `_zoomTransformer.getTransform(...)` (around line 1316),
- the `_focalTrackFor(...)` helper — add a `ZoomFraming framing` param to its
  signature and forward to `DeterministicFocalTrack.build(framing: framing)` AND
  to the `cached.matches(framing: framing)` check; pass `zoomFraming` at the
  call site (around line 876).

- [ ] **Step 3: Analyze both packages**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter analyze lib/export/frame_compositor.dart
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart
```
Expected: `No issues found!` for both.

- [ ] **Step 4: Run the preview↔export parity test (device geometry)**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_device_parity_test.dart`
Expected: `All tests passed!` (videoRect/bezelRect parity unchanged; the focal now flows through the same framing in both).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(zoom): feed device ZoomFraming to preview + export pipelines"
```

---

### Task 6: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Engine + recorder suites + analyze**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test 2>&1 | tail -3
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder && flutter analyze 2>&1 | tail -2 && flutter test 2>&1 | tail -3
```
Expected: both suites `All tests passed!`; analyze `No issues found!`. (The normal-path tests passing confirms identity framing is byte-compatible.)

- [ ] **Step 2: Build, sign, run; visually verify on the 1170×2532 recording**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
osascript -e 'quit app "Slipreel"' 2>/dev/null; flutter build macos --release 2>&1 | tail -2
IDENT=CE7C4468C650F29F8EBC819F378B49133F820954
APP=build/macos/Build/Products/Release/Slipreel.app
ENT=macos/Runner/Release.entitlements
find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -print | while read -r i; do codesign --force --timestamp=none --options runtime -s "$IDENT" "$i" >/dev/null 2>&1; done
codesign --force --timestamp=none --options runtime --entitlements "$ENT" -s "$IDENT" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP" && open "$APP"
```
Expected: app launches; open the 1170×2532 device recording, add a device frame + padding, place a zoom near a portrait edge → the bezel + selected padding stay framed (A fixed) and the focal pans in lock-step with the scale (B fixed). User confirms.

- [ ] **Step 3: Commit any incidental fixes (only if Step 1 required edits)**

```bash
git add -A && git commit -m "fix(zoom): test/analyze fixes for device-frame framing"
```

---

## Self-Review

**Spec coverage:**
- `ZoomFraming` identity/device + clampFocal/clampFocalRadial/centerOffset → Task 1. ✓
- `getTransform` framing param → Task 2. ✓
- Controller 7 clamp sites routed → Task 3. ✓
- `ScenePassBuilder` + `DeterministicFocalTrack` threading (+ `matches`) → Task 4. ✓
- Export + preview wiring incl. frame_compositor:902 visibleFocal + stale comment → Task 5. ✓
- Tests (framing unit, transformer, controller edge, parity, suites) → Tasks 1-6. ✓
- Degenerate-size fallback to identity → Task 1 `ZoomFraming.device`. ✓
- Normal path unchanged (null default / identity) → Global Constraints + every task's null-default. ✓
- Runtime visual verify → Task 6. ✓

**Placeholder scan:** No TBD/TODO; all code shown. The controller's 7 sites are enumerated by role (the implementer matches them in the file). ✓

**Type consistency:** `ZoomFraming` ctor/methods identical across Tasks 1-5. `framing` param name consistent in getTransform/update/build/matches. `centerOffset` returns canvas-px translation consumed by the existing `Matrix4` builder. ✓
