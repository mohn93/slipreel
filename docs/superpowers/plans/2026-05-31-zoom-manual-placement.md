# Zoom Manual Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small mini-frame placement picker inside the zoom inspector that lets users position a manual (`followCursor: false`) zoom region's focal by dragging a rectangle, with live canvas preview while dragging.

**Architecture:** A pure `ZoomPlacementPicker` widget in the inspector emits `Rect` callbacks; a `ZoomPreviewOverride` `ValueNotifier<ZoomRegion?>` held at the playback screen relays the in-flight rect to the canvas. `ScenePassBuilder` and `ZoomFocalController` gain a single optional `activeRegionOverride` param so the override bypasses their normal `ZoomRegion.activeAt(playhead, regions)` lookup. On drag release, the inspector commits the new rect via the existing `EditorProjectController.updateZoomAt`. No model changes, no native code.

**Tech Stack:** Flutter 3.41.5 (FVM), Riverpod (state), `package:slipreel_engine` (zoom rendering pipeline), `package:screen_recorder` (editor UI), `flutter_test` (TDD).

---

## File Structure

**Created:**
- `packages/screen_recorder/lib/state/zoom_preview_override.dart` — `ValueNotifier<ZoomRegion?>` subclass.
- `packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart` — pure stateful widget.
- `packages/screen_recorder/test/state/zoom_preview_override_test.dart`
- `packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart`
- `packages/slipreel_engine/test/rendering/scene_pass_builder_override_test.dart`

**Modified:**
- `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart` — add optional `activeRegionOverride` param, pipe to focal.
- `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart` — add optional `activeRegionOverride` param, bypass `activeAt` when set.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — accept override notifier, pass to scene pass builder.
- `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` — add "Placement" section gated on `!followCursor` + `videoSize != Size.zero`.
- `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` — thread `videoSize`, `onPlacementPreview`, `onPlacementCommit` callbacks.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — construct override, wire callbacks, clear on selection change.

---

## Pre-flight

Working directory: `/Users/mohn93/Desktop/side_projects/screenflow_studio`. The earlier session left local-only edits (debug probe swap, tip overlay polish, recording bar tip grow, onboarding panel switch). These are **uncommitted** and should stay that way during this work — they are unrelated. Branch off `main` without staging them.

- [ ] **Pre-step 1: Create the feature branch from main**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git checkout -b feat/zoom-manual-placement
```

Expected: switched to a new branch. Existing uncommitted edits ride along on the branch — that is fine; they are not committed by any task here.

---

## Task 1: `ZoomPreviewOverride` notifier

**Why first:** Every other task depends on a stable type. Two-liner with a one-liner test, so the dependency chain starts on solid ground.

**Files:**
- Create: `packages/screen_recorder/lib/state/zoom_preview_override.dart`
- Test: `packages/screen_recorder/test/state/zoom_preview_override_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/zoom_preview_override_test.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  test('starts null', () {
    final n = ZoomPreviewOverride();
    expect(n.value, isNull);
  });

  test('notifies on set and clear', () {
    final n = ZoomPreviewOverride();
    var ticks = 0;
    n.addListener(() => ticks++);

    final region = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );

    n.value = region;
    expect(n.value, same(region));
    expect(ticks, 1);

    n.value = null;
    expect(n.value, isNull);
    expect(ticks, 2);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/fvm/versions/3.41.5/bin/dart test packages/screen_recorder/test/state/zoom_preview_override_test.dart`
Expected: compile error — `ZoomPreviewOverride` does not exist.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/state/zoom_preview_override.dart
import 'package:flutter/foundation.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

/// Live placement-picker override. While the user is dragging the
/// focal handle in the zoom inspector, this holds the in-flight
/// [ZoomRegion] that should replace the normal
/// `ZoomRegion.activeAt(playhead, regions)` result. Cleared on drag
/// release and on any change to the selected zoom index.
class ZoomPreviewOverride extends ValueNotifier<ZoomRegion?> {
  ZoomPreviewOverride() : super(null);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/fvm/versions/3.41.5/bin/dart test packages/screen_recorder/test/state/zoom_preview_override_test.dart`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/zoom_preview_override.dart \
        packages/screen_recorder/test/state/zoom_preview_override_test.dart
git commit -m "feat(zoom): ZoomPreviewOverride notifier for live placement preview"
```

---

## Task 2: `ZoomPlacementPicker` widget (pure)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart`

**Contract:**
- Inputs: `videoSize`, current `rect`, `zoomLevel`, `onPreview(Rect)`, `onCommit(Rect)`.
- Renders a mini-frame whose aspect ratio matches `videoSize`, max width `_kMiniFrameMaxWidth = 280` logical px.
- Inner rect size = `videoSize / zoomLevel`, scaled into mini-frame space.
- Pan gesture on the inner rect translates drag deltas to video-coord deltas; clamps so the rect stays fully inside `videoSize`.
- `onPreview` fires on each pan update with the new rect. `onCommit` fires once on pan end with the final rect.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          // Constrain like the real inspector column so the picker
          // resolves a finite width.
          child: SizedBox(width: 300, child: child),
        ),
      ),
    ),
  );
}

void main() {
  const videoSize = Size(1920, 1080);

  testWidgets('renders with initial rect centered', (tester) async {
    final initial = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (_) {},
        onCommit: (_) {},
      ),
    );
    expect(find.byKey(const Key('zoom-placement-mini-frame')), findsOneWidget);
    expect(find.byKey(const Key('zoom-placement-inner-rect')), findsOneWidget);
  });

  testWidgets('drag to mini-frame center emits center in video coords',
      (tester) async {
    Rect? latestPreview;
    Rect? committed;
    final initial = Rect.fromCenter(
      center: const Offset(100, 100),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (r) => latestPreview = r,
        onCommit: (r) => committed = r,
      ),
    );

    final miniFrame =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    final innerStart =
        tester.getCenter(find.byKey(const Key('zoom-placement-inner-rect')));
    final miniCenter = miniFrame.center;

    // Drag the inner rect by the delta from its current position to the
    // mini-frame center.
    await tester.timedDrag(
      find.byKey(const Key('zoom-placement-inner-rect')),
      miniCenter - innerStart,
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();

    expect(latestPreview, isNotNull);
    expect(committed, isNotNull);
    // Expect the inner rect to be centered in the video.
    expect(committed!.center.dx, closeTo(960, 1.0));
    expect(committed!.center.dy, closeTo(540, 1.0));
    // Size derived from videoSize / zoomLevel.
    expect(committed!.size.width, closeTo(960, 0.5));
    expect(committed!.size.height, closeTo(540, 0.5));
  });

  testWidgets('drag past top-left clamps to half-size center',
      (tester) async {
    Rect? committed;
    final initial = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (_) {},
        onCommit: (r) => committed = r,
      ),
    );

    final miniFrame =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    final innerStart =
        tester.getCenter(find.byKey(const Key('zoom-placement-inner-rect')));
    // Aim well past the top-left corner of the mini-frame.
    final farTopLeft = miniFrame.topLeft - const Offset(200, 200);

    await tester.timedDrag(
      find.byKey(const Key('zoom-placement-inner-rect')),
      farTopLeft - innerStart,
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();

    expect(committed, isNotNull);
    // Clamped: rect's top-left at (0,0), so center is at half size.
    expect(committed!.center.dx, closeTo(480, 1.0));
    expect(committed!.center.dy, closeTo(270, 1.0));
  });

  testWidgets('emit cadence: many previews, exactly one commit',
      (tester) async {
    int previews = 0;
    int commits = 0;
    final initial = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 960,
      height: 540,
    );
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: videoSize,
        rect: initial,
        zoomLevel: 2.0,
        onPreview: (_) => previews++,
        onCommit: (_) => commits++,
      ),
    );

    final inner = find.byKey(const Key('zoom-placement-inner-rect'));
    final gesture = await tester.startGesture(tester.getCenter(inner));
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    await gesture.moveBy(const Offset(5, 5));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(previews, greaterThanOrEqualTo(3));
    expect(commits, 1);
  });

  testWidgets('matches vertical (9:16) videoSize aspect', (tester) async {
    const verticalVideo = Size(1080, 1920);
    await _pump(
      tester,
      ZoomPlacementPicker(
        videoSize: verticalVideo,
        rect: Rect.fromCenter(
            center: const Offset(540, 960), width: 540, height: 960),
        zoomLevel: 2.0,
        onPreview: (_) {},
        onCommit: (_) {},
      ),
    );
    final miniFrame =
        tester.getRect(find.byKey(const Key('zoom-placement-mini-frame')));
    // Width 280 cap, so height = 280 * (1920/1080) ≈ 497.78.
    expect(miniFrame.width, closeTo(280, 0.5));
    expect(miniFrame.height / miniFrame.width,
        closeTo(verticalVideo.height / verticalVideo.width, 0.001));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart`
Expected: compile error — `ZoomPlacementPicker` does not exist.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart
import 'package:flutter/material.dart';

/// Mini-frame placement picker for a manual (`followCursor: false`)
/// zoom region. Renders a small box whose aspect ratio matches the
/// video; inside, a smaller rectangle shows the framing area
/// (`videoSize / zoomLevel`). Pan the inner rect to move the focal.
///
/// Pure UI: no Riverpod, no async, no platform calls.
class ZoomPlacementPicker extends StatefulWidget {
  const ZoomPlacementPicker({
    super.key,
    required this.videoSize,
    required this.rect,
    required this.zoomLevel,
    required this.onPreview,
    required this.onCommit,
  });

  /// Source video size in pixels (e.g. 1920×1080).
  final Size videoSize;

  /// Current focal rect in video coordinates.
  final Rect rect;

  /// Current zoom strength. Used to derive the inner rect's size.
  final double zoomLevel;

  /// Fires on each pan update with the new rect (video coords, clamped).
  final ValueChanged<Rect> onPreview;

  /// Fires once on pan end with the final rect (video coords, clamped).
  final ValueChanged<Rect> onCommit;

  @override
  State<ZoomPlacementPicker> createState() => _ZoomPlacementPickerState();
}

class _ZoomPlacementPickerState extends State<ZoomPlacementPicker> {
  static const double _kMiniFrameMaxWidth = 280;

  /// Working rect in video coords during an active drag. Null when no
  /// drag is in flight — UI falls back to widget.rect.
  Rect? _dragRect;

  Rect _currentRect() => _dragRect ?? widget.rect;

  /// Size of the framed inner rect in video coordinates.
  Size _innerSize() => Size(
        widget.videoSize.width / widget.zoomLevel,
        widget.videoSize.height / widget.zoomLevel,
      );

  /// Clamp a center so the inner rect stays fully inside videoSize.
  Offset _clampCenter(Offset c, Size inner) {
    final halfW = inner.width / 2;
    final halfH = inner.height / 2;
    return Offset(
      c.dx.clamp(halfW, widget.videoSize.width - halfW),
      c.dy.clamp(halfH, widget.videoSize.height - halfH),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.videoSize.width / widget.videoSize.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : _kMiniFrameMaxWidth;
        final miniWidth = available.clamp(0.0, _kMiniFrameMaxWidth);
        final miniHeight = miniWidth / aspect;
        final scale = miniWidth / widget.videoSize.width;

        final inner = _innerSize();
        final innerW = inner.width * scale;
        final innerH = inner.height * scale;

        final cur = _currentRect();
        // Position of inner rect's top-left in mini-frame coordinates.
        final innerLeft = (cur.center.dx - inner.width / 2) * scale;
        final innerTop = (cur.center.dy - inner.height / 2) * scale;

        return SizedBox(
          width: miniWidth,
          height: miniHeight,
          child: Container(
            key: const Key('zoom-placement-mini-frame'),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A22),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF2A2A35)),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: innerLeft,
                  top: innerTop,
                  width: innerW,
                  height: innerH,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) {
                      setState(() => _dragRect = widget.rect);
                    },
                    onPanUpdate: (d) {
                      final cur2 = _dragRect ?? widget.rect;
                      // delta is in mini-frame (logical) px; convert to video.
                      final deltaVideo = d.delta / scale;
                      final innerSz = _innerSize();
                      final newCenter =
                          _clampCenter(cur2.center + deltaVideo, innerSz);
                      final newRect =
                          Rect.fromCenter(center: newCenter, width: innerSz.width, height: innerSz.height);
                      setState(() => _dragRect = newRect);
                      widget.onPreview(newRect);
                    },
                    onPanEnd: (_) {
                      final committed = _dragRect ?? widget.rect;
                      setState(() => _dragRect = null);
                      widget.onCommit(committed);
                    },
                    onPanCancel: () {
                      setState(() => _dragRect = null);
                    },
                    child: Container(
                      key: const Key('zoom-placement-inner-rect'),
                      decoration: BoxDecoration(
                        color: const Color(0x33A78BFA),
                        border: Border.all(color: const Color(0xFFA78BFA), width: 1.5),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart \
        packages/screen_recorder/test/ui/widgets/inspector/zoom_placement_picker_test.dart
git commit -m "feat(zoom): ZoomPlacementPicker mini-frame widget"
```

---

## Task 3: Engine — `ScenePassBuilder` accepts `activeRegionOverride`

**Why this is engine-side:** `ScenePassBuilder.build` internally calls `_activeZoomAt(position, regions)` (`scene_pass_builder.dart:146`) and also passes `zoomRegions` to `ZoomFocalController.update`, which calls `ZoomRegion.activeAt` again (`zoom_focal_controller.dart:458`). To make a transient override "win" regardless of playhead, both callers must consult the override first. This task adds one optional named param to each.

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart`
- Modify: `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`
- Test: `packages/slipreel_engine/test/rendering/scene_pass_builder_override_test.dart`

- [ ] **Step 1: Read the existing test wiring**

Run: `ls packages/slipreel_engine/test/rendering/`
Expected: directory exists with at least `scene_pass_builder_test.dart` (or similar). Look at the first ~50 lines of any existing test there with `head -50 packages/slipreel_engine/test/rendering/<file>` to copy the import + setup pattern.

- [ ] **Step 2: Write the failing test**

```dart
// packages/slipreel_engine/test/rendering/scene_pass_builder_override_test.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/scene_pass_builder.dart';

void main() {
  test('activeRegionOverride wins even when playhead is outside all regions',
      () {
    // A real region runs 5..8s.
    final real = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: const Duration(seconds: 5),
      duration: const Duration(seconds: 3),
      zoomLevel: 2.0,
      followCursor: false,
    );
    // Synthetic override with a different focal.
    final override = ZoomRegion(
      rect: const Rect.fromLTWH(800, 600, 960, 540),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
      followCursor: false,
    );

    final builder = ScenePassBuilder();
    // Playhead at 2s — outside any real region; would normally produce
    // no zoom.
    final pass = builder.build(
      position: const Duration(seconds: 2),
      zoomRegions: [real],
      cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth),
      cursorRecording: CursorRecording(),
      videoSize: const Size(1920, 1080),
      fps: 60,
      hasCursorData: false,
      activeRegionOverride: override,
    );

    // The focal controller's target should be the override region,
    // not "no zoom".
    expect(pass.focalUpdate, isNotNull);
    expect(pass.focalUpdate!.zoom.zoomLevel, closeTo(2.0, 1e-6));
  });

  test('null override falls back to activeAt', () {
    final real = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: const Duration(seconds: 1),
      duration: const Duration(seconds: 3),
      zoomLevel: 2.0,
      followCursor: false,
    );
    final builder = ScenePassBuilder();
    // Playhead at 0.5s — no region active, no override.
    final pass = builder.build(
      position: const Duration(milliseconds: 500),
      zoomRegions: [real],
      cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth),
      cursorRecording: CursorRecording(),
      videoSize: const Size(1920, 1080),
      fps: 60,
      hasCursorData: false,
    );
    // No region is active → focalUpdate is null.
    expect(pass.focalUpdate, isNull);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/rendering/scene_pass_builder_override_test.dart`
Expected: compile error — `activeRegionOverride` is not a known parameter on `ScenePassBuilder.build`.

- [ ] **Step 4: Add the param to `ScenePassBuilder.build`**

Edit `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart`.

Add to the named-param list of `build`:

```dart
    /// When non-null, replaces the natural `ZoomRegion.activeAt`
    /// lookup result for this frame. Used by the editor's manual
    /// placement picker to live-preview a drag-in-flight rect, and by
    /// any other caller that wants to bypass timing-driven activation
    /// for one frame. Cleared by the caller when the preview ends.
    ZoomRegion? activeRegionOverride,
```

Replace the line `final activeZoom = _activeZoomAt(position, zoomRegions);` (around line 146) with:

```dart
    final activeZoom =
        activeRegionOverride ?? _activeZoomAt(position, zoomRegions);
```

Replace the `focal.update(...)` call (around line 158) — pass the override through to the focal controller:

```dart
    final focalUpdate = focal.update(
      position: position,
      zoomRegions: zoomRegions,
      cursor: cursorForFocal,
      videoSize: videoSize,
      cursorVelocity: rawVelocity,
      forceSnap: forceSnap,
      activeRegionOverride: activeRegionOverride,
    );
```

- [ ] **Step 5: Add the param to `ZoomFocalController.update`**

Edit `packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart`. Find `update(...)` (around line 440). Add to its named-param list:

```dart
    ZoomRegion? activeRegionOverride,
```

Find the internal `activeAt` lookup (around line 458). Replace:

```dart
      ZoomRegion.activeAt(position, zoomRegions);
```

with a single line that prefers the override:

```dart
      activeRegionOverride ?? ZoomRegion.activeAt(position, zoomRegions);
```

(Use the surrounding context to make sure the replacement lands on the right binding — there is only one `activeAt` call inside `update`.)

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/rendering/scene_pass_builder_override_test.dart`
Expected: both tests pass.

- [ ] **Step 7: Run the full engine test suite to confirm no regressions**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/`
Expected: all green. The override param is opt-in, so existing call sites are unaffected.

- [ ] **Step 8: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/scene_pass_builder.dart \
        packages/slipreel_engine/lib/rendering/zoom_focal_controller.dart \
        packages/slipreel_engine/test/rendering/scene_pass_builder_override_test.dart
git commit -m "feat(engine): scene pass + focal controller activeRegionOverride"
```

---

## Task 4: `PlaybackCanvas` consumes the override

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`

The canvas is large; we are adding a single optional `ValueListenable<ZoomRegion?>` field, listening to it with `AnimatedBuilder`-style rebuilds, and forwarding its current value to `_scenePassBuilder.build` as `activeRegionOverride`.

- [ ] **Step 1: Add the import + field + constructor param**

At the top of `playback_canvas.dart`, alongside other slipreel_engine imports, add:

```dart
import 'package:screen_recorder/state/zoom_preview_override.dart';
```

In the `PlaybackCanvas` class, add to the constructor (in the same `required this.foo`/`this.bar` list near the existing optional fields):

```dart
    this.zoomPreviewOverride,
```

And declare the field next to the other `final` fields:

```dart
  /// Editor-only: when non-null, the canvas reads its current value
  /// per build and passes it to `ScenePassBuilder.build` so a manual
  /// placement-picker drag live-previews the proposed rect. Pure
  /// playback callers leave this null.
  final ZoomPreviewOverride? zoomPreviewOverride;
```

- [ ] **Step 2: Listen for override changes so the canvas rebuilds**

In `_PlaybackCanvasState`, add an `initState` listener (and remove it in `dispose`). If `initState`/`dispose` already exist, add the two `addListener`/`removeListener` lines inside them; otherwise create them.

```dart
  @override
  void initState() {
    super.initState();
    widget.zoomPreviewOverride?.addListener(_onPreviewChanged);
  }

  @override
  void didUpdateWidget(covariant PlaybackCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomPreviewOverride != widget.zoomPreviewOverride) {
      oldWidget.zoomPreviewOverride?.removeListener(_onPreviewChanged);
      widget.zoomPreviewOverride?.addListener(_onPreviewChanged);
    }
  }

  @override
  void dispose() {
    widget.zoomPreviewOverride?.removeListener(_onPreviewChanged);
    super.dispose();
  }

  void _onPreviewChanged() {
    if (mounted) setState(() {});
  }
```

If `_PlaybackCanvasState` already has `initState`/`dispose`/`didUpdateWidget`, splice the listener wiring into them instead of duplicating.

- [ ] **Step 3: Forward the override to `_scenePassBuilder.build`**

Find the `_scenePassBuilder.build(...)` call (around line 403). Add one named argument at the bottom of its call:

```dart
              activeRegionOverride: widget.zoomPreviewOverride?.value,
```

- [ ] **Step 4: Build the package to confirm it compiles**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
Expected: no errors. (Pre-existing info-level warnings unchanged.)

- [ ] **Step 5: Run the screen_recorder test suite**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/`
Expected: all green. No existing test passes a non-null override, so behaviour is unchanged for them.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(zoom): PlaybackCanvas pipes zoomPreviewOverride to scene pass"
```

---

## Task 5: `ZoomContextInspector` renders the Placement section

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`

We add a "Placement" section that renders only when `!zoom.followCursor` AND `videoSize != Size.zero`. The section hosts the picker plus a small label. The picker's `onPreview` and `onCommit` flow through new callback props on `ZoomContextInspector`.

- [ ] **Step 1: Add the new constructor params**

At the top of `zoom_context_inspector.dart`, add the import:

```dart
import 'package:screen_recorder/ui/widgets/inspector/zoom_placement_picker.dart';
```

Add fields (next to existing `final` fields, e.g. just below `final ValueChanged<CubicBezierCurve?> onCurveOverrideChanged;`):

```dart
  /// Video frame size; needed to drive the placement picker's
  /// coordinate model. Zero ⇒ video not yet measured ⇒ section hidden.
  final Size videoSize;

  /// Live placement preview: fires for every drag-update with the
  /// in-flight rect, so the canvas can live-preview the framing.
  final ValueChanged<Rect>? onPlacementPreview;

  /// Placement commit: fires once on drag release with the final
  /// rect, so the editor can persist it via `updateZoomAt`.
  final ValueChanged<Rect>? onPlacementCommit;
```

Add to the constructor's named-arg list (next to existing required ones):

```dart
    required this.videoSize,
    this.onPlacementPreview,
    this.onPlacementCommit,
```

- [ ] **Step 2: Render the Placement section above "Zoom level"**

Inside `build`'s ListView children (the `ListView` inside `Expanded`), insert a new section immediately BEFORE the existing `InspectorSlider(label: 'Zoom level', ...)` block:

```dart
              if (!zoom.followCursor && !videoSize.isEmpty) ...[
                const Text(
                  'Placement',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Drag to set the zoom focal.',
                  style: TextStyle(
                    color: kInspectorMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                ZoomPlacementPicker(
                  videoSize: videoSize,
                  rect: zoom.rect,
                  zoomLevel: zoom.zoomLevel,
                  onPreview: (r) => onPlacementPreview?.call(r),
                  onCommit: (r) => onPlacementCommit?.call(r),
                ),
                const InspectorSectionDivider(),
              ],
```

(`kInspectorMuted` already exists at the top imports — same constant used by the `_Header` subtitle.)

- [ ] **Step 3: Build the package to confirm it compiles**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`
Expected: no errors. There may be missing-arg errors in `inspector_panel.dart`'s `ZoomContextInspector(...)` call — those are fixed in Task 6.

- [ ] **Step 4: Commit (compile-only checkpoint; Task 6 closes the loop)**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart
git commit -m "feat(zoom): ZoomContextInspector renders Placement section for manual regions"
```

---

## Task 6: Wire the override into `InspectorPanel` and `PlaybackScreen`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

We thread three new props from the playback screen to the inspector and on to `ZoomContextInspector`: `videoSize`, `onPlacementPreview`, `onPlacementCommit`. We also wire the canvas to the override notifier.

- [ ] **Step 1: Thread props through `InspectorPanel`**

Edit `inspector_panel.dart`. Add fields to `InspectorPanel`:

```dart
  /// Video frame size; passed to `ZoomContextInspector` so the
  /// placement picker can render and compute coordinates.
  final Size videoSize;

  /// Live placement preview callback for the zoom context.
  final ValueChanged<Rect>? onPlacementPreview;

  /// Placement commit callback for the zoom context.
  final ValueChanged<Rect>? onPlacementCommit;
```

Add to the constructor (named args):

```dart
    this.videoSize = Size.zero,
    this.onPlacementPreview,
    this.onPlacementCommit,
```

Find the `ZoomContextInspector(...)` call inside `_zoomContext` (around line 152). Add the three new args:

```dart
      videoSize: widget.videoSize,
      onPlacementPreview: widget.onPlacementPreview,
      onPlacementCommit: widget.onPlacementCommit,
```

- [ ] **Step 2: Construct the override notifier in `_PlaybackScreenState`**

Edit `playback_screen.dart`. Add the import:

```dart
import 'package:screen_recorder/state/zoom_preview_override.dart';
```

In `_PlaybackScreenState`, add a field next to the other state fields (search for `int? _selectedZoomIndex;`):

```dart
  final _zoomPreviewOverride = ZoomPreviewOverride();
```

In `dispose`, dispose it:

```dart
  @override
  void dispose() {
    _zoomPreviewOverride.dispose();
    // ...keep existing dispose calls...
    super.dispose();
  }
```

(If `dispose` does not yet exist on `_PlaybackScreenState`, create it with the disposal + a `super.dispose()`.)

- [ ] **Step 3: Clear the override whenever the selection changes**

Locate the two places in `playback_screen.dart` that assign `_selectedZoomIndex` (around lines 342 and 364). Wrap each assignment in a helper:

```dart
  void _setSelectedZoomIndex(int? next) {
    if (next != _selectedZoomIndex) {
      _zoomPreviewOverride.value = null;
    }
    setState(() => _selectedZoomIndex = next);
  }
```

Then replace `setState(() => _selectedZoomIndex = newIndex);` and any other in-place mutations of `_selectedZoomIndex` with `_setSelectedZoomIndex(newIndex)`. There are about a dozen call sites; an `Edit` with `replace_all: true` on the textual pattern is risky because of indentation differences — do them one by one with grep `grep -n "_selectedZoomIndex = " packages/screen_recorder/lib/ui/screens/playback_screen.dart` to enumerate.

For the deletion compaction (around line 1240, `_selectedZoomIndex = _selectedZoomIndex! - 1`), keep the existing in-place mutation but ALSO clear the override there — selection drift after a delete is still a selection change.

- [ ] **Step 4: Add the live-preview + commit handlers**

In `_PlaybackScreenState`, add two methods near `_setSelectedZoomIndex`:

```dart
  void _onPlacementPreview(Rect newRect) {
    final idx = _selectedZoomIndex;
    if (idx == null) return;
    final region = _project.zoomRegions[idx];
    _zoomPreviewOverride.value = region.copyWith(
      rect: newRect,
      videoBounds: _metadata == null
          ? null
          : Size(_metadata!.widthPx.toDouble(), _metadata!.heightPx.toDouble()),
    );
  }

  void _onPlacementCommit(Rect newRect) {
    final idx = _selectedZoomIndex;
    if (idx != null) {
      final region = _project.zoomRegions[idx];
      _projectController.updateZoomAt(
        idx,
        region.copyWith(
          rect: newRect,
          videoBounds: _metadata == null
              ? null
              : Size(_metadata!.widthPx.toDouble(), _metadata!.heightPx.toDouble()),
        ),
      );
    }
    _zoomPreviewOverride.value = null;
  }
```

(`_project` and `_projectController` are the existing fields. `_metadata` is the recording metadata that already exists on the state — confirm the field name with `grep -n "_metadata\b" packages/screen_recorder/lib/ui/screens/playback_screen.dart | head -5`. Adjust if the field is named differently.)

- [ ] **Step 5: Pass the override to the canvas and the callbacks to the inspector**

Find every `PlaybackCanvas(...)` construction in `playback_screen.dart` (`grep -n "PlaybackCanvas(" packages/screen_recorder/lib/ui/screens/playback_screen.dart`). Add to each:

```dart
              zoomPreviewOverride: _zoomPreviewOverride,
```

Find every `InspectorPanel(...)` construction (around lines 925 and 1217). Add to each:

```dart
                      videoSize: _videoSize(),
                      onPlacementPreview: _onPlacementPreview,
                      onPlacementCommit: _onPlacementCommit,
```

If a `_videoSize()` helper does not already exist, add it next to the placement handlers:

```dart
  Size _videoSize() {
    final m = _metadata;
    if (m == null) return Size.zero;
    return Size(m.widthPx.toDouble(), m.heightPx.toDouble());
  }
```

- [ ] **Step 6: Build and test**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/`
Expected: no new errors.

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(zoom): wire placement picker through inspector and playback screen"
```

---

## Task 7: Integration test — selection-change clears the override

**Files:**
- Create: `packages/screen_recorder/test/ui/screens/zoom_placement_selection_clear_test.dart`

We unit-test that changing `_selectedZoomIndex` while the override is set clears the override. Full `PlaybackScreen` wiring is hard to spin up in tests (it pulls in a video controller, Riverpod overrides, the project store). Instead, validate the contract on a small harness state class that mirrors `_setSelectedZoomIndex`'s behaviour, OR on `ZoomPreviewOverride` directly with a manual driver.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/screens/zoom_placement_selection_clear_test.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  test('selection-change helper clears the override', () {
    int? selectedIndex;
    final override = ZoomPreviewOverride();

    void setSelectedIndex(int? next) {
      if (next != selectedIndex) override.value = null;
      selectedIndex = next;
    }

    // Seed: a drag is in flight on region 0.
    selectedIndex = 0;
    override.value = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );
    expect(override.value, isNotNull);

    // User clicks a different region on the timeline.
    setSelectedIndex(1);
    expect(override.value, isNull,
        reason: 'override must clear when selection changes');

    // No-op when the same index is re-asserted.
    override.value = ZoomRegion(
      rect: const Rect.fromLTWH(50, 50, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );
    setSelectedIndex(1);
    expect(override.value, isNotNull,
        reason: 'override stable when index does not change');
  });
}
```

- [ ] **Step 2: Run test to verify the assertions hold**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/screens/zoom_placement_selection_clear_test.dart`
Expected: green. (This is a documentation test of the helper contract — no implementation to add in this task.)

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/test/ui/screens/zoom_placement_selection_clear_test.dart
git commit -m "test(zoom): selection-change clears the placement-preview override"
```

---

## Task 8: Final verification

- [ ] **Step 1: Run the full repo test suite via melos**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos run test --no-select`
Expected: all packages green; same count as before plus the new tests added here (~9 new tests across 4 test files).

- [ ] **Step 2: Static analysis**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos run analyze --no-select`
Expected: only pre-existing info-level findings; zero new warnings.

- [ ] **Step 3: macOS compile check (Swift unaffected, but confirm the host app builds)**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter build macos --debug 2>&1 | tail -5`
Expected: `✓ Built build/macos/Build/Products/Debug/Slipreel.app`. The MEMORY note `[[macos-build-verify-command]]` says plain `flutter build macos` works on Flutter 3.41.5; `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build` is the fallback if fvm-pinned SDK is in play.

- [ ] **Step 4: Manual smoke (real Mac required)**

These are not automated; record results in the merge note:

1. Open a recording in the editor.
2. Add a zoom region via timeline tap.
3. Toggle "Auto-zoom on cursor" OFF in the inspector.
4. Confirm the "Placement" section appears between the region header and "Zoom level".
5. Drag the inner rect — the main canvas should live-preview the framing immediately, including when playback is paused and when it is playing.
6. Release the drag — the region's `rect` is persisted; clicking elsewhere then back onto the region shows the rect at the new center.
7. Click a different zoom region while dragging — preview clears, no stale focal.
8. Toggle "Auto-zoom on cursor" back ON — placement section disappears.

---

## Cross-task wiring summary

| Property/Type | Defined in | Consumed by |
|---|---|---|
| `ZoomPreviewOverride extends ValueNotifier<ZoomRegion?>` | Task 1 | Task 4, Task 6, Task 7 |
| `ZoomPlacementPicker(videoSize, rect, zoomLevel, onPreview, onCommit)` | Task 2 | Task 5 |
| `ScenePassBuilder.build(..., activeRegionOverride)` | Task 3 | Task 4 |
| `ZoomFocalController.update(..., activeRegionOverride)` | Task 3 | Task 3 (internal to ScenePassBuilder) |
| `PlaybackCanvas(zoomPreviewOverride)` | Task 4 | Task 6 |
| `ZoomContextInspector(videoSize, onPlacementPreview, onPlacementCommit)` | Task 5 | Task 6 |
| `InspectorPanel(videoSize, onPlacementPreview, onPlacementCommit)` | Task 6 | Task 6 (consumed at the playback screen) |
