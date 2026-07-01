# Zoom Movements Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional per-zoom "Movement" (None / Push-in / Sweep / Drift) that animates the held camera during a zoom, folded into the existing Phase 1 3D matrix builder.

**Architecture:** A new pure value type `ZoomMovement` lives on `ZoomRegion` next to `Tilt3D`. It resolves, per source position, to an additive `ZoomMovementSample` (scale multiplier + extra tilt angles + focal drift). `ZoomTransformer.getTransform` folds that sample into the matrix it already builds, so preview and export get movement identically and the None/flat path stays byte-identical. Movement is a pure function of position, so determinism (preview == scrub == export) is preserved for free.

**Tech Stack:** Dart / Flutter, melos monorepo. Engine package `slipreel_engine`, UI package `screen_recorder`. Tests via `flutter test` (run through melos or per-package).

## Global Constraints

- **Determinism invariant:** the rendered zoom transform MUST be a pure function of source position — preview-play == scrub == export. Movement adds NO statefulness.
- **Zero regression:** a zoom with `ZoomMovementKind.none` MUST produce a byte-identical matrix to today's Phase 1 output. Existing saved projects (no `movement` JSON key) load as None.
- **New zooms default to None** — do NOT auto-apply movement to auto-detected or manual zooms.
- **Do NOT run `dart format`** on existing files (pinned formatter reflows unrelated lines). Match surrounding style by hand; verify via `flutter analyze` + tests.
- **Follow existing patterns:** `ZoomMovement` mirrors `Tilt3D` (same file shape, JSON defensiveness, `copyWith`/`==`/`hashCode`). Inspector controls mirror the existing 3D-tilt block.
- Movement magnitudes are compile-time `const` in `zoom_movement.dart` (like `kTiltSubtleMaxDeg`).
- **Drift is manual-only** in the UI (it moves the focal, which would fight follow-cursor). Push-in / Sweep apply to both.

---

### Task 1: `ZoomMovement` model + resolve math

**Files:**
- Create: `packages/slipreel_engine/lib/models/zoom_movement.dart`
- Test: `packages/slipreel_engine/test/models/zoom_movement_test.dart`

**Interfaces:**
- Produces:
  - `enum ZoomMovementKind { none, pushIn, sweep, drift }`
  - `enum ZoomMovementIntensity { subtle, dramatic }`
  - `class ZoomMovementSample { final double scaleMul; final double extraTiltXRad; final double extraTiltYRad; final Offset focalDriftFrac; const ZoomMovementSample(...); static const identity = ...; }`
  - `class ZoomMovement { final ZoomMovementKind kind; final ZoomMovementIntensity intensity; const ZoomMovement({kind = none, intensity = subtle}); bool get isActive; ZoomMovementSample resolveAt({required double holdProgress, required double rampGate, required Offset normalizedFocal}); ZoomMovement copyWith({...}); Map<String,dynamic> toJson(); factory ZoomMovement.fromJson(...); == / hashCode }`
  - Consts: `kPushInSubtleExtra=0.06`, `kPushInDramaticExtra=0.12`, `kSweepSubtleDeg=5.0`, `kSweepDramaticDeg=10.0`, `kDriftSubtleFrac=0.04`, `kDriftDramaticFrac=0.08`.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/models/zoom_movement_test.dart`:

```dart
import 'dart:ui' show Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';

void main() {
  // A focal sitting right-of-center (positive nx) so auto directions resolve.
  const focalRight = Offset(0.5, 0.0);

  ZoomMovementSample resolve(
    ZoomMovement m, {
    double holdProgress = 1.0,
    double rampGate = 1.0,
    Offset focal = focalRight,
  }) =>
      m.resolveAt(
        holdProgress: holdProgress,
        rampGate: rampGate,
        normalizedFocal: focal,
      );

  group('resolveAt identity conditions', () {
    test('none is always the identity sample', () {
      final s = resolve(const ZoomMovement());
      expect(s.scaleMul, 1.0);
      expect(s.extraTiltXRad, 0.0);
      expect(s.extraTiltYRad, 0.0);
      expect(s.focalDriftFrac, Offset.zero);
    });

    test('rampGate 0 zeroes any movement (faded out at the ramp)', () {
      final s = resolve(
        const ZoomMovement(kind: ZoomMovementKind.pushIn),
        rampGate: 0.0,
      );
      expect(s.scaleMul, 1.0);
    });

    test('holdProgress 0 is the identity (motion starts gently)', () {
      final s = resolve(
        const ZoomMovement(kind: ZoomMovementKind.pushIn),
        holdProgress: 0.0,
      );
      expect(s.scaleMul, 1.0);
    });
  });

  group('per-move channel isolation', () {
    test('pushIn only scales', () {
      final s = resolve(const ZoomMovement(kind: ZoomMovementKind.pushIn));
      expect(s.scaleMul, greaterThan(1.0));
      expect(s.extraTiltXRad, 0.0);
      expect(s.extraTiltYRad, 0.0);
      expect(s.focalDriftFrac, Offset.zero);
    });

    test('sweep only tilts (yaw)', () {
      final s = resolve(const ZoomMovement(kind: ZoomMovementKind.sweep));
      expect(s.scaleMul, 1.0);
      expect(s.extraTiltYRad.abs(), greaterThan(0.0));
      expect(s.extraTiltXRad, 0.0);
      expect(s.focalDriftFrac, Offset.zero);
    });

    test('drift only shifts the focal', () {
      final s = resolve(const ZoomMovement(kind: ZoomMovementKind.drift));
      expect(s.scaleMul, 1.0);
      expect(s.extraTiltXRad, 0.0);
      expect(s.extraTiltYRad, 0.0);
      expect(s.focalDriftFrac.dx.abs(), greaterThan(0.0));
    });
  });

  group('intensity + curve', () {
    test('dramatic push-in scales more than subtle', () {
      final sub = resolve(const ZoomMovement(kind: ZoomMovementKind.pushIn));
      final dra = resolve(const ZoomMovement(
          kind: ZoomMovementKind.pushIn,
          intensity: ZoomMovementIntensity.dramatic));
      expect(dra.scaleMul, greaterThan(sub.scaleMul));
    });

    test('push-in scale grows monotonically with holdProgress', () {
      const m = ZoomMovement(kind: ZoomMovementKind.pushIn);
      final a = resolve(m, holdProgress: 0.25).scaleMul;
      final b = resolve(m, holdProgress: 0.75).scaleMul;
      expect(b, greaterThan(a));
    });

    test('sweep direction follows the focal side', () {
      const m = ZoomMovement(kind: ZoomMovementKind.sweep);
      final right = resolve(m, focal: const Offset(0.5, 0)).extraTiltYRad;
      final left = resolve(m, focal: const Offset(-0.5, 0)).extraTiltYRad;
      expect(right.sign, isNot(equals(left.sign)));
    });
  });

  group('json', () {
    test('round-trips kind + intensity', () {
      const m = ZoomMovement(
          kind: ZoomMovementKind.sweep,
          intensity: ZoomMovementIntensity.dramatic);
      expect(ZoomMovement.fromJson(m.toJson()), m);
    });

    test('empty / unknown json defaults to none + subtle', () {
      final m = ZoomMovement.fromJson(const {});
      expect(m.kind, ZoomMovementKind.none);
      expect(m.intensity, ZoomMovementIntensity.subtle);
      final u = ZoomMovement.fromJson(const {'kind': 'bogus'});
      expect(u.kind, ZoomMovementKind.none);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/zoom_movement_test.dart`
Expected: FAIL — `zoom_movement.dart` / `ZoomMovement` does not exist (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `packages/slipreel_engine/lib/models/zoom_movement.dart`:

```dart
import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Push-in extra scale reached at full hold (multiplier = 1 + extra).
const double kPushInSubtleExtra = 0.06;
const double kPushInDramaticExtra = 0.12;

/// Sweep yaw magnitude (degrees) reached at full hold.
const double kSweepSubtleDeg = 5.0;
const double kSweepDramaticDeg = 10.0;

/// Drift focal offset reached at full hold, as a fraction of the video size.
const double kDriftSubtleFrac = 0.04;
const double kDriftDramaticFrac = 0.08;

/// The named camera moves in the v1 library. [none] == today's static hold.
enum ZoomMovementKind { none, pushIn, sweep, drift }

/// Movement magnitude preset, mirroring the tilt vocabulary.
enum ZoomMovementIntensity { subtle, dramatic }

/// One frame's additive movement contribution, on top of the settled
/// (Phase 1) zoom transform. All fields are pre-gated by the ramp so they
/// fade in/out with the zoom.
class ZoomMovementSample {
  const ZoomMovementSample({
    this.scaleMul = 1.0,
    this.extraTiltXRad = 0.0,
    this.extraTiltYRad = 0.0,
    this.focalDriftFrac = Offset.zero,
  });

  /// Multiply the settled zoom factor (1.0 = no change).
  final double scaleMul;

  /// Added to the tilt angles (radians).
  final double extraTiltXRad;
  final double extraTiltYRad;

  /// Added to the focal, expressed as a fraction of the video size (each axis).
  final Offset focalDriftFrac;

  static const ZoomMovementSample identity = ZoomMovementSample();
}

/// Per-zoom camera movement. Lives on [ZoomRegion] next to `Tilt3D`.
///
/// The *direction* of a move is auto-derived from where the focal sits in the
/// frame ([normalizedFocal]); the *magnitude* is set by [intensity] and by how
/// far into the hold the playhead is ([holdProgress]), then gated by the ramp
/// ([rampGate]) so motion is zero at the ramps and full only at the settled
/// hold. Everything is a pure function of position — no state, no path
/// dependence — so preview == scrub == export.
class ZoomMovement {
  const ZoomMovement({
    this.kind = ZoomMovementKind.none,
    this.intensity = ZoomMovementIntensity.subtle,
  });

  final ZoomMovementKind kind;
  final ZoomMovementIntensity intensity;

  bool get isActive => kind != ZoomMovementKind.none;

  /// Ease-in-out (smoothstep) so motion starts and ends gently. This eased
  /// sample of [holdProgress] is the internal "keyframe track" a future editor
  /// could expose.
  static double _ease(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
  }

  ZoomMovementSample resolveAt({
    required double holdProgress,
    required double rampGate,
    required Offset normalizedFocal,
  }) {
    if (!isActive || rampGate <= 0.0) return ZoomMovementSample.identity;
    final env = _ease(holdProgress) * rampGate.clamp(0.0, 1.0);
    if (env <= 0.0) return ZoomMovementSample.identity;

    switch (kind) {
      case ZoomMovementKind.none:
        return ZoomMovementSample.identity;
      case ZoomMovementKind.pushIn:
        final extra = intensity == ZoomMovementIntensity.dramatic
            ? kPushInDramaticExtra
            : kPushInSubtleExtra;
        return ZoomMovementSample(scaleMul: 1.0 + extra * env);
      case ZoomMovementKind.sweep:
        final deg = intensity == ZoomMovementIntensity.dramatic
            ? kSweepDramaticDeg
            : kSweepSubtleDeg;
        final dir = normalizedFocal.dx >= 0 ? 1.0 : -1.0;
        final rad = deg * (math.pi / 180.0) * dir * env;
        return ZoomMovementSample(extraTiltYRad: rad);
      case ZoomMovementKind.drift:
        final frac = intensity == ZoomMovementIntensity.dramatic
            ? kDriftDramaticFrac
            : kDriftSubtleFrac;
        // Reveal toward the frame center: drift opposite the focal side.
        final dir = normalizedFocal.dx >= 0 ? -1.0 : 1.0;
        return ZoomMovementSample(
            focalDriftFrac: Offset(frac * dir * env, 0.0));
    }
  }

  ZoomMovement copyWith({
    ZoomMovementKind? kind,
    ZoomMovementIntensity? intensity,
  }) {
    return ZoomMovement(
      kind: kind ?? this.kind,
      intensity: intensity ?? this.intensity,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'intensity': intensity.name,
      };

  factory ZoomMovement.fromJson(Map<String, dynamic> json) {
    ZoomMovementKind kind = ZoomMovementKind.none;
    final kindName = json['kind'] as String?;
    if (kindName != null) {
      for (final k in ZoomMovementKind.values) {
        if (k.name == kindName) {
          kind = k;
          break;
        }
      }
    }
    ZoomMovementIntensity intensity = ZoomMovementIntensity.subtle;
    final intName = json['intensity'] as String?;
    if (intName != null) {
      for (final i in ZoomMovementIntensity.values) {
        if (i.name == intName) {
          intensity = i;
          break;
        }
      }
    }
    return ZoomMovement(kind: kind, intensity: intensity);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomMovement &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          intensity == other.intensity;

  @override
  int get hashCode => Object.hash(kind, intensity);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/zoom_movement_test.dart`
Expected: PASS (all groups green).

- [ ] **Step 5: Analyze + commit**

Run: `cd packages/slipreel_engine && flutter analyze lib/models/zoom_movement.dart test/models/zoom_movement_test.dart`
Expected: No issues.

```bash
git add packages/slipreel_engine/lib/models/zoom_movement.dart packages/slipreel_engine/test/models/zoom_movement_test.dart
git commit -m "feat(zoom): ZoomMovement model + resolve math (Phase 2 movements)"
```

---

### Task 2: Wire `movement` onto `ZoomRegion`

**Files:**
- Modify: `packages/slipreel_engine/lib/models/zoom_region.dart` (field, ctor, `copyWith`, `toJson`, `fromJson`, `==`, `hashCode`)
- Test: `packages/slipreel_engine/test/models/zoom_region_movement_test.dart` (create)

**Interfaces:**
- Consumes: `ZoomMovement` (Task 1).
- Produces: `ZoomRegion.movement` (`ZoomMovement`, default `const ZoomMovement()`), constructor param `ZoomMovement movement`, `copyWith({ZoomMovement? movement})`, JSON key `movement`.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/models/zoom_region_movement_test.dart`:

```dart
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  ZoomRegion base() => ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2,
      );

  test('defaults to none movement', () {
    expect(base().movement.kind, ZoomMovementKind.none);
  });

  test('copyWith sets the movement', () {
    final r = base().copyWith(
        movement: const ZoomMovement(kind: ZoomMovementKind.pushIn));
    expect(r.movement.kind, ZoomMovementKind.pushIn);
  });

  test('copyWith without movement preserves it', () {
    final r = base()
        .copyWith(movement: const ZoomMovement(kind: ZoomMovementKind.sweep))
        .copyWith(zoomLevel: 3);
    expect(r.movement.kind, ZoomMovementKind.sweep);
  });

  test('json round-trips the movement', () {
    final r = base().copyWith(
        movement: const ZoomMovement(
            kind: ZoomMovementKind.drift,
            intensity: ZoomMovementIntensity.dramatic));
    final back = ZoomRegion.fromJson(r.toJson());
    expect(back.movement, r.movement);
  });

  test('legacy json without a movement key loads as none', () {
    final json = base().toJson()..remove('movement');
    expect(ZoomRegion.fromJson(json).movement.kind, ZoomMovementKind.none);
  });

  test('movement participates in == / hashCode', () {
    final a = base().copyWith(
        movement: const ZoomMovement(kind: ZoomMovementKind.pushIn));
    final b = base().copyWith(
        movement: const ZoomMovement(kind: ZoomMovementKind.sweep));
    expect(a == b, isFalse);
    expect(a.hashCode == b.hashCode, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/zoom_region_movement_test.dart`
Expected: FAIL — `ZoomRegion` has no `movement` getter / no `movement` copyWith param.

- [ ] **Step 3: Write minimal implementation**

In `packages/slipreel_engine/lib/models/zoom_region.dart`:

3a. Add the import near the other model imports (top of file, alongside the `tilt3d.dart` import):

```dart
import 'zoom_movement.dart';
```

3b. Add the field right after `final Tilt3D tilt;` (line ~115):

```dart
  final ZoomMovement movement;
```

3c. Add the constructor param. In the constructor parameter list, after `this.tilt = const Tilt3D(),`:

```dart
    this.movement = const ZoomMovement(),
```

3d. In `copyWith`, add the param after `Tilt3D? tilt,`:

```dart
    ZoomMovement? movement,
```

and in the returned `ZoomRegion(...)`, after `tilt: tilt ?? this.tilt,`:

```dart
      movement: movement ?? this.movement,
```

3e. In `toJson()`, after `'tilt': tilt.toJson(),`:

```dart
      'movement': movement.toJson(),
```

3f. In `fromJson`, in the returned `ZoomRegion(...)`, after the `tilt:` argument block:

```dart
      movement: json['movement'] is Map
          ? ZoomMovement.fromJson(
              (json['movement'] as Map).cast<String, dynamic>())
          : const ZoomMovement(),
```

3g. In `operator ==`, add before the closing `;`, after `tilt == other.tilt`:

```dart
          &&
          movement == other.movement
```

(i.e. it becomes `... && tilt == other.tilt && movement == other.movement;`)

3h. In `hashCode`'s `Object.hash(...)`, add `movement,` after `tilt,`. Note: `Object.hash` takes up to 20 positional args; `ZoomRegion` currently passes 15, so there is room.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/zoom_region_movement_test.dart`
Expected: PASS.

- [ ] **Step 5: Full model suite + analyze + commit**

Run: `cd packages/slipreel_engine && flutter test test/models/ && flutter analyze lib/models/zoom_region.dart`
Expected: PASS, no analyze issues. (Confirms no existing `zoom_region` test broke.)

```bash
git add packages/slipreel_engine/lib/models/zoom_region.dart packages/slipreel_engine/test/models/zoom_region_movement_test.dart
git commit -m "feat(zoom): add movement field to ZoomRegion (ctor/copyWith/json/eq)"
```

---

### Task 3: Fold movement into `ZoomTransformer.getTransform`

**Files:**
- Modify: `packages/slipreel_engine/lib/effects/zoom_transformer.dart` (`getTransform`, lines ~52-89)
- Test: `packages/slipreel_engine/test/effects/zoom_transformer_movement_test.dart` (create)

**Interfaces:**
- Consumes: `ZoomRegion.movement` (Task 2), `ZoomMovement.resolveAt` (Task 1), existing `ZoomFraming.normalizedFocalOffset` / `centerOffset` / `centerOffsetInPlace` / `perspectiveTilt`, `ZoomTransformer.clampFocalToBounds`.
- Produces: `getTransform` now applies the movement sample; signature unchanged (callers untouched).

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/effects/zoom_transformer_movement_test.dart`:

```dart
import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  final t = ZoomTransformer();
  const videoSize = Size(1000, 1000);
  final framing = ZoomFraming.identity(videoSize);

  ZoomRegion region({
    required ZoomMovement movement,
    bool followCursor = false,
  }) =>
      ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 4),
        zoomLevel: 2,
        // 1s enter + 1s exit => hold window is [1s, 3s].
        enterDuration: const Duration(seconds: 1),
        exitDuration: const Duration(seconds: 1),
        followCursor: followCursor,
        movement: movement,
      );

  // A frame in the middle of the hold (holdProgress ~= 0.5, ramp fully in).
  const midHold = Duration(milliseconds: 2000);

  // The scale factor a matrix applies along X (row-major storage index 0).
  double scaleX(m) => m.storage[0].abs();

  test('none movement is byte-identical to a region without movement', () {
    final none = t.getTransform(
      position: midHold,
      zoomRegion: region(movement: const ZoomMovement()),
      videoSize: videoSize,
      framing: framing,
    );
    final bare = t.getTransform(
      position: midHold,
      zoomRegion: ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 4),
        zoomLevel: 2,
        enterDuration: const Duration(seconds: 1),
        exitDuration: const Duration(seconds: 1),
        followCursor: false,
      ),
      videoSize: videoSize,
      framing: framing,
    );
    expect(none.storage, bare.storage);
  });

  test('push-in enlarges the effective scale versus none', () {
    final withPush = t.getTransform(
      position: midHold,
      zoomRegion:
          region(movement: const ZoomMovement(kind: ZoomMovementKind.pushIn)),
      videoSize: videoSize,
      framing: framing,
    );
    final none = t.getTransform(
      position: midHold,
      zoomRegion: region(movement: const ZoomMovement()),
      videoSize: videoSize,
      framing: framing,
    );
    expect(scaleX(withPush), greaterThan(scaleX(none)));
  });

  test('movement is gated out during the enter ramp', () {
    // 500ms is inside the enter ramp => rampGate < 1 and holdProgress 0.
    const inRamp = Duration(milliseconds: 500);
    final withPush = t.getTransform(
      position: inRamp,
      zoomRegion:
          region(movement: const ZoomMovement(kind: ZoomMovementKind.pushIn)),
      videoSize: videoSize,
      framing: framing,
    );
    final none = t.getTransform(
      position: inRamp,
      zoomRegion: region(movement: const ZoomMovement()),
      videoSize: videoSize,
      framing: framing,
    );
    expect(scaleX(withPush), closeTo(scaleX(none), 1e-9));
  });

  test('getTransform is deterministic — same position, same matrix, '
      'regardless of call order (preview == export)', () {
    final r =
        region(movement: const ZoomMovement(kind: ZoomMovementKind.sweep));
    Object call(Duration p) => t
        .getTransform(
          position: p,
          zoomRegion: r,
          videoSize: videoSize,
          framing: framing,
        )
        .storage;
    // Sample forward, then the same positions in reverse.
    final fwd = [for (final ms in [1200, 1800, 2400]) call(Duration(milliseconds: ms))];
    final rev = [for (final ms in [2400, 1800, 1200]) call(Duration(milliseconds: ms))];
    expect(fwd[0], rev[2]);
    expect(fwd[1], rev[1]);
    expect(fwd[2], rev[0]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/effects/zoom_transformer_movement_test.dart`
Expected: FAIL — `push-in enlarges...` fails (movement not applied yet; scales equal). The `none` and determinism tests may already pass.

- [ ] **Step 3: Write minimal implementation**

In `packages/slipreel_engine/lib/effects/zoom_transformer.dart`, replace the body from the `final focal = ...` line through the final `return` (currently lines ~56-89) with:

```dart
    final focal = focalPoint ?? zoomRegion.rect.center;
    final f = framing ?? ZoomFraming.identity(videoSize);

    // Ramp progress (0 at z==1, 1 at settled zoom) — drives BOTH the tilt
    // magnitude and the movement fade, so movement is zero during the ramps
    // and full only at the settled hold.
    final denom = zoomRegion.zoomLevel - 1.0;
    final rampGate = denom <= 0 ? 0.0 : ((z - 1.0) / denom).clamp(0.0, 1.0);

    // Movement (Phase 2): a pure, position-parameterized additive sample folded
    // on top of the settled 2D+tilt transform. None => identity sample => the
    // math below collapses to the Phase 1 result.
    final mv = zoomRegion.movement.resolveAt(
      holdProgress: _holdProgress(position, zoomRegion),
      rampGate: rampGate,
      normalizedFocal: f.normalizedFocalOffset(focal),
    );
    final zEff = z * mv.scaleMul;
    final focalEff = mv.focalDriftFrac == Offset.zero
        ? focal
        : Offset(
            focal.dx + mv.focalDriftFrac.dx * videoSize.width,
            focal.dy + mv.focalDriftFrac.dy * videoSize.height,
          );
    // Defensive: keep a drifted focal in-bounds for follow-cursor zooms (the UI
    // never offers Drift there, but hand-edited JSON could). Manual placements
    // magnify in place and are intentionally unclamped, so leave them.
    final focalUsed =
        (zoomRegion.followCursor && mv.focalDriftFrac != Offset.zero)
            ? clampFocalToBounds(focalEff, videoSize, zEff)
            : focalEff;

    final pCenterRel = zoomRegion.followCursor
        ? f.centerOffset(focalUsed, zEff) // center-and-clamp (unchanged)
        : f.centerOffsetInPlace(focalUsed, zEff); // magnify-in-place (new)

    final base = Matrix4.identity()
      ..translateByDouble(-zEff * pCenterRel.dx, -zEff * pCenterRel.dy, 0, 1.0)
      ..scaleByDouble(zEff, zEff, 1.0, 1.0);

    // 2D / flat AND no movement tilt => return the legacy 2D matrix. (Push-in /
    // Drift add no tilt, so they fall through here with only base changed.)
    final angles = zoomRegion.tilt.resolveAngles(
      normalizedFocal: f.normalizedFocalOffset(focalUsed),
      progress: rampGate,
    );
    final axRad = angles.xRad + mv.extraTiltXRad;
    final ayRad = angles.yRad + mv.extraTiltYRad;
    if (axRad == 0.0 && ayRad == 0.0) return base;
    return f.perspectiveTilt(axRad, ayRad).multiplied(base);
```

Then add this private helper as a top-level function at the bottom of the file (after the `ZoomTransformer` class):

```dart
/// Normalized position within a region's HOLD window (between the enter and
/// exit ramps): 0 before the hold, 0→1 across it, 1 after. A degenerate hold
/// (enter+exit consume the region) yields 0 until the very end, so movement
/// contributes ~nothing and can't whip on tiny zooms.
double _holdProgress(Duration position, ZoomRegion r) {
  final holdStart = r.startTime + r.enterDuration;
  final holdEnd = r.endTime - r.exitDuration;
  final span = (holdEnd - holdStart).inMicroseconds;
  if (span <= 0) return position >= holdEnd ? 1.0 : 0.0;
  final e = (position - holdStart).inMicroseconds / span;
  return e.clamp(0.0, 1.0);
}
```

Also add the movement import at the top of the file (with the other model imports):

```dart
import '../models/zoom_movement.dart';
```

Note: the old inline `progress` variable used only in the tilt branch is now `rampGate`; the `final denom`/`progress` lines that previously sat inside the 3D branch are removed (replaced by the `rampGate` computed above). Ensure no duplicate `denom`/`progress` remains.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/effects/zoom_transformer_movement_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full effects suite (tilt regression guard) + analyze**

Run: `cd packages/slipreel_engine && flutter test test/effects/ && flutter analyze lib/effects/zoom_transformer.dart`
Expected: PASS — existing `zoom_transformer_test.dart` and `zoom_transformer_tilt_test.dart` still green (the None/flat path is unchanged), no analyze issues.

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/effects/zoom_transformer.dart packages/slipreel_engine/test/effects/zoom_transformer_movement_test.dart
git commit -m "feat(zoom): fold movement sample into getTransform (scale/tilt/focal)"
```

---

### Task 4: Zoom inspector — Movement picker + intensity

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` (add movement block after the 3D-tilt block, before the `InspectorSectionDivider()` that precedes the follow toggle)
- Test: `packages/screen_recorder/test/ui/widgets/inspector/zoom_movement_inspector_test.dart` (create)

**Interfaces:**
- Consumes: `ZoomMovement`, `ZoomMovementKind`, `ZoomMovementIntensity` (Task 1); `ZoomRegion.copyWith(movement:)` (Task 2); existing `InspectorSectionLabel`, `InspectorChip`, `onChanged(ZoomRegion)` callback, `zoom.followCursor`.
- Produces: no new public API — UI only.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/ui/widgets/inspector/zoom_movement_inspector_test.dart`:

```dart
import 'dart:ui' show Rect;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/zoom_movement.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';

ZoomRegion _region({bool followCursor = false, ZoomMovement? movement}) =>
    ZoomRegion(
      rect: const Rect.fromLTWH(100, 100, 200, 200),
      startTime: Duration.zero,
      duration: const Duration(seconds: 3),
      zoomLevel: 2,
      followCursor: followCursor,
      movement: movement ?? const ZoomMovement(),
    );

Future<void> _pump(WidgetTester tester, ZoomRegion zoom,
    void Function(ZoomRegion) onChanged) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ZoomContextInspector(zoom: zoom, onChanged: onChanged),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selecting Push-in sets the movement on the region',
      (tester) async {
    ZoomRegion? updated;
    await _pump(tester, _region(), (z) => updated = z);

    await tester.tap(find.text('Push-in'));
    await tester.pumpAndSettle();

    expect(updated, isNotNull);
    expect(updated!.movement.kind, ZoomMovementKind.pushIn);
  });

  testWidgets('Drift is hidden for follow-cursor zooms', (tester) async {
    await _pump(tester, _region(followCursor: true), (_) {});
    expect(find.text('Drift'), findsNothing);
  });

  testWidgets('Drift is offered for manual (in-place) zooms', (tester) async {
    await _pump(tester, _region(followCursor: false), (_) {});
    expect(find.text('Drift'), findsOneWidget);
  });

  testWidgets('intensity control appears once a movement is chosen',
      (tester) async {
    await _pump(
        tester,
        _region(movement: const ZoomMovement(kind: ZoomMovementKind.sweep)),
        (_) {});
    expect(find.text('Subtle'), findsWidgets);
    expect(find.text('Dramatic'), findsWidgets);
  });
}
```

Note: the test taps by the visible label text (`'Push-in'`, `'Drift'`, etc.), so the implementation MUST render those exact strings via `InspectorChip(label: ...)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/zoom_movement_inspector_test.dart`
Expected: FAIL — no `Push-in` chip found.

- [ ] **Step 3: Write minimal implementation**

In `zoom_context_inspector.dart`:

3a. Add the import near the `tilt3d.dart` import:

```dart
import 'package:slipreel_engine/models/zoom_movement.dart';
```

3b. Locate the end of the 3D-tilt block — the `if (zoom.tilt.is3D) ...[ ... ]` list that closes just before `const InspectorSectionDivider()` preceding the follow toggle (around line 283-306). Insert the movement block immediately AFTER the tilt block's closing `]`, and BEFORE that divider:

```dart
              const InspectorSectionDivider(),
              const InspectorSectionLabel('Movement'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in [
                    (ZoomMovementKind.none, 'None'),
                    (ZoomMovementKind.pushIn, 'Push-in'),
                    (ZoomMovementKind.sweep, 'Sweep'),
                    // Drift moves the focal — only meaningful for manual
                    // (in-place) zooms; it would fight the cursor follow.
                    if (!zoom.followCursor) (ZoomMovementKind.drift, 'Drift'),
                  ])
                    InspectorChip(
                      label: entry.$2,
                      selected: zoom.movement.kind == entry.$1,
                      dense: true,
                      onTap: () => onChanged(zoom.copyWith(
                          movement: zoom.movement.copyWith(kind: entry.$1))),
                    ),
                ],
              ),
              if (zoom.movement.isActive) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in const [
                      (ZoomMovementIntensity.subtle, 'Subtle'),
                      (ZoomMovementIntensity.dramatic, 'Dramatic'),
                    ])
                      InspectorChip(
                        label: entry.$2,
                        selected: zoom.movement.intensity == entry.$1,
                        dense: true,
                        onTap: () => onChanged(zoom.copyWith(
                            movement:
                                zoom.movement.copyWith(intensity: entry.$1))),
                      ),
                  ],
                ),
              ],
```

Note: if a `const InspectorSectionDivider()` already sits between the tilt block and the follow toggle, do NOT add a second one — reuse it (place the movement block after the existing divider). Verify the surrounding structure when editing; the goal is one divider between the tilt controls and the Movement label.

3c. If `InspectorSectionLabel` does not accept a positional `String`, check its constructor in `packages/screen_recorder/lib/ui/widgets/inspector/` and match the existing call sites (e.g. it may be `InspectorSectionLabel(label: 'Movement')`). Use the same form the file already uses for other section labels.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/zoom_movement_inspector_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`
Expected: No issues.

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart packages/screen_recorder/test/ui/widgets/inspector/zoom_movement_inspector_test.dart
git commit -m "feat(zoom): Movement picker + intensity in the zoom inspector"
```

---

### Task 5: Full-suite verification + branch finish

**Files:** none (verification only).

- [ ] **Step 1: Engine suite**

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS (all engine tests, including the new model/transformer tests and the untouched tilt/determinism suites).

- [ ] **Step 2: Recorder suite**

Run: `cd packages/screen_recorder && flutter test`
Expected: PASS.

- [ ] **Step 3: Repo analyze (CI parity)**

Run: `melos run analyze`
Expected: `flutter analyze --no-fatal-infos` clean across packages.

- [ ] **Step 4: Live visual pass (manual)**

Build + run, add a manual zoom, try each movement (Push-in / Sweep / Drift) at Subtle and Dramatic, and a follow-cursor zoom (Push-in / Sweep only). Confirm: motion fades in/out with the ramp (no pop), Drift is absent on follow zooms, and scrub-to-frame matches play-through (determinism). Reference: build via `flutter build macos --release` + `open` (reap-proof; see the anticipatory-follow test-harness note in memory).

- [ ] **Step 5: Finish the branch**

Invoke `superpowers:finishing-a-development-branch` to open the PR (base `main`), referencing issue #12 (Phase 2). Update the `3d_zoom_tilt_subproject` memory + `MEMORY.md` index with the Phase 2 outcome.

---

## Self-Review

**Spec coverage:**
- Model `ZoomMovement` (kind + intensity, pure `resolveAt`, JSON) → Task 1. ✓
- Per-region property on `ZoomRegion`, default None, absent-key migration → Task 2. ✓
- Fold into `getTransform`, ramp-gated, hold-windowed, None byte-identical, determinism → Task 3. ✓
- v1 library None/Push-in/Sweep/Drift with distinct channels (scale/tilt/focal) → Tasks 1+3. ✓
- Drift manual-only (engine clamp + UI hide) → Task 3 (clamp) + Task 4 (hide). ✓
- Subtle/Dramatic intensity → Task 1 (magnitudes) + Task 4 (control). ✓
- Auto direction from focal → Task 1 (sweep/drift `dir`). ✓
- Inspector UI mirroring tilt → Task 4. ✓
- Preview==export via deterministic pure function → Task 3 determinism test. ✓
- Testing (model, transformer regression, determinism, inspector) → Tasks 1-4; golden parity is covered by the matrix-equality/determinism assertions (movement lives inside the shared `getTransform`, so a separate pixel golden adds no coverage beyond the Phase 1 goldens). ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `ZoomMovement` / `ZoomMovementKind` / `ZoomMovementIntensity` / `ZoomMovementSample` names, `resolveAt({holdProgress, rampGate, normalizedFocal})`, `focalDriftFrac` (Offset, fraction of video size), `scaleMul`, `extraTiltXRad`/`extraTiltYRad`, and `_holdProgress(position, region)` are used consistently across Tasks 1, 3, and 4. ✓

**Scope:** Single implementation plan, one feature; no keyframe editor, no extra moves, no cross-zoom objects (all deferred per spec). ✓
