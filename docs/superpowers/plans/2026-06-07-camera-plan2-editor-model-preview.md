# Camera — Plan 2: Editor Model & Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the camera the user recorded in Plan 1 inside the editor — load the `.camera.mov` / `.camera.json` sidecars, seed a first PiP region from the self-view position, render a position-synced camera bubble in the preview with the global look (shape, roundness, mirror, border, shadow, opacity), and let the user place/size it on a camera timeline lane, on the canvas, and in a Camera inspector tab. Export is **out of scope** (Plan 3).

**Architecture:** A new engine layer parallels the zoom-region architecture exactly: `CameraSettings` (global look) lives on `EditorProjectState`; `CameraTrack` / `CameraRegion` live on `Timeline` beside `ZoomTrack`. A pure `CameraPlacementResolver` maps the playhead to an interpolated `CameraPlacement` (or "hidden" in gaps). The editor loads the `.camera.json` (`CameraSidecarMeta`, already shipped in Plan 1), seeds a first region from `selfViewX/Y`, opens a second `VideoPlayerController` on the `.camera.mov` slaved to the main player via `cameraOffsetMicros`, and composites a `CameraBubble` overlay into `PlaybackCanvas` — canvas-fixed (not zoomed), on top of the keystroke layer, exactly where keystrokes already mount. A `CameraLane` (sibling of `ZoomLane`), a real `CameraTab`, a `CameraContextInspector`, and on-canvas drag/resize handles complete the editing surface, all routed through new `EditorProjectController` camera mutators.

**Tech Stack:** Dart/Flutter + Riverpod (`StateNotifier`), `video_player`, the `slipreel_engine` model layer, the existing inspector/timeline widget kit.

**Spec:** `docs/superpowers/specs/2026-06-07-camera-facecam-design.md` (§3 editor model, §4 editor UI, §5 preview rendering, §7 error handling).

**Scope note:** This is Plan 2 of 3. Plan 1 (capture & recording, merged `7ef0cd6`) wrote the aligned sidecars. Plan 3 (export compositing — a second `FfmpegDecoder` camera pass in `FrameCompositor`) is a separate plan; nothing here touches export.

---

## Conventions & locked design decisions

These resolve every ambiguity in the spec. They are binding for this plan.

1. **`CameraRegion` geometry = placement + scale, NOT a stored Rect.** The spec's locked decision is "shape/roundness/style are global; only position/size/visibility are per-region" and "aspect of the rendered frame comes from the global shape." Storing a `Rect` would bake a per-region aspect, contradicting that. So a region stores **`centerX`, `centerY`** (normalized 0..1 in **canvas** space, top-left origin) and **`size`** (bubble width as a fraction of canvas **width**). The rendered bubble's **height is derived at render time** from the global `CameraShape`'s pixel-aspect and the canvas aspect. Changing the global shape instantly re-aspects every region with zero data migration. This is the faithful implementation of the locked decision.

2. **Time model mirrors `ZoomRegion`:** `startTime` + `duration` (microseconds), `endTime => startTime + duration`, half-open `isActive` `[start, end)`. (The spec wrote "startTime/endTime"; start+duration is the codebase convention and makes the lane code identical to the zoom lane.)

3. **Visibility & glide (the `CameraPlacementResolver` contract):**
   - The bubble is visible **iff** the playhead is inside some region. Gaps ⇒ **hidden** (resolver returns `null`).
   - Within a region, placement is **static** at the region's `(centerX, centerY, size)` **except** for a lead-in **glide**: if the immediately-preceding region's `endTime` is within `kCameraGlideJoinTolerance` of this region's `startTime` (i.e. the two regions **touch**), then over the first `glideDuration` of this region the placement **lerps** from the predecessor's placement to this region's, eased by `glideCurve`. This makes "place two touching regions with different spots → the bubble glides bottom-right → top-left."
   - Defaults: `glideDuration = 350ms`, `glideCurve = Curves.easeInOut`, `kCameraGlideJoinTolerance = Duration(milliseconds: 4)` (absorbs rounding from lane snapping).

4. **The camera overlay is canvas-fixed, not zoomed.** Like the keystroke overlay, it mounts on top of the composition, outside the zoom `Transform` and outside the scene-blur `RepaintBoundary`, so a screen zoom-in does not move or smear the PiP. It is threaded through `_buildSceneMotionBlurPass` as a new `cameraOverlayWidget` parallel to `keystrokeOverlayWidget`.

5. **Alignment:** `screen_time = camera_time + cameraOffsetMicros`. So `camera_time = screen_time − offsetMicros`. The second player seeks to `(mainPositionMicros − offsetMicros).clamp(0, cameraDurationMicros)`.

6. **`CameraSettings.enabled`** is the user's master show/hide for the camera in this project (independent of having a sidecar). Default `true`. The Camera inspector **tab** is separately disabled when the recording has **no** `.camera.json` (no sidecar ⇒ nothing to show).

7. **No native, no export here.** Every task is Dart and unit/widget-testable, except the three `playback_screen.dart` / `editor_timeline.dart` integration tasks which finish with `melos analyze` + a manual-verification note (the screen is not unit-tested in this repo). `flutter build macos` is broken in this environment — do **not** rely on it.

8. **Persistence** rides the existing `<videoPath>.editor.json` sidecar via `EditorProjectStore`. New state is additive; schema bumps **v8 → v9**.

9. **Security guardrail (unchanged from Plan 1):** never `git add -A`. Stage only the exact files each task lists. Never commit `.claude/`, `.codex/`, `packages/screen_recorder/devtools_options.yaml`, or the local-only `agent_wires_probe` edits in `packages/screen_recorder/lib/main.dart` / `packages/screen_recorder/pubspec.yaml`.

**Test commands** (per package, run from the package dir):
- `cd packages/slipreel_engine && flutter test test/<path>`
- `cd packages/screen_recorder && flutter test test/<path>`
- Full guard after a phase: `cd packages/slipreel_engine && flutter test` / `cd packages/screen_recorder && flutter test`.

---

## File structure

**New files (engine — `packages/slipreel_engine/`)**
- `lib/models/camera_shape.dart` — `CameraShape` enum + `pixelAspect`.
- `lib/models/camera_settings.dart` — `CameraSettings` (global look).
- `lib/models/camera_region.dart` — `CameraRegion` (placement + scale + time).
- `lib/editor/camera_placement_resolver.dart` — `CameraPlacement` + `CameraPlacementResolver` (glide / gap math).
- `lib/editor/camera_seed.dart` — `cameraSeedRegion(...)` first-region builder.

**Modified files (engine)**
- `lib/timeline/timeline.dart` — `CameraTrack` + `Timeline.cameraTracks` + `activeCameraRegions`.
- `lib/state/editor_project_state.dart` — `cameraSettings`, `cameraRegions` accessor, copyWith/json/`==`/hashCode, schema v9 migration.
- `lib/state/editor_project_controller.dart` — camera mutators.

**New files (app — `packages/screen_recorder/`)**
- `lib/state/camera_playback_sync.dart` — `CameraPlaybackSync` (pure sync math).
- `lib/ui/widgets/camera/camera_bubble.dart` — the rendered (and optionally editable) PiP bubble.
- `lib/ui/widgets/timeline/camera_lane.dart` — the camera timeline lane.
- `lib/ui/widgets/inspector/contexts/camera_context_inspector.dart` — selected-region inspector.

**Modified files (app)**
- `lib/ui/widgets/inspector/timeline_selection.dart` — `CameraSelected`.
- `lib/ui/widgets/inspector/inspector_tab.dart` — enable the Camera tab.
- `lib/ui/widgets/inspector/tabs/camera_tab.dart` — real look controls.
- `lib/ui/widgets/inspector/inspector_panel.dart` — camera context route + params.
- `lib/ui/widgets/zoom/playback_canvas.dart` — camera overlay compositing.
- `lib/ui/widgets/timeline/editor_timeline.dart` — camera lane row + wiring.
- `lib/ui/screens/playback_screen.dart` — sidecar load/seed, second player + sync, selection, callbacks.

---

# Phase A — Engine model & logic (`slipreel_engine`)

Pure Dart, full TDD. This is the foundation; it mirrors the zoom-region model the editor already trusts.

## Task A1: `CameraShape` enum + pixel-aspect helper

**Files:**
- Create: `packages/slipreel_engine/lib/models/camera_shape.dart`
- Test: `packages/slipreel_engine/test/models/camera_shape_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/camera_shape_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_shape.dart';

void main() {
  group('CameraShape.pixelAspect', () {
    test('square and circle are 1:1', () {
      expect(CameraShape.square.pixelAspect(1.7777), 1.0);
      expect(CameraShape.circle.pixelAspect(1.7777), 1.0);
    });
    test('horizontal is 16:9, vertical is 9:16', () {
      expect(CameraShape.horizontal.pixelAspect(1.0), closeTo(16 / 9, 1e-9));
      expect(CameraShape.vertical.pixelAspect(1.0), closeTo(9 / 16, 1e-9));
    });
    test('original passes the source aspect through', () {
      expect(CameraShape.original.pixelAspect(1.3333), closeTo(1.3333, 1e-9));
    });
    test('original falls back to 1.0 for a non-finite/zero source aspect', () {
      expect(CameraShape.original.pixelAspect(0), 1.0);
      expect(CameraShape.original.pixelAspect(double.nan), 1.0);
    });
    test('isRound only for circle', () {
      expect(CameraShape.circle.isRound, isTrue);
      expect(CameraShape.square.isRound, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_shape_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../camera_shape.dart'`.

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/models/camera_shape.dart

/// The crop frame of the camera bubble. Global (not per-region) per the
/// brainstorming decision: every region shares one shape/roundness/style;
/// only position/size/visibility vary per region.
enum CameraShape {
  square,
  horizontal,
  vertical,
  original,
  circle;

  /// Pixel width:height the bubble box should hold for this shape. The
  /// region stores only placement + width; the renderer derives the box
  /// height from this aspect, so changing the shape re-aspects every
  /// region with no data migration.
  ///
  /// [originalAspect] is the source camera's width/height, used only by
  /// [CameraShape.original]; a non-finite or non-positive value falls back
  /// to 1.0 so a missing sidecar never yields a degenerate box.
  double pixelAspect(double originalAspect) {
    switch (this) {
      case CameraShape.square:
      case CameraShape.circle:
        return 1.0;
      case CameraShape.horizontal:
        return 16 / 9;
      case CameraShape.vertical:
        return 9 / 16;
      case CameraShape.original:
        return (originalAspect.isFinite && originalAspect > 0)
            ? originalAspect
            : 1.0;
    }
  }

  /// Circle is always fully round, so the roundness control greys out.
  bool get isRound => this == CameraShape.circle;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_shape_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/camera_shape.dart \
        packages/slipreel_engine/test/models/camera_shape_test.dart
git commit -m "feat(camera): CameraShape enum + pixelAspect helper"
```

---

## Task A2: `CameraSettings` model (global look)

**Files:**
- Create: `packages/slipreel_engine/lib/models/camera_settings.dart`
- Test: `packages/slipreel_engine/test/models/camera_settings_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/camera_settings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';

void main() {
  group('CameraSettings', () {
    test('defaults match the locked brainstorming decisions', () {
      const s = CameraSettings();
      expect(s.enabled, isTrue);
      expect(s.shape, CameraShape.circle);
      expect(s.roundness, 1.0);
      expect(s.mirror, isTrue); // mirror default ON
      expect(s.borderWidth, 0.0);
      expect(s.borderColor, 0xFFFFFFFF);
      expect(s.shadow, isTrue);
      expect(s.opacity, 1.0);
    });

    test('json round-trips', () {
      const s = CameraSettings(
        enabled: false,
        shape: CameraShape.horizontal,
        roundness: 0.3,
        mirror: false,
        borderWidth: 4,
        borderColor: 0xFF112233,
        shadow: false,
        opacity: 0.8,
      );
      expect(CameraSettings.fromJson(s.toJson()), s);
    });

    test('fromJson tolerates missing keys (falls back to defaults)', () {
      final s = CameraSettings.fromJson(const {});
      expect(s, const CameraSettings());
    });

    test('fromJson clamps out-of-range numerics and unknown shape', () {
      final s = CameraSettings.fromJson(const {
        'shape': 'not-a-shape',
        'roundness': 5.0,
        'opacity': -1.0,
        'borderWidth': -3.0,
      });
      expect(s.shape, CameraShape.circle); // fallback
      expect(s.roundness, 1.0);
      expect(s.opacity, 0.0);
      expect(s.borderWidth, 0.0);
    });

    test('copyWith replaces only named fields', () {
      const s = CameraSettings();
      expect(s.copyWith(mirror: false).mirror, isFalse);
      expect(s.copyWith(mirror: false).shape, CameraShape.circle);
    });

    test('equality and hashCode by value', () {
      const a = CameraSettings(opacity: 0.5);
      const b = CameraSettings(opacity: 0.5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const CameraSettings(opacity: 0.6), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_settings_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/models/camera_settings.dart
import 'package:slipreel_engine/models/camera_shape.dart';

/// The global look of the camera bubble for one recording. Stored on
/// `EditorProjectState`; shape/roundness/style are deliberately global
/// (only position/size/visibility live on each `CameraRegion`).
class CameraSettings {
  /// Master show/hide for the camera in this project. Independent of
  /// whether a `.camera.mov` sidecar exists.
  final bool enabled;

  final CameraShape shape;

  /// Corner-radius factor 0..1 for the rectangular shapes. Ignored when
  /// [shape] is [CameraShape.circle] (always fully round).
  final double roundness;

  /// Horizontal flip. Default true — most webcams read more natural
  /// mirrored, matching how the user sees themselves while recording.
  final bool mirror;

  /// Border thickness in canvas pixels (0 = no border).
  final double borderWidth;

  /// Border color as a 32-bit ARGB int (matches `Color.value`).
  final int borderColor;

  final bool shadow;

  /// 0..1 overall opacity of the bubble.
  final double opacity;

  const CameraSettings({
    this.enabled = true,
    this.shape = CameraShape.circle,
    this.roundness = 1.0,
    this.mirror = true,
    this.borderWidth = 0.0,
    this.borderColor = 0xFFFFFFFF,
    this.shadow = true,
    this.opacity = 1.0,
  });

  CameraSettings copyWith({
    bool? enabled,
    CameraShape? shape,
    double? roundness,
    bool? mirror,
    double? borderWidth,
    int? borderColor,
    bool? shadow,
    double? opacity,
  }) =>
      CameraSettings(
        enabled: enabled ?? this.enabled,
        shape: shape ?? this.shape,
        roundness: roundness ?? this.roundness,
        mirror: mirror ?? this.mirror,
        borderWidth: borderWidth ?? this.borderWidth,
        borderColor: borderColor ?? this.borderColor,
        shadow: shadow ?? this.shadow,
        opacity: opacity ?? this.opacity,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'shape': shape.name,
        'roundness': roundness,
        'mirror': mirror,
        'borderWidth': borderWidth,
        'borderColor': borderColor,
        'shadow': shadow,
        'opacity': opacity,
      };

  factory CameraSettings.fromJson(Map<String, dynamic> json) {
    CameraShape shape = CameraShape.circle;
    final raw = json['shape'];
    if (raw is String) {
      for (final s in CameraShape.values) {
        if (s.name == raw) {
          shape = s;
          break;
        }
      }
    }
    double clamp01(Object? v, double fallback) =>
        (v is num && v.isFinite) ? v.toDouble().clamp(0.0, 1.0) : fallback;
    return CameraSettings(
      enabled: json['enabled'] as bool? ?? true,
      shape: shape,
      roundness: clamp01(json['roundness'], 1.0),
      mirror: json['mirror'] as bool? ?? true,
      borderWidth: (json['borderWidth'] is num && (json['borderWidth'] as num).isFinite)
          ? (json['borderWidth'] as num).toDouble().clamp(0.0, 64.0)
          : 0.0,
      borderColor: (json['borderColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      shadow: json['shadow'] as bool? ?? true,
      opacity: clamp01(json['opacity'], 1.0),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraSettings &&
          other.enabled == enabled &&
          other.shape == shape &&
          other.roundness == roundness &&
          other.mirror == mirror &&
          other.borderWidth == borderWidth &&
          other.borderColor == borderColor &&
          other.shadow == shadow &&
          other.opacity == opacity;

  @override
  int get hashCode => Object.hash(enabled, shape, roundness, mirror,
      borderWidth, borderColor, shadow, opacity);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_settings_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/camera_settings.dart \
        packages/slipreel_engine/test/models/camera_settings_test.dart
git commit -m "feat(camera): CameraSettings global-look model"
```

---

## Task A3: `CameraRegion` model (placement + scale + time)

**Files:**
- Create: `packages/slipreel_engine/lib/models/camera_region.dart`
- Test: `packages/slipreel_engine/test/models/camera_region_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/camera_region_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';

void main() {
  group('CameraRegion', () {
    CameraRegion region() => CameraRegion(
          startTime: const Duration(seconds: 1),
          duration: const Duration(seconds: 2),
          centerX: 0.8,
          centerY: 0.75,
          size: 0.22,
        );

    test('endTime is start + duration', () {
      expect(region().endTime, const Duration(seconds: 3));
    });

    test('isActive is half-open [start, end)', () {
      final r = region();
      expect(r.isActive(const Duration(seconds: 1)), isTrue);
      expect(r.isActive(const Duration(milliseconds: 2999)), isTrue);
      expect(r.isActive(const Duration(seconds: 3)), isFalse); // end excluded
      expect(r.isActive(const Duration(milliseconds: 999)), isFalse);
    });

    test('constructor clamps placement into the unit square and size > 0', () {
      final r = CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        centerX: 1.5,
        centerY: -0.2,
        size: 5.0,
      );
      expect(r.centerX, 1.0);
      expect(r.centerY, 0.0);
      expect(r.size, 1.0); // size clamps to (0, 1]
    });

    test('json round-trips', () {
      final r = region();
      expect(CameraRegion.fromJson(r.toJson()), r);
    });

    test('copyWith replaces only named fields', () {
      final r = region();
      expect(r.copyWith(centerX: 0.1).centerX, 0.1);
      expect(r.copyWith(centerX: 0.1).size, 0.22);
    });

    test('equality and hashCode by value', () {
      expect(region(), region());
      expect(region().hashCode, region().hashCode);
      expect(region() == region().copyWith(size: 0.3), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_region_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/models/camera_region.dart

/// One span on the camera timeline lane where the bubble is visible.
///
/// Geometry is **placement + scale**, not a rect: [centerX]/[centerY] are
/// normalized (0..1, top-left origin) positions on the output canvas and
/// [size] is the bubble width as a fraction of canvas width. The rendered
/// height is derived from the GLOBAL `CameraShape`'s pixel-aspect, so the
/// per-region data never encodes aspect (matching the locked decision that
/// shape/roundness/style are global).
///
/// Time mirrors `ZoomRegion`: [startTime] + [duration], half-open
/// `[startTime, endTime)`.
class CameraRegion {
  final Duration startTime;
  final Duration duration;
  final double centerX;
  final double centerY;
  final double size;

  CameraRegion({
    required this.startTime,
    required this.duration,
    required double centerX,
    required double centerY,
    required double size,
  })  : assert(duration > Duration.zero, 'duration must be positive'),
        centerX = centerX.clamp(0.0, 1.0),
        centerY = centerY.clamp(0.0, 1.0),
        // A zero/negative size would render an invisible bubble the user
        // can't grab; clamp to a small floor.
        size = size.clamp(0.02, 1.0);

  Duration get endTime => startTime + duration;

  /// Half-open `[startTime, endTime)` — matches `ZoomRegion.isActive`, so a
  /// shared edge resolves to the later region with no one-frame ambiguity.
  bool isActive(Duration position) =>
      position >= startTime && position < endTime;

  CameraRegion copyWith({
    Duration? startTime,
    Duration? duration,
    double? centerX,
    double? centerY,
    double? size,
  }) =>
      CameraRegion(
        startTime: startTime ?? this.startTime,
        duration: duration ?? this.duration,
        centerX: centerX ?? this.centerX,
        centerY: centerY ?? this.centerY,
        size: size ?? this.size,
      );

  Map<String, dynamic> toJson() => {
        'startTimeMicros': startTime.inMicroseconds,
        'durationMicros': duration.inMicroseconds,
        'centerX': centerX,
        'centerY': centerY,
        'size': size,
      };

  factory CameraRegion.fromJson(Map<String, dynamic> json) => CameraRegion(
        startTime: Duration(microseconds: (json['startTimeMicros'] as num).toInt()),
        duration: Duration(microseconds: (json['durationMicros'] as num).toInt()),
        centerX: (json['centerX'] as num).toDouble(),
        centerY: (json['centerY'] as num).toDouble(),
        size: (json['size'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraRegion &&
          other.startTime == startTime &&
          other.duration == duration &&
          other.centerX == centerX &&
          other.centerY == centerY &&
          other.size == size;

  @override
  int get hashCode =>
      Object.hash(startTime, duration, centerX, centerY, size);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/camera_region_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/camera_region.dart \
        packages/slipreel_engine/test/models/camera_region_test.dart
git commit -m "feat(camera): CameraRegion placement+scale+time model"
```

---

## Task A4: `CameraTrack` + `Timeline.cameraTracks`

Add a `CameraTrack` (wrapper around an ordered `List<CameraRegion>`) and thread it through `Timeline` exactly like `ZoomTrack`.

**Files:**
- Modify: `packages/slipreel_engine/lib/timeline/timeline.dart`
- Test: `packages/slipreel_engine/test/timeline/timeline_camera_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/timeline/timeline_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  CameraRegion region() => CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      );

  group('Timeline.cameraTracks', () {
    test('defaults to no camera tracks; activeCameraRegions is empty', () {
      final t = Timeline.defaults();
      expect(t.cameraTracks, isEmpty);
      expect(t.activeCameraRegions, isEmpty);
    });

    test('activeCameraRegions returns the first track regions', () {
      final t = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      expect(t.activeCameraRegions, hasLength(1));
    });

    test('json round-trips camera tracks alongside zoom + clips', () {
      final t = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      final back = Timeline.fromJson(t.toJson());
      expect(back.activeCameraRegions, [region()]);
      expect(back, t);
    });

    test('fromJson with no cameraTracks key yields an empty list (old sidecar)', () {
      final back = Timeline.fromJson(const {'zoomTracks': [], 'clips': []});
      expect(back.cameraTracks, isEmpty);
    });

    test('equality includes camera tracks', () {
      final a = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      final b = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      expect(a, b);
      expect(a == Timeline.defaults(), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/timeline/timeline_camera_test.dart`
Expected: FAIL — `CameraTrack` / `cameraTracks` undefined.

- [ ] **Step 3: Implement in `timeline.dart`**

a) Add the import at the top, after the `zoom_region.dart` import:
```dart
import 'package:slipreel_engine/models/camera_region.dart';
```

b) Add the `CameraTrack` class directly after the `ZoomTrack` class (after its closing `}` near line 35):
```dart
/// One lane of [CameraRegion]s on the [Timeline]. Parallels [ZoomTrack];
/// today the editor renders only the first camera track.
class CameraTrack {
  const CameraTrack({this.regions = const <CameraRegion>[]});

  final List<CameraRegion> regions;

  CameraTrack copyWith({List<CameraRegion>? regions}) =>
      CameraTrack(regions: regions ?? this.regions);

  Map<String, dynamic> toJson() => {
        'regions': regions.map((r) => r.toJson()).toList(),
      };

  factory CameraTrack.fromJson(Map<String, dynamic> json) {
    final raw = json['regions'];
    final regions = <CameraRegion>[];
    if (raw is List) {
      for (final r in raw) {
        if (r is Map<String, dynamic>) {
          regions.add(CameraRegion.fromJson(r));
        }
      }
    }
    return CameraTrack(regions: List.unmodifiable(regions));
  }
}
```

c) In the `Timeline` constructor, add the field param after `this.clips = const <ClipSlice>[],`:
```dart
    this.cameraTracks = const <CameraTrack>[],
```

d) Add the field declaration after `final List<ClipSlice> clips;`:
```dart
  final List<CameraTrack> cameraTracks;
```

e) Add the accessor after the `activeZoomRegions` getter:
```dart
  /// Regions on the first (active) camera track, or empty when none.
  /// The editor renders against this today.
  List<CameraRegion> get activeCameraRegions =>
      cameraTracks.isEmpty ? const <CameraRegion>[] : cameraTracks.first.regions;
```

f) In `copyWith`, add the param after `List<ClipSlice>? clips,`:
```dart
    List<CameraTrack>? cameraTracks,
```
and in the returned `Timeline(...)` after `clips: clips ?? this.clips,`:
```dart
        cameraTracks: cameraTracks ?? this.cameraTracks,
```

g) In `toJson`, add after the `'clips'` entry:
```dart
        'cameraTracks': cameraTracks.map((t) => t.toJson()).toList(),
```

h) In `fromJson`, after the `clips` block (before the returned `Timeline(...)`), add:
```dart
    final rawCameraTracks = json['cameraTracks'];
    final cameraTracks = <CameraTrack>[];
    if (rawCameraTracks is List) {
      for (final t in rawCameraTracks) {
        if (t is Map<String, dynamic>) {
          cameraTracks.add(CameraTrack.fromJson(t));
        }
      }
    }
```
and in the returned `Timeline(...)` add after `clips: List.unmodifiable(clips),`:
```dart
      cameraTracks: List.unmodifiable(cameraTracks),
```

i) In `operator ==`, add to the `&&` chain (after `_listEq(other.clips, clips)`):
```dart
          && _listEq(other.cameraTracks, cameraTracks)
```

j) In `hashCode`, add `Object.hashAll(cameraTracks)` to the `Object.hash(...)` args:
```dart
  int get hashCode => Object.hash(
        Object.hashAll(zoomTracks),
        Object.hashAll(clips),
        Object.hashAll(cameraTracks),
      );
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/timeline/timeline_camera_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Guard existing timeline tests**

Run: `cd packages/slipreel_engine && flutter test test/timeline/`
Expected: PASS (existing + new).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/timeline/timeline.dart \
        packages/slipreel_engine/test/timeline/timeline_camera_test.dart
git commit -m "feat(camera): CameraTrack + Timeline.cameraTracks"
```

---

## Task A5: `EditorProjectState` — `cameraSettings`, accessor, json, schema v9

Add `cameraSettings` (top-level) and a `cameraRegions` convenience (write-through to the first camera track), bump schema to v9, and add the additive migration.

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_state_camera_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/state/editor_project_state_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  const dur = Duration(seconds: 10);
  CameraRegion region() => CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      );

  group('EditorProjectState camera', () {
    test('defaults: enabled circle look, empty camera regions', () {
      final s = EditorProjectState.defaults();
      expect(s.cameraSettings, const CameraSettings());
      expect(s.cameraRegions, isEmpty);
    });

    test('schemaVersion is 9', () {
      expect(EditorProjectState.currentSchemaVersion, 9);
      expect(EditorProjectState.defaults().toJson()['schemaVersion'], 9);
    });

    test('json round-trips cameraSettings + cameraRegions', () {
      final s = EditorProjectState.defaults().copyWith(
        cameraSettings: const CameraSettings(shape: CameraShape.horizontal),
        cameraRegions: [region()],
      );
      final back = EditorProjectState.fromJson(s.toJson(), videoDuration: dur);
      expect(back.cameraSettings.shape, CameraShape.horizontal);
      expect(back.cameraRegions, [region()]);
    });

    test('copyWith(cameraRegions:) writes through to the first camera track '
        'without disturbing zoom regions or clips', () {
      final base = EditorProjectState.defaults().copyWith(
        timeline: Timeline(
          zoomTracks: const [ZoomTrack()],
          clips: EditorProjectState.defaults().timeline.clips,
          cameraTracks: const [],
        ),
      );
      final next = base.copyWith(cameraRegions: [region()]);
      expect(next.cameraRegions, [region()]);
      expect(next.timeline.clips, base.timeline.clips);
    });

    test('a v8 sidecar (no camera keys) migrates to v9 with defaults', () {
      final v8 = EditorProjectState.defaults().toJson()
        ..['schemaVersion'] = 8
        ..remove('cameraSettings');
      (v8['timeline'] as Map<String, dynamic>).remove('cameraTracks');
      final s = EditorProjectState.fromJson(v8, videoDuration: dur);
      expect(s.cameraSettings, const CameraSettings());
      expect(s.cameraRegions, isEmpty);
    });

    test('equality includes cameraSettings', () {
      final a = EditorProjectState.defaults();
      final b = a.copyWith(
          cameraSettings: const CameraSettings(opacity: 0.5));
      expect(a == b, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_state_camera_test.dart`
Expected: FAIL — `cameraSettings` / `cameraRegions` undefined and `currentSchemaVersion` is 8.

- [ ] **Step 3: Implement in `editor_project_state.dart`**

a) Add imports at the top, after the `zoom_region.dart` import:
```dart
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
```

b) Add the constructor param after `this.keystrokeOverlay = const KeystrokeOverlaySettings(),`:
```dart
    this.cameraSettings = const CameraSettings(),
```

c) In `EditorProjectState.defaults()`, the new field has a const default so no change is needed there.

d) Add the field + accessor after the `keystrokeOverlay` field (near line 143):
```dart
  /// Global camera (facecam) look — shape, roundness, mirror, border,
  /// shadow, opacity, and the master enable. Per-region placement lives
  /// on `timeline.cameraTracks`.
  final CameraSettings cameraSettings;

  /// Convenience read accessor for the active (first) camera track's
  /// regions. Empty when the recording has no camera. Mirrors
  /// [zoomRegions].
  List<CameraRegion> get cameraRegions => timeline.activeCameraRegions;
```

e) Bump the version:
```dart
  static const int currentSchemaVersion = 9;
```

f) Add the two copyWith params after `KeystrokeOverlaySettings? keystrokeOverlay,`:
```dart
    List<CameraRegion>? cameraRegions,
    CameraSettings? cameraSettings,
```

g) Extend the `nextTimeline` computation in `copyWith`. Replace the existing block:
```dart
    final Timeline nextTimeline;
    if (timeline != null) {
      nextTimeline = timeline;
    } else if (zoomRegions != null) {
      final tracks = this.timeline.zoomTracks;
      final existingClips = this.timeline.clips;
      if (tracks.isEmpty) {
        nextTimeline = Timeline(
          zoomTracks: [ZoomTrack(regions: zoomRegions)],
          clips: existingClips,
        );
      } else {
        final updated = List<ZoomTrack>.from(tracks);
        updated[0] = tracks[0].copyWith(regions: zoomRegions);
        nextTimeline = Timeline(zoomTracks: updated, clips: existingClips);
      }
    } else {
      nextTimeline = this.timeline;
    }
```
with this version that also threads `cameraRegions` (preserving cameraTracks through the zoom path and vice versa):
```dart
    final Timeline nextTimeline;
    if (timeline != null) {
      nextTimeline = timeline;
    } else if (zoomRegions != null || cameraRegions != null) {
      var t = this.timeline;
      if (zoomRegions != null) {
        final tracks = t.zoomTracks;
        if (tracks.isEmpty) {
          t = t.copyWith(zoomTracks: [ZoomTrack(regions: zoomRegions)]);
        } else {
          final updated = List<ZoomTrack>.from(tracks)
            ..[0] = tracks[0].copyWith(regions: zoomRegions);
          t = t.copyWith(zoomTracks: updated);
        }
      }
      if (cameraRegions != null) {
        final tracks = t.cameraTracks;
        if (tracks.isEmpty) {
          t = t.copyWith(cameraTracks: [CameraTrack(regions: cameraRegions)]);
        } else {
          final updated = List<CameraTrack>.from(tracks)
            ..[0] = tracks[0].copyWith(regions: cameraRegions);
          t = t.copyWith(cameraTracks: updated);
        }
      }
      nextTimeline = t;
    } else {
      nextTimeline = this.timeline;
    }
```
> Note: `Timeline.copyWith` preserves `clips` (and the other track lists) by default, so the explicit clip-preservation the old zoom branch did by hand is now automatic.

h) In the returned `EditorProjectState(...)` of `copyWith`, add after `keystrokeOverlay: keystrokeOverlay ?? this.keystrokeOverlay,`:
```dart
      cameraSettings: cameraSettings ?? this.cameraSettings,
```

i) In `toJson`, add after `'keystrokeOverlay': keystrokeOverlay.toJson(),`:
```dart
    'cameraSettings': cameraSettings.toJson(),
```
> (Camera **regions** persist via `timeline.toJson()` from Task A4 — no separate key.)

j) In `fromJson`, add to the returned `EditorProjectState(...)` after the `keystrokeOverlay:` argument:
```dart
      cameraSettings: json['cameraSettings'] is Map<String, dynamic>
          ? CameraSettings.fromJson(
              json['cameraSettings'] as Map<String, dynamic>)
          : const CameraSettings(),
```

k) In `operator ==`, add to the chain (after `other.keystrokeOverlay == keystrokeOverlay`):
```dart
        && other.cameraSettings == cameraSettings
```

l) In `hashCode`'s `Object.hashAll([...])`, add `cameraSettings,` after `keystrokeOverlay,`.

m) Add the v8→v9 migration. Append to `_schemaMigrations` (after the existing v7→v8 entry, before the closing `];`):
```dart
  // v8 → v9: add the camera layer — top-level `cameraSettings` and
  // `timeline.cameraTracks`. Additive: fromJson fills CameraSettings
  // defaults and Timeline.fromJson fills an empty camera-track list when
  // the keys are absent, so the migration only bumps the version marker.
  (json, _) => {...json, 'schemaVersion': 9},
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_state_camera_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Guard the whole state suite (migrations are easy to break)**

Run: `cd packages/slipreel_engine && flutter test test/state/`
Expected: PASS. If a pre-existing migration test asserts `currentSchemaVersion == 8`, update it to 9 (the bump is intentional and additive).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_project_state_camera_test.dart
git commit -m "feat(camera): EditorProjectState camera settings/regions + schema v9"
```

---

## Task A6: `EditorProjectController` camera mutators

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_controller_camera_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/state/editor_project_controller_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  CameraRegion region({double cx = 0.8}) => CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        centerX: cx,
        centerY: 0.8,
        size: 0.22,
      );

  group('EditorProjectController camera mutators', () {
    test('setCameraSettings replaces the look', () {
      final c = EditorProjectController();
      c.setCameraSettings(const CameraSettings(shape: CameraShape.vertical));
      expect(c.current.cameraSettings.shape, CameraShape.vertical);
    });

    test('add / update / remove / replace camera regions', () {
      final c = EditorProjectController();
      c.addCameraRegion(region());
      expect(c.current.cameraRegions, hasLength(1));

      c.updateCameraRegionAt(0, region(cx: 0.1));
      expect(c.current.cameraRegions.single.centerX, 0.1);

      c.replaceCameraRegions([region(cx: 0.2), region(cx: 0.3)]);
      expect(c.current.cameraRegions, hasLength(2));

      c.removeCameraRegionAt(0);
      expect(c.current.cameraRegions.single.centerX, 0.3);
    });

    test('out-of-range update/remove are no-ops', () {
      final c = EditorProjectController();
      c.addCameraRegion(region());
      c.updateCameraRegionAt(5, region(cx: 0.1)); // ignored
      c.removeCameraRegionAt(-1); // ignored
      expect(c.current.cameraRegions, hasLength(1));
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_controller_camera_test.dart`
Expected: FAIL — mutators undefined.

- [ ] **Step 3: Implement in `editor_project_controller.dart`**

a) Add the imports at the top, after the `zoom_region.dart` import:
```dart
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
```

b) Add this block after the zoom-region mutators (after `removeZoomAt`, before the `// ---- slice mutators ----` divider):
```dart
  // ---- camera region list + settings ------------------------------------
  //
  // Mirrors the zoom-region mutators: operate on the active (first) camera
  // track, creating it on first write so call sites aren't special-cased.

  void setCameraSettings(CameraSettings settings) {
    if (settings == state.cameraSettings) return;
    state = state.copyWith(cameraSettings: settings);
  }

  List<CameraRegion> _activeCameraRegions() {
    final tracks = state.timeline.cameraTracks;
    return tracks.isEmpty ? const <CameraRegion>[] : tracks.first.regions;
  }

  Timeline _timelineWithActiveCameraRegions(List<CameraRegion> regions) {
    final immutable = List<CameraRegion>.unmodifiable(regions);
    final tracks = state.timeline.cameraTracks;
    if (tracks.isEmpty) {
      return state.timeline.copyWith(
        cameraTracks: [CameraTrack(regions: immutable)],
      );
    }
    final updated = List<CameraTrack>.from(tracks)
      ..[0] = tracks[0].copyWith(regions: immutable);
    return state.timeline.copyWith(cameraTracks: updated);
  }

  void replaceCameraRegions(List<CameraRegion> regions) => state =
      state.copyWith(timeline: _timelineWithActiveCameraRegions(regions));

  void addCameraRegion(CameraRegion region) {
    final next = List<CameraRegion>.from(_activeCameraRegions())..add(region);
    state = state.copyWith(timeline: _timelineWithActiveCameraRegions(next));
  }

  void updateCameraRegionAt(int index, CameraRegion region) {
    final regions = _activeCameraRegions();
    if (index < 0 || index >= regions.length) return;
    final next = List<CameraRegion>.from(regions)..[index] = region;
    state = state.copyWith(timeline: _timelineWithActiveCameraRegions(next));
  }

  void removeCameraRegionAt(int index) {
    final regions = _activeCameraRegions();
    if (index < 0 || index >= regions.length) return;
    final next = List<CameraRegion>.from(regions)..removeAt(index);
    state = state.copyWith(timeline: _timelineWithActiveCameraRegions(next));
  }
```

> `Timeline` and `CameraTrack` are already imported (the file imports `timeline.dart`); `CameraTrack` is exported from there as of Task A4.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_controller_camera_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart \
        packages/slipreel_engine/test/state/editor_project_controller_camera_test.dart
git commit -m "feat(camera): EditorProjectController camera mutators"
```

---

## Task A7: `CameraPlacementResolver` (glide + gap = hidden)

The pure function preview and export both consult: given a playhead and the regions, return the interpolated `CameraPlacement` or `null` (hidden).

**Files:**
- Create: `packages/slipreel_engine/lib/editor/camera_placement_resolver.dart`
- Test: `packages/slipreel_engine/test/editor/camera_placement_resolver_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/editor/camera_placement_resolver_test.dart
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';

void main() {
  CameraRegion r(int startMs, int durMs, double cx) => CameraRegion(
        startTime: Duration(milliseconds: startMs),
        duration: Duration(milliseconds: durMs),
        centerX: cx,
        centerY: 0.8,
        size: 0.22,
      );

  group('CameraPlacementResolver', () {
    test('gap = hidden (null)', () {
      final regions = [r(0, 1000, 0.2)];
      expect(
        CameraPlacementResolver.placementAt(
            const Duration(milliseconds: 1500), regions),
        isNull,
      );
    });

    test('inside an isolated region = static placement', () {
      final regions = [r(0, 1000, 0.2)];
      final p = CameraPlacementResolver.placementAt(
          const Duration(milliseconds: 500), regions)!;
      expect(p.centerX, 0.2);
      expect(p.size, 0.22);
    });

    test('two touching regions glide from predecessor to current', () {
      // region A: [0,1000) cx=0.2 ; region B: [1000,2000) cx=0.8 (touching).
      final regions = [r(0, 1000, 0.2), r(1000, 1000, 0.8)];
      const glide = Duration(milliseconds: 400);

      // At B.start: placement equals A's (cx 0.2).
      final atStart = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000),
        regions,
        glideDuration: glide,
        glideCurve: Curves.linear,
      )!;
      expect(atStart.centerX, closeTo(0.2, 1e-9));

      // Halfway through the glide (linear): midpoint cx 0.5.
      final mid = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1200),
        regions,
        glideDuration: glide,
        glideCurve: Curves.linear,
      )!;
      expect(mid.centerX, closeTo(0.5, 1e-9));

      // After the glide window: B's static cx 0.8.
      final after = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1600),
        regions,
        glideDuration: glide,
        glideCurve: Curves.linear,
      )!;
      expect(after.centerX, closeTo(0.8, 1e-9));
    });

    test('non-touching predecessor (gap before) does not glide', () {
      // A ends at 800, B starts at 1000 — a 200ms gap > tolerance.
      final regions = [r(0, 800, 0.2), r(1000, 1000, 0.8)];
      final p = CameraPlacementResolver.placementAt(
        const Duration(milliseconds: 1000),
        regions,
        glideDuration: const Duration(milliseconds: 400),
      )!;
      expect(p.centerX, closeTo(0.8, 1e-9)); // snaps to B, no glide
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/camera_placement_resolver_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/editor/camera_placement_resolver.dart
import 'package:flutter/animation.dart';

import 'package:slipreel_engine/models/camera_region.dart';

/// The interpolated camera bubble placement at a playhead instant. All
/// values are normalized canvas-space (see [CameraRegion]).
class CameraPlacement {
  const CameraPlacement({
    required this.centerX,
    required this.centerY,
    required this.size,
  });

  final double centerX;
  final double centerY;
  final double size;

  @override
  bool operator ==(Object other) =>
      other is CameraPlacement &&
      other.centerX == centerX &&
      other.centerY == centerY &&
      other.size == size;

  @override
  int get hashCode => Object.hash(centerX, centerY, size);
}

/// Maps a playhead position to a [CameraPlacement], or `null` when the
/// camera is hidden (the playhead is in a gap between regions).
///
/// Within a region the placement is static, EXCEPT a lead-in glide when the
/// immediately-preceding region **touches** this one (their boundary is
/// within [joinTolerance]): over the first [glideDuration] the placement
/// lerps from the predecessor's to this region's, eased by [glideCurve].
/// Shared by the preview ([PlaybackCanvas]) and, in Plan 3, the exporter.
class CameraPlacementResolver {
  const CameraPlacementResolver._();

  static const Duration defaultGlideDuration = Duration(milliseconds: 350);
  static const Duration defaultJoinTolerance = Duration(milliseconds: 4);

  static CameraPlacement? placementAt(
    Duration position,
    List<CameraRegion> regions, {
    Duration glideDuration = defaultGlideDuration,
    Curve glideCurve = Curves.easeInOut,
    Duration joinTolerance = defaultJoinTolerance,
  }) {
    if (regions.isEmpty) return null;

    // Active region (half-open). If none, the camera is hidden.
    CameraRegion? active;
    for (final r in regions) {
      if (r.isActive(position)) {
        active = r;
        break;
      }
    }
    if (active == null) return null;

    final base = CameraPlacement(
      centerX: active.centerX,
      centerY: active.centerY,
      size: active.size,
    );

    if (glideDuration <= Duration.zero) return base;

    // Predecessor = the region with the greatest endTime <= active.startTime.
    CameraRegion? pred;
    for (final r in regions) {
      if (identical(r, active)) continue;
      if (r.endTime <= active.startTime) {
        if (pred == null || r.endTime > pred.endTime) pred = r;
      }
    }
    if (pred == null) return base;

    // Only glide when the predecessor TOUCHES the active region.
    final joinGap = active.startTime - pred.endTime;
    if (joinGap > joinTolerance) return base;

    final into = position - active.startTime;
    if (into >= glideDuration) return base;

    final tRaw = into.inMicroseconds / glideDuration.inMicroseconds;
    final t = glideCurve.transform(tRaw.clamp(0.0, 1.0));
    return CameraPlacement(
      centerX: _lerp(pred.centerX, active.centerX, t),
      centerY: _lerp(pred.centerY, active.centerY, t),
      size: _lerp(pred.size, active.size, t),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/editor/camera_placement_resolver_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/editor/camera_placement_resolver.dart \
        packages/slipreel_engine/test/editor/camera_placement_resolver_test.dart
git commit -m "feat(camera): CameraPlacementResolver (glide + gap=hidden)"
```

---

## Task A8: `cameraSeedRegion` — first-region builder

Builds the seeded region from the self-view position so the bubble lands where the user left it while recording, sized ≈22% of canvas width and pixel-square for the default circle.

**Files:**
- Create: `packages/slipreel_engine/lib/editor/camera_seed.dart`
- Test: `packages/slipreel_engine/test/editor/camera_seed_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/editor/camera_seed_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_seed.dart';

void main() {
  group('cameraSeedRegion', () {
    test('spans the whole video at the self-view position', () {
      final r = cameraSeedRegion(
        videoDuration: const Duration(seconds: 12),
        selfViewX: 0.82,
        selfViewY: 0.78,
      );
      expect(r.startTime, Duration.zero);
      expect(r.duration, const Duration(seconds: 12));
      expect(r.centerX, 0.82);
      expect(r.centerY, 0.78);
      expect(r.size, 0.22);
    });

    test('clamps an off-canvas self-view center into the unit square', () {
      final r = cameraSeedRegion(
        videoDuration: const Duration(seconds: 1),
        selfViewX: 1.4,
        selfViewY: -0.3,
      );
      expect(r.centerX, 1.0);
      expect(r.centerY, 0.0);
    });

    test('honors a custom width fraction', () {
      final r = cameraSeedRegion(
        videoDuration: const Duration(seconds: 1),
        selfViewX: 0.5,
        selfViewY: 0.5,
        widthFraction: 0.3,
      );
      expect(r.size, 0.3);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/camera_seed_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/editor/camera_seed.dart
import 'package:slipreel_engine/models/camera_region.dart';

/// Builds the first camera region for a freshly-opened recording that has a
/// `.camera.json` sidecar but no saved camera regions yet. Mirrors the
/// auto-zoom seeding pattern: the region spans the whole video and is placed
/// at the self-view's final normalized center so the editor bubble starts
/// where the user framed themselves. Saved immediately by the caller so a
/// later delete sticks.
///
/// [widthFraction] is the bubble width as a fraction of canvas width
/// (default 0.22). Height is derived at render time from the global shape,
/// so the seed only carries placement + width.
CameraRegion cameraSeedRegion({
  required Duration videoDuration,
  required double selfViewX,
  required double selfViewY,
  double widthFraction = 0.22,
}) {
  return CameraRegion(
    startTime: Duration.zero,
    duration: videoDuration <= Duration.zero
        ? const Duration(milliseconds: 1)
        : videoDuration,
    centerX: selfViewX,
    centerY: selfViewY,
    size: widthFraction,
  );
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/editor/camera_seed_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Phase A full-suite guard**

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS (all existing + the new camera tests).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/editor/camera_seed.dart \
        packages/slipreel_engine/test/editor/camera_seed_test.dart
git commit -m "feat(camera): cameraSeedRegion first-region builder"
```

---

# Phase B — Selection + sidecar loading/seeding

## Task B1: `CameraSelected` timeline selection

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/timeline_selection.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/timeline_selection_camera_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/timeline_selection_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';

void main() {
  test('CameraSelected is value-equal by index', () {
    expect(const CameraSelected(2), const CameraSelected(2));
    expect(const CameraSelected(2) == const CameraSelected(3), isFalse);
    expect(const CameraSelected(2).hashCode, const CameraSelected(2).hashCode);
  });

  test('CameraSelected is a TimelineSelection distinct from ZoomSelected', () {
    const TimelineSelection sel = CameraSelected(0);
    expect(sel, isA<CameraSelected>());
    expect(sel == const ZoomSelected(0), isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/timeline_selection_camera_test.dart`
Expected: FAIL — `CameraSelected` undefined.

- [ ] **Step 3: Implement** — append to `timeline_selection.dart`:

```dart
/// The user clicked a camera pill. [index] points into the active camera
/// track's regions (so callbacks can mutate the right one).
class CameraSelected extends TimelineSelection {
  const CameraSelected(this.index);
  final int index;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraSelected && other.index == index;

  @override
  int get hashCode => index.hashCode;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/timeline_selection_camera_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/timeline_selection.dart \
        packages/screen_recorder/test/ui/widgets/inspector/timeline_selection_camera_test.dart
git commit -m "feat(camera): CameraSelected timeline selection"
```

---

## Task B2: Load the sidecar + seed the first region (playback_screen)

Detect the `.camera.json` on editor open, expose its meta + movie path, and seed a first camera region when present and the camera track is empty — mirroring the AutoZoomDetector seeding at `playback_screen.dart:596-621`.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

> No automated test — `_PlaybackScreenState` is not unit-tested in this repo. The pure pieces this depends on (`cameraSeedRegion`, `CameraSidecarMeta.loadForVideo`) are already tested. Verify via `melos analyze` + the manual checklist at the end of the plan.

- [ ] **Step 1: Add imports** (top of `playback_screen.dart`, with the other `slipreel_engine` imports):

```dart
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';
import 'package:slipreel_engine/editor/camera_seed.dart';
```

- [ ] **Step 2: Add state fields** near `_metadata` / `_projectStore` (after the `Timer? _saveDebounce;` field near line 332):

```dart
  /// Camera sidecar metadata (`.camera.json`) for this recording, or null
  /// when the recording has no camera. Its presence enables the Camera
  /// inspector tab and the camera lane.
  CameraSidecarMeta? _cameraMeta;

  /// Absolute path of the `.camera.mov` when a camera sidecar exists and the
  /// file is present on disk; null otherwise.
  String? _cameraMoviePath;

  /// Whether this recording has a usable camera sidecar.
  bool get _hasCamera => _cameraMeta != null && _cameraMoviePath != null;
```

- [ ] **Step 3: Load + seed inside `_initializeVideo`.** After the auto-zoom block's closing `}` (the `catch (e) { AppLogger.ui.w('Auto-zoom detection failed...'); }` ends near line 621) and **before** `_projectController.replace(restored);` (line 626), insert:

```dart
      // Camera sidecar: load meta, confirm the movie exists, and seed the
      // first region from the self-view position if none is saved yet
      // (mirrors auto-zoom seeding — the seeded region is saved so a later
      // delete sticks across opens).
      try {
        final meta = await CameraSidecarMeta.loadForVideo(widget.videoPath);
        if (meta != null && meta.frameCount > 0) {
          final moviePath = CameraSidecarMeta.moviePathForVideo(widget.videoPath);
          if (await File(moviePath).exists()) {
            _cameraMeta = meta;
            _cameraMoviePath = moviePath;
            if (restored.cameraRegions.isEmpty) {
              final seed = cameraSeedRegion(
                videoDuration: _controller.value.duration,
                selfViewX: meta.selfViewX,
                selfViewY: meta.selfViewY,
              );
              restored = restored.copyWith(cameraRegions: [seed]);
              await _projectStore.save(restored);
            }
          } else {
            AppLogger.ui.w(
              'Camera sidecar meta present but .camera.mov missing at '
              '$moviePath — opening editor without camera.',
            );
          }
        }
      } catch (e) {
        AppLogger.ui.w('Camera sidecar load failed; editor opens without camera: $e');
      }
```

> `File` and `AppLogger` are already imported in this file (used by `_initializeVideo`). `restored` is the local `EditorProjectState` already in scope.

- [ ] **Step 4: Analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/playback_screen.dart`
Expected: No new issues (pre-existing warnings unrelated to camera are acceptable — confirm none reference the new code).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(camera): load .camera sidecar + seed first region on editor open"
```

---

# Phase C — Preview rendering

## Task C1: `CameraPlaybackSync` — pure two-player sync math

The decision logic that slaves the camera player to the main player: the desired camera position (apply offset, clamp) and whether the drift warrants a seek.

**Files:**
- Create: `packages/screen_recorder/lib/state/camera_playback_sync.dart`
- Test: `packages/screen_recorder/test/state/camera_playback_sync_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/camera_playback_sync_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/camera_playback_sync.dart';

void main() {
  group('CameraPlaybackSync', () {
    test('desired camera position = main − offset, clamped to [0, camDur]', () {
      const dur = Duration(seconds: 10);
      // offset +200ms: screen_time = camera_time + 200ms ⇒ camera lags.
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(seconds: 2),
          offsetMicros: 200000,
          cameraDuration: dur,
        ),
        const Duration(milliseconds: 1800),
      );
    });

    test('clamps below zero and beyond camera duration', () {
      const dur = Duration(seconds: 5);
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(milliseconds: 100),
          offsetMicros: 500000,
          cameraDuration: dur,
        ),
        Duration.zero,
      );
      expect(
        CameraPlaybackSync.desiredCameraPosition(
          mainPosition: const Duration(seconds: 9),
          offsetMicros: 0,
          cameraDuration: dur,
        ),
        dur,
      );
    });

    test('shouldSeek only when drift exceeds threshold', () {
      expect(
        CameraPlaybackSync.shouldSeek(
          current: const Duration(seconds: 2),
          desired: const Duration(milliseconds: 2010),
          threshold: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
      expect(
        CameraPlaybackSync.shouldSeek(
          current: const Duration(seconds: 2),
          desired: const Duration(milliseconds: 2200),
          threshold: const Duration(milliseconds: 50),
        ),
        isTrue,
      );
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/camera_playback_sync_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/state/camera_playback_sync.dart

/// Pure helpers that slave the camera `.camera.mov` player to the main
/// screen player. `screen_time = camera_time + offsetMicros`, so the camera
/// position for a given screen playhead is `main − offset`, clamped to the
/// camera's own duration.
class CameraPlaybackSync {
  const CameraPlaybackSync._();

  /// Default re-seek threshold. Below this drift the two players are
  /// considered in sync (video_player position granularity is ~frame-level,
  /// so a small tolerance avoids thrashing seeks every tick).
  static const Duration defaultThreshold = Duration(milliseconds: 60);

  static Duration desiredCameraPosition({
    required Duration mainPosition,
    required int offsetMicros,
    required Duration cameraDuration,
  }) {
    final raw = mainPosition.inMicroseconds - offsetMicros;
    final clamped = raw < 0
        ? 0
        : (raw > cameraDuration.inMicroseconds
            ? cameraDuration.inMicroseconds
            : raw);
    return Duration(microseconds: clamped);
  }

  static bool shouldSeek({
    required Duration current,
    required Duration desired,
    Duration threshold = defaultThreshold,
  }) {
    final drift = (current.inMicroseconds - desired.inMicroseconds).abs();
    return drift > threshold.inMicroseconds;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/camera_playback_sync_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/camera_playback_sync.dart \
        packages/screen_recorder/test/state/camera_playback_sync_test.dart
git commit -m "feat(camera): CameraPlaybackSync pure sync math"
```

---

## Task C2: `CameraBubble` widget (render + optional on-canvas edit)

Renders the camera frame at a normalized placement with the global look (shape clip, roundness, mirror, border, shadow, opacity). When `selected` and `onPlacementChanged` are provided, the bubble is draggable (move) with four corner resize handles, reporting a new normalized `CameraPlacement`.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/camera/camera_bubble.dart`
- Test: `packages/screen_recorder/test/ui/widgets/camera/camera_bubble_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/camera/camera_bubble_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:screen_recorder/ui/widgets/camera/camera_bubble.dart';

void main() {
  Widget host(CameraBubble bubble) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 800, height: 450, child: bubble),
          ),
        ),
      );

  const placement = CameraPlacement(centerX: 0.8, centerY: 0.8, size: 0.25);

  testWidgets('positions the bubble box from the placement + canvas size',
      (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(shape: CameraShape.square),
      child: const ColoredBox(color: Colors.red),
    )));
    final box = tester.getSize(find.byKey(const Key('camera-bubble-box')));
    // width = size * canvasW = 0.25 * 800 = 200; square ⇒ height 200.
    expect(box.width, closeTo(200, 0.5));
    expect(box.height, closeTo(200, 0.5));
  });

  testWidgets('circle shape clips with ClipOval; rectangular uses ClipRRect',
      (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(shape: CameraShape.circle),
      child: const ColoredBox(color: Colors.red),
    )));
    expect(find.byType(ClipOval), findsOneWidget);
  });

  testWidgets('opacity wraps the bubble', (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(opacity: 0.5),
      child: const ColoredBox(color: Colors.red),
    )));
    final op = tester.widget<Opacity>(find.byKey(const Key('camera-bubble-opacity')));
    expect(op.opacity, 0.5);
  });

  testWidgets('shows resize handles only when selected & editable',
      (tester) async {
    await tester.pumpWidget(host(CameraBubble(
      canvasSize: const Size(800, 450),
      placement: placement,
      settings: const CameraSettings(),
      selected: true,
      onPlacementChanged: (_) {},
      child: const ColoredBox(color: Colors.red),
    )));
    expect(find.byKey(const Key('camera-handle-br')), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/camera/camera_bubble_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/widgets/camera/camera_bubble.dart
import 'package:flutter/material.dart';

import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';

/// The camera PiP bubble, laid out in CANVAS coordinate space (the same
/// `totalSize` space `PlaybackCanvas` composes in). Given a normalized
/// [placement] it computes the pixel box (width from `placement.size`,
/// height derived from the global [settings.shape]'s pixel-aspect), then
/// applies mirror → shape clip + roundness → border → shadow → opacity to
/// the [child] (a `VideoPlayer`, or any widget in tests).
///
/// When [selected] is true AND [onPlacementChanged] is non-null the bubble
/// is interactive: drag the body to move (reports new centerX/centerY) and
/// drag a corner handle to resize (reports new size). All deltas are
/// converted back to normalized canvas space using [canvasSize].
class CameraBubble extends StatelessWidget {
  const CameraBubble({
    super.key,
    required this.canvasSize,
    required this.placement,
    required this.settings,
    required this.child,
    this.originalAspect = 1.0,
    this.selected = false,
    this.onPlacementChanged,
  });

  /// The canvas (`totalSize`) this bubble is positioned within.
  final Size canvasSize;
  final CameraPlacement placement;
  final CameraSettings settings;

  /// The camera source's width/height; used only when shape == original.
  final double originalAspect;

  final Widget child;
  final bool selected;

  /// When non-null and [selected], the bubble is editable; called with the
  /// new normalized placement during drag/resize.
  final ValueChanged<CameraPlacement>? onPlacementChanged;

  static const double _minSize = 0.05;
  static const double _maxSize = 1.2;

  Rect _pixelBox() {
    final w = (placement.size * canvasSize.width);
    final aspect = settings.shape.pixelAspect(originalAspect);
    final h = w / aspect;
    final cx = placement.centerX * canvasSize.width;
    final cy = placement.centerY * canvasSize.height;
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
  }

  bool get _editable => selected && onPlacementChanged != null;

  @override
  Widget build(BuildContext context) {
    final box = _pixelBox();

    Widget framed = SizedBox(
      key: const Key('camera-bubble-box'),
      width: box.width,
      height: box.height,
      child: _clipped(child),
    );

    // Mirror (horizontal flip) around the box center. diagonal3Values(-1,1,1)
    // scales x by -1 → a horizontal flip in place with alignment center.
    if (settings.mirror) {
      framed = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: framed,
      );
    }

    // Border + shadow live on a container sized to the box, behind the clip.
    Widget decorated = framed;
    if (settings.borderWidth > 0 || settings.shadow) {
      decorated = Container(
        width: box.width,
        height: box.height,
        decoration: BoxDecoration(
          shape: settings.shape.isRound ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: settings.shape.isRound
              ? null
              : BorderRadius.circular(_cornerRadius(box)),
          border: settings.borderWidth > 0
              ? Border.all(
                  color: Color(settings.borderColor),
                  width: settings.borderWidth,
                )
              : null,
          boxShadow: settings.shadow
              ? const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: framed,
      );
    }

    Widget bubble = Opacity(
      key: const Key('camera-bubble-opacity'),
      opacity: settings.opacity.clamp(0.0, 1.0),
      child: decorated,
    );

    if (_editable) {
      bubble = _withEditAffordances(bubble, box);
    }

    // Self-contained: the bubble fills the canvas and positions its box in an
    // internal Stack, so it can be dropped straight into PlaybackCanvas (or a
    // test) without the caller providing a Stack.
    return SizedBox(
      width: canvasSize.width,
      height: canvasSize.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: box.left, top: box.top, child: bubble),
        ],
      ),
    );
  }

  Widget _clipped(Widget c) {
    final fitted = FittedBox(fit: BoxFit.cover, child: c);
    if (settings.shape.isRound) {
      return ClipOval(child: fitted);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(_cornerRadiusFor(placement.size)),
      child: fitted,
    );
  }

  double _cornerRadius(Rect box) {
    if (settings.shape.isRound) return box.shortestSide / 2;
    return settings.roundness.clamp(0.0, 1.0) * (box.shortestSide / 2);
  }

  // Roundness in normalized terms for the clip (uses the smaller pixel side).
  double _cornerRadiusFor(double size) {
    final w = size * canvasSize.width;
    final aspect = settings.shape.pixelAspect(originalAspect);
    final h = w / aspect;
    final shortest = w < h ? w : h;
    return settings.roundness.clamp(0.0, 1.0) * (shortest / 2);
  }

  Widget _withEditAffordances(Widget bubble, Rect box) {
    const handle = 16.0;
    Widget cornerHandle(String id, Alignment a) => Positioned(
          left: a.x < 0 ? -handle / 2 : null,
          right: a.x > 0 ? -handle / 2 : null,
          top: a.y < 0 ? -handle / 2 : null,
          bottom: a.y > 0 ? -handle / 2 : null,
          child: GestureDetector(
            key: Key('camera-handle-$id'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => _resizeBy(d.delta, a),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: Container(
                width: handle,
                height: handle,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF6C63FF), width: 2),
                ),
              ),
            ),
          ),
        );

    return SizedBox(
      width: box.width,
      height: box.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Move handle = the body.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => _moveBy(d.delta),
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: bubble,
            ),
          ),
          // A thin selection ring for affordance.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape:
                      settings.shape.isRound ? BoxShape.circle : BoxShape.rectangle,
                  border: Border.all(color: const Color(0xFF6C63FF), width: 1.5),
                ),
              ),
            ),
          ),
          cornerHandle('tl', Alignment.topLeft),
          cornerHandle('tr', Alignment.topRight),
          cornerHandle('bl', Alignment.bottomLeft),
          cornerHandle('br', Alignment.bottomRight),
        ],
      ),
    );
  }

  void _moveBy(Offset deltaPx) {
    final cb = onPlacementChanged;
    if (cb == null) return;
    final dx = deltaPx.dx / canvasSize.width;
    final dy = deltaPx.dy / canvasSize.height;
    cb(CameraPlacement(
      centerX: (placement.centerX + dx).clamp(0.0, 1.0),
      centerY: (placement.centerY + dy).clamp(0.0, 1.0),
      size: placement.size,
    ));
  }

  void _resizeBy(Offset deltaPx, Alignment corner) {
    final cb = onPlacementChanged;
    if (cb == null) return;
    // Dragging a corner outward (away from center) grows the box. Project the
    // drag onto the outward diagonal of this corner and convert to a width
    // fraction of canvas width.
    final outward = (deltaPx.dx * corner.x + deltaPx.dy * corner.y);
    final dSize = outward / canvasSize.width;
    cb(CameraPlacement(
      centerX: placement.centerX,
      centerY: placement.centerY,
      size: (placement.size + dSize).clamp(_minSize, _maxSize),
    ));
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/camera/camera_bubble_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/camera/camera_bubble.dart \
        packages/screen_recorder/test/ui/widgets/camera/camera_bubble_test.dart
git commit -m "feat(camera): CameraBubble render + on-canvas drag/resize"
```

---

## Task C3: Composite the camera overlay into `PlaybackCanvas`

Add camera inputs to `PlaybackCanvas` and render the `CameraBubble` as a top, canvas-fixed (un-zoomed, un-smeared) overlay — exactly where the keystroke overlay mounts.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
- Test: `packages/screen_recorder/test/ui/widgets/zoom/playback_canvas_camera_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/zoom/playback_canvas_camera_test.dart
//
// Smoke test for the camera overlay gate: the canvas builds a CameraBubble
// when a controller + active region exist, and omits it otherwise. We can't
// initialize a real VideoPlayerController in a unit test, so we drive the
// gate via the pure `cameraOverlayBuilder` seam (see implementation).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';

void main() {
  test('cameraPlacementForTest returns null in a gap and a placement inside', () {
    final regions = [
      CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      ),
    ];
    expect(
      cameraPlacementForTest(const Duration(milliseconds: 500), regions, true),
      isA<CameraPlacement>(),
    );
    expect(
      cameraPlacementForTest(const Duration(milliseconds: 1500), regions, true),
      isNull,
    );
    // Disabled settings ⇒ always hidden.
    expect(
      cameraPlacementForTest(const Duration(milliseconds: 500), regions, false),
      isNull,
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/playback_canvas_camera_test.dart`
Expected: FAIL — `cameraPlacementForTest` undefined.

- [ ] **Step 3: Implement in `playback_canvas.dart`**

a) Add imports at the top (with the other engine imports):
```dart
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:screen_recorder/ui/widgets/camera/camera_bubble.dart';
```

b) Add the test seam — a top-level function near `cameraFocalTraceEnabled` (around line 62):
```dart
/// Pure gate used by the canvas (and a unit test) to resolve the camera
/// placement at a playhead. Returns null when the camera is disabled or the
/// playhead sits in a gap between regions.
CameraPlacement? cameraPlacementForTest(
  Duration position,
  List<CameraRegion> regions,
  bool enabled,
) {
  if (!enabled) return null;
  return CameraPlacementResolver.placementAt(position, regions);
}
```

c) Add constructor params (in the `const PlaybackCanvas({...})` list, after `this.keystrokeOverlaySettings,`):
```dart
    this.cameraController,
    this.cameraSettings,
    this.cameraRegions = const [],
    this.cameraOriginalAspect = 1.0,
    this.selectedCameraIndex,
    this.onCameraPlacementChanged,
```

d) Add the field declarations (after the keystroke fields near line 257):
```dart
  /// Second player for `<recording>.camera.mov`, position-synced upstream by
  /// the playback screen. Null when the recording has no camera.
  final VideoPlayerController? cameraController;

  /// Global camera look. Null ⇒ no camera overlay.
  final CameraSettings? cameraSettings;

  /// Camera regions (active track). Drives bubble visibility + placement.
  final List<CameraRegion> cameraRegions;

  /// Source camera width/height; used when the shape is "original".
  final double cameraOriginalAspect;

  /// Selected camera region (enables on-canvas drag/resize) or null.
  final int? selectedCameraIndex;

  /// Called with the edited region's new placement during on-canvas
  /// drag/resize. Null in pure-playback callers.
  final void Function(int index, CameraPlacement placement)?
      onCameraPlacementChanged;
```

e) Build the overlay inside the per-frame `builder` of the main `AnimatedBuilder`. Right after the `keystrokeOverlayWidget` block (ends near line 640, before the `// Wallpaper is rendered...` comment), add:

```dart
            // Camera PiP overlay — canvas-fixed (NOT zoomed) and outside the
            // scene-blur capture, exactly like the keystroke overlay. Drawn
            // on top of everything. Hidden in gaps / when disabled / when no
            // camera player is attached.
            Widget? cameraOverlayWidget;
            final camSettings = widget.cameraSettings;
            final camController = widget.cameraController;
            if (camSettings != null &&
                camSettings.enabled &&
                camController != null &&
                camController.value.isInitialized &&
                widget.cameraRegions.isNotEmpty) {
              final placement = CameraPlacementResolver.placementAt(
                pos,
                widget.cameraRegions,
              );
              if (placement != null) {
                // Which region is active at pos (for the edit callback index).
                int? activeIndex;
                for (var i = 0; i < widget.cameraRegions.length; i++) {
                  if (widget.cameraRegions[i].isActive(pos)) {
                    activeIndex = i;
                    break;
                  }
                }
                final editable = activeIndex != null &&
                    activeIndex == widget.selectedCameraIndex &&
                    widget.onCameraPlacementChanged != null;
                // CameraBubble fills the canvas and positions its own box, so
                // it drops straight in as a sibling overlay (canvas-fixed).
                cameraOverlayWidget = CameraBubble(
                  canvasSize: totalSize,
                  placement: placement,
                  settings: camSettings,
                  originalAspect: widget.cameraOriginalAspect,
                  selected: editable,
                  onPlacementChanged: editable
                      ? (p) => widget.onCameraPlacementChanged!(activeIndex!, p)
                      : null,
                  child: VideoPlayer(camController),
                );
              }
            }
```

f) Thread it through `_buildSceneMotionBlurPass`. Add the param to the method signature (after `Widget? keystrokeOverlayWidget,`):
```dart
    Widget? cameraOverlayWidget,
```
In the early-return `bodyWithCursor()` layer list, add after the keystroke entry:
```dart
        if (cameraOverlayWidget != null) cameraOverlayWidget,
```
In the final `Stack(...)` children (the scene-pass branch), add after the keystroke entry (`if (keystrokeOverlayWidget != null) keystrokeOverlayWidget,`):
```dart
        if (cameraOverlayWidget != null) cameraOverlayWidget,
```

g) Pass it at the three `_buildSceneMotionBlurPass(...)` call sites. In the `if (focalUpdate == null)` early-return call, and in the zoomed return call, add the argument after `keystrokeOverlayWidget: keystrokeOverlayWidget,`:
```dart
                cameraOverlayWidget: cameraOverlayWidget,
```

> The camera overlay is intentionally NOT wrapped by the zoom `Transform` (it's passed as a sibling like keystrokes), so it stays anchored in canvas space while the screen zooms.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/playback_canvas_camera_test.dart`
Expected: PASS (1 test).

- [ ] **Step 5: Guard the canvas/zoom widget tests**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/`
Expected: PASS (existing canvas tests unaffected — the new params are optional with defaults).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart \
        packages/screen_recorder/test/ui/widgets/zoom/playback_canvas_camera_test.dart
git commit -m "feat(camera): composite camera bubble overlay in PlaybackCanvas"
```

---

## Task C4: Second player lifecycle + sync + wire into the canvas (playback_screen)

Open a `VideoPlayerController` on the `.camera.mov`, slave it to the main player via `CameraPlaybackSync`, pass it (+ settings/regions/selection) into `PlaybackCanvas`, and dispose it.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

> Integration task; verify via `melos analyze` + manual checklist. The sync math (C1) and placement (A7) are unit-tested.

- [ ] **Step 1: Add imports** (with the other app imports):
```dart
import 'package:screen_recorder/state/camera_playback_sync.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
```

- [ ] **Step 2: Add state fields** near `_cameraMeta` (Task B2):
```dart
  /// Second player for the camera sidecar, slaved to [_controller]. Null
  /// until a camera sidecar is confirmed and initialized.
  VideoPlayerController? _cameraController;

  /// Selected camera region index, or null. Mutually exclusive with
  /// [_selectedZoomIndex] / [_selectedSliceIndex].
  int? _selectedCameraIndex;
```

- [ ] **Step 3: Create + sync the camera player.** In `_initializeVideo`, after the `setState(() { _isInitialized = true; ... })` block (around line 643), add:

```dart
      // Bring up the camera player (if any) and slave it to the main one.
      if (_hasCamera) {
        await _initCameraPlayer();
      }
```

Then add these methods (near `_initializeVideo`):

```dart
  Future<void> _initCameraPlayer() async {
    final path = _cameraMoviePath;
    if (path == null) return;
    try {
      final cam = VideoPlayerController.file(File(path));
      await cam.initialize();
      await cam.setVolume(0); // camera track carries no audio; be safe
      _cameraController = cam;
      // Slave play/pause + position to the main controller.
      _controller.addListener(_syncCameraPlayer);
      _syncCameraPlayer();
      if (mounted) setState(() {});
    } catch (e) {
      AppLogger.ui.w('Camera player init failed; camera hidden in editor: $e');
      _cameraController = null;
    }
  }

  void _syncCameraPlayer() {
    final cam = _cameraController;
    final meta = _cameraMeta;
    if (cam == null || meta == null || !cam.value.isInitialized) return;
    // Mirror play/pause.
    if (_controller.value.isPlaying && !cam.value.isPlaying) {
      cam.play();
    } else if (!_controller.value.isPlaying && cam.value.isPlaying) {
      cam.pause();
    }
    // Re-seek on drift.
    final desired = CameraPlaybackSync.desiredCameraPosition(
      mainPosition: _controller.value.position,
      offsetMicros: meta.offsetMicros,
      cameraDuration: cam.value.duration,
    );
    if (CameraPlaybackSync.shouldSeek(
      current: cam.value.position,
      desired: desired,
    )) {
      cam.seekTo(desired);
    }
  }
```

- [ ] **Step 4: Dispose** — in `dispose()` (around line 799), after `_smoothPlayhead?.dispose();` and before/after `_controller.dispose();`, add:
```dart
    _controller.removeListener(_syncCameraPlayer);
    _cameraController?.dispose();
```

- [ ] **Step 5: Pass camera inputs into `PlaybackCanvas`.** In the `PlaybackCanvas(...)` construction (around line 2085), add after `keystrokeOverlaySettings: project.keystrokeOverlay,`:
```dart
      cameraController: _cameraController,
      cameraSettings: _hasCamera ? project.cameraSettings : null,
      cameraRegions: _hasCamera ? project.cameraRegions : const [],
      cameraOriginalAspect: _cameraMeta == null || _cameraMeta!.height == 0
          ? 1.0
          : _cameraMeta!.width / _cameraMeta!.height,
      selectedCameraIndex: _selectedCameraIndex,
      onCameraPlacementChanged: (index, placement) {
        final regions = _project.cameraRegions;
        if (index < 0 || index >= regions.length) return;
        _projectController.updateCameraRegionAt(
          index,
          regions[index].copyWith(
            centerX: placement.centerX,
            centerY: placement.centerY,
            size: placement.size,
          ),
        );
      },
```

> `CameraPlacement` is imported (Step 1) so the callback type resolves. `project` is the `ref.watch`'d state already in scope at this call site (used by the surrounding canvas args).

- [ ] **Step 6: Analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/playback_screen.dart`
Expected: no new issues from the camera code.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(camera): second player lifecycle + sync + canvas wiring"
```

---

# Phase D — Editor UI: Camera tab, context inspector, lane

## Task D1: Real Camera inspector tab (global look controls)

Replace the `CameraTab` placeholder with controls bound to `cameraSettings`, enable the rail tab, and disable it when the recording has no camera.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_tab.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/camera_tab.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/camera_tab_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/camera_tab_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/camera_tab.dart';

void main() {
  Widget host(EditorProjectController controller, {bool hasCamera = true}) =>
      ProviderScope(
        overrides: [
          editorProjectControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          home: Scaffold(body: CameraTab(hasCamera: hasCamera)),
        ),
      );

  testWidgets('no sidecar ⇒ shows the disabled placeholder', (tester) async {
    await tester.pumpWidget(host(EditorProjectController(), hasCamera: false));
    expect(find.textContaining('No camera'), findsOneWidget);
  });

  testWidgets('toggling Mirror writes through to cameraSettings',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(host(c));
    expect(c.current.cameraSettings.mirror, isTrue);
    await tester.tap(find.byKey(const Key('camera-mirror-toggle')));
    await tester.pump();
    expect(c.current.cameraSettings.mirror, isFalse);
  });

  testWidgets('selecting a shape chip updates the shape', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(host(c));
    await tester.tap(find.text('Horizontal'));
    await tester.pump();
    expect(c.current.cameraSettings.shape, CameraShape.horizontal);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/camera_tab_test.dart`
Expected: FAIL — `CameraTab` takes no `hasCamera`, and the keys don't exist.

- [ ] **Step 3: Enable the rail tab** in `inspector_tab.dart`:
```dart
  camera(icon: Icons.account_box_outlined, label: 'Camera', isEnabled: true),
```

- [ ] **Step 4: Rewrite `camera_tab.dart`**

```dart
// packages/screen_recorder/lib/ui/widgets/inspector/tabs/camera_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Global camera look controls. Reads/writes `cameraSettings` on the editor
/// notifier. Shows a disabled placeholder when the recording has no camera
/// sidecar.
class CameraTab extends ConsumerWidget {
  const CameraTab({super.key, this.hasCamera = false});

  /// Whether this recording has a `.camera.mov` sidecar. When false the tab
  /// is informational only.
  final bool hasCamera;

  static const _shapes = <(CameraShape, String)>[
    (CameraShape.circle, 'Circle'),
    (CameraShape.square, 'Square'),
    (CameraShape.horizontal, 'Horizontal'),
    (CameraShape.vertical, 'Vertical'),
    (CameraShape.original, 'Original'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasCamera) {
      return const InspectorPlaceholder(
        icon: Icons.account_box_outlined,
        title: 'No camera in this recording',
        body: 'Turn on the camera chip in the recording bar before you '
            'record to capture a webcam track. It will appear here as a '
            'picture-in-picture bubble you can place and style.',
      );
    }

    final settings = ref.watch(
      editorProjectControllerProvider.select((s) => s.cameraSettings),
    );
    final controller = ref.read(editorProjectControllerProvider.notifier);
    void update(CameraSettings next) => controller.setCameraSettings(next);

    return ListView(
      padding: const EdgeInsets.only(right: 12),
      children: [
        InspectorToggle(
          key: const Key('camera-enable-toggle'),
          label: 'Show camera',
          subtitle: 'Composite the webcam bubble in the preview and export.',
          value: settings.enabled,
          onChanged: (v) => update(settings.copyWith(enabled: v)),
        ),
        const InspectorSectionDivider(),
        const InspectorSectionLabel('Shape'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (shape, label) in _shapes)
              InspectorChip(
                label: label,
                selected: settings.shape == shape,
                onTap: () => update(settings.copyWith(shape: shape)),
                dense: true,
              ),
          ],
        ),
        const SizedBox(height: 20),
        // Roundness greys out for Circle (always fully round).
        Opacity(
          opacity: settings.shape.isRound ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: settings.shape.isRound,
            child: InspectorSlider(
              label: 'Roundness',
              subtitle: settings.shape.isRound
                  ? 'Circle is always fully round.'
                  : '${(settings.roundness * 100).round()}% corner radius',
              value: settings.roundness,
              min: 0,
              max: 1,
              onChanged: (v) => update(settings.copyWith(roundness: v)),
              onReset: () => update(settings.copyWith(roundness: 1.0)),
              canReset: settings.roundness != 1.0,
            ),
          ),
        ),
        const InspectorSectionDivider(),
        InspectorToggle(
          key: const Key('camera-mirror-toggle'),
          label: 'Mirror',
          subtitle: 'Flip horizontally (most webcams read more natural '
              'mirrored).',
          value: settings.mirror,
          onChanged: (v) => update(settings.copyWith(mirror: v)),
        ),
        const SizedBox(height: 16),
        InspectorToggle(
          label: 'Shadow',
          subtitle: 'Soft drop shadow under the bubble.',
          value: settings.shadow,
          onChanged: (v) => update(settings.copyWith(shadow: v)),
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Border width',
          subtitle: settings.borderWidth <= 0
              ? 'No border'
              : '${settings.borderWidth.round()} px',
          value: settings.borderWidth,
          min: 0,
          max: 16,
          onChanged: (v) => update(settings.copyWith(borderWidth: v)),
          onReset: () => update(settings.copyWith(borderWidth: 0)),
          canReset: settings.borderWidth != 0,
        ),
        const SizedBox(height: 16),
        _BorderColorRow(
          selected: settings.borderColor,
          onPick: (c) => update(settings.copyWith(borderColor: c)),
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Opacity',
          subtitle: '${(settings.opacity * 100).round()}%',
          value: settings.opacity,
          min: 0.2,
          max: 1,
          onChanged: (v) => update(settings.copyWith(opacity: v)),
          onReset: () => update(settings.copyWith(opacity: 1.0)),
          canReset: settings.opacity != 1.0,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _BorderColorRow extends StatelessWidget {
  const _BorderColorRow({required this.selected, required this.onPick});
  final int selected;
  final ValueChanged<int> onPick;

  static const _swatches = <int>[
    0xFFFFFFFF, 0xFF000000, 0xFF6C63FF, 0xFFE53935, 0xFF43A047, 0xFFFB8C00,
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Border color',
            style: TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in _swatches)
              GestureDetector(
                onTap: () => onPick(c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == selected
                          ? const Color(0xFF6C63FF)
                          : const Color(0xFF35354A),
                      width: c == selected ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: Pass `hasCamera` to the tab.** In `inspector_panel.dart`:

a) Add a field to `InspectorPanel`:
```dart
  /// Whether this recording has a camera sidecar (enables the Camera tab's
  /// real controls; otherwise the tab shows a placeholder).
  final bool hasCamera;
```
and add `this.hasCamera = false,` to the constructor param list.

b) Update the `_formatContent()` camera case:
```dart
        InspectorTab.camera => CameraTab(hasCamera: widget.hasCamera),
```

- [ ] **Step 6: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/camera_tab_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/inspector_tab.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/tabs/camera_tab.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart \
        packages/screen_recorder/test/ui/widgets/inspector/camera_tab_test.dart
git commit -m "feat(camera): real Camera inspector tab (global look controls)"
```

---

## Task D2: `CameraContextInspector` + inspector context route

Shown when a camera region is selected: header with the region's time range, a size slider, a placement hint, and Delete.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/camera_context_inspector.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/camera_context_inspector_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/camera_context_inspector_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/camera_context_inspector.dart';

void main() {
  CameraRegion region() => CameraRegion(
        startTime: const Duration(seconds: 1),
        duration: const Duration(seconds: 3),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.25,
      );

  testWidgets('size slider edits the region; delete + close fire', (tester) async {
    CameraRegion? changed;
    var deleted = false;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CameraContextInspector(
          region: region(),
          regionNumber: 2,
          onChanged: (r) => changed = r,
          onDelete: () => deleted = true,
          onClose: () => closed = true,
        ),
      ),
    ));

    expect(find.text('Camera 2'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(-200, 0));
    await tester.pump();
    expect(changed, isNotNull);

    await tester.tap(find.byKey(const Key('camera-region-delete')));
    expect(deleted, isTrue);

    await tester.tap(find.byKey(const Key('camera-region-close')));
    expect(closed, isTrue);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/camera_context_inspector_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/widgets/inspector/contexts/camera_context_inspector.dart
import 'package:flutter/material.dart';

import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

/// Properties view shown when a camera region (pill) is selected. Look
/// controls (shape/roundness/mirror/border/shadow/opacity) live in the
/// global Camera tab; this context edits the per-region geometry (size) and
/// hosts delete. Position is edited by dragging the bubble on the canvas.
class CameraContextInspector extends StatelessWidget {
  const CameraContextInspector({
    super.key,
    required this.region,
    required this.regionNumber,
    required this.onChanged,
    required this.onDelete,
    required this.onClose,
  });

  final CameraRegion region;
  final int regionNumber;
  final ValueChanged<CameraRegion> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Camera $regionNumber',
          subtitle: _rangeLabel(region),
          onClose: onClose,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(right: 12),
            children: [
              const Text(
                'Drag the bubble on the preview to reposition it. Resize with '
                'the corner handles, or use the slider below.',
                style: TextStyle(color: kInspectorMuted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              InspectorSlider(
                label: 'Size',
                subtitle: '${(region.size * 100).round()}% of canvas width',
                value: region.size,
                min: 0.05,
                max: 1.0,
                onChanged: (v) => onChanged(region.copyWith(size: v)),
                onReset: () => onChanged(region.copyWith(size: 0.22)),
                canReset: (region.size - 0.22).abs() > 1e-6,
              ),
              const InspectorSectionDivider(),
              _DeleteButton(onPressed: onDelete),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  static String _rangeLabel(CameraRegion r) {
    String fmt(Duration d) {
      final m = d.inMinutes;
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }
    return '${fmt(r.startTime)} → ${fmt(r.endTime)}';
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: kInspectorAccent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.account_box_outlined,
              color: kInspectorAccent, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(
                      color: kInspectorMuted, fontSize: 12)),
            ],
          ),
        ),
        SpringyIconButton(
          key: const Key('camera-region-close'),
          icon: Icons.close,
          tooltip: 'Close camera inspector',
          isActive: false,
          onTap: onClose,
          size: 32,
          iconSize: 16,
          tooltipPlacement: SpringyTooltipPlacement.bottom,
        ),
      ],
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: onPressed,
      borderRadius: 10,
      child: Container(
        key: const Key('camera-region-delete'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF3A1F26),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF8B2E3F)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline, color: Color(0xFFE57373), size: 18),
            SizedBox(width: 8),
            Text('Delete camera region',
                style: TextStyle(
                    color: Color(0xFFE57373),
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Route it in `inspector_panel.dart`.**

a) Add the import:
```dart
import 'package:screen_recorder/ui/widgets/inspector/contexts/camera_context_inspector.dart';
import 'package:slipreel_engine/models/camera_region.dart';
```

b) Add `InspectorPanel` fields + constructor params:
```dart
  /// Camera regions, indexed by [CameraSelected.index].
  final List<CameraRegion> cameraRegions;

  /// Mutate a camera region (size, etc.).
  final void Function(int index, CameraRegion next)? onCameraChanged;

  /// Delete a camera region.
  final void Function(int index)? onCameraDeleted;
```
Add to the constructor: `this.cameraRegions = const [],`, `this.onCameraChanged,`, `this.onCameraDeleted,`.

c) Add the context branch in `_contextMode`'s `switch`:
```dart
        CameraSelected(:final index) => _cameraContext(index),
```

d) Add the `_cameraContext` builder (next to `_zoomContext`):
```dart
  Widget _cameraContext(int index) {
    if (index < 0 || index >= widget.cameraRegions.length) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onSelectionCleared?.call(),
      );
      return const SizedBox.shrink();
    }
    final region = widget.cameraRegions[index];
    return CameraContextInspector(
      region: region,
      regionNumber: index + 1,
      onChanged: (next) => widget.onCameraChanged?.call(index, next),
      onDelete: () => widget.onCameraDeleted?.call(index),
      onClose: () => widget.onSelectionCleared?.call(),
    );
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/inspector/camera_context_inspector_test.dart`
Expected: PASS (1 test).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/contexts/camera_context_inspector.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart \
        packages/screen_recorder/test/ui/widgets/inspector/camera_context_inspector_test.dart
git commit -m "feat(camera): CameraContextInspector + inspector context route"
```

---

## Task D3: `CameraLane` timeline widget

A purpose-built lane (simpler than `ZoomLane` — camera pills have no ramps) rendering one bar per region with move-in-time, edge-resize, ghost-add on empty hover, click-to-select, and delete. Coordinates mirror `ZoomLane`: regions are stored in **source** time; the lane maps source↔edited via `clips`.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/timeline/camera_lane.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/camera_lane_test.dart`

> **Implementer guidance:** open `packages/screen_recorder/lib/ui/widgets/timeline/zoom_lane.dart` and reuse its exact time↔pixel helpers (`timeToX`, `xToTime`, `_sourceToEdited`, `_editedToSource`), ghost-range logic, and `_PillEdgeHandle` interaction shape. The constructor and callbacks below intentionally mirror `ZoomLane` so `editor_timeline.dart` wiring (Task D4) is a copy of the zoom-lane wiring. Keep the camera pill body visually distinct (e.g. a webcam glyph + teal fill via `timeline_constants.dart` — add `cameraFill`/`cameraStroke` tokens parallel to the zoom tokens if not present).

- [ ] **Step 1: Write the failing widget test** (behavioral smoke — render pills, select, delete, ghost-add)

```dart
// packages/screen_recorder/test/ui/widgets/timeline/camera_lane_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:screen_recorder/ui/widgets/timeline/camera_lane.dart';

void main() {
  CameraRegion region(int startMs, int durMs) => CameraRegion(
        startTime: Duration(milliseconds: startMs),
        duration: Duration(milliseconds: durMs),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      );

  Widget host({
    required List<CameraRegion> regions,
    int? selectedIndex,
    ValueChanged<int?>? onSelected,
    ValueChanged<int>? onDeleted,
    void Function(Duration, Duration)? onAdded,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 64,
            child: CameraLane(
              duration: const Duration(seconds: 10),
              pixelsPerSecond: 60,
              contentWidth: 600,
              cameraRegions: regions,
              clips: const [],
              selectedIndex: selectedIndex,
              onSeek: (_) {},
              onCameraSelected: onSelected,
              onCameraDeleted: onDeleted,
              onCameraAdded: onAdded,
              onCameraChanged: (_, __) {},
            ),
          ),
        ),
      );

  testWidgets('renders one pill per region', (tester) async {
    await tester.pumpWidget(host(regions: [region(0, 2000), region(3000, 2000)]));
    expect(find.byKey(const Key('camera-pill-0')), findsOneWidget);
    expect(find.byKey(const Key('camera-pill-1')), findsOneWidget);
  });

  testWidgets('tapping a pill selects it', (tester) async {
    int? selected;
    await tester.pumpWidget(host(
      regions: [region(0, 2000)],
      onSelected: (i) => selected = i,
    ));
    await tester.tap(find.byKey(const Key('camera-pill-0')));
    await tester.pump();
    expect(selected, 0);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/camera_lane_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement `CameraLane`.** Build it by adapting `ZoomLane` with these exact differences:
  - Replace `List<ZoomRegion> zoomRegions` → `List<CameraRegion> cameraRegions`; callbacks renamed `onZoom*` → `onCamera*` with the same signatures (`onCameraChanged(int index, CameraRegion next)`, `onCameraSelected(int?)`, `onCameraDeleted(int)`, `onCameraAdded(Duration start, Duration end)`). Keep `onSeek`, `selectedIndex`, `duration`, `pixelsPerSecond`, `contentWidth`, `clips`, `trimDragging`, `animateLayout`.
  - A camera pill exposes only **body drag** (move in time) and **left/right edge resize** (change start/duration). There is **no** enter/exit-ramp scaling — drop all `_dragStartEnter`/`_dragStartExit` logic from the zoom pill; an edge drag changes only `startTime`/`duration` with the same min-duration clamp (`minZoomDurationMs` → add a `minCameraDurationMs` constant of `200` to `timeline_constants.dart`, or reuse the zoom constant).
  - Ghost-add: identical to `ZoomLane._ghostRange()`; on tap, call `onCameraAdded(sourceStart, sourceEnd)`.
  - Pill body key: `Key('camera-pill-$index')`. Delete button (top-right on hover) calls `onCameraDeleted(index)`.
  - Visuals: webcam glyph (`Icons.videocam`/`Icons.account_box_outlined`) + a teal/`cameraFill` body so it reads distinct from zoom pills. Add `cameraFill`/`cameraStroke`/`cameraFillSelected` color tokens to `timeline_constants.dart` next to the zoom tokens.
  - On a body drag/edge resize commit, call `onCameraChanged(index, region.copyWith(startTime: ..., duration: ...))`.

> Keep the file self-contained and under ~400 lines. Do not reproduce the zoom pill's ramp math — the camera pill is strictly simpler.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/camera_lane_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/camera_lane.dart \
        packages/screen_recorder/lib/ui/widgets/timeline/timeline_constants.dart \
        packages/screen_recorder/test/ui/widgets/timeline/camera_lane_test.dart
git commit -m "feat(camera): CameraLane timeline lane"
```

---

## Task D4: Add the camera lane row to `EditorTimeline`

Thread camera regions + selection + callbacks through `EditorTimeline` and render a `CameraLane` row directly under the zoom lane, mirroring the zoom-lane block at `editor_timeline.dart:1701-1721`.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`

> Integration task; verify via `melos analyze` + manual checklist.

- [ ] **Step 1: Add the import** (with the other lane imports near line 30):
```dart
import 'package:screen_recorder/ui/widgets/timeline/camera_lane.dart';
import 'package:slipreel_engine/models/camera_region.dart';
```

- [ ] **Step 2: Add widget fields + constructor params.** In `EditorTimeline`'s constructor (after the zoom params `this.onZoomAdded,` near line 124):
```dart
    this.cameraRegions = const [],
    this.selectedCameraIndex,
    this.onCameraChanged,
    this.onCameraSelected,
    this.onCameraDeleted,
    this.onCameraAdded,
```
And declare the fields (after the zoom field declarations; match the existing `final` style):
```dart
  final List<CameraRegion> cameraRegions;
  final int? selectedCameraIndex;
  final void Function(int, CameraRegion)? onCameraChanged;
  final ValueChanged<int?>? onCameraSelected;
  final ValueChanged<int>? onCameraDeleted;
  final void Function(Duration start, Duration end)? onCameraAdded;
```

- [ ] **Step 3: Render the lane.** Immediately after the zoom-lane `TipAnchor(...)` block closes (the `),` at line 1721, before `if (showKeystrokeLane)` at line 1722), insert:
```dart
                                const SizedBox(height: laneSpacing),
                                SizedBox(
                                  height: zoomLaneHeight,
                                  child: CameraLane(
                                    duration: widget.duration,
                                    pixelsPerSecond: pps,
                                    contentWidth: cw,
                                    cameraRegions: widget.cameraRegions,
                                    clips: widget.clips,
                                    selectedIndex: widget.selectedCameraIndex,
                                    onCameraChanged: widget.onCameraChanged,
                                    onCameraSelected: widget.onCameraSelected,
                                    onCameraDeleted: widget.onCameraDeleted,
                                    onCameraAdded: widget.onCameraAdded,
                                    onSeek: widget.onSeek,
                                    trimDragging: _trimDragging,
                                    animateLayout: animateTimelineLayout,
                                  ),
                                ),
```

> If the lane sits inside a fixed-height parent, the added row may need the parent's height budget bumped. Check the `totalHeight` / lane-stack height math in this file (search `zoomLaneHeight`) and add one more `zoomLaneHeight + laneSpacing` where the zoom lane contributes, so the new row isn't clipped. Adjust only if a render-overflow appears.

- [ ] **Step 4: Analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/timeline/editor_timeline.dart`
Expected: no new issues.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart
git commit -m "feat(camera): camera lane row in EditorTimeline"
```

---

## Task D5: Wire camera selection + callbacks in `playback_screen`

Connect the camera lane, inspector, and on-canvas selection: add `_selectedCameraIndex` state, route `EditorTimeline` + `InspectorPanel` camera callbacks, add the timeline-ghost add handler, and enforce mutual exclusion with zoom/slice selection.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

> Integration task; verify via `melos analyze` + manual checklist. `_selectedCameraIndex` was declared in Task C4 Step 2.

- [ ] **Step 1: Add the import**:
```dart
import 'package:slipreel_engine/models/camera_region.dart';
```

- [ ] **Step 2: Extend the selection getter.** At the `_currentSelection()` / `_selection` getter (around line 468 where `_selectedZoomIndex` is checked), add a camera branch **before** the zoom one (so camera wins when set; they're mutually exclusive anyway):
```dart
    if (_selectedCameraIndex != null) {
      return CameraSelected(_selectedCameraIndex!);
    }
```
> Ensure `CameraSelected` is imported (it's in `timeline_selection.dart`, already imported by this screen).

- [ ] **Step 3: Add a camera-add handler** (next to `_addZoomAt`, around line 1381):
```dart
  /// Click-to-add a camera region from the lane ghost. Places it at the
  /// current camera look/default size, centered bottom-right, and selects it.
  void _addCameraAt(Duration start, Duration end) {
    if (!_isInitialized || !_hasCamera) return;
    if (end <= start) return;
    // Seed placement from the most recent region if any, else default.
    final existing = _project.cameraRegions;
    final tmpl = existing.isNotEmpty ? existing.last : null;
    final region = CameraRegion(
      startTime: start,
      duration: end - start,
      centerX: tmpl?.centerX ?? 0.82,
      centerY: tmpl?.centerY ?? 0.82,
      size: tmpl?.size ?? 0.22,
    );
    _projectController.addCameraRegion(region);
    setState(() {
      _selectedCameraIndex = _project.cameraRegions.length - 1;
      _selectedZoomIndex = null;
      _selectedSliceIndex = null;
    });
    _controller.seekTo(start);
  }
```

- [ ] **Step 4: Wire `EditorTimeline`.** In the `EditorTimeline(...)` construction (around line 2358), after `onZoomAdded: _addZoomAt,`, add:
```dart
                cameraRegions: _hasCamera ? _project.cameraRegions : const [],
                selectedCameraIndex: _selectedCameraIndex,
                onCameraSelected: (i) {
                  setState(() {
                    _selectedCameraIndex = i;
                    if (i != null) {
                      _selectedZoomIndex = null;
                      _selectedSliceIndex = null;
                    }
                  });
                },
                onCameraChanged: (i, next) =>
                    _projectController.updateCameraRegionAt(i, next),
                onCameraDeleted: (index) {
                  _projectController.removeCameraRegionAt(index);
                  setState(() {
                    if (_selectedCameraIndex == index) {
                      _selectedCameraIndex = null;
                    } else if (_selectedCameraIndex != null &&
                        _selectedCameraIndex! > index) {
                      _selectedCameraIndex = _selectedCameraIndex! - 1;
                    }
                  });
                },
                onCameraAdded: _addCameraAt,
```
Also, in the existing `onSeek` handler (which clears `_selectedSliceIndex`/`_selectedZoomIndex` on an empty-timeline tap, around line 2392), add:
```dart
                    _selectedCameraIndex = null;
```
And in `onZoomSelected` / `onSliceSelected`, add `_selectedCameraIndex = null;` where they currently null out the other selections (so all three stay mutually exclusive).

- [ ] **Step 5: Wire `InspectorPanel`.** In the `InspectorPanel(...)` construction (around line 1984), add:
```dart
                          hasCamera: _hasCamera,
                          cameraRegions:
                              _hasCamera ? project.cameraRegions : const [],
                          onCameraChanged: (i, next) =>
                              _projectController.updateCameraRegionAt(i, next),
                          onCameraDeleted: (index) {
                            _projectController.removeCameraRegionAt(index);
                            setState(() => _selectedCameraIndex = null);
                          },
```
And in the panel's `onSelectionCleared` callback (which sets `_selectedZoomIndex`/`_selectedSliceIndex` to null), add `_selectedCameraIndex = null;`.

- [ ] **Step 6: Analyze + full app suite**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/playback_screen.dart`
Then: `cd packages/screen_recorder && flutter test`
Expected: analyze clean of new issues; tests pass (the pre-existing `no_agent_wires_import_test` failure caused by the LOCAL-ONLY probe in `main.dart` is expected on this working tree and passes on a clean checkout — do not "fix" it by committing the probe).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(camera): wire camera lane + inspector + on-canvas selection"
```

---

# Final verification

- [ ] **Engine suite:** `cd packages/slipreel_engine && flutter test` → all pass.
- [ ] **App suite:** `cd packages/screen_recorder && flutter test` → all pass except the known local-only `no_agent_wires_import_test` (passes on clean checkout/CI).
- [ ] **Monorepo analyze:** `melos analyze` → no NEW issues attributable to camera files (compare against the pre-existing baseline of unused-import warnings in playback/export test files noted in Plan 1).
- [ ] **Whole-branch review** (subagent-driven-development final gate): dispatch the final code reviewer over the full diff before finishing the branch.

## Manual verification (requires a real Mac launch — the agent cannot do this)

Open a recording **made with the camera on** (Plan 1) and confirm:
1. The camera bubble appears in the preview at roughly the self-view position, circular by default.
2. Play: the camera stays frame-synced with the screen across play/pause and seeking (no drift, no audio from the camera track).
3. Drag the bubble on the canvas → it moves; corner handles resize it; edits persist after closing/reopening the editor (`.editor.json` round-trip).
4. The Camera inspector tab shows real controls; changing shape/roundness/mirror/border/shadow/opacity updates the preview live. Roundness greys out for Circle.
5. The camera lane shows a pill spanning the recording; drag/resize in time, add a second touching pill with a different placement → the bubble **glides** between them; leave a gap → the bubble **hides** in the gap.
6. Open a recording made **without** a camera: no camera lane pill, the Camera tab shows the "No camera in this recording" placeholder, no second player is created, preview is unchanged.
7. Corrupt/rename the `.camera.mov` and reopen: the editor still opens (logged warning), no bubble, no crash.

---

## Notes carried to Plan 3 (export compositing)

- The exporter (`FrameCompositor`) must reuse **`CameraPlacementResolver.placementAt`** and the **same look application order** the `CameraBubble` uses (mirror → shape crop → roundness → border → shadow → opacity) so export matches preview pixel-for-pixel. Factor the look-application into a shared painter if the widget tree can't be reused directly.
- The exporter opens a second `FfmpegDecoder` on `<video>.camera.mov`, pulls the aligned frame at `source_time − offsetMicros`, and paints the camera pass **after** the keystroke layer (canvas-fixed, not zoomed), skipping frames where the resolver returns `null`.
- `cameraOriginalAspect` for the export bubble comes from `CameraSidecarMeta.width/height` (same as the preview).
