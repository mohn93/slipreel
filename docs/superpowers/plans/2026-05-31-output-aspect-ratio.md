# Output Aspect Ratio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an editor-level output aspect ratio control (Auto, 16:9, 1:1, 4:3, 9:16, 3:4, 4:5) that reshapes the canvas in both the live preview and the final export, letterbox-fitting the video inside the chosen ratio.

**Architecture:** New `OutputAspect` enum lives on `EditorProjectState`. A new pure `OutputCanvasResolver` becomes the single source of truth for canvas dimensions, replacing the per-callsite `FramePainter.calculateTotalSize`/`effectivePadding` calls in `PlaybackCanvas`, `FrameCompositor`, `motion_blur_playground_screen`, and the export pipelines. Aspect-scaled padding is removed in favor of uniform padding now that aspect is explicit. A new `AspectRatioPicker` widget inside a `CanvasToolbar` host sits above the editor canvas and dispatches through a `setOutputAspect` mutator.

**Tech Stack:** Dart 3 / Flutter (Material 3), Riverpod StateNotifier, melos monorepo, FVM 3.41.5 (`~/fvm/versions/3.41.5/bin/`), `flutter test`.

**Spec:** `docs/superpowers/specs/2026-05-31-output-aspect-ratio-design.md`.

---

## File Structure

**Create:**
- `packages/slipreel_engine/lib/models/output_aspect.dart` — enum, ratio getter, label.
- `packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart` — pure helper that resolves (videoSize, padding, aspect) → (canvasSize, videoRect).
- `packages/slipreel_engine/test/models/output_aspect_test.dart`
- `packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart`
- `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart`
- `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart`
- `packages/screen_recorder/test/ui/widgets/canvas_toolbar/aspect_ratio_picker_test.dart`

**Modify:**
- `packages/slipreel_engine/lib/state/editor_project_state.dart` — `outputAspect` field, JSON migration v4→v5.
- `packages/slipreel_engine/lib/state/editor_project_controller.dart` — `setOutputAspect`.
- `packages/slipreel_engine/lib/rendering/frame_painter.dart` — delegate canvas-size + paint to resolver; remove `effectivePadding`.
- `packages/slipreel_engine/lib/export/frame_compositor.dart` — replace `FramePainter.calculateTotalSize`/`effectivePadding` calls with one resolver call.
- `packages/slipreel_engine/lib/export/export_pipeline.dart` — base `outDims` on the resolver's canvas size, not the raw source video.
- `packages/slipreel_engine/lib/export/gif_export_pipeline.dart` — same.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — accept `outputAspect` prop; route through resolver.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — insert `CanvasToolbar` above canvas; canvas-aware `sourceVideoSize` for the export dialog.
- `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart` — pass `aspect` through new `calculateTotalSize` signature.
- `packages/slipreel_engine/test/rendering/frame_painter_test.dart` — update aspect-scaled-padding assertions to uniform-padding.
- `packages/slipreel_engine/test/export/frame_compositor_test.dart` — same; add a 9:16 case.
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` — cover new field + migration.

---

## Tasks

### Task 1: `OutputAspect` enum

**Files:**
- Create: `packages/slipreel_engine/lib/models/output_aspect.dart`
- Test: `packages/slipreel_engine/test/models/output_aspect_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// packages/slipreel_engine/test/models/output_aspect_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';

void main() {
  group('OutputAspect', () {
    test('auto.ratio is null (resolved by caller against video size)', () {
      expect(OutputAspect.auto.ratio, isNull);
    });

    test('numeric ratios match width/height', () {
      expect(OutputAspect.wide16x9.ratio, closeTo(16 / 9, 1e-9));
      expect(OutputAspect.square1x1.ratio, closeTo(1.0, 1e-9));
      expect(OutputAspect.classic4x3.ratio, closeTo(4 / 3, 1e-9));
      expect(OutputAspect.vertical9x16.ratio, closeTo(9 / 16, 1e-9));
      expect(OutputAspect.tall3x4.ratio, closeTo(3 / 4, 1e-9));
      expect(OutputAspect.portrait4x5.ratio, closeTo(4 / 5, 1e-9));
    });

    test('labels are stable user-facing strings', () {
      expect(OutputAspect.auto.label, 'Auto');
      expect(OutputAspect.wide16x9.label, 'Wide 16:9');
      expect(OutputAspect.square1x1.label, 'Square 1:1');
      expect(OutputAspect.classic4x3.label, 'Classic 4:3');
      expect(OutputAspect.vertical9x16.label, 'Vertical 9:16');
      expect(OutputAspect.tall3x4.label, 'Tall 3:4');
      expect(OutputAspect.portrait4x5.label, 'Portrait 4:5');
    });

    test('name round-trip via values.byName', () {
      for (final v in OutputAspect.values) {
        expect(OutputAspect.values.byName(v.name), v);
      }
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/models/output_aspect_test.dart`
Expected: FAIL with "Target of URI doesn't exist: 'package:slipreel_engine/models/output_aspect.dart'".

- [ ] **Step 3: Implement the enum**

```dart
// packages/slipreel_engine/lib/models/output_aspect.dart

/// Output canvas aspect ratio. Picked from the editor's canvas toolbar
/// and persisted on `EditorProjectState`. Drives canvas dimensions in
/// both the live preview (PlaybackCanvas) and the export pipeline
/// (FrameCompositor) via `OutputCanvasResolver`.
///
/// `auto` defers to the source video's intrinsic aspect ratio.
/// Explicit variants force the canvas to the named width:height ratio;
/// the video is letterbox-fit centered inside, with the WindowFrame's
/// wallpaper filling any extra space.
enum OutputAspect {
  auto,
  wide16x9,
  square1x1,
  classic4x3,
  vertical9x16,
  tall3x4,
  portrait4x5;

  /// Numeric width/height ratio. `null` for [auto] — callers resolve
  /// against the source video size at render time.
  double? get ratio {
    switch (this) {
      case OutputAspect.auto:
        return null;
      case OutputAspect.wide16x9:
        return 16 / 9;
      case OutputAspect.square1x1:
        return 1.0;
      case OutputAspect.classic4x3:
        return 4 / 3;
      case OutputAspect.vertical9x16:
        return 9 / 16;
      case OutputAspect.tall3x4:
        return 3 / 4;
      case OutputAspect.portrait4x5:
        return 4 / 5;
    }
  }

  /// Human-readable label shown in the editor's aspect picker.
  String get label {
    switch (this) {
      case OutputAspect.auto:
        return 'Auto';
      case OutputAspect.wide16x9:
        return 'Wide 16:9';
      case OutputAspect.square1x1:
        return 'Square 1:1';
      case OutputAspect.classic4x3:
        return 'Classic 4:3';
      case OutputAspect.vertical9x16:
        return 'Vertical 9:16';
      case OutputAspect.tall3x4:
        return 'Tall 3:4';
      case OutputAspect.portrait4x5:
        return 'Portrait 4:5';
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/models/output_aspect_test.dart`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/output_aspect.dart \
        packages/slipreel_engine/test/models/output_aspect_test.dart
git commit -m "feat(engine): add OutputAspect enum"
```

---

### Task 2: Persist `outputAspect` on `EditorProjectState`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Modify: `packages/slipreel_engine/test/state/editor_project_state_test.dart`

- [ ] **Step 1: Write the failing tests**

Add these test cases to `packages/slipreel_engine/test/state/editor_project_state_test.dart` (inside the existing top-level `void main()`; group them under a new `group('outputAspect', ...)`):

```dart
import 'package:slipreel_engine/models/output_aspect.dart';

// ... inside main():

group('outputAspect', () {
  test('defaults to OutputAspect.auto', () {
    final state = EditorProjectState.defaults();
    expect(state.outputAspect, OutputAspect.auto);
  });

  test('copyWith updates outputAspect', () {
    final base = EditorProjectState.defaults();
    final next = base.copyWith(outputAspect: OutputAspect.vertical9x16);
    expect(next.outputAspect, OutputAspect.vertical9x16);
    expect(base.outputAspect, OutputAspect.auto, reason: 'immutable');
  });

  test('JSON round-trip preserves outputAspect for every variant', () {
    for (final variant in OutputAspect.values) {
      final state = EditorProjectState.defaults().copyWith(outputAspect: variant);
      final decoded = EditorProjectState.fromJson(state.toJson());
      expect(decoded.outputAspect, variant, reason: 'variant=$variant');
    }
  });

  test('JSON without outputAspect defaults to auto', () {
    // Build a current-schema JSON, then strip the field to simulate
    // a project saved before this feature shipped.
    final json = EditorProjectState.defaults().toJson();
    json.remove('outputAspect');
    final decoded = EditorProjectState.fromJson(json);
    expect(decoded.outputAspect, OutputAspect.auto);
  });

  test('v4 JSON (pre-outputAspect) migrates forward to current and defaults aspect', () {
    final v4Json = EditorProjectState.defaults().toJson()
      ..['schemaVersion'] = 4
      ..remove('outputAspect');
    final decoded = EditorProjectState.fromJson(v4Json);
    expect(decoded.outputAspect, OutputAspect.auto);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_test.dart`
Expected: FAIL — five new tests fail because `outputAspect` doesn't exist on `EditorProjectState`.

- [ ] **Step 3: Add the field, copyWith, toJson, fromJson**

Edit `packages/slipreel_engine/lib/state/editor_project_state.dart`:

(a) Add the import at the top alongside the other model imports:
```dart
import 'package:slipreel_engine/models/output_aspect.dart';
```

(b) Bump `currentSchemaVersion`:
```dart
static const int currentSchemaVersion = 5;
```

(c) Add the constructor parameter (default `OutputAspect.auto`) just before `audioMix`:
```dart
this.outputAspect = OutputAspect.auto,
this.audioMix = const AudioMix(),
```

(d) Add the field declaration near `audioMix`:
```dart
/// Output canvas aspect ratio. Drives canvas dimensions for both the
/// editor preview and the export pipeline via `OutputCanvasResolver`.
/// Defaults to [OutputAspect.auto] — match the source video aspect.
final OutputAspect outputAspect;
```

(e) Add the `copyWith` parameter:
```dart
OutputAspect? outputAspect,
```
and propagate it in the constructor call inside `copyWith`:
```dart
outputAspect: outputAspect ?? this.outputAspect,
```

(f) Add `toJson` entry:
```dart
'outputAspect': outputAspect.name,
```

(g) Add to `fromJson`, between the `audioMix` and the closing parenthesis:
```dart
outputAspect: (json['outputAspect'] is String) &&
        OutputAspect.values.any((v) => v.name == json['outputAspect'])
    ? OutputAspect.values.byName(json['outputAspect'] as String)
    : defaults.outputAspect,
```

(h) Append the v4→v5 migration to `_schemaMigrations`:
```dart
// v4 → v5: add the per-project outputAspect (no value transform —
// fromJson fills the auto default when the key is absent).
(json) => {...json, 'schemaVersion': 5},
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_test.dart`
Expected: PASS — all tests (existing + 5 new) green.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_project_state_test.dart
git commit -m "feat(engine): persist outputAspect on EditorProjectState (schema v5)"
```

---

### Task 3: `setOutputAspect` mutator on `EditorProjectController`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Modify: `packages/slipreel_engine/test/state/editor_project_controller_test.dart` *(if absent, create it; otherwise extend)*

- [ ] **Step 1: Write the failing test**

If `editor_project_controller_test.dart` does not yet exist, create it with:

```dart
// packages/slipreel_engine/test/state/editor_project_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  group('EditorProjectController.setOutputAspect', () {
    test('publishes new state with the chosen aspect', () {
      final controller = EditorProjectController();
      expect(controller.current.outputAspect, OutputAspect.auto);

      controller.setOutputAspect(OutputAspect.vertical9x16);

      expect(controller.current.outputAspect, OutputAspect.vertical9x16);
    });
  });
}
```

If it already exists, add the `group('setOutputAspect', ...)` block above to its `main()`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_controller_test.dart`
Expected: FAIL — `The method 'setOutputAspect' isn't defined`.

- [ ] **Step 3: Add the mutator**

Edit `packages/slipreel_engine/lib/state/editor_project_controller.dart`:

(a) Add import:
```dart
import 'package:slipreel_engine/models/output_aspect.dart';
```

(b) Add the mutator next to the other single-field mutators (e.g. just below `setWindowFrame`):
```dart
void setOutputAspect(OutputAspect value) =>
    state = state.copyWith(outputAspect: value);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart \
        packages/slipreel_engine/test/state/editor_project_controller_test.dart
git commit -m "feat(engine): setOutputAspect mutator on EditorProjectController"
```

---

### Task 4: `OutputCanvasResolver` pure helper

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart`
- Test: `packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

void main() {
  group('OutputCanvasResolver.resolve', () {
    test('auto + square video + zero padding → canvas equals video', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1000, 1000),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.auto,
      );
      expect(r.canvasSize, const Size(1000, 1000));
      expect(r.videoRect, const Rect.fromLTWH(0, 0, 1000, 1000));
    });

    test('auto + 1920x1080 + uniform 50px padding → 2020x1180 canvas, video at (50,50)', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: const EdgeInsets.all(50),
        aspect: OutputAspect.auto,
      );
      expect(r.canvasSize, const Size(2020, 1180));
      expect(r.videoRect, const Rect.fromLTWH(50, 50, 1920, 1080));
    });

    test('wide16x9 on square 1000x1000 video → canvas grows horizontally', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1000, 1000),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.wide16x9,
      );
      // Canvas height = padded height = 1000; canvas width = 1000 * 16/9 ≈ 1777.78.
      expect(r.canvasSize.height, 1000);
      expect(r.canvasSize.width, closeTo(1000 * 16 / 9, 1e-6));
      // Video sits centered horizontally inside canvas.
      final expectedDx = (r.canvasSize.width - 1000) / 2;
      expect(r.videoRect.left, closeTo(expectedDx, 1e-6));
      expect(r.videoRect.top, 0);
      expect(r.videoRect.width, 1000);
      expect(r.videoRect.height, 1000);
    });

    test('vertical9x16 on 1920x1080 video → canvas grows vertically', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.vertical9x16,
      );
      // Canvas width = padded width = 1920; canvas height = 1920 / (9/16) ≈ 3413.33.
      expect(r.canvasSize.width, 1920);
      expect(r.canvasSize.height, closeTo(1920 / (9 / 16), 1e-6));
      // Video sits centered vertically inside canvas.
      final expectedDy = (r.canvasSize.height - 1080) / 2;
      expect(r.videoRect.left, 0);
      expect(r.videoRect.top, closeTo(expectedDy, 1e-6));
      expect(r.videoRect.width, 1920);
      expect(r.videoRect.height, 1080);
    });

    test('square1x1 on 1920x1080 video → canvas grows vertically to 1920x1920', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.square1x1,
      );
      expect(r.canvasSize, const Size(1920, 1920));
      expect(r.videoRect, const Rect.fromLTWH(0, 420, 1920, 1080));
    });

    test('vertical9x16 on 1920x1080 + 50px padding → padded 2020x1180; canvas grows to 9:16', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: const EdgeInsets.all(50),
        aspect: OutputAspect.vertical9x16,
      );
      // Padded inner = 2020 × 1180. target < inner aspect → grow vertically.
      // canvas.height = 2020 / (9/16) ≈ 3591.11.
      expect(r.canvasSize.width, 2020);
      expect(r.canvasSize.height, closeTo(2020 / (9 / 16), 1e-6));
      // Video offset: inner centered → padded inner at (0, (3591.11 - 1180)/2),
      // then video sits at +50 inset inside the padded inner.
      final innerDy = (r.canvasSize.height - 1180) / 2;
      expect(r.videoRect.left, closeTo(50, 1e-6));
      expect(r.videoRect.top, closeTo(innerDy + 50, 1e-6));
      expect(r.videoRect.width, 1920);
      expect(r.videoRect.height, 1080);
    });

    test('zero-size video returns zero canvas (defensive)', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: Size.zero,
        padding: EdgeInsets.zero,
        aspect: OutputAspect.wide16x9,
      );
      expect(r.canvasSize, Size.zero);
      expect(r.videoRect, Rect.zero);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart`
Expected: FAIL with "Target of URI doesn't exist".

- [ ] **Step 3: Implement the resolver**

```dart
// packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/output_aspect.dart';

/// Result of [OutputCanvasResolver.resolve]: the final canvas
/// dimensions and the rect inside that canvas where the source video
/// should be drawn.
class ResolvedCanvas {
  const ResolvedCanvas({required this.canvasSize, required this.videoRect});

  /// Total output canvas size in pixels (wallpaper + padding + video).
  final Size canvasSize;

  /// Where the source video sits inside [canvasSize], in canvas
  /// coordinates. The video is aspect-preserved — never stretched.
  final Rect videoRect;
}

/// Single source of truth for output-canvas dimensions, used by both
/// the editor preview ([PlaybackCanvas]) and the export pipeline
/// ([FrameCompositor]).
///
/// Composes three inputs into a canvas + video rect:
///   • [videoSize] — the raw source video resolution.
///   • [padding] — uniform inset around the video (from `WindowFrame`).
///   • [aspect] — the target output aspect; [OutputAspect.auto] defers
///     to the source video's intrinsic aspect.
///
/// Letterbox-fit only — when the chosen aspect doesn't match the
/// padded inner region, the canvas GROWS along the under-sized axis to
/// reach the target ratio. The video itself never crops or stretches.
class OutputCanvasResolver {
  const OutputCanvasResolver._();

  static ResolvedCanvas resolve({
    required Size videoSize,
    required EdgeInsets padding,
    required OutputAspect aspect,
  }) {
    // Defensive: zero-size video → zero-size canvas. Prevents NaN /
    // div-by-zero downstream; PlaybackCanvas can briefly see this
    // during video-controller initialization.
    if (videoSize.width <= 0 || videoSize.height <= 0) {
      return const ResolvedCanvas(
        canvasSize: Size.zero,
        videoRect: Rect.zero,
      );
    }

    final paddedWidth = videoSize.width + padding.horizontal;
    final paddedHeight = videoSize.height + padding.vertical;
    final innerAspect = paddedWidth / paddedHeight;

    // Resolve target aspect ratio. `auto` adopts the padded inner
    // aspect, which collapses step 3 to "canvas = padded inner".
    final targetAspect = aspect.ratio ?? innerAspect;

    // Grow whichever axis is shorter to reach the target ratio.
    final double canvasWidth;
    final double canvasHeight;
    if (targetAspect > innerAspect) {
      // Need a wider canvas.
      canvasWidth = paddedHeight * targetAspect;
      canvasHeight = paddedHeight;
    } else if (targetAspect < innerAspect) {
      // Need a taller canvas.
      canvasWidth = paddedWidth;
      canvasHeight = paddedWidth / targetAspect;
    } else {
      canvasWidth = paddedWidth;
      canvasHeight = paddedHeight;
    }

    final canvasSize = Size(canvasWidth, canvasHeight);

    // Padded inner region sits centered in the canvas; video sits at
    // the padding inset inside that.
    final innerDx = (canvasWidth - paddedWidth) / 2;
    final innerDy = (canvasHeight - paddedHeight) / 2;
    final videoRect = Rect.fromLTWH(
      innerDx + padding.left,
      innerDy + padding.top,
      videoSize.width,
      videoSize.height,
    );

    return ResolvedCanvas(canvasSize: canvasSize, videoRect: videoRect);
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart`
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart \
        packages/slipreel_engine/test/rendering/output_canvas_resolver_test.dart
git commit -m "feat(engine): add OutputCanvasResolver pure helper"
```

---

### Task 5: Refactor `FramePainter` onto the resolver; drop aspect-scaled padding

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/frame_painter.dart`
- Modify: `packages/slipreel_engine/test/rendering/frame_painter_test.dart`

Behavioral change: the old `effectivePadding` aspect-scaling trick is removed. Padding becomes uniform on all sides. For `OutputAspect.auto` this means existing projects with non-zero padding will see their horizontal padding shrink slightly on wide videos. Accepted regression per the spec.

- [ ] **Step 1: Update the existing `calculateTotalSize` test to assert uniform padding**

Open `packages/slipreel_engine/test/rendering/frame_painter_test.dart` and find the test currently titled `'should calculate total size with aspect-scaled padding'` (around line 71). Replace its body with:

```dart
test('calculateTotalSize uses uniform padding for OutputAspect.auto', () {
  final frame = WindowFrame(
    name: 'Test',
    padding: const EdgeInsets.all(30),
    cornerRadius: 0,
    shadowBlur: 0,
    shadowOffset: Offset.zero,
    shadowColor: Color(0x00000000),
  );
  final totalSize = FramePainter.calculateTotalSize(
    frame: frame,
    videoSize: const Size(320, 240),
  );
  // Uniform: 320 + 30 + 30 = 380; 240 + 30 + 30 = 300.
  expect(totalSize, const Size(380, 300));
});

test('calculateTotalSize honors explicit aspect (vertical9x16 grows height)', () {
  final frame = WindowFrame(
    name: 'Test',
    padding: EdgeInsets.zero,
    cornerRadius: 0,
    shadowBlur: 0,
    shadowOffset: Offset.zero,
    shadowColor: Color(0x00000000),
  );
  final totalSize = FramePainter.calculateTotalSize(
    frame: frame,
    videoSize: const Size(1920, 1080),
    aspect: OutputAspect.vertical9x16,
  );
  expect(totalSize.width, 1920);
  expect(totalSize.height, closeTo(1920 / (9 / 16), 1e-6));
});
```

Add the import at the top of the test file:
```dart
import 'package:slipreel_engine/models/output_aspect.dart';
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/rendering/frame_painter_test.dart`
Expected: FAIL — the new "vertical9x16" test fails because `calculateTotalSize` doesn't accept an `aspect` parameter yet.

- [ ] **Step 3: Refactor `FramePainter`**

Edit `packages/slipreel_engine/lib/rendering/frame_painter.dart`:

(a) Add imports:
```dart
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
```

(b) Replace the existing `paint` method's content-rect computation. Find the line `final p = effectivePadding(frame.padding, videoSize);` near the top of `paint`, and replace it and the immediately following content-rect construction so the method reads:

```dart
@override
void paint(Canvas canvas, Size size) {
  // Skip rendering if frame is 'None'
  if (frame.name == 'None') {
    return;
  }

  // Use the resolver so paint targets the same rect the canvas
  // layout uses. We pass OutputAspect.auto here because the painter
  // is invoked at the canvas's already-sized rect — the consumer
  // (PlaybackCanvas / FrameCompositor) is responsible for sizing the
  // CustomPaint to the resolver's canvasSize. We only need the
  // video rect to know where to draw the shadow / inset ring /
  // background / border.
  final resolved = OutputCanvasResolver.resolve(
    videoSize: videoSize,
    padding: frame.padding,
    aspect: OutputAspect.auto,
  );
  final contentRect = resolved.videoRect;
  // ... rest of paint() unchanged: rrect, insetRRect, shadow, ring,
  // background, border all use contentRect as before.
```

(c) Replace `calculateTotalSize` with the resolver-backed version:

```dart
/// Total canvas size (wallpaper + padding + video), shaped by the
/// chosen [aspect]. Defaults to [OutputAspect.auto] (canvas matches
/// the video's intrinsic aspect).
///
/// Padding is uniform — no aspect-scaling trick anymore now that
/// aspect is an explicit parameter.
static Size calculateTotalSize({
  required WindowFrame frame,
  required Size videoSize,
  OutputAspect aspect = OutputAspect.auto,
}) {
  if (frame.name == 'None') {
    return videoSize;
  }
  return OutputCanvasResolver.resolve(
    videoSize: videoSize,
    padding: frame.padding,
    aspect: aspect,
  ).canvasSize;
}
```

(d) **Delete** the `effectivePadding` static method entirely (lines 160–176 in the current file). It's no longer referenced once Tasks 6 and 7 land. Add the deletion in this task to lock in the behavior change; the next two tasks update the callers.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/rendering/frame_painter_test.dart`
Expected: PASS — both new tests green, existing tests untouched still pass.

NOTE — this step intentionally leaves callers (`playback_canvas.dart`, `frame_compositor.dart`, `motion_blur_playground_screen.dart`) broken (they still reference `effectivePadding`). The next three tasks fix them in order. Do **not** run the full suite yet.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/frame_painter.dart \
        packages/slipreel_engine/test/rendering/frame_painter_test.dart
git commit -m "refactor(engine): FramePainter delegates canvas size to OutputCanvasResolver"
```

---

### Task 6: Update `PlaybackCanvas` to consume `outputAspect` via the resolver

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`

- [ ] **Step 1: Add the `outputAspect` prop**

Open `playback_canvas.dart` and locate the `PlaybackCanvas` widget's constructor parameter list. Add:

```dart
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
```

and a required prop on the widget:

```dart
final OutputAspect outputAspect;
```

Add it to the constructor:

```dart
required this.outputAspect,
```

- [ ] **Step 2: Replace `calculateTotalSize` + `effectivePadding` calls with a single resolver call**

In `playback_canvas.dart` around lines 343–352, replace:

```dart
final totalSize = FramePainter.calculateTotalSize(
  frame: currentFrame,
  videoSize: videoSize,
);
// Effective padding has X scaled by the video aspect so layout
// matches the canvas computed by calculateTotalSize.
final effPadding = FramePainter.effectivePadding(
  currentFrame.padding,
  videoSize,
);
```

with:

```dart
final resolved = OutputCanvasResolver.resolve(
  videoSize: videoSize,
  padding: currentFrame.padding,
  aspect: widget.outputAspect,
);
final totalSize = resolved.canvasSize;
// Top-left of the video inside the canvas. Replaces the previous
// `effPadding.left / .top` use sites verbatim — the resolver already
// returns the inset, including any aspect-driven recentering.
final videoOriginX = resolved.videoRect.left;
final videoOriginY = resolved.videoRect.top;
```

Then in the remainder of the build method, replace **every** reference to `effPadding.left` with `videoOriginX` and `effPadding.top` with `videoOriginY`. These appear around lines 526, 527, 550, 551, 610, 611. Use Edit's `replace_all: false` and do them one at a time so unique-string matching succeeds.

- [ ] **Step 3: Verify the file compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
Expected: No errors. (Warnings about unused imports are fine; the file imports plenty already.)

- [ ] **Step 4: Run the screen_recorder test suite to verify no widget tests broke**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/zoom/`
Expected: PASS (or no tests found — both are acceptable). Existing visual tests don't check pixel positions, so the padding semantics change won't surface here.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "refactor(app): PlaybackCanvas reads canvas dims from OutputCanvasResolver"
```

---

### Task 7: Update `FrameCompositor` to use the resolver

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Modify: `packages/slipreel_engine/test/export/frame_compositor_test.dart`

- [ ] **Step 1: Update the failing existing test + add a 9:16 case**

In `packages/slipreel_engine/test/export/frame_compositor_test.dart`:

(a) Find the test titled `'totalSize includes aspect-scaled padding for a framed clip'` (around line 38). Rename + update it:

```dart
test('totalSize includes uniform padding for a framed clip (auto aspect)', () {
  // 30px uniform on all sides: 320 + 30+30 = 380; 240 + 30+30 = 300.
  // (Old aspect-scaled behavior: left/right = 30 * 4/3 = 40, canvas 400×300.)
  final compositor = _build(
    videoSize: const Size(320, 240),
    padding: const EdgeInsets.all(30),
  );
  expect(compositor.totalSize, const Size(380, 300));
});
```

(b) Add a new test below it:

```dart
test('totalSize honors OutputAspect.vertical9x16 (canvas grows vertically)', () {
  final compositor = _build(
    videoSize: const Size(1920, 1080),
    padding: EdgeInsets.zero,
    outputAspect: OutputAspect.vertical9x16,
  );
  // 1920 × (1920 / 0.5625) ≈ 1920 × 3413 → rounded to 1920 × 3414 (even for yuv420p).
  expect(compositor.totalSize.width, 1920);
  expect(compositor.totalSize.height, isIn([3412, 3414]),
      reason: 'rounded to even for yuv420p; allow either side of the boundary');
});
```

(c) The existing `_build` test helper (search for `FrameCompositor _build(` in the test file) needs an optional `outputAspect` parameter. Update it:

```dart
FrameCompositor _build({
  required Size videoSize,
  EdgeInsets padding = EdgeInsets.zero,
  OutputAspect outputAspect = OutputAspect.auto,
}) {
  final frame = WindowFrame(/* ... existing args ... */, padding: padding);
  final state = EditorProjectState.defaults().copyWith(
    windowFrame: frame,
    outputAspect: outputAspect,
  );
  return FrameCompositor(
    projectState: state,
    cursorRecording: CursorRecording.empty(),
    metadata: null,
    videoSize: videoSize,
    fps: 60,
  );
}
```

Add the import at the top:
```dart
import 'package:slipreel_engine/models/output_aspect.dart';
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/export/frame_compositor_test.dart`
Expected: FAIL — `outputAspect` named parameter doesn't exist on `_build` yet; vertical test fails to compile until `FrameCompositor` reads `projectState.outputAspect`.

- [ ] **Step 3: Refactor `FrameCompositor`**

Edit `packages/slipreel_engine/lib/export/frame_compositor.dart`:

(a) Add imports:
```dart
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
```

(b) Replace the constructor initializer list. The current constructor (lines ~36–69) computes `totalSize` and `_effectivePadding` via separate calls. Replace with:

```dart
FrameCompositor({
  required this.projectState,
  required this.cursorRecording,
  required this.metadata,
  required this.videoSize,
  required this.fps,
}) : _framePainter = FramePainter(
       frame: projectState.windowFrame,
       videoSize: videoSize,
     ),
     // Compute the canvas + video rect once, then derive everything
     // downstream from it. Single source of truth keeps preview and
     // export pixel-aligned.
     _resolved = OutputCanvasResolver.resolve(
       videoSize: videoSize,
       padding: projectState.windowFrame.padding,
       aspect: projectState.outputAspect,
     ),
     totalSize = _evenSize(
       OutputCanvasResolver.resolve(
         videoSize: videoSize,
         padding: projectState.windowFrame.padding,
         aspect: projectState.outputAspect,
       ).canvasSize,
     );
```

(c) Replace the `_effectivePadding` field with the resolved video rect. Find:

```dart
final FramePainter _framePainter;
final EdgeInsets _effectivePadding;
```

and replace with:

```dart
final FramePainter _framePainter;
final ResolvedCanvas _resolved;

/// Where the source video sits inside [totalSize]. Replaces the
/// previous `_effectivePadding`-derived top-left coordinate.
Rect get _videoRect => _resolved.videoRect;
```

(d) Remove the existing `_centeredPadding` helper if present, **and** the call to it inside the constructor. The resolver already returns a centered rect — no need for the post-rounding recenter dance.

(e) Update every reference inside `frame_compositor.dart` that used `_effectivePadding.left` → `_videoRect.left`, and `_effectivePadding.top` → `_videoRect.top`. These are at lines ~573, ~574, ~638, ~639 in the current file.

(f) Update the `FrameCompositor` doc comments that mention `effectivePadding` or aspect-scaled padding to reflect the new model (search for "effective padding" / "effPad" / "aspect-scaled" comment instances and rewrite them in plain language: "uniform inset from the WindowFrame padding").

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/export/frame_compositor_test.dart`
Expected: PASS — including the new 9:16 case.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/slipreel_engine/test/export/frame_compositor_test.dart
git commit -m "refactor(engine): FrameCompositor uses OutputCanvasResolver"
```

---

### Task 8: Update `motion_blur_playground_screen` to the new `calculateTotalSize` signature

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart`

- [ ] **Step 1: Replace the calculateTotalSize call**

Open `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart`. Search for the `FramePainter.calculateTotalSize(` call (around line 474). It currently passes `frame` and `videoSize`. Since this screen has no editor-aspect concept, pass `OutputAspect.auto`:

```dart
import 'package:slipreel_engine/models/output_aspect.dart';

// ... at the call site:
final totalSize = FramePainter.calculateTotalSize(
  frame: /* existing arg */,
  videoSize: /* existing arg */,
  aspect: OutputAspect.auto,
);
```

(The `aspect` parameter has a default of `OutputAspect.auto` in Task 5, so passing it is technically optional — include it explicitly for searchability when we later grep for "outputAspect" callers.)

- [ ] **Step 2: Verify the file compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart
git commit -m "refactor(app): motion_blur_playground passes explicit OutputAspect.auto"
```

---

### Task 9: Canvas-aware `outDims` in `export_pipeline` and `gif_export_pipeline`

**Files:**
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart`

This task changes the final MP4/GIF pixel dimensions to reflect the chosen aspect ratio rather than the raw source video's aspect. Without this, a vertical-9:16 export would still write a 16:9 MP4 file.

- [ ] **Step 1: Update `export_pipeline.dart`**

Find the block around lines 98–102 in `packages/slipreel_engine/lib/export/export_pipeline.dart`:

```dart
final outDims = settings.resolution.dimensionsFor(
  Size(srcWidth.toDouble(), srcHeight.toDouble()),
);
```

Replace with:

```dart
// Output dimensions match the COMPOSITED canvas (aspect + padding),
// not the raw source. Without this, a vertical-9:16 export at 1080p
// would still produce a 16:9 MP4 because `dimensionsFor` would
// width-scale from the raw 1920×1080 source.
final composedCanvas = OutputCanvasResolver.resolve(
  videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
  padding: projectState.windowFrame.padding,
  aspect: projectState.outputAspect,
).canvasSize;
final outDims = settings.resolution.dimensionsFor(composedCanvas);
```

Add the import at the top of the file:
```dart
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
```

- [ ] **Step 2: Update `gif_export_pipeline.dart`**

Find the same `settings.resolution.dimensionsFor(...)` block around line 97 in `packages/slipreel_engine/lib/export/gif_export_pipeline.dart`. Apply the same replacement: compute `composedCanvas` via the resolver, pass it to `dimensionsFor` instead of the raw video size. Add the same import.

- [ ] **Step 3: Verify the engine compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/slipreel_engine`
Expected: No errors.

- [ ] **Step 4: Run the full engine test suite**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine`
Expected: PASS. The export pipeline doesn't currently have unit tests asserting specific `outDims` values, so this change is covered transitively by the existing pipeline tests not breaking.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/export_pipeline.dart \
        packages/slipreel_engine/lib/export/gif_export_pipeline.dart
git commit -m "feat(engine): export pipelines size output to the composed canvas"
```

---

### Task 10: Canvas-aware `sourceVideoSize` passed into the export dialog

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

The export dialog's `sourceVideoSize` parameter is used by the resolution picker to show "Export at 1920×1080" etc. With aspect ratio in play, that label should reflect the composed-canvas dimensions so the user sees the correct final pixel count.

- [ ] **Step 1: Compute and pass canvas-aware size into the dialog**

Open `packages/screen_recorder/lib/ui/screens/playback_screen.dart`. Find the block around line 461–491 where `sourceVideoSize` is computed and passed into the export dialog (search for `sourceVideoSize: sourceVideoSize,`).

Wrap the dialog launch with a resolver call. Insert just before the dialog construction:

```dart
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

// ... inside the relevant method, after sourceVideoSize is computed:
final composedVideoSize = OutputCanvasResolver.resolve(
  videoSize: sourceVideoSize,
  padding: project.windowFrame.padding,
  aspect: project.outputAspect,
).canvasSize;
```

Then change the dialog construction to pass `composedVideoSize` instead of `sourceVideoSize`:

```dart
sourceVideoSize: composedVideoSize,
```

(The `project` variable is the current `EditorProjectState` already in scope at this call site; confirm by reading 20 lines of surrounding context.)

- [ ] **Step 2: Verify the file compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/screens/playback_screen.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): export dialog displays canvas-aware dimensions"
```

---

### Task 11: `AspectRatioPicker` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart`
- Test: `packages/screen_recorder/test/ui/widgets/canvas_toolbar/aspect_ratio_picker_test.dart`

- [ ] **Step 1: Write the failing widget tests**

```dart
// packages/screen_recorder/test/ui/widgets/canvas_toolbar/aspect_ratio_picker_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart';
import 'package:slipreel_engine/models/output_aspect.dart';

void main() {
  Future<void> pump(WidgetTester tester, {
    required OutputAspect current,
    required void Function(OutputAspect) onChanged,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AspectRatioPicker(current: current, onChanged: onChanged),
        ),
      ),
    ));
  }

  testWidgets('renders the current label', (tester) async {
    await pump(tester, current: OutputAspect.vertical9x16, onChanged: (_) {});
    expect(find.text('Vertical 9:16'), findsOneWidget);
  });

  testWidgets('opens a menu with all 7 entries on tap', (tester) async {
    await pump(tester, current: OutputAspect.auto, onChanged: (_) {});
    await tester.tap(find.byType(AspectRatioPicker));
    await tester.pumpAndSettle();
    for (final v in OutputAspect.values) {
      expect(find.text(v.label), findsWidgets,
          reason: 'expected entry for ${v.label}');
    }
  });

  testWidgets('fires onChanged with the chosen variant', (tester) async {
    OutputAspect? chosen;
    await pump(
      tester,
      current: OutputAspect.auto,
      onChanged: (v) => chosen = v,
    );
    await tester.tap(find.byType(AspectRatioPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wide 16:9').last);
    await tester.pumpAndSettle();
    expect(chosen, OutputAspect.wide16x9);
  });

  testWidgets('shows a checkmark next to the current entry', (tester) async {
    await pump(
      tester,
      current: OutputAspect.square1x1,
      onChanged: (_) {},
    );
    await tester.tap(find.byType(AspectRatioPicker));
    await tester.pumpAndSettle();
    // Find the row whose label is "Square 1:1" and assert a check icon
    // sits in the same widget subtree.
    final activeRow = find.ancestor(
      of: find.text('Square 1:1'),
      matching: find.byType(MenuItemButton),
    );
    expect(activeRow, findsOneWidget);
    expect(
      find.descendant(of: activeRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/canvas_toolbar/`
Expected: FAIL with "Target of URI doesn't exist".

- [ ] **Step 3: Implement the picker**

```dart
// packages/screen_recorder/lib/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart
import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/output_aspect.dart';

/// Compact button + dropdown that lets the user pick an output aspect
/// ratio. Pure widget: no Riverpod inside — parent wires the state.
class AspectRatioPicker extends StatelessWidget {
  const AspectRatioPicker({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final OutputAspect current;
  final ValueChanged<OutputAspect> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      builder: (context, controller, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_iconFor(current), size: 18),
                const SizedBox(width: 8),
                Text(current.label, style: theme.textTheme.bodyMedium),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
        );
      },
      menuChildren: [
        for (final v in OutputAspect.values)
          MenuItemButton(
            leadingIcon: Icon(_iconFor(v), size: 18),
            trailingIcon: v == current
                ? const Icon(Icons.check, size: 18)
                : const SizedBox(width: 18),
            onPressed: () => onChanged(v),
            child: Text(v.label),
          ),
      ],
    );
  }

  IconData _iconFor(OutputAspect v) {
    switch (v) {
      case OutputAspect.auto:
        return Icons.aspect_ratio;
      case OutputAspect.wide16x9:
      case OutputAspect.classic4x3:
        return Icons.crop_landscape;
      case OutputAspect.square1x1:
        return Icons.crop_square;
      case OutputAspect.vertical9x16:
      case OutputAspect.tall3x4:
      case OutputAspect.portrait4x5:
        return Icons.crop_portrait;
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/canvas_toolbar/`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart \
        packages/screen_recorder/test/ui/widgets/canvas_toolbar/aspect_ratio_picker_test.dart
git commit -m "feat(app): add AspectRatioPicker widget"
```

---

### Task 12: `CanvasToolbar` host widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart`

- [ ] **Step 1: Implement the host**

```dart
// packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart
import 'package:flutter/material.dart';

/// Slim horizontal toolbar that sits above the playback canvas. Holds
/// canvas-scoped controls (aspect picker today; mask / frame picker
/// next). Centered, fixed height so the layout doesn't reflow when
/// children update.
class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 16),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
```

No tests for this — it's a trivial layout wrapper; the picker tests cover the only meaningful behavior. (YAGNI.)

- [ ] **Step 2: Verify it compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart
git commit -m "feat(app): add CanvasToolbar host widget"
```

---

### Task 13: Wire `CanvasToolbar` + picker into `PlaybackScreen`; thread `outputAspect` into `PlaybackCanvas`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

- [ ] **Step 1: Add imports**

At the top of `playback_screen.dart`:

```dart
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/canvas_toolbar.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart';
```

- [ ] **Step 2: Pass `outputAspect` into the existing `PlaybackCanvas` construction**

Find the `PlaybackCanvas(` call around line 1055 (search for `playbackCanvas = PlaybackCanvas(`). Add a parameter:

```dart
final playbackCanvas = PlaybackCanvas(
  // ... existing params ...
  outputAspect: project.outputAspect,
);
```

There is a second `PlaybackCanvas(` call around line 1129 used for export preview; pass the same `outputAspect: project.outputAspect` there too.

- [ ] **Step 3: Insert the toolbar above the canvas**

Find where the canvas widget is placed in the layout. Wrap the canvas in a `Column` that puts the toolbar above:

```dart
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    CanvasToolbar(
      children: [
        AspectRatioPicker(
          current: project.outputAspect,
          onChanged: (v) => ref
              .read(editorProjectControllerProvider.notifier)
              .setOutputAspect(v),
        ),
      ],
    ),
    Expanded(child: playbackCanvas),
  ],
)
```

The exact wrap depends on the existing layout — read 30 lines of surrounding context around the `playbackCanvas` widget placement to confirm the correct parent. The principle: the toolbar must be in the same column as the canvas, above it, and must not displace the timeline or inspector.

- [ ] **Step 4: Verify the screen compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/screens/playback_screen.dart`
Expected: No errors.

- [ ] **Step 5: Run the full app test suite to catch regressions**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder`
Expected: PASS. (Some pre-existing failures in `debug_probe_test.dart` are unrelated and tracked separately per session notes; they may already be skipped.)

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): canvas toolbar wires AspectRatioPicker into PlaybackScreen"
```

---

### Task 14: Manual verification (UI + export)

**Files:** none (testing only)

This task is the gate before declaring the feature shipped. No code; verify the live behavior against the spec.

- [ ] **Step 1: Build + boot the app via the agent-wires probe**

Per `agent_wires_debug_setup` memory, the probe is wired through `debug_probe.dart`'s LOCAL-ONLY swap. From the project root:

```bash
~/fvm/versions/3.41.5/bin/flutter run -d macos packages/screen_recorder/lib/main.dart
```

(Or use `mcp__flutter-qa__boot_app` if running through the MCP probe.)

- [ ] **Step 2: Open an existing recording**

From the Recents screen, open any prior recording. Confirm the canvas toolbar appears above the playback canvas, with the picker showing **Auto**.

- [ ] **Step 3: Switch through every preset**

Pick each preset in turn — **Wide 16:9**, **Square 1:1**, **Classic 4:3**, **Vertical 9:16**, **Tall 3:4**, **Portrait 4:5** — and confirm:
  - The canvas reshapes immediately.
  - The video is centered with no stretching.
  - Wallpaper fills the new space.
  - The padding slider still works on all four sides uniformly.

- [ ] **Step 4: Verify persistence**

Pick **Vertical 9:16**, close the recording (back to Recents), reopen it. Confirm the picker still reads **Vertical 9:16** and the canvas reflects it.

- [ ] **Step 5: Verify export**

With **Vertical 9:16** selected, export an MP4 at 1080p. Confirm the exported file:
  - Has dimensions **608 × 1080** (1080-tall, width scaled to 9:16) — check via `ffprobe -hide_banner -i <path>` or QuickTime info.
  - Plays back correctly with the video letterboxed inside the vertical canvas.

- [ ] **Step 6: Verify Auto still matches source aspect**

Set the picker back to **Auto**. Confirm the canvas shape returns to the source video's aspect ratio (with uniform padding — slightly narrower horizontal padding than the old behavior on wide videos; expected per the spec).

- [ ] **Step 7: No commit**

This is a verification task — no code changes, no commit. If any step fails, file the issue, fix it in a follow-up task, then re-run from step 1.

---

## Done

After Task 14 passes, hand off to `superpowers:finishing-a-development-branch` to merge/push.
