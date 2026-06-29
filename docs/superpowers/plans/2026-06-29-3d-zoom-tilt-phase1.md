# 3D Zoom Tilt — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give zooms an optional 3D perspective tilt — a floating content panel that leans in 3D over a static background — controlled by a per-zoom 2D/3D toggle with auto direction, style presets, and a manual override.

**Architecture:** A new `Tilt3D` value lives on each `ZoomRegion`. `ZoomTransformer.getTransform` composes a perspective+rotation matrix on top of the existing 2D scale+translate matrix; flat tilt returns the existing matrix byte-identically. Both the preview (`Transform` widget) and export (`Canvas.transform`) pipelines already apply that single matrix to an already-isolated content panel over an already-static wallpaper, so no layer-tree refactor is needed — only the matrix changes (plus making the export non-device frame chrome share the panel transform under 3D). Tilt magnitude ramps with the live zoom factor so it never desyncs. Enabling 3D enforces a project-wide minimum padding floor so the tilt always reveals wallpaper, not bare background.

**Tech Stack:** Dart/Flutter, `Matrix4` (vector_math), Riverpod, melos monorepo, `fvm flutter test`.

## Global Constraints

- **Do NOT run `dart format` on existing files.** The pinned formatter is tall-style but committed code is not; running it reflows ~50+ unrelated lines. CI does not enforce it. Match surrounding style by hand; verify via analyze + test.
- **Flat / 2D must be byte-identical to today.** The flat path returns the exact existing matrix and changes no rendering. This is the zero-regression guarantee — guard it with a test.
- **Tunable values (use these exact defaults):** `subtle` max tilt = **4°**, `dramatic` max tilt = **11°**, `kPerspective` = **1.6**, `kMinPadding3D` = **6%** of the canvas/video short side (rounded to whole px).
- **New zooms default to 3D/Subtle; deserialized (old) zooms default to 2D/flat.** Implement the "new = subtle" default only at the two real creation sites; the `ZoomRegion` constructor default and `fromJson` default are **flat** (keeps 98 existing test/demo call sites and old projects unchanged).
- **Captions stay flat (untilted).** Do not tilt captions.
- **Removing the last 3D zoom does not auto-lower padding** — the floor enforcement only ever raises padding, never lowers it.
- Verify each package with `cd packages/<pkg> && fvm flutter analyze` and `fvm flutter test <path>`. Goldens are `@TestOn('mac-os')`.

---

## File Structure

**New files:**
- `packages/slipreel_engine/lib/models/tilt3d.dart` — `ZoomTiltStyle` enum + `Tilt3D` value type (style, optional manual X/Y angles, `is3D`, JSON, `==`/`hashCode`) + pure angle resolution (`resolveAngles`) and the angle constants.
- `packages/slipreel_engine/test/models/tilt3d_test.dart`
- `packages/slipreel_engine/test/rendering/zoom_framing_tilt_test.dart`
- `packages/slipreel_engine/test/effects/zoom_transformer_tilt_test.dart`
- `packages/slipreel_engine/test/export/frame_compositor_tilt_golden_test.dart`
- `packages/screen_recorder/test/ui/inspector/zoom_tilt_inspector_test.dart`
- `packages/slipreel_engine/test/state/editor_project_controller_tilt_padding_test.dart`

**Modified files:**
- `packages/slipreel_engine/lib/models/zoom_region.dart` — add `tilt` field (default flat) through ctor / `copyWith` / `toJson` / `fromJson` / `==` / `hashCode`.
- `packages/slipreel_engine/lib/rendering/zoom_framing.dart` — add `normalizedFocalOffset` + `perspectiveTilt`.
- `packages/slipreel_engine/lib/effects/zoom_transformer.dart` — compose the 3D matrix in `getTransform`.
- `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart` — new auto zooms default to subtle.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — new manual zooms default to subtle.
- `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` — 2D/3D toggle + style + manual controls.
- `packages/slipreel_engine/lib/state/editor_project_controller.dart` — enforce the 3D padding floor.
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart` — slider min reflects the floor while 3D is active.
- `packages/slipreel_engine/lib/export/frame_compositor.dart` — non-device frame chrome shares the panel transform under 3D.

---

## Task 1: `Tilt3D` model + angle resolution

**Files:**
- Create: `packages/slipreel_engine/lib/models/tilt3d.dart`
- Test: `packages/slipreel_engine/test/models/tilt3d_test.dart`

**Interfaces:**
- Produces:
  - `enum ZoomTiltStyle { flat, subtle, dramatic }`
  - `class Tilt3D { final ZoomTiltStyle style; final double? manualAngleX; final double? manualAngleY; const Tilt3D({this.style = ZoomTiltStyle.flat, this.manualAngleX, this.manualAngleY}); bool get is3D; Tilt3D copyWith({...}); Map<String,dynamic> toJson(); factory Tilt3D.fromJson(Map<String,dynamic>); == / hashCode; }`
  - `({double xRad, double yRad}) Tilt3D.resolveAngles({required Offset normalizedFocal, required double progress})` — returns tilt angles in **radians**. Auto direction from `normalizedFocal` (each component in `[-1,1]`), magnitude `* progress`. Manual angles (degrees), when non-null, replace the auto value per-axis (still `* progress`). Flat → `(0,0)`.
  - Constants: `kTiltSubtleMaxDeg = 4.0`, `kTiltDramaticMaxDeg = 11.0`.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/slipreel_engine/test/models/tilt3d_test.dart
import 'dart:math' as math;
import 'dart:ui' show Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';

void main() {
  group('Tilt3D model', () {
    test('default is flat / 2D', () {
      const t = Tilt3D();
      expect(t.style, ZoomTiltStyle.flat);
      expect(t.is3D, isFalse);
      expect(t.manualAngleX, isNull);
      expect(t.manualAngleY, isNull);
    });

    test('subtle/dramatic are 3D', () {
      expect(const Tilt3D(style: ZoomTiltStyle.subtle).is3D, isTrue);
      expect(const Tilt3D(style: ZoomTiltStyle.dramatic).is3D, isTrue);
    });

    test('json round-trips style + manual angles', () {
      const t = Tilt3D(
          style: ZoomTiltStyle.dramatic, manualAngleX: -7, manualAngleY: 3);
      expect(Tilt3D.fromJson(t.toJson()), t);
    });

    test('fromJson of empty map is flat (legacy default)', () {
      expect(Tilt3D.fromJson(const {}), const Tilt3D());
    });

    test('copyWith changes style and clears manual via flags', () {
      const t = Tilt3D(style: ZoomTiltStyle.subtle, manualAngleX: 5);
      expect(t.copyWith(style: ZoomTiltStyle.dramatic).style,
          ZoomTiltStyle.dramatic);
      expect(t.copyWith(clearManual: true).manualAngleX, isNull);
    });
  });

  group('Tilt3D.resolveAngles', () {
    test('flat resolves to zero', () {
      final a = const Tilt3D().resolveAngles(
          normalizedFocal: const Offset(1, 1), progress: 1);
      expect(a.xRad, 0);
      expect(a.yRad, 0);
    });

    test('auto direction: focal to the right yields +Y rotation, '
        'focal below yields -X rotation', () {
      final a = const Tilt3D(style: ZoomTiltStyle.subtle).resolveAngles(
          normalizedFocal: const Offset(1, 1), progress: 1);
      // yRad = +nx*max ; xRad = -ny*max
      expect(a.yRad, closeTo(kTiltSubtleMaxDeg * math.pi / 180, 1e-9));
      expect(a.xRad, closeTo(-kTiltSubtleMaxDeg * math.pi / 180, 1e-9));
    });

    test('magnitude scales linearly with progress', () {
      final full = const Tilt3D(style: ZoomTiltStyle.subtle).resolveAngles(
          normalizedFocal: const Offset(1, 0), progress: 1);
      final half = const Tilt3D(style: ZoomTiltStyle.subtle).resolveAngles(
          normalizedFocal: const Offset(1, 0), progress: 0.5);
      expect(half.yRad, closeTo(full.yRad / 2, 1e-9));
    });

    test('manual angle replaces auto per-axis (degrees), still * progress', () {
      final a = const Tilt3D(style: ZoomTiltStyle.subtle, manualAngleY: 10)
          .resolveAngles(normalizedFocal: const Offset(-1, 0), progress: 0.5);
      expect(a.yRad, closeTo(10 * math.pi / 180 * 0.5, 1e-9));
    });

    test('dramatic uses the larger max angle', () {
      final a = const Tilt3D(style: ZoomTiltStyle.dramatic).resolveAngles(
          normalizedFocal: const Offset(1, 0), progress: 1);
      expect(a.yRad, closeTo(kTiltDramaticMaxDeg * math.pi / 180, 1e-9));
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/tilt3d_test.dart`
Expected: FAIL — `Tilt3D`/`ZoomTiltStyle` not defined (compile error).

- [ ] **Step 3: Write the implementation**

```dart
// packages/slipreel_engine/lib/models/tilt3d.dart
import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Max auto tilt angle (degrees) for the Subtle preset.
const double kTiltSubtleMaxDeg = 4.0;

/// Max auto tilt angle (degrees) for the Dramatic preset.
const double kTiltDramaticMaxDeg = 11.0;

/// The 3D-tilt style of a zoom. [flat] is the 2D case (no tilt); [subtle] and
/// [dramatic] are 3D presets that set the maximum tilt angle.
enum ZoomTiltStyle { flat, subtle, dramatic }

/// Per-zoom 3D tilt configuration. Lives on [ZoomRegion]. [flat] == 2D.
///
/// The tilt *direction* is auto-derived from where the zoom's focal sits in the
/// composed frame; the *magnitude* is set by [style] and ramps with the zoom
/// factor (see [resolveAngles]). [manualAngleX] / [manualAngleY] (degrees), when
/// non-null, override the auto-derived angle on that axis.
class Tilt3D {
  const Tilt3D({
    this.style = ZoomTiltStyle.flat,
    this.manualAngleX,
    this.manualAngleY,
  });

  final ZoomTiltStyle style;
  final double? manualAngleX;
  final double? manualAngleY;

  bool get is3D => style != ZoomTiltStyle.flat;

  double get _maxDeg => switch (style) {
        ZoomTiltStyle.flat => 0.0,
        ZoomTiltStyle.subtle => kTiltSubtleMaxDeg,
        ZoomTiltStyle.dramatic => kTiltDramaticMaxDeg,
      };

  /// Tilt angles in RADIANS for the current frame.
  ///
  /// [normalizedFocal] is the focal's offset from the canvas center, each axis
  /// in `[-1, 1]`. [progress] is the live zoom ramp progress in `[0, 1]` (0 at
  /// rest, 1 at full zoom). Auto: `yRad = nx*max`, `xRad = -ny*max` so the focal
  /// side leans toward the viewer. Manual angles replace the auto value per axis.
  ({double xRad, double yRad}) resolveAngles({
    required Offset normalizedFocal,
    required double progress,
  }) {
    if (!is3D) return (xRad: 0.0, yRad: 0.0);
    const deg2rad = math.pi / 180.0;
    final autoXDeg = -normalizedFocal.dy * _maxDeg;
    final autoYDeg = normalizedFocal.dx * _maxDeg;
    final xDeg = manualAngleX ?? autoXDeg;
    final yDeg = manualAngleY ?? autoYDeg;
    return (xRad: xDeg * deg2rad * progress, yRad: yDeg * deg2rad * progress);
  }

  Tilt3D copyWith({
    ZoomTiltStyle? style,
    double? manualAngleX,
    double? manualAngleY,
    bool clearManual = false,
  }) {
    return Tilt3D(
      style: style ?? this.style,
      manualAngleX: clearManual ? null : (manualAngleX ?? this.manualAngleX),
      manualAngleY: clearManual ? null : (manualAngleY ?? this.manualAngleY),
    );
  }

  Map<String, dynamic> toJson() => {
        'style': style.name,
        if (manualAngleX != null) 'manualAngleX': manualAngleX,
        if (manualAngleY != null) 'manualAngleY': manualAngleY,
      };

  factory Tilt3D.fromJson(Map<String, dynamic> json) {
    final name = json['style'] as String?;
    var style = ZoomTiltStyle.flat;
    if (name != null) {
      for (final s in ZoomTiltStyle.values) {
        if (s.name == name) {
          style = s;
          break;
        }
      }
    }
    return Tilt3D(
      style: style,
      manualAngleX: (json['manualAngleX'] as num?)?.toDouble(),
      manualAngleY: (json['manualAngleY'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tilt3D &&
          runtimeType == other.runtimeType &&
          style == other.style &&
          manualAngleX == other.manualAngleX &&
          manualAngleY == other.manualAngleY;

  @override
  int get hashCode => Object.hash(style, manualAngleX, manualAngleY);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/tilt3d_test.dart`
Expected: PASS (all tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/slipreel_engine && fvm flutter analyze lib/models/tilt3d.dart test/models/tilt3d_test.dart
git add packages/slipreel_engine/lib/models/tilt3d.dart packages/slipreel_engine/test/models/tilt3d_test.dart
git commit -m "feat(zoom): add Tilt3D model + angle resolution (#12)"
```

---

## Task 2: Thread `tilt` into `ZoomRegion`

**Files:**
- Modify: `packages/slipreel_engine/lib/models/zoom_region.dart`
- Test: `packages/slipreel_engine/test/models/zoom_region_tilt_test.dart` (create)

**Interfaces:**
- Consumes: `Tilt3D` (Task 1).
- Produces: `ZoomRegion.tilt` (a `Tilt3D`, default `const Tilt3D()`), threaded through the constructor, `copyWith` (with `Tilt3D? tilt`), `toJson`, `fromJson`, `==`, `hashCode`.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/slipreel_engine/test/models/zoom_region_tilt_test.dart
import 'dart:ui' show Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

ZoomRegion _base({Tilt3D? tilt}) => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2,
      videoBounds: const Size(100, 100),
      tilt: tilt ?? const Tilt3D(),
    );

void main() {
  test('default tilt is flat', () {
    expect(_base().tilt, const Tilt3D());
  });

  test('tilt round-trips through json', () {
    final r = _base(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    final back = ZoomRegion.fromJson(r.toJson());
    expect(back.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));
  });

  test('legacy json without tilt loads as flat', () {
    final r = _base(tilt: const Tilt3D(style: ZoomTiltStyle.dramatic));
    final json = r.toJson()..remove('tilt');
    expect(ZoomRegion.fromJson(json).tilt, const Tilt3D());
  });

  test('copyWith preserves tilt when not specified, changes when given', () {
    final r = _base(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(r.copyWith(zoomLevel: 3).tilt,
        const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(r.copyWith(tilt: const Tilt3D(style: ZoomTiltStyle.dramatic)).tilt,
        const Tilt3D(style: ZoomTiltStyle.dramatic));
  });

  test('equality and hashCode account for tilt', () {
    final flat = _base();
    final subtle = _base(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    expect(flat == subtle, isFalse);
    expect(flat.hashCode == subtle.hashCode, isFalse);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/zoom_region_tilt_test.dart`
Expected: FAIL — `tilt` named param / getter not defined.

- [ ] **Step 3: Implement — edit `zoom_region.dart`**

Add the import at the top (after the existing `animation_curve.dart` import):

```dart
import 'package:slipreel_engine/models/tilt3d.dart';
```

Add the field (after the `followDuration` field declaration, ~line 103):

```dart
  /// 3D perspective tilt for this zoom. [Tilt3D.flat] (the default) is a 2D
  /// zoom — byte-identical to legacy behavior. Subtle/dramatic/manual add a
  /// perspective tilt to the content panel (see [ZoomTransformer.getTransform]).
  final Tilt3D tilt;
```

Add the constructor param (in the `ZoomRegion({...})` parameter list, after `predictiveWindow,`):

```dart
    this.tilt = const Tilt3D(),
```

(The `tilt` field is a direct `this.tilt` initializer — no initializer-list entry needed.)

Add to `copyWith` — new param in the signature (after `predictiveWindow,`):

```dart
    Tilt3D? tilt,
```

and in the returned `ZoomRegion(...)` (after `predictiveWindow: predictiveWindow ?? this.predictiveWindow,`):

```dart
      tilt: tilt ?? this.tilt,
```

Add to `toJson` (after the `predictiveWindowMicros` entry, before the closing `};`):

```dart
      'tilt': tilt.toJson(),
```

Add to `fromJson` — in the returned `ZoomRegion(...)` (after `predictiveWindow: optMicros('predictiveWindowMicros'),`):

```dart
      tilt: json['tilt'] is Map
          ? Tilt3D.fromJson(
              (json['tilt'] as Map).cast<String, dynamic>())
          : const Tilt3D(),
```

Add to `operator ==` (append before the closing `;`, after `predictiveWindow == other.predictiveWindow`):

```dart
          &&
          tilt == other.tilt
```

Add to `hashCode` `Object.hash(...)` — add `tilt,` as the last argument before the closing `)`. NOTE: `Object.hash` takes up to 20 positional args; the current call has 13, so adding one is fine.

- [ ] **Step 4: Run to verify pass**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/zoom_region_tilt_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the existing zoom-region suite (no regressions)**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/zoom_region_test.dart test/models/zoom_region_json_test.dart`
Expected: PASS (existing tests construct `ZoomRegion` without `tilt` → default flat; round-trip now includes `tilt` but that does not break legacy-load assertions).

- [ ] **Step 6: Analyze + commit**

```bash
cd packages/slipreel_engine && fvm flutter analyze lib/models/zoom_region.dart
git add packages/slipreel_engine/lib/models/zoom_region.dart packages/slipreel_engine/test/models/zoom_region_tilt_test.dart
git commit -m "feat(zoom): thread Tilt3D through ZoomRegion (#12)"
```

---

## Task 3: `ZoomFraming` tilt helpers

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/zoom_framing.dart`
- Test: `packages/slipreel_engine/test/rendering/zoom_framing_tilt_test.dart` (create)

**Interfaces:**
- Produces on `ZoomFraming`:
  - `Offset normalizedFocalOffset(Offset focal)` — focal's canvas position minus canvas center, divided by half-canvas, each axis clamped to `[-1,1]`.
  - `Matrix4 perspectiveTilt(double axRad, double ayRad)` — `Matrix4.identity()..setEntry(3,2,-1/(canvasSize.height*kPerspective))..rotateX(axRad)..rotateY(ayRad)`.
  - `const double kPerspective = 1.6;` (top-level in this file).

- [ ] **Step 1: Write the failing tests**

```dart
// packages/slipreel_engine/test/rendering/zoom_framing_tilt_test.dart
import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  group('normalizedFocalOffset (identity framing, 200x100 video)', () {
    final f = ZoomFraming.identity(const Size(200, 100));

    test('center is (0,0)', () {
      expect(f.normalizedFocalOffset(const Offset(100, 50)), const Offset(0, 0));
    });
    test('corners clamp to +/-1', () {
      expect(f.normalizedFocalOffset(const Offset(200, 100)), const Offset(1, 1));
      expect(f.normalizedFocalOffset(const Offset(0, 0)), const Offset(-1, -1));
    });
    test('beyond bounds is clamped', () {
      expect(f.normalizedFocalOffset(const Offset(400, -50)),
          const Offset(1, -1));
    });
  });

  group('perspectiveTilt', () {
    test('zero angles still set a height-scaled perspective entry', () {
      final f = ZoomFraming.identity(const Size(100, 100));
      final m = f.perspectiveTilt(0, 0);
      // entry(3,2) == -1/(height*kPerspective)
      expect(m.entry(3, 2), closeTo(-1 / (100 * kPerspective), 1e-12));
    });

    test('perspective strength scales with canvas height '
        '(resolution-independent)', () {
      final small = ZoomFraming.identity(const Size(100, 100));
      final big = ZoomFraming.identity(const Size(200, 200));
      expect(small.perspectiveTilt(0, 0).entry(3, 2) * 100,
          closeTo(big.perspectiveTilt(0, 0).entry(3, 2) * 200, 1e-9));
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/zoom_framing_tilt_test.dart`
Expected: FAIL — `normalizedFocalOffset` / `perspectiveTilt` / `kPerspective` not defined.

- [ ] **Step 3: Implement — edit `zoom_framing.dart`**

Add the `Matrix4` import (the file currently imports only `painting.dart`). At the top:

```dart
import 'package:flutter/rendering.dart' show Matrix4;
```

Add the top-level constant above the `class ZoomFraming` declaration:

```dart
/// Perspective "focal length" multiplier: the camera distance used for the 3D
/// tilt is `canvasHeight * kPerspective`. Derived from canvas height so the
/// projection is resolution-independent (1080p preview == 4K export).
const double kPerspective = 1.6;
```

Add these methods inside the class (after `centerOffsetInPlace`, before `manualViewportRect`):

```dart
  /// The focal's offset from the canvas center, normalized so each axis is in
  /// `[-1, 1]` (clamped). Used to derive the auto 3D-tilt direction: a focal to
  /// the right of center → `dx > 0`, below center → `dy > 0`.
  Offset normalizedFocalOffset(Offset focal) {
    final cf = toCanvas(focal);
    final nx = ((cf.dx - canvasSize.width / 2) / (canvasSize.width / 2))
        .clamp(-1.0, 1.0);
    final ny = ((cf.dy - canvasSize.height / 2) / (canvasSize.height / 2))
        .clamp(-1.0, 1.0);
    return Offset(nx, ny);
  }

  /// The perspective + rotation matrix for a 3D tilt, in canvas-center-relative
  /// coordinates (the space the zoom matrix already operates in). Composed by
  /// [ZoomTransformer.getTransform] on top of the 2D scale+translate matrix.
  /// Perspective strength scales with [canvasSize] height (see [kPerspective]).
  Matrix4 perspectiveTilt(double axRad, double ayRad) {
    return Matrix4.identity()
      ..setEntry(3, 2, -1.0 / (canvasSize.height * kPerspective))
      ..rotateX(axRad)
      ..rotateY(ayRad);
  }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/zoom_framing_tilt_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/slipreel_engine && fvm flutter analyze lib/rendering/zoom_framing.dart
git add packages/slipreel_engine/lib/rendering/zoom_framing.dart packages/slipreel_engine/test/rendering/zoom_framing_tilt_test.dart
git commit -m "feat(zoom): ZoomFraming normalizedFocalOffset + perspectiveTilt (#12)"
```

---

## Task 4: Compose the 3D matrix in `getTransform`

**Files:**
- Modify: `packages/slipreel_engine/lib/effects/zoom_transformer.dart`
- Test: `packages/slipreel_engine/test/effects/zoom_transformer_tilt_test.dart` (create)

**Interfaces:**
- Consumes: `ZoomRegion.tilt` (Task 2), `ZoomFraming.normalizedFocalOffset` / `perspectiveTilt` (Task 3), `Tilt3D.resolveAngles` (Task 1).
- Produces: `getTransform` returns the existing 2D matrix when `tilt` is flat (byte-identical), and `perspectiveTilt(...).multiplied(base)` when 3D.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/slipreel_engine/test/effects/zoom_transformer_tilt_test.dart
import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

void main() {
  final t = ZoomTransformer();
  const videoSize = Size(1000, 1000);
  final framing = ZoomFraming.identity(videoSize);

  ZoomRegion region({required Tilt3D tilt, bool followCursor = true}) =>
      ZoomRegion(
        rect: const Rect.fromLTWH(600, 600, 100, 100),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2,
        enterDuration: Duration.zero,
        exitDuration: Duration.zero,
        followCursor: followCursor,
        tilt: tilt,
      );

  // Mid-hold so z == zoomLevel (progress == 1).
  const pos = Duration(seconds: 1);

  test('flat tilt is byte-identical to a region with no tilt config', () {
    final flat = t.getTransform(
        position: pos,
        zoomRegion: region(tilt: const Tilt3D()),
        videoSize: videoSize,
        focalPoint: const Offset(650, 650),
        framing: framing);
    // Perspective row must be identity (no setEntry(3,2)).
    expect(flat.entry(3, 2), 0.0);
    expect(flat.entry(3, 3), 1.0);
  });

  test('3D tilt sets a non-zero perspective entry and rotation', () {
    final tilted = t.getTransform(
        position: pos,
        zoomRegion: region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        videoSize: videoSize,
        focalPoint: const Offset(650, 650),
        framing: framing);
    expect(tilted.entry(3, 2), isNot(0.0));
  });

  test('manual placement (followCursor:false) also tilts', () {
    final tilted = t.getTransform(
        position: pos,
        zoomRegion: region(
            tilt: const Tilt3D(style: ZoomTiltStyle.dramatic),
            followCursor: false),
        videoSize: videoSize,
        framing: framing);
    expect(tilted.entry(3, 2), isNot(0.0));
  });

  test('resolution-independence: a focal point projects to the same '
      'normalized screen position at 1080p and 4K', () {
    // 2x canvas == 4K of the same scene. Same normalized focal, same tilt.
    final f1 = ZoomFraming.identity(const Size(1920, 1080));
    final f2 = ZoomFraming.identity(const Size(3840, 2160));
    final r = region(tilt: const Tilt3D(style: ZoomTiltStyle.subtle));
    final m1 = t.getTransform(
        position: pos,
        zoomRegion: r,
        videoSize: const Size(1920, 1080),
        focalPoint: const Offset(1400, 800),
        framing: f1);
    final m2 = t.getTransform(
        position: pos,
        zoomRegion: r,
        videoSize: const Size(3840, 2160),
        focalPoint: const Offset(2800, 1600),
        framing: f2);
    // perspective entry scales by 1/2 between the two resolutions.
    expect(m1.entry(3, 2), closeTo(m2.entry(3, 2) * 2, 1e-9));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/slipreel_engine && fvm flutter test test/effects/zoom_transformer_tilt_test.dart`
Expected: FAIL — the 3D test sees `entry(3,2) == 0` because tilt is not composed yet.

- [ ] **Step 3: Implement — edit `getTransform` in `zoom_transformer.dart`**

Replace the final `return Matrix4.identity()..translateByDouble(...)..scaleByDouble(...);` block (currently lines ~69-71) with:

```dart
    // The 2D zoom: scale by Z, then translate so the focal lands at the
    // viewport center (operates in canvas-center-relative coords because both
    // pipelines apply this with alignment == center).
    final base = Matrix4.identity()
      ..translateByDouble(-z * pCenterRel.dx, -z * pCenterRel.dy, 0, 1.0)
      ..scaleByDouble(z, z, 1.0, 1.0);

    // 2D / flat: return the legacy matrix unchanged (byte-identical).
    if (!zoomRegion.tilt.is3D) return base;

    // 3D: layer a perspective tilt about the canvas center on top of the 2D
    // zoom. Direction is auto-derived from the focal's position in the composed
    // frame; magnitude ramps with the zoom factor (0 at z==1, full at zoomLevel)
    // so the tilt is always in lock-step with the scale.
    final denom = zoomRegion.zoomLevel - 1.0;
    final progress = denom <= 0 ? 0.0 : ((z - 1.0) / denom).clamp(0.0, 1.0);
    final angles = zoomRegion.tilt.resolveAngles(
      normalizedFocal: f.normalizedFocalOffset(focal),
      progress: progress,
    );
    return f.perspectiveTilt(angles.xRad, angles.yRad).multiplied(base);
```

Update the method doc comment (the `[framing]` paragraph) to note: "When the region's `tilt` is 3D, a perspective rotation is composed about the canvas center on top of the 2D zoom; flat tilt returns the 2D matrix unchanged."

- [ ] **Step 4: Run to verify pass**

Run: `cd packages/slipreel_engine && fvm flutter test test/effects/zoom_transformer_tilt_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the full existing transformer + framing suites (flat regression)**

Run: `cd packages/slipreel_engine && fvm flutter test test/effects/zoom_transformer_test.dart test/rendering/zoom_framing_transform_test.dart test/rendering/manual_magnify_in_place_pipeline_test.dart`
Expected: PASS — existing zooms have flat tilt (default), so `getTransform` returns the identical legacy `base` matrix.

- [ ] **Step 6: Analyze + commit**

```bash
cd packages/slipreel_engine && fvm flutter analyze lib/effects/zoom_transformer.dart
git add packages/slipreel_engine/lib/effects/zoom_transformer.dart packages/slipreel_engine/test/effects/zoom_transformer_tilt_test.dart
git commit -m "feat(zoom): compose 3D perspective tilt in getTransform (#12)"
```

---

## Task 5: Default new zooms to 3D / Subtle

**Files:**
- Modify: `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart:110`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart:1678`
- Test: `packages/slipreel_engine/test/editor/auto_zoom_detector_tilt_test.dart` (create)

**Interfaces:**
- Consumes: `Tilt3D` / `ZoomTiltStyle` (Task 1), `ZoomRegion.tilt` (Task 2).

- [ ] **Step 1: Write the failing test (auto-detector default)**

```dart
// packages/slipreel_engine/test/editor/auto_zoom_detector_tilt_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
// NOTE: import the detector + whatever CursorRecording/builder helpers the
// existing auto_zoom_detector_test.dart uses; mirror its setup to synthesize
// one isolated click, then assert the emitted region's tilt.

void main() {
  test('auto-detected click zooms default to 3D subtle', () {
    // Arrange a CursorRecording with a single isolated click (copy the
    // smallest fixture from auto_zoom_detector_test.dart).
    // final regions = AutoZoomDetector(...).detect(...);
    // expect(regions, isNotEmpty);
    // expect(regions.first.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));
  }, skip: 'fill in using the fixtures from auto_zoom_detector_test.dart');
}
```

> Implementer: open `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`, copy its smallest single-click fixture and detector invocation into this test, remove the `skip`, and assert `regions.first.tilt == const Tilt3D(style: ZoomTiltStyle.subtle)`.

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/slipreel_engine && fvm flutter test test/editor/auto_zoom_detector_tilt_test.dart`
Expected: FAIL — emitted tilt is flat (default), not subtle.

- [ ] **Step 3: Implement — auto detector**

In `auto_zoom_detector.dart`, add the import:

```dart
import 'package:slipreel_engine/models/tilt3d.dart';
```

In the `ZoomRegion(...)` at line ~110, add (after `followCursor: false,`):

```dart
    tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
```

- [ ] **Step 4: Implement — manual add (playback_screen)**

In `playback_screen.dart`, ensure the import exists:

```dart
import 'package:slipreel_engine/models/tilt3d.dart';
```

In the `ZoomRegion(...)` at line ~1678 (the timeline-ghost add), add (after the `followCursor: ...` arg):

```dart
    tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
```

(Leave the `copyWith` placement preview/commit at ~1583/1603 unchanged — `copyWith` preserves `tilt`.)

- [ ] **Step 5: Run to verify pass + analyze**

Run: `cd packages/slipreel_engine && fvm flutter test test/editor/auto_zoom_detector_tilt_test.dart`
Expected: PASS.
Run: `cd packages/slipreel_engine && fvm flutter analyze lib/editor/auto_zoom_detector.dart`
Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/screens/playback_screen.dart`
Expected: no new issues.

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/editor/auto_zoom_detector.dart packages/screen_recorder/lib/ui/screens/playback_screen.dart packages/slipreel_engine/test/editor/auto_zoom_detector_tilt_test.dart
git commit -m "feat(zoom): new zooms default to 3D subtle (#12)"
```

---

## Task 6: Inspector — 2D/3D toggle + style + manual controls

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`
- Test: `packages/screen_recorder/test/ui/inspector/zoom_tilt_inspector_test.dart` (create)

**Interfaces:**
- Consumes: `ZoomContextInspector` (`final ZoomRegion zoom; final ValueChanged<ZoomRegion> onChanged;`), existing `InspectorToggle` / `InspectorChip` / `InspectorSlider` / `InspectorCollapsible` widgets, `Tilt3D` / `ZoomTiltStyle`.
- Produces: a tilt UI block that commits via `onChanged(zoom.copyWith(tilt: ...))`.

**Behavior:**
- A **2D / 3D** toggle (`InspectorToggle` labeled "3D tilt"): off → `tilt: const Tilt3D()` (flat); on → `tilt: Tilt3D(style: ZoomTiltStyle.subtle)` (only if currently flat — preserve subtle/dramatic if already 3D).
- When 3D: a **Subtle / Dramatic** segmented row (two `InspectorChip`s, mirroring `_FollowModeSegmented`) → `copyWith(tilt: zoom.tilt.copyWith(style: ...))`.
- An **"Advanced"** `InspectorCollapsible` with two `InspectorSlider`s (X tilt, Y tilt; min -20, max 20) writing `manualAngleX`/`manualAngleY`, and a reset on each that clears that axis back to auto (use `tilt.copyWith(manualAngleX: v)`; reset via a `Tilt3D` rebuilt without that axis — see note).

> Note on clearing a single axis: `Tilt3D.copyWith(clearManual: true)` clears BOTH axes. To reset one axis to auto while keeping the other, build a new `Tilt3D(style: tilt.style, manualAngleX: keepX, manualAngleY: keepY)` with the reset axis passed as `null`. Provide a small local helper in the inspector.

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/inspector/zoom_tilt_inspector_test.dart
import 'dart:ui' show Rect, Size;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart';

ZoomRegion _zoom({Tilt3D tilt = const Tilt3D()}) => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 2),
      zoomLevel: 2,
      videoBounds: const Size(100, 100),
      tilt: tilt,
    );

Future<void> _pump(WidgetTester tester, ZoomRegion zoom,
    ValueChanged<ZoomRegion> onChanged) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ZoomContextInspector(zoom: zoom, onChanged: onChanged),
      ),
    ),
  ));
}

void main() {
  testWidgets('toggling 3D on sets subtle; off sets flat', (tester) async {
    ZoomRegion? out;
    await _pump(tester, _zoom(), (z) => out = z);
    await tester.tap(find.text('3D tilt'));
    await tester.pump();
    expect(out!.tilt, const Tilt3D(style: ZoomTiltStyle.subtle));

    await _pump(tester, _zoom(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        (z) => out = z);
    await tester.tap(find.text('3D tilt'));
    await tester.pump();
    expect(out!.tilt, const Tilt3D());
  });

  testWidgets('Dramatic chip sets dramatic style', (tester) async {
    ZoomRegion? out;
    await _pump(tester, _zoom(tilt: const Tilt3D(style: ZoomTiltStyle.subtle)),
        (z) => out = z);
    await tester.tap(find.text('Dramatic'));
    await tester.pump();
    expect(out!.tilt.style, ZoomTiltStyle.dramatic);
  });
}
```

> Implementer: match the exact label strings you render ("3D tilt", "Dramatic") between the widget and this test. If `ZoomContextInspector` requires more constructor params than `zoom`/`onChanged`, supply defaults in `_pump` to match its real signature.

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/inspector/zoom_tilt_inspector_test.dart`
Expected: FAIL — no "3D tilt" control found.

- [ ] **Step 3: Implement the tilt UI block**

Add `import 'package:slipreel_engine/models/tilt3d.dart';` to the inspector. Insert a tilt block in `build()` near the zoom-level slider (place it directly under the zoom-level `InspectorSlider`). Use the existing widgets; follow `_FollowModeSegmented` for the style chips. Commit via the existing `onChanged(zoom.copyWith(tilt: ...))` pattern. Example shape:

```dart
InspectorToggle(
  label: '3D tilt',
  subtitle: 'Perspective lean as the zoom plays',
  value: zoom.tilt.is3D,
  onChanged: (on) => onChanged(zoom.copyWith(
    tilt: on
        ? (zoom.tilt.is3D
            ? zoom.tilt
            : const Tilt3D(style: ZoomTiltStyle.subtle))
        : const Tilt3D(),
  )),
),
if (zoom.tilt.is3D) ...[
  // Subtle / Dramatic segmented row (mirror _FollowModeSegmented):
  Wrap(spacing: 8, runSpacing: 8, children: [
    for (final (s, label) in const [
      (ZoomTiltStyle.subtle, 'Subtle'),
      (ZoomTiltStyle.dramatic, 'Dramatic'),
    ])
      InspectorChip(
        label: label,
        selected: zoom.tilt.style == s,
        dense: true,
        onTap: () => onChanged(
            zoom.copyWith(tilt: zoom.tilt.copyWith(style: s))),
      ),
  ]),
  InspectorCollapsible(
    title: 'Advanced',
    child: Column(children: [
      InspectorSlider(
        label: 'Tilt X',
        value: zoom.tilt.manualAngleX ?? 0,
        min: -20,
        max: 20,
        onChanged: (v) => onChanged(
            zoom.copyWith(tilt: zoom.tilt.copyWith(manualAngleX: v))),
        onReset: () => onChanged(zoom.copyWith(
            tilt: Tilt3D(
                style: zoom.tilt.style,
                manualAngleY: zoom.tilt.manualAngleY))),
        canReset: zoom.tilt.manualAngleX != null,
        subtitle: zoom.tilt.manualAngleX == null
            ? 'Auto'
            : '${zoom.tilt.manualAngleX!.toStringAsFixed(0)}°',
      ),
      InspectorSlider(
        label: 'Tilt Y',
        value: zoom.tilt.manualAngleY ?? 0,
        min: -20,
        max: 20,
        onChanged: (v) => onChanged(
            zoom.copyWith(tilt: zoom.tilt.copyWith(manualAngleY: v))),
        onReset: () => onChanged(zoom.copyWith(
            tilt: Tilt3D(
                style: zoom.tilt.style,
                manualAngleX: zoom.tilt.manualAngleX))),
        canReset: zoom.tilt.manualAngleY != null,
        subtitle: zoom.tilt.manualAngleY == null
            ? 'Auto'
            : '${zoom.tilt.manualAngleY!.toStringAsFixed(0)}°',
      ),
    ]),
  ),
],
```

- [ ] **Step 4: Run to verify pass + analyze**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/inspector/zoom_tilt_inspector_test.dart`
Expected: PASS.
Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`
Expected: no new issues.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart packages/screen_recorder/test/ui/inspector/zoom_tilt_inspector_test.dart
git commit -m "feat(zoom): 2D/3D tilt inspector controls (#12)"
```

---

## Task 7: Minimum padding floor while 3D is in use

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_controller_tilt_padding_test.dart` (create)

**Interfaces:**
- Consumes: `EditorProjectController` (`addZoom`, `updateZoomAt`, `removeZoomAt`, `setWindowFrame`, `current` → `EditorProjectState`), `EditorProjectState.zoomRegions`, `WindowFrame.padding` (`EdgeInsets`), the project's source video size.
- Produces:
  - `static int kMinPadding3D(Size videoSize)` helper (or a top-level `int minPadding3DFor(Size)`): `(0.06 * shortSide).round()`.
  - Padding-floor enforcement invoked after every zoom-list mutation; raises padding only.

**Behavior:** After any zoom add/update, if any region `tilt.is3D` and the current uniform padding (`windowFrame.padding.left`) is below `minPadding3DFor(videoSize)`, raise the frame padding to the floor (`EdgeInsets.all(floor)`) via `setWindowFrame` and emit one `AppAlerts.info(...)`. Never lower padding. The background-tab slider's `min` becomes the floor while any region is 3D.

> Implementer: confirm how the controller reads the source video size. Search `editor_project_state.dart` / `editor_project_controller.dart` for a `videoSize`/`Size` accessor (the export resolver receives one — trace its source). Use that. If the size is not reachable from the controller, compute the floor in the background-tab UI (which has the metadata) and pass it down, and keep the controller enforcement keyed off whatever size source `OutputCanvasResolver` already uses. Do NOT guess a hard-coded px floor.

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/state/editor_project_controller_tilt_padding_test.dart
import 'dart:ui' show Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
// import the controller + a helper that builds a minimal EditorProjectState
// with a known videoSize and a low padding (copy setup from
// editor_project_controller_test.dart).

void main() {
  test('enabling a 3D zoom raises padding to the 6% floor', () {
    // Arrange: controller with videoSize 1000x1000, windowFrame padding all=10.
    // final c = ...;
    // Act: c.addZoom(ZoomRegion(... tilt: Tilt3D(style: subtle) ...));
    // Assert: c.current.windowFrame.padding.left == 60  (0.06 * 1000)
  }, skip: 'fill in using fixtures from editor_project_controller_test.dart');

  test('a 2D zoom does not change padding', () {
    // addZoom with flat tilt → padding stays at 10.
  }, skip: 'fill in using fixtures from editor_project_controller_test.dart');

  test('removing the last 3D zoom leaves the raised padding untouched', () {
    // After raising to 60, removeZoomAt(0) → padding stays 60 (never lowered).
  }, skip: 'fill in using fixtures from editor_project_controller_test.dart');
}
```

> Implementer: replace the skipped bodies using the real `EditorProjectState` construction from `editor_project_controller_test.dart`. Assert the exact floor (`(0.06 * shortSide).round()`).

- [ ] **Step 2: Run to verify failure**

Run: `cd packages/slipreel_engine && fvm flutter test test/state/editor_project_controller_tilt_padding_test.dart`
Expected: FAIL (after un-skipping) — padding not raised.

- [ ] **Step 3: Implement the floor helper + enforcement**

In `editor_project_controller.dart`, add the import for `tilt3d.dart` if needed, a helper, and an `_enforce3DPaddingFloor()` called at the end of `addZoom` and `updateZoomAt`:

```dart
/// The minimum uniform padding (px) required while a 3D zoom is present:
/// 6% of the video's short side.
int minPadding3DFor(Size videoSize) =>
    (0.06 * (videoSize.shortestSide)).round();
```

```dart
void _enforce3DPaddingFloor() {
  final any3D = state.zoomRegions.any((z) => z.tilt.is3D);
  if (!any3D) return;
  final videoSize = /* the project's source video Size — see note above */;
  final floor = minPadding3DFor(videoSize);
  final current = state.windowFrame.padding.left;
  if (current >= floor) return;
  setWindowFrame(state.windowFrame
      .copyWith(padding: EdgeInsets.all(floor.toDouble()), name: 'Custom'));
  AppAlerts.info('3D zoom needs breathing room — padding set to ${floor}px');
}
```

Call `_enforce3DPaddingFloor();` as the last line of `addZoom` and `updateZoomAt`. Do NOT call it from `removeZoomAt` (so removing 3D never lowers padding).

> `AppAlerts` lives in `screen_recorder`; the controller is in `slipreel_engine`. If `slipreel_engine` cannot import `AppAlerts`, raise the padding in the controller (no alert) and fire the `AppAlerts.info(...)` from the inspector toggle handler in Task 6 instead (when it turns 3D on and detects the bump). Keep the floor math in the controller regardless. Pick whichever respects the existing package dependency direction — verify which package depends on which.

- [ ] **Step 4: Implement the slider-min reflection (background_tab.dart)**

Read the controller's zoom regions; when any is 3D, set the padding `InspectorSlider`'s `min` to `minPadding3DFor(videoSize)` instead of `0`:

```dart
final any3D = ref.watch(editorProjectControllerProvider).zoomRegions
    .any((z) => z.tilt.is3D);
final paddingMin = any3D ? minPadding3DFor(videoSize).toDouble() : 0.0;
// ... InspectorSlider(min: paddingMin, ...)
```

> Implementer: use the same `videoSize` source the tab already has for the canvas preview; match the provider name actually used in this file.

- [ ] **Step 5: Run to verify pass + analyze**

Run: `cd packages/slipreel_engine && fvm flutter test test/state/editor_project_controller_tilt_padding_test.dart`
Expected: PASS.
Run: `cd packages/slipreel_engine && fvm flutter analyze lib/state/editor_project_controller.dart`
Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/tabs/background_tab.dart`
Expected: no new issues.

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart packages/slipreel_engine/test/state/editor_project_controller_tilt_padding_test.dart
git commit -m "feat(zoom): enforce minimum padding floor while 3D is in use (#12)"
```

---

## Task 8: Export panel coherence + preview/export parity golden

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Test: `packages/slipreel_engine/test/export/frame_compositor_tilt_golden_test.dart` (create)

**Interfaces:**
- Consumes: `getTransform` (now 3D-aware), `_framing`, the `applyZoom` closure, the standard + device compose paths.

**Behavior:** Under a 3D-tilt region the whole content panel must tilt as one. In the standard (non-device) path the frame **chrome** (rounded-rect shadow/ring/border) must share the same `applyZoom` transform as the video so the shadow tilts with the screen (today it may be drawn un-zoomed/crisp — a flat shadow behind a tilted screen looks broken). The device path already wraps both the video and the bezel in `applyZoom`, so it is correct as-is. Flat regions keep the existing chrome behavior unchanged.

- [ ] **Step 1: Determine current chrome behavior**

Read `frame_compositor.dart` around the standard-path chrome composition (the agent map cited lines ~333–366 for `applyZoom(chromeCanvas)` and ~458–472 for the final `drawImage` composite). Establish whether the chrome is currently transformed by `applyZoom`. Record the finding in the task report.

- [ ] **Step 2: Write the failing parity/coherence golden test**

```dart
// packages/slipreel_engine/test/export/frame_compositor_tilt_golden_test.dart
@TestOn('mac-os')
library;

import 'package:flutter_test/flutter_test.dart';
// import FrameCompositor + the existing golden harness used by
// frame_compositor_test.dart / frame_compositor_device_test.dart.

void main() {
  // Render one frame mid-hold of a 3D-subtle zoom on a PADDED (non-device)
  // recording and compare against a committed golden. The golden must show the
  // framed screenshot (chrome + video) tilted together over a static wallpaper.
  testWidgets('3D-tilt standard-path frame matches golden', (tester) async {
    // Build a FrameCompositor with a small synthetic video + wallpaper +
    // padding, one ZoomRegion(tilt: Tilt3D(style: subtle)). Render the
    // hold-phase frame to an image; expect it matches
    // 'goldens/frame_compositor_tilt_standard.png'.
  }, skip: 'fill in using the existing frame_compositor golden harness');
}
```

> Implementer: model this on the closest existing test in `frame_compositor_test.dart`/`frame_compositor_device_test.dart`. Generate the golden with `--update-goldens` ONLY after visually confirming (Step 4 runtime check) the tilt looks correct; a golden locks in whatever you render, so it must be verified first.

- [ ] **Step 3: Implement chrome coherence**

If Step 1 found the chrome is NOT transformed: make the standard-path chrome canvas apply the same `applyZoom` as the foreground **only when the active region is 3D** (so flat stays byte-identical). Concretely, gate the chrome `applyZoom` on `focalUpdate?.zoom.tilt.is3D == true`. Keep the existing crisp-chrome code path for flat. Add a short comment explaining the divergence and why 3D needs the chrome to tilt with the video.

- [ ] **Step 4: Runtime visual verification (REQUIRED before generating the golden)**

Build and launch a dev-signed Release, create a padded recording, add a manual zoom (defaults to 3D subtle), and confirm in BOTH preview and an exported clip that: the screen tilts with its shadow as one panel; the wallpaper stays static; no bare-background sliver. (Use the project's standard build+sign+launch-from-terminal flow.) Capture the result in the task report.

- [ ] **Step 5: Generate golden, run, analyze, commit**

```bash
cd packages/slipreel_engine && fvm flutter test --update-goldens test/export/frame_compositor_tilt_golden_test.dart
cd packages/slipreel_engine && fvm flutter test test/export/frame_compositor_tilt_golden_test.dart
cd packages/slipreel_engine && fvm flutter analyze lib/export/frame_compositor.dart
git add packages/slipreel_engine/lib/export/frame_compositor.dart packages/slipreel_engine/test/export/frame_compositor_tilt_golden_test.dart packages/slipreel_engine/test/export/goldens/
git commit -m "feat(zoom): frame chrome tilts with panel under 3D + parity golden (#12)"
```

- [ ] **Step 6: Run the full export suite (flat regression)**

Run: `cd packages/slipreel_engine && fvm flutter test test/export/`
Expected: PASS — flat regions render unchanged.

---

## Final verification (after all tasks)

- [ ] Run both package suites: `cd packages/slipreel_engine && fvm flutter test` and `cd packages/screen_recorder && fvm flutter test`. All green.
- [ ] Analyze both packages: `fvm flutter analyze` in each. No new issues.
- [ ] Whole-branch code review (superpowers:requesting-code-review) focused on: flat byte-identical guarantee, preview/export parity, the padding-floor cross-package dependency direction, tilt-direction sign correctness.
- [ ] Runtime smoke on a dev-signed Release: 2D zoom unchanged; 3D subtle (default) tilts correctly; Dramatic; manual angle override; follow-cursor 3D doesn't jitter; padding floor engages and the slider min reflects it.

## Self-review against the spec

- Spec §"control model" → Tasks 1 (resolveAngles), 6 (toggle/style/manual). ✔
- Spec §"transform matrix" / perspective resolution-independence → Tasks 3, 4. ✔
- Spec §"rendering modes / panel coherence" → Task 8. ✔
- Spec §"minimum padding under 3D" → Task 7. ✔
- Spec §"data model / defaults / serialization" → Tasks 2 (thread + flat default + legacy load), 5 (new = subtle). ✔
- Spec §"cache key" → Task 2 (tilt in `==`, consumed by `DeterministicFocalTrack.matches` via region equality — verified by explorer; no separate task needed). ✔
- Spec §"inspector UI" → Task 6. ✔
- Spec §"testing & verification" → per-task tests + Task 8 golden + final review. ✔
- Spec §"captions stay flat" → no task changes caption rendering (captions are drawn outside `applyZoom`/the Transform in both pipelines — confirmed by explorer); guarded by leaving those paths untouched. ✔
