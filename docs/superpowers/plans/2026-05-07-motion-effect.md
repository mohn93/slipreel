# Motion Effect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing `motionBlur` slider in the Animation tab so it actually renders directional motion blur on the cursor and an anisotropic Gaussian blur on the screen composition, in both the playback preview and the exported video.

**Architecture:** Two pure helpers (`computeMotionBlurSamples` for cursor multi-stamp parameters, `screenBlurSigma` for `ImageFilter.blur` sigmas) are reused by the preview canvas and `frame_compositor`. Cursor velocity comes from extending `CursorMotionUpdate`; screen-pan velocity comes from a new `ScreenPanVelocityTracker` that watches the zoom transform's translation per frame. The slider value (already plumbed through state and persistence) is the intensity ceiling; effective blur scales with measured speed.

**Tech Stack:** Flutter (Dart 3), `flutter_test`, `dart:ui` (`Canvas`, `ImageFilter.blur`, `Matrix4`).

**Spec:** `docs/superpowers/specs/2026-05-07-motion-effect-design.md`

**Run from package root:** `cd packages/screen_recorder` for all `flutter test` invocations below. From repo root, `melos run test` runs the full suite.

---

## Task 1: `MotionBlurSamples` pure helper

**Files:**
- Create: `packages/screen_recorder/lib/effects/motion_blur_samples.dart`
- Test: `packages/screen_recorder/test/effects/motion_blur_samples_test.dart`

The sampler is a pure function that, given a velocity vector and a slider intensity, returns how many stamps to draw, the per-stamp offset, and the alpha for each. Single-stamp short-circuit when blur should be off (slider 0, very low velocity, or `slider × speed/ref < 0.05`). Alphas sum to 1.0 so the surface doesn't change perceived brightness when blur kicks in. Step direction is `−v̂` so the trail is *behind* the head.

- [ ] **Step 1.1: Write the failing test**

`packages/screen_recorder/test/effects/motion_blur_samples_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/motion_blur_samples.dart';

void main() {
  group('computeMotionBlurSamples', () {
    test('slider 0 → single stamp regardless of velocity', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(5000, 0),
        sliderIntensity: 0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 1);
      expect(s.stepPx, Offset.zero);
      expect(s.alphas, [closeTo(1.0, 1e-9)]);
    });

    test('velocity below 1 px/s → single stamp regardless of slider', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(0.4, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 1);
      expect(s.stepPx, Offset.zero);
    });

    test('effective intensity below 0.05 → single stamp', () {
      // slider 0.1, speed = 800, ref 2000 → effective = 0.04
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(800, 0),
        sliderIntensity: 0.1,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 1);
    });

    test('horizontal velocity at max speed, slider 1 → 8 stamps along -x', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, 8);
      expect(s.stepPx.dx, lessThan(0));
      expect(s.stepPx.dy, closeTo(0, 1e-9));
      // (count - 1) steps span maxReachPx exactly at max effective
      expect(s.stepPx.dx * (s.count - 1), closeTo(-12.0, 1e-6));
    });

    test('alphas sum to 1.0', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      final sum = s.alphas.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-9));
    });

    test('alphas are monotonically increasing (tail dim → head bright)', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      for (var i = 1; i < s.alphas.length; i++) {
        expect(s.alphas[i], greaterThan(s.alphas[i - 1]));
      }
    });

    test('supersonic velocity is clamped — no >maxStamps stamps, no >maxReach offset', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(20000, 0),
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(s.count, lessThanOrEqualTo(8));
      expect(s.stepPx.dx.abs() * (s.count - 1), lessThanOrEqualTo(12.0 + 1e-6));
    });

    test('45-degree velocity → step direction is exactly -v_hat', () {
      final s = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(1500, 1500), // |v| ≈ 2121
        sliderIntensity: 1.0,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      // step direction should be (-1/√2, -1/√2)
      final mag = s.stepPx.distance;
      expect(s.stepPx.dx / mag, closeTo(-1 / 1.41421356, 1e-3));
      expect(s.stepPx.dy / mag, closeTo(-1 / 1.41421356, 1e-3));
    });

    test('count grows with effective intensity (1 + round((max-1) * eff))', () {
      // effective = 0.5 → count = 1 + round(7 * 0.5) = 1 + 4 = 5  (sliderIntensity 0.5 at max ref speed)
      final mid = computeMotionBlurSamples(
        velocityPxPerSec: const Offset(2000, 0),
        sliderIntensity: 0.5,
        referenceSpeedPxPerSec: 2000,
        maxReachPx: 12,
      );
      expect(mid.count, 5);
    });
  });
}
```

- [ ] **Step 1.2: Run the test to verify it fails**

```
flutter test test/effects/motion_blur_samples_test.dart
```

Expected: FAIL — `Target of URI doesn't exist: 'package:screen_recorder/effects/motion_blur_samples.dart'`.

- [ ] **Step 1.3: Implement `motion_blur_samples.dart`**

`packages/screen_recorder/lib/effects/motion_blur_samples.dart`:

```dart
import 'package:flutter/painting.dart';

/// Result of [computeMotionBlurSamples]: how many stamps to draw, the
/// per-stamp offset (so consecutive stamps step backwards along the
/// motion vector), and the alpha to assign each stamp. Tail at index
/// 0 (dimmest), head at index [count] - 1 (brightest, offset 0).
class MotionBlurSamples {
  const MotionBlurSamples({
    required this.count,
    required this.stepPx,
    required this.alphas,
  });

  final int count;
  final Offset stepPx;
  final List<double> alphas;
}

/// Single-stamp result reused for the no-blur short-circuit so callers
/// can branch on `samples.count == 1`.
const _noBlur = MotionBlurSamples(
  count: 1,
  stepPx: Offset.zero,
  alphas: [1.0],
);

/// Tunables on the no-blur shortcut. A blur strength below 0.05
/// renders identically to no blur to the eye, so we skip the
/// saveLayer + multi-stamp loop for it.
const _kEffectiveCutoff = 0.05;

/// Velocities slower than this don't produce visible directional
/// blur. Below it we report no blur regardless of slider value.
const _kMinSpeedPxPerSec = 1.0;

/// Returns the per-stamp parameters for cursor motion blur.
///
/// `effective = sliderIntensity × clamp(|v| / referenceSpeed, 0, 1)`.
/// Count grows from 1 at effective=0 to [maxStamps] at effective=1.
/// Step magnitude grows from 0 to `maxReachPx / (count - 1)`.
/// Alphas linearly taper from 1/Σ at the tail to count/Σ at the head
/// (Σ = N(N+1)/2), then are normalized so the alpha sum is 1.0.
MotionBlurSamples computeMotionBlurSamples({
  required Offset velocityPxPerSec,
  required double sliderIntensity,
  required double referenceSpeedPxPerSec,
  required double maxReachPx,
  int maxStamps = 8,
}) {
  if (sliderIntensity <= 0) return _noBlur;
  final speed = velocityPxPerSec.distance;
  if (speed < _kMinSpeedPxPerSec) return _noBlur;

  final effective =
      (sliderIntensity * speed / referenceSpeedPxPerSec).clamp(0.0, 1.0);
  if (effective < _kEffectiveCutoff) return _noBlur;

  final count = 1 + ((maxStamps - 1) * effective).round();
  if (count <= 1) return _noBlur;

  final reach = effective * maxReachPx;
  final stepMag = reach / (count - 1);
  final invSpeed = 1.0 / speed;
  final stepPx = Offset(
    -velocityPxPerSec.dx * invSpeed * stepMag,
    -velocityPxPerSec.dy * invSpeed * stepMag,
  );

  final sumWeights = count * (count + 1) / 2.0;
  final alphas = List<double>.generate(
    count,
    (i) => (i + 1) / sumWeights,
    growable: false,
  );

  return MotionBlurSamples(
    count: count,
    stepPx: stepPx,
    alphas: alphas,
  );
}
```

- [ ] **Step 1.4: Run the test to verify it passes**

```
flutter test test/effects/motion_blur_samples_test.dart
```

Expected: All 9 tests pass.

- [ ] **Step 1.5: Commit**

```
git add packages/screen_recorder/lib/effects/motion_blur_samples.dart \
        packages/screen_recorder/test/effects/motion_blur_samples_test.dart
git commit -m "feat(motion-blur): pure sampler for cursor multi-stamp parameters"
```

---

## Task 2: `screenBlurSigma` pure helper

**Files:**
- Create: `packages/screen_recorder/lib/effects/motion_blur_screen.dart`
- Test: `packages/screen_recorder/test/effects/motion_blur_screen_test.dart`

The screen-blur helper turns a velocity + intensity into per-axis Gaussian sigmas for `ImageFilter.blur(sigmaX, sigmaY)`. Anisotropic so axis-aligned pans get directional-feeling blur without a custom shader. Returns `Offset.zero` for the no-blur fast path.

- [ ] **Step 2.1: Write the failing test**

`packages/screen_recorder/test/effects/motion_blur_screen_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/motion_blur_screen.dart';

void main() {
  group('screenBlurSigma', () {
    test('intensity 0 → zero sigmas regardless of velocity', () {
      final s = screenBlurSigma(
        velocity: const Offset(2000, 2000),
        intensity: 0,
      );
      expect(s, Offset.zero);
    });

    test('zero velocity → zero sigmas', () {
      final s = screenBlurSigma(
        velocity: Offset.zero,
        intensity: 1.0,
      );
      expect(s, Offset.zero);
    });

    test('horizontal pan at max speed, intensity 1 → sigmaX=maxReach, sigmaY=0', () {
      final s = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 1.0,
      );
      expect(s.dx, closeTo(10.0, 1e-6));
      expect(s.dy, closeTo(0, 1e-6));
    });

    test('vertical pan at max speed, intensity 1 → sigmaY=maxReach, sigmaX=0', () {
      final s = screenBlurSigma(
        velocity: const Offset(0, 800),
        intensity: 1.0,
      );
      expect(s.dx, closeTo(0, 1e-6));
      expect(s.dy, closeTo(10.0, 1e-6));
    });

    test('intensity scales sigma linearly at fixed speed', () {
      final half = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 0.5,
      );
      final full = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 1.0,
      );
      expect(half.dx, closeTo(full.dx * 0.5, 1e-6));
    });

    test('speed above reference is clamped', () {
      final cap = screenBlurSigma(
        velocity: const Offset(80000, 0),
        intensity: 1.0,
      );
      expect(cap.dx, closeTo(10.0, 1e-6));
    });

    test('negative velocity components → absolute-value sigmas', () {
      final s = screenBlurSigma(
        velocity: const Offset(-800, -800),
        intensity: 1.0,
      );
      expect(s.dx, closeTo(10.0, 1e-6));
      expect(s.dy, closeTo(10.0, 1e-6));
    });

    test('sub-pixel sigma is snapped to Offset.zero (avoid invisible saveLayer cost)', () {
      // intensity 0.001 × speed 800 / ref 800 × maxReach 10 = 0.01 px
      // — invisible to the eye but a real per-frame saveLayer cost
      // if we pass it to ImageFilter. Helper must snap.
      final s = screenBlurSigma(
        velocity: const Offset(800, 0),
        intensity: 0.001,
      );
      expect(s, Offset.zero);
    });
  });
}
```

- [ ] **Step 2.2: Run the test to verify it fails**

```
flutter test test/effects/motion_blur_screen_test.dart
```

Expected: FAIL — URI doesn't exist.

- [ ] **Step 2.3: Implement `motion_blur_screen.dart`**

`packages/screen_recorder/lib/effects/motion_blur_screen.dart`:

```dart
import 'package:flutter/painting.dart';

/// Returns per-axis Gaussian sigmas for [ImageFilter.blur] given the
/// screen layer's translation velocity and the slider intensity.
/// Anisotropic so a horizontal pan blurs horizontally and vice versa.
///
/// Caller passes the result straight to `ImageFilter.blur(sigmaX:
/// sigma.dx, sigmaY: sigma.dy)` — both fields are non-negative, so
/// `Offset.zero` means "do not apply the filter".
/// Sigmas below this on BOTH axes round to zero — invisible to the
/// eye but each one would still cost a per-frame `saveLayer` if
/// passed to `ImageFilter.blur`.
const double _kSigmaCutoff = 0.05;

Offset screenBlurSigma({
  required Offset velocity,
  required double intensity,
  double referenceSpeed = 800,
  double maxReach = 10,
}) {
  if (intensity <= 0) return Offset.zero;
  final fxX =
      (intensity * velocity.dx.abs() / referenceSpeed).clamp(0.0, 1.0);
  final fxY =
      (intensity * velocity.dy.abs() / referenceSpeed).clamp(0.0, 1.0);
  final sx = fxX * maxReach;
  final sy = fxY * maxReach;
  if (sx < _kSigmaCutoff && sy < _kSigmaCutoff) return Offset.zero;
  return Offset(sx, sy);
}
```

- [ ] **Step 2.4: Run the test to verify it passes**

```
flutter test test/effects/motion_blur_screen_test.dart
```

Expected: All 7 tests pass.

- [ ] **Step 2.5: Commit**

```
git add packages/screen_recorder/lib/effects/motion_blur_screen.dart \
        packages/screen_recorder/test/effects/motion_blur_screen_test.dart
git commit -m "feat(motion-blur): screenBlurSigma helper for ImageFilter.blur"
```

---

## Task 3: `ScreenPanVelocityTracker`

**Files:**
- Create: `packages/screen_recorder/lib/effects/screen_pan_velocity_tracker.dart`
- Test: `packages/screen_recorder/test/effects/screen_pan_velocity_tracker_test.dart`

Tracks the zoom transform's translation between consecutive `compose`/build calls and reports translation velocity in totalSize-px/sec. Idempotent on duplicate `position` calls (returns the cached velocity without re-advancing state). Backwards-in-time `position` returns `Offset.zero` rather than producing a negative-Δt blowup.

- [ ] **Step 3.1: Write the failing test**

`packages/screen_recorder/test/effects/screen_pan_velocity_tracker_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/screen_pan_velocity_tracker.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

Matrix4 _translation(double dx, double dy) =>
    Matrix4.identity()..translateByVector3(Vector3(dx, dy, 0));

void main() {
  group('ScreenPanVelocityTracker', () {
    test('first call after construction returns zero', () {
      final t = ScreenPanVelocityTracker();
      final v = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 0),
      );
      expect(v, Offset.zero);
    });

    test('two calls with translation Δ=(20,0) over 16ms → ~1250 px/s on x', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 0),
      );
      final v = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      expect(v.dx, closeTo(1250.0, 1.0));
      expect(v.dy, closeTo(0, 1e-6));
    });

    test('same position called twice returns cached velocity, no state advance', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 0),
      );
      final v1 = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      // Calling at the same position must NOT update _last; otherwise
      // a subsequent forward step would see a fake Δt of 0.
      final v1Again = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      expect(v1Again, v1);
      // Now advance forward — state should have advanced from the
      // FIRST call only, not the duplicate.
      final v2 = t.update(
        transform: _translation(40, 0),
        position: const Duration(milliseconds: 32),
      );
      expect(v2.dx, closeTo(1250.0, 1.0));
    });

    test('reset clears state — first call after reset returns zero', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 0),
      );
      t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 16),
      );
      t.reset();
      final v = t.update(
        transform: _translation(60, 0),
        position: const Duration(milliseconds: 32),
      );
      expect(v, Offset.zero);
    });

    test('backwards position returns zero (no negative-Δt blowup)', () {
      final t = ScreenPanVelocityTracker();
      t.update(
        transform: _translation(0, 0),
        position: const Duration(milliseconds: 100),
      );
      final v = t.update(
        transform: _translation(20, 0),
        position: const Duration(milliseconds: 50),
      );
      expect(v, Offset.zero);
    });
  });
}
```

- [ ] **Step 3.2: Run the test to verify it fails**

```
flutter test test/effects/screen_pan_velocity_tracker_test.dart
```

Expected: FAIL — URI doesn't exist.

- [ ] **Step 3.3: Implement `screen_pan_velocity_tracker.dart`**

`packages/screen_recorder/lib/effects/screen_pan_velocity_tracker.dart`:

```dart
import 'package:flutter/painting.dart';

/// Per-frame translation velocity of a `Matrix4` (the zoom transform
/// applied to the playback canvas / export composition).
///
/// Designed to be ticked once per frame: pass the current frame's
/// transform plus its [Duration] [position]. Returns the translation
/// velocity in canvas-px-per-second. Idempotent on duplicate
/// [position] (returns cached result without advancing state) — same
/// pattern as [ZoomFocalController]'s result cache. Backwards
/// [position] returns [Offset.zero].
class ScreenPanVelocityTracker {
  Offset? _lastTranslation;
  Duration? _lastPosition;
  Offset _lastResult = Offset.zero;

  /// Returns the translation velocity (px/sec) implied by going from
  /// the previous call's transform to [transform] over the wall-clock
  /// gap between [position] values. First call returns [Offset.zero].
  Offset update({
    required Matrix4 transform,
    required Duration position,
  }) {
    final tx = Offset(transform.entry(0, 3), transform.entry(1, 3));

    if (_lastPosition == null || _lastTranslation == null) {
      _lastTranslation = tx;
      _lastPosition = position;
      _lastResult = Offset.zero;
      return Offset.zero;
    }

    if (position == _lastPosition) {
      // Idempotent same-frame rebuild: don't advance state, return
      // last computed result.
      return _lastResult;
    }

    if (position < _lastPosition!) {
      // Scrub backwards: don't fabricate a negative-Δt velocity.
      // Re-anchor state to the new position so a subsequent forward
      // step is computed from here.
      _lastTranslation = tx;
      _lastPosition = position;
      _lastResult = Offset.zero;
      return Offset.zero;
    }

    final dtUs = (position - _lastPosition!).inMicroseconds;
    final dx = tx.dx - _lastTranslation!.dx;
    final dy = tx.dy - _lastTranslation!.dy;
    final inv = 1e6 / dtUs;
    final v = Offset(dx * inv, dy * inv);

    _lastTranslation = tx;
    _lastPosition = position;
    _lastResult = v;
    return v;
  }

  void reset() {
    _lastTranslation = null;
    _lastPosition = null;
    _lastResult = Offset.zero;
  }
}
```

- [ ] **Step 3.4: Run the test to verify it passes**

```
flutter test test/effects/screen_pan_velocity_tracker_test.dart
```

Expected: All 5 tests pass.

- [ ] **Step 3.5: Commit**

```
git add packages/screen_recorder/lib/effects/screen_pan_velocity_tracker.dart \
        packages/screen_recorder/test/effects/screen_pan_velocity_tracker_test.dart
git commit -m "feat(motion-blur): per-frame screen pan velocity tracker"
```

---

## Task 4: `CursorMotionUpdate.velocityPxPerSec`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/cursor_motion_controller.dart`
- Modify (existing): `packages/screen_recorder/test/ui/widgets/zoom/cursor_motion_controller_test.dart`

`CursorMotionController` already smooths the cursor position via FIR. Extend `CursorMotionUpdate` with `velocityPxPerSec` and have the controller compute it as `(currentSmoothedPos − previousSmoothedPos) × (1e6 / Δt.inMicroseconds)`. First call, backwards scrubs, and missing previous-frame state all return `Offset.zero`. The existing result cache key already captures `position` + config; the velocity must be cached alongside `_cachedResult` so same-frame rebuilds don't re-compute or re-advance previous-frame state.

- [ ] **Step 4.1: Write the failing test (append to existing test file)**

Append at the end of `packages/screen_recorder/test/ui/widgets/zoom/cursor_motion_controller_test.dart`, **inside the same outer `group('CursorMotionController (FIR)', () { ... });`** block (locate the closing `});` of that group and put the new tests immediately before it):

```dart
    test('velocityPxPerSec is zero on the first call', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16667, x: 30, y: 0, clicked: false),
      ]);
      final out = ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('two forward updates produce a non-zero velocity along the path', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      // First call seeds the controller.
      ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      // Second call — None preset bypasses FIR so velocity is exactly
      // (Δx / Δt) on the raw samples: 30 px / 16.667 ms ≈ 1800 px/s.
      final out = ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec.dx, closeTo(1800, 5));
      expect(out.velocityPxPerSec.dy, closeTo(0, 1e-6));
    });

    test('backwards scrub returns zero velocity', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      ctrl.update(
        position: const Duration(microseconds: 50000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out = ctrl.update(
        position: const Duration(microseconds: 16667), // earlier
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('reset clears velocity history — first call after reset returns zero', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      ctrl.reset();
      final out = ctrl.update(
        position: const Duration(microseconds: 50000),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.velocityPxPerSec, Offset.zero);
    });

    test('idempotent same-position call returns the same velocity (no state advance)', () {
      final ctrl = CursorMotionController();
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667,
            x: i * 30.0,
            y: 0.0,
            clicked: false,
          )));
      ctrl.update(
        position: const Duration(microseconds: 16667),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out1 = ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      final out1Again = ctrl.update(
        position: const Duration(microseconds: 33334),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out1Again!.velocityPxPerSec, out1!.velocityPxPerSec);
      // Stepping forward from here should compute against frame 33334,
      // NOT against the duplicate call. If state had advanced on the
      // duplicate, dt would be 0 here.
      final out2 = ctrl.update(
        position: const Duration(microseconds: 50001),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out2!.velocityPxPerSec.dx, closeTo(1800, 5));
    });
  });
}
```

(The trailing `});\n}` closes the outer `group` and `void main()`. If you copy and the file already ends in those closers, replace them — don't double-close.)

- [ ] **Step 4.2: Run the test to verify it fails**

```
flutter test test/ui/widgets/zoom/cursor_motion_controller_test.dart
```

Expected: FAIL — `The named parameter 'velocityPxPerSec' isn't defined` on `CursorMotionUpdate`.

- [ ] **Step 4.3: Update `CursorMotionUpdate` and `CursorMotionController.update`**

In `packages/screen_recorder/lib/ui/widgets/zoom/cursor_motion_controller.dart`:

Replace the `CursorMotionUpdate` class (currently at lines 153-160) with:

```dart
class CursorMotionUpdate {
  const CursorMotionUpdate({
    required this.screenPos,
    required this.isClicked,
    required this.velocityPxPerSec,
  });
  final Offset screenPos;
  final bool isClicked;

  /// Smoothed cursor velocity in screen-space pixels per second.
  /// Zero on the first call, on backward scrubs, and whenever the
  /// previous-frame state isn't trustworthy.
  final Offset velocityPxPerSec;
}
```

No new imports — the existing `import 'package:flutter/animation.dart';` re-exports `Offset` from `dart:ui`.

In the `CursorMotionController` class, add private fields right after the existing result-cache fields (after the `_cachedConfigKey` declaration):

```dart
  // Velocity tracking. Carries last *advanced* state so duplicate-
  // position calls don't fake a Δt=0 step.
  Duration? _velPrevPosition;
  Offset? _velPrevScreenPos;
```

In `update()`, replace the cache-hit early return so it includes velocity:

Locate the existing block:

```dart
    if (_cachedPosition == position && _cachedConfigKey == configKey) {
      return _cachedResult;
    }
```

Leave it as-is (the cached result already contains the velocity field once we wire it).

Then locate the two return paths that build a `CursorMotionUpdate`:

**Path 1 — `window == 0` (None preset)**:

```dart
      _cachedResult = CursorMotionUpdate(
        screenPos: Offset(raw.x, raw.y),
        isClicked: raw.isClicked,
      );
      return _cachedResult;
```

Replace with:

```dart
      final screenPos = Offset(raw.x, raw.y);
      final velocity = _computeVelocity(screenPos: screenPos, position: position);
      _cachedResult = CursorMotionUpdate(
        screenPos: screenPos,
        isClicked: raw.isClicked,
        velocityPxPerSec: velocity,
      );
      return _cachedResult;
```

**Path 2 — FIR-smoothed**:

```dart
    final inv = 1.0 / accW;
    _cachedResult = CursorMotionUpdate(
      screenPos: Offset(accX * inv, accY * inv),
      isClicked: clicked,
    );
    return _cachedResult;
```

Replace with:

```dart
    final inv = 1.0 / accW;
    final screenPos = Offset(accX * inv, accY * inv);
    final velocity = _computeVelocity(screenPos: screenPos, position: position);
    _cachedResult = CursorMotionUpdate(
      screenPos: screenPos,
      isClicked: clicked,
      velocityPxPerSec: velocity,
    );
    return _cachedResult;
```

Add the helper method to the class (below the existing `_ensureKernel`):

```dart
  Offset _computeVelocity({
    required Offset screenPos,
    required Duration position,
  }) {
    final prevPos = _velPrevPosition;
    final prevScreen = _velPrevScreenPos;
    if (prevPos == null || prevScreen == null) {
      _velPrevPosition = position;
      _velPrevScreenPos = screenPos;
      return Offset.zero;
    }
    if (position < prevPos) {
      // Scrub backwards: re-anchor and report zero.
      _velPrevPosition = position;
      _velPrevScreenPos = screenPos;
      return Offset.zero;
    }
    if (position == prevPos) {
      // Same-frame rebuild — should be served from _cachedResult
      // already, but guard the no-Δt case anyway.
      return Offset.zero;
    }
    final dtUs = (position - prevPos).inMicroseconds;
    final dx = screenPos.dx - prevScreen.dx;
    final dy = screenPos.dy - prevScreen.dy;
    final inv = 1e6 / dtUs;
    _velPrevPosition = position;
    _velPrevScreenPos = screenPos;
    return Offset(dx * inv, dy * inv);
  }
```

Update `reset()` to clear the velocity state:

```dart
  void reset() {
    _cachedPosition = null;
    _cachedResult = null;
    _cachedConfigKey = null;
    _velPrevPosition = null;
    _velPrevScreenPos = null;
  }
```

- [ ] **Step 4.4: Update existing tests that construct `CursorMotionUpdate` directly**

Search for any test that constructs `CursorMotionUpdate(...)` directly:

```
grep -rn "CursorMotionUpdate(" packages/screen_recorder/test/
```

For each match, add `velocityPxPerSec: Offset.zero,` to the constructor argument list. (At time of writing, the only consumers are the FIR controller tests we're adding to, which call `controller.update(...)`, and `frame_compositor.dart` which reads `motion.screenPos` — neither constructs the type directly. If new direct constructors appear in your tree, add the field.)

- [ ] **Step 4.5: Run the test to verify it passes**

```
flutter test test/ui/widgets/zoom/cursor_motion_controller_test.dart
```

Expected: All tests pass — both the existing FIR tests and the 5 new velocity tests.

Also run analyze to catch missed call sites:

```
flutter analyze
```

Expected: clean.

- [ ] **Step 4.6: Commit**

```
git add packages/screen_recorder/lib/ui/widgets/zoom/cursor_motion_controller.dart \
        packages/screen_recorder/test/ui/widgets/zoom/cursor_motion_controller_test.dart
git commit -m "feat(motion-blur): expose smoothed cursor velocity from CursorMotionController"
```

---

## Task 5: `CursorOverlayPainter` multi-stamp

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart`
- Modify (existing): `packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart`

Add `velocityPxPerSec` and `motionBlurIntensity` parameters. In `paint()`, call `computeMotionBlurSamples` and either fall through to the existing single-call path (when `count == 1`) or stamp the cursor sprite N times along `−v̂`. Each stamp wraps `paintCursorWithEffects` in a `saveLayer` whose `Paint` carries the alpha for that stamp (Flutter idiom: `Paint()..color = Colors.white.withOpacity(α)` applied to the layer alpha).

The painter is verified via a `MockCanvas` that records `saveLayer`/`restore`/`translate` invocations. We can't golden-test the actual pixel output without rendering at a real DPR, and the existing `cursor_overlay_painter_test.dart` already opts for behavioral assertions.

- [ ] **Step 5.1: Write the failing test (append to existing test file)**

Append to `packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart`. Add this `_RecordingCanvas` test double at the top of the file (after the existing imports):

```dart
import 'dart:ui' as ui;

class _RecordingCanvas implements Canvas {
  final List<String> calls = [];

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    calls.add('saveLayer(alpha=${paint.color.opacity.toStringAsFixed(3)})');
  }

  @override
  void restore() {
    calls.add('restore');
  }

  @override
  void translate(double dx, double dy) {
    calls.add('translate(${dx.toStringAsFixed(2)}, ${dy.toStringAsFixed(2)})');
  }

  // Unused-by-this-test methods all delegate to noOp. The painter
  // calls drawCircle / drawPath / drawLine etc. via paintCursorWithEffects;
  // we don't care what they do — we only count the stamp envelope.
  @override
  noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) {
      calls.add(invocation.memberName.toString());
    }
    return null;
  }
}
```

Add these tests (in `void main()`, after the existing two tests):

```dart
  test('motionBlurIntensity 0 → no saveLayer/restore wrapping (single direct paint)', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final stampOpens = canvas.calls.where((c) => c.startsWith('saveLayer'));
    expect(stampOpens, isEmpty,
        reason: 'No blur ⇒ painter draws directly without a stamp envelope.');
  });

  test('motionBlurIntensity > 0 + velocity > 0 → N saveLayer/restore pairs', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final painter = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(50, 25),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: const Offset(2000, 0),
      motionBlurIntensity: 1.0,
    );
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(200, 100));
    final saveLayers = canvas.calls.where((c) => c.startsWith('saveLayer'));
    final restores = canvas.calls.where((c) => c == 'restore');
    expect(saveLayers.length, 8,
        reason: 'slider=1, max speed → 8 stamps.');
    expect(restores.length, 8);
  });

  test('shouldRepaint reflects velocity and intensity changes', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final a = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: Offset.zero,
      motionBlurIntensity: 0,
    );
    final b = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: const Offset(500, 0),
      motionBlurIntensity: 0,
    );
    final c = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      screenPos: const Offset(0, 0),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
      velocityPxPerSec: Offset.zero,
      motionBlurIntensity: 0.5,
    );
    expect(b.shouldRepaint(a), isTrue, reason: 'velocity changed');
    expect(c.shouldRepaint(a), isTrue, reason: 'intensity changed');
  });
```

- [ ] **Step 5.2: Run the test to verify it fails**

```
flutter test test/ui/widgets/cursor_overlay_painter_test.dart
```

Expected: FAIL — `The named parameter 'velocityPxPerSec' isn't defined` on `CursorOverlayPainter`.

- [ ] **Step 5.3: Implement multi-stamp painting**

Replace `packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart` entirely with:

```dart
// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'package:flutter/material.dart';
import '../../effects/motion_blur_samples.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_click_effect.dart';
import '../../rendering/cursor_geometry.dart';
import '../../rendering/cursor_glyph.dart';

/// Paints the recorded cursor on top of the video at the player's current
/// position. Takes a pre-computed [screenPos] (in screen-space pixels)
/// so the parent can apply motion smoothing via a CursorMotionController
/// — the painter itself stays stateless. Click events are still looked
/// up against [cursorRecording] for the press-pulse + ripple.
///
/// The glyph + click effects are drawn via [paintCursorWithEffects] so
/// the preview and the exported video stay visually consistent. When
/// [motionBlurIntensity] is > 0 and [velocityPxPerSec] is non-trivial,
/// the sprite is stamped multiple times along `−v̂` to produce a
/// directional motion-blur trail.
class CursorOverlayPainter extends CustomPainter {
  final CursorRecording cursorRecording;
  final Duration position;
  final Offset screenPos;
  final Size videoSize;
  final Size screenSize;
  final double sizeMultiplier;
  final CursorStyle style;
  final CursorClickEffect clickEffect;
  final Offset velocityPxPerSec;
  final double motionBlurIntensity;

  CursorOverlayPainter({
    required this.cursorRecording,
    required this.position,
    required this.screenPos,
    required this.videoSize,
    required this.screenSize,
    this.sizeMultiplier = 1.0,
    this.style = CursorStyle.modernDark,
    this.clickEffect = CursorClickEffect.ripple,
    this.velocityPxPerSec = Offset.zero,
    this.motionBlurIntensity = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final inVideo = screenToVideoSpace(
      screenPos: screenPos,
      screenSize: screenSize,
      videoSize: videoSize,
    );
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;
    final widgetPos = Offset(inVideo.dx * scaleX, inVideo.dy * scaleY);

    // Diameter scales with the widget→video ratio so the cursor stays
    // visually proportional even when the preview is rendered at a
    // size other than the native video size.
    final pxDiameter =
        kCursorBaseDiameter * sizeMultiplier * (scaleX + scaleY) / 2;

    final dt =
        microsSinceClick(cursorRecording, position.inMicroseconds);

    final samples = computeMotionBlurSamples(
      velocityPxPerSec: velocityPxPerSec,
      sliderIntensity: motionBlurIntensity,
      referenceSpeedPxPerSec: 2000,
      maxReachPx: 12,
    );

    if (samples.count == 1) {
      paintCursorWithEffects(
        canvas,
        position: widgetPos,
        baseDiameter: pxDiameter,
        style: style,
        microsSinceClick: dt,
        effect: clickEffect,
      );
      return;
    }

    // Pad bounds by max stamp reach so stamps near canvas edges
    // aren't clipped by the layer rect.
    final reach = samples.stepPx.distance * (samples.count - 1);
    final stampBounds = Rect.fromCircle(
      center: widgetPos,
      radius: pxDiameter * 1.5 + reach,
    );

    // Index 0 = oldest tail (lowest alpha, largest negative offset).
    // Index count-1 = head (highest alpha, offset 0).
    for (var i = 0; i < samples.count; i++) {
      final tailIndex = samples.count - 1 - i;
      final dx = samples.stepPx.dx * tailIndex;
      final dy = samples.stepPx.dy * tailIndex;
      canvas.saveLayer(
        stampBounds,
        Paint()..color = Colors.white.withOpacity(samples.alphas[i]),
      );
      canvas.translate(dx, dy);
      paintCursorWithEffects(
        canvas,
        position: widgetPos,
        baseDiameter: pxDiameter,
        style: style,
        microsSinceClick: dt,
        effect: clickEffect,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CursorOverlayPainter old) {
    return old.position != position ||
        old.screenPos != screenPos ||
        old.cursorRecording != cursorRecording ||
        old.videoSize != videoSize ||
        old.screenSize != screenSize ||
        old.sizeMultiplier != sizeMultiplier ||
        old.style != style ||
        old.clickEffect != clickEffect ||
        old.velocityPxPerSec != velocityPxPerSec ||
        old.motionBlurIntensity != motionBlurIntensity;
  }
}
```

- [ ] **Step 5.4: Run the test to verify it passes**

```
flutter test test/ui/widgets/cursor_overlay_painter_test.dart
```

Expected: All 5 tests pass (2 existing + 3 new).

- [ ] **Step 5.5: Run the full screen_recorder test suite to catch construction-site regressions**

```
flutter test
flutter analyze
```

Expected: green. Both `playback_canvas.dart` and `frame_compositor.dart` construct `CursorOverlayPainter` — they continue to compile because the new params have defaults (`velocityPxPerSec = Offset.zero`, `motionBlurIntensity = 0`).

- [ ] **Step 5.6: Commit**

```
git add packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart \
        packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart
git commit -m "feat(motion-blur): cursor multi-stamp directional blur"
```

---

## Task 6: Wire preview path

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

`PlaybackCanvas` gets a new `motionBlur` widget prop, an internal `ScreenPanVelocityTracker`, and pipes:
- cursor `velocityPxPerSec` from the extended `CursorMotionUpdate` into the cursor painter,
- `motionBlur` slider value into the cursor painter as `motionBlurIntensity`,
- `screenBlurSigma` over the inner `composition` via `ImageFiltered`, computed from the per-frame zoom transform's velocity.

`playback_screen.dart` already holds `_motionBlur`; it just needs to forward it to the `PlaybackCanvas` constructor.

This task has no new unit test — the canvas is integration-tested by running the app. The internals it relies on (samples helper, sigma helper, velocity trackers, painter) all have unit tests from Tasks 1-5.

- [ ] **Step 6.1: Add the `motionBlur` prop and tracker to `PlaybackCanvas`**

In `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`:

Add the import block additions (alongside existing imports):

```dart
import 'package:screen_recorder/effects/motion_blur_screen.dart';
import 'package:screen_recorder/effects/screen_pan_velocity_tracker.dart';
```

In the `PlaybackCanvas` constructor and field list, add:

```dart
    required this.motionBlur,
```

(Locate the constructor's required-fields block at lines 38-52 and slot it in alphabetically-ish — just after `cursorAnimationConfig`.)

Below the existing `final CursorAnimationConfig cursorAnimationConfig;` field, add:

```dart
  /// Slider value 0..1 from the inspector's Animation tab. 0 means
  /// "no motion blur" and short-circuits the screen ImageFilter and
  /// the cursor multi-stamp path.
  final double motionBlur;
```

In `_PlaybackCanvasState`, alongside the existing `_zoomTransformer`, `_zoomFocalController`, `_cursorMotionController` fields, add:

```dart
  final ScreenPanVelocityTracker _screenPanTracker = ScreenPanVelocityTracker();
```

- [ ] **Step 6.2: Pipe cursor velocity + intensity into the painter**

In `playback_canvas.dart`, locate the `CursorOverlayPainter` constructor call inside the `if (showCursor && motion != null)` Positioned block (around line 180-191). Replace the constructor with:

```dart
                      child: CustomPaint(
                        painter: CursorOverlayPainter(
                          cursorRecording: widget.cursorRecording,
                          position: pos,
                          screenPos: motion.screenPos,
                          videoSize: videoSize,
                          screenSize: videoSize,
                          sizeMultiplier: widget.cursorSize,
                          style: widget.cursorStyle,
                          clickEffect: widget.cursorClickEffect,
                          velocityPxPerSec: motion.velocityPxPerSec,
                          motionBlurIntensity: widget.motionBlur,
                        ),
                      ),
```

- [ ] **Step 6.3: Wrap the composition in `ImageFiltered` when screen blur is active**

The screen-blur wrapper has to live INSIDE `TweenAnimationBuilder.builder`, where the per-frame `transform` matrix is in scope. Currently the builder returns:

```dart
                return Transform(
                  transform: transform,
                  alignment: Alignment.center,
                  child: transformChild,
                );
```

`transformChild` is the `composition` (the entire moving Stack). Replace the `Transform` body with:

```dart
                final screenVelocity = _screenPanTracker.update(
                  transform: transform,
                  position: pos,
                );
                final sigma = screenBlurSigma(
                  velocity: screenVelocity,
                  intensity: widget.motionBlur,
                );
                final blurredChild = (sigma == Offset.zero)
                    ? transformChild
                    : ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: sigma.dx,
                          sigmaY: sigma.dy,
                        ),
                        child: transformChild,
                      );
                return Transform(
                  transform: transform,
                  alignment: Alignment.center,
                  child: blurredChild,
                );
```

(`ui` is already imported as `import 'dart:ui' as ui;` at the top of the file.)

- [ ] **Step 6.4: Pass `_motionBlur` from `playback_screen.dart` to `PlaybackCanvas`**

In `packages/screen_recorder/lib/ui/screens/playback_screen.dart`, locate the `PlaybackCanvas(...)` constructor call. It will fail to compile after Step 6.1 because `motionBlur` is now required.

Add `motionBlur: _motionBlur,` to the call site. Search for the construction:

```
grep -n "PlaybackCanvas(" lib/ui/screens/playback_screen.dart
```

In that constructor invocation, add:

```dart
              motionBlur: _motionBlur,
```

(Place it near the other animation-config props for readability.)

Also, while editing `playback_screen.dart`, remove the comment at line 76 that says `// motionBlur is captured but not yet rendered.` — it's now stale.

- [ ] **Step 6.5: Run analyze and the test suite**

```
flutter analyze
flutter test
```

Expected: clean. No tests should break — Tasks 1-5 introduced unit tests but no widget tests of `PlaybackCanvas` exist that would catch the wiring; the painter and helper unit tests are unaffected.

- [ ] **Step 6.6: Smoke-test in the running app**

Run the macOS desktop app (`flutter run -d macos` from `packages/screen_recorder`), open a recording, and:

1. Drag the **Motion blur** slider in the Animation tab from 0 → 1. Expect: cursor leaves a directional trail when moved fast; static cursor stays sharp at any slider value.
2. Trigger a zoom region and watch the focal-tracking pan. Expect: the framed video gets a horizontal/vertical Gaussian blur during fast pans, sharpens when the camera settles.
3. Pause playback at a non-end frame. Expect: blur freezes (velocity = 0 once paused, but smoothing of in-flight extrapolation may persist for one frame at most).

If anything doesn't work, drop back into Task 6 — don't paper over it in Task 7.

- [ ] **Step 6.7: Commit**

```
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(motion-blur): wire slider into preview canvas"
```

---

## Task 7: Wire export path

**Files:**
- Modify: `packages/screen_recorder/lib/export/frame_compositor.dart`
- Modify (existing): `packages/screen_recorder/test/export/frame_compositor_test.dart`

`FrameCompositor.compose` mirrors the preview's blur logic against the imperative Canvas. Steps:

1. Compute the zoom transform (already done at lines 137-150).
2. Compute screen velocity via a per-instance `ScreenPanVelocityTracker`.
3. If `screenBlurSigma > 0`, open a `saveLayer` with `Paint..imageFilter = ImageFilter.blur(sigmaX, sigmaY)` over `totalSize`.
4. Paint wallpaper / frame / video / cursor as today, BUT pass the cursor's velocity + intensity into `_paintCursor`.
5. Close the `saveLayer` if opened.

`projectState.motionBlur` is already on `EditorProjectState` (verified in spec context).

The existing `frame_compositor_test.dart` builds a real-ish composition; the new behavior is verified by running it with `motionBlur: 1` and just asserting the export still produces a non-empty buffer at the expected size. End-to-end pixel verification is out of scope; the per-helper tests already pin behavior.

- [ ] **Step 7.1: Extend `copyForTest` to support `motionBlur` overrides**

The bottom of `packages/screen_recorder/test/export/frame_compositor_test.dart` defines an extension:

```dart
extension on EditorProjectState {
  EditorProjectState copyForTest({
    WindowFrame? windowFrame,
    List<ZoomRegion>? zoomRegions,
  }) { ... }
}
```

Replace it with:

```dart
extension on EditorProjectState {
  EditorProjectState copyForTest({
    WindowFrame? windowFrame,
    List<ZoomRegion>? zoomRegions,
    double? motionBlur,
  }) {
    return EditorProjectState(
      zoomRegions: zoomRegions ?? this.zoomRegions,
      screenAnimationConfig: screenAnimationConfig,
      cursorAnimationConfig: cursorAnimationConfig,
      cursorSize: cursorSize,
      cursorStyle: cursorStyle,
      cursorClickEffect: cursorClickEffect,
      hideCursorOverlay: hideCursorOverlay,
      motionBlur: motionBlur ?? this.motionBlur,
      windowFrame: windowFrame ?? this.windowFrame,
    );
  }
}
```

- [ ] **Step 7.2: Write the failing test (append to existing test file)**

Add this test inside the existing `group('FrameCompositor', () { ... })` block in `packages/screen_recorder/test/export/frame_compositor_test.dart`, immediately before the closing `});` of the group:

```dart
    test('compose with motionBlur=1 still returns RGBA bytes sized to totalSize', () async {
      // Smoke test for the screen-blur saveLayer + ImageFilter wrap.
      // We don't pixel-assert the blur (that's covered by the
      // helper unit tests) — we just confirm the wrapped path
      // produces a buffer of the right length and doesn't throw.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyForTest(
          motionBlur: 1.0,
          windowFrame: const WindowFrame(
            name: 'None',
            padding: EdgeInsets.zero,
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(8, 4),
        fps: 30,
      );

      final magenta = _solidBgra(8, 4, 0xFF, 0x00, 0xFF);
      // First frame seeds the velocity tracker (zero velocity → no
      // ImageFilter wrap). Second frame at non-zero position would
      // see zero translation (no zoom in this fixture) → still no
      // wrap. Either way: no crash, buffer of expected length.
      final rgba0 = await compositor.compose(
        videoFrameBgra: magenta,
        position: Duration.zero,
      );
      final rgba1 = await compositor.compose(
        videoFrameBgra: magenta,
        position: const Duration(milliseconds: 33),
      );
      expect(rgba0.length, 8 * 4 * 4);
      expect(rgba1.length, 8 * 4 * 4);
    });
```

- [ ] **Step 7.3: Run the test to confirm it passes BEFORE the implementation**

```
flutter test test/export/frame_compositor_test.dart
```

Expected: PASS. `motionBlur: 1` is currently ignored by the compositor — that's the point. The test locks the contract that compose-with-blur doesn't crash; we re-run it after the implementation in Step 7.5 to confirm the wired-up path also produces a valid buffer.

- [ ] **Step 7.4: Wire screen blur and cursor blur into `frame_compositor.dart`**

In `packages/screen_recorder/lib/export/frame_compositor.dart`:

Add the imports near the existing ones:

```dart
import 'package:screen_recorder/effects/motion_blur_screen.dart';
import 'package:screen_recorder/effects/screen_pan_velocity_tracker.dart';
```

Add a new private field next to `_focalController` and `_motionController`:

```dart
  final ScreenPanVelocityTracker _screenPanTracker = ScreenPanVelocityTracker();
```

In `compose()`, locate the block that builds the zoom transform (around lines 137-150 in the existing file). Replace the existing block:

```dart
      if (focalUpdate != null) {
        final ramp = focalUpdate.zoom.rampCurveOverride?.toFlutterCurve() ??
            projectState.screenAnimationConfig.rampCurve;
        final transform = ZoomTransformer().getTransform(
          position: position,
          zoomRegion: focalUpdate.zoom,
          videoSize: videoSize,
          focalPoint: focalUpdate.focal,
          rampCurve: ramp,
        );
        canvas.translate(totalSize.width / 2, totalSize.height / 2);
        canvas.transform(transform.storage);
        canvas.translate(-totalSize.width / 2, -totalSize.height / 2);
      }
```

with:

```dart
      Matrix4 zoomTransform = Matrix4.identity();
      if (focalUpdate != null) {
        final ramp = focalUpdate.zoom.rampCurveOverride?.toFlutterCurve() ??
            projectState.screenAnimationConfig.rampCurve;
        zoomTransform = ZoomTransformer().getTransform(
          position: position,
          zoomRegion: focalUpdate.zoom,
          videoSize: videoSize,
          focalPoint: focalUpdate.focal,
          rampCurve: ramp,
        );
        canvas.translate(totalSize.width / 2, totalSize.height / 2);
        canvas.transform(zoomTransform.storage);
        canvas.translate(-totalSize.width / 2, -totalSize.height / 2);
      }

      // Screen-pan velocity is computed AFTER the matrix is built (not
      // applied to the canvas) so the velocity tracker sees the same
      // matrix the preview's TweenAnimationBuilder ticks against.
      final screenVelocity = _screenPanTracker.update(
        transform: zoomTransform,
        position: position,
      );
      final screenSigma = screenBlurSigma(
        velocity: screenVelocity,
        intensity: projectState.motionBlur,
      );
      final hasScreenBlur = screenSigma != Offset.zero;
      if (hasScreenBlur) {
        canvas.saveLayer(
          Rect.fromLTWH(0, 0, totalSize.width, totalSize.height),
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: screenSigma.dx,
              sigmaY: screenSigma.dy,
            ),
        );
      }
```

Then at the cursor paint block (around lines 155-157), replace:

```dart
      if (motion != null && !projectState.hideCursorOverlay) {
        _paintCursor(canvas, position: position, screenPos: motion.screenPos);
      }
```

with:

```dart
      if (motion != null && !projectState.hideCursorOverlay) {
        _paintCursor(
          canvas,
          position: position,
          screenPos: motion.screenPos,
          velocity: motion.velocityPxPerSec,
          intensity: projectState.motionBlur,
        );
      }

      if (hasScreenBlur) canvas.restore();
```

Update `_paintCursor` (around line 238) to accept and forward the new params:

```dart
  void _paintCursor(
    Canvas canvas, {
    required Duration position,
    required Offset screenPos,
    required Offset velocity,
    required double intensity,
  }) {
    canvas.save();
    canvas.translate(_effectivePadding.left, _effectivePadding.top);
    final painter = CursorOverlayPainter(
      cursorRecording: cursorRecording,
      position: position,
      screenPos: screenPos,
      videoSize: videoSize,
      screenSize: videoSize,
      sizeMultiplier: projectState.cursorSize,
      style: projectState.cursorStyle,
      clickEffect: projectState.cursorClickEffect,
      velocityPxPerSec: velocity,
      motionBlurIntensity: intensity,
    );
    painter.paint(canvas, videoSize);
    canvas.restore();
  }
```

- [ ] **Step 7.5: Run the test suite**

```
flutter test
flutter analyze
```

Expected: green. The new compositor test passes; no regressions in existing export tests.

- [ ] **Step 7.6: End-to-end smoke test (manual)**

Export a short recording with `motionBlur` slider at 1.0. Open the resulting MP4 and visually confirm:
- Cursor leaves a directional trail when moving fast.
- Screen pan during a zoom region is blurred along the pan direction.
- A still frame (slider=1, no motion) renders identically to slider=0 — the blur is speed-gated.

If the export looks correct, the WYSIWYG guarantee with the preview is preserved.

- [ ] **Step 7.7: Commit**

```
git add packages/screen_recorder/lib/export/frame_compositor.dart \
        packages/screen_recorder/test/export/frame_compositor_test.dart
git commit -m "feat(motion-blur): wire slider into export frame compositor"
```

---

## Task 8: Inspector subtitle copy

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart`

Drop the "(Coming soon — value is captured but not yet rendered.)" parenthetical from the slider subtitle. The class doc comment at the top of the file also says "Motion blur is still state-only" — update it.

- [ ] **Step 8.1: Update the slider subtitle**

In `packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart`, locate the `InspectorSlider` block (around lines 193-205). Replace:

```dart
        InspectorSlider(
          label: 'Motion blur',
          subtitle:
              'While mouse cursor or screen is moving, cinematic motion '
              'blur effect will be applied. (Coming soon — value is '
              'captured but not yet rendered.)',
          value: widget.motionBlur,
```

with:

```dart
        InspectorSlider(
          label: 'Motion blur',
          subtitle:
              'While mouse cursor or screen is moving, cinematic motion '
              'blur effect will be applied.',
          value: widget.motionBlur,
```

- [ ] **Step 8.2: Update the class doc comment**

At the top of the same file (around lines 10-14), replace the comment block:

```dart
/// Animation tab — screen / cursor animation styles + motion blur.
///
/// Screen and cursor styles write through to the playback render
/// pipeline. Motion blur is still state-only (proper motion blur
/// needs a separate cursor-trail or shader pass).
class AnimationTab extends StatefulWidget {
```

with:

```dart
/// Animation tab — screen / cursor animation styles + motion blur.
///
/// Screen and cursor styles write through to the playback render
/// pipeline. Motion blur drives directional cursor stamps + an
/// anisotropic Gaussian on the screen layer; both are speed-gated so
/// the slider only takes effect when something is actually moving.
class AnimationTab extends StatefulWidget {
```

- [ ] **Step 8.3: Run analyze**

```
flutter analyze
```

Expected: clean.

- [ ] **Step 8.4: Smoke-test the inspector**

Run the app, open the Animation tab, and confirm the subtitle no longer carries the "Coming soon" parenthetical.

- [ ] **Step 8.5: Commit**

```
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart
git commit -m "docs(motion-blur): drop 'coming soon' from Animation-tab subtitle"
```

---

## Final verification

- [ ] **Run the full test suite from repo root**

```
melos run test
```

Expected: All tests green (including the existing 440+ already in the suite plus the new tests from Tasks 1-5 and 7).

- [ ] **Run analyze across all packages**

```
melos run analyze
```

Expected: clean.

- [ ] **Final smoke test**

Open the app, exercise these flows:
1. Slider at 0 → preview and export look identical to pre-feature behavior.
2. Slider at 1 + cursor flick → directional cursor trail in preview, baked into the exported MP4.
3. Slider at 1 + zoom region with focal pan → anisotropic blur during pan, sharp at hold and at scale-only moments.
4. Scrubbing the timeline backwards with slider=1 → no jitter, no blur from negative-Δt artifacts.
5. Pause at end-of-clip with slider=1 → playhead pins clean (existing fix from `13bc3d5` still works).

If all five pass, the feature is shippable.
