# Slice Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace today's project-global `playbackSpeed`/`fadeIn`/`fadeOut`/`audioMix` with a per-slice `ClipSlice` model addressed via `Timeline.clips`, and ship a `SliceEditor` widget that edits one slice. In this sub-project the system always has exactly one slice spanning the whole video (so behavior is observably equivalent to today), but the data model and controller API become slice-addressed so sub-project C can introduce the cut tool by only touching cut-creation.

**Architecture:** `ClipSlice(start, end, playbackSpeed, fadeIn, fadeOut, micGainPercent, micMuted, systemGainPercent, systemMuted, hideCursor, disableSmoothMouse)` lives on `Timeline.clips: List<ClipSlice>`. Schema bumps v6→v7 with a migration that synthesizes a single slice from existing globals (requires the video duration to be plumbed into `EditorProjectStore.load`). Preview reads `state.timeline.clips[0].playbackSpeed` (multiplied by sub-A's preview-rate dropdown). Export reads from `clips[0]` and produces the same ffmpeg arg lists it produced from globals. SliceEditor replaces the inspector panel content when a clip bar is tapped.

**Tech Stack:** Dart 3, Flutter 3.41.5 (FVM `~/fvm/versions/3.41.5/bin/flutter`), Riverpod 2 (`StateNotifier`), `flutter_test` for unit/widget tests, existing schema-versioned JSON sidecar persistence (`<videoPath>.editor.json`).

**Branch:** `feat/slice-editor` from `main`.

**Spec:** `docs/superpowers/specs/2026-06-02-slice-editor-design.md`.

---

## Critical Project Conventions

Read before starting any task — these are repo-specific landmines.

1. **`packages/screen_recorder/lib/debug/debug_probe.dart` has LOCAL-ONLY markers and MUST NOT be staged or committed.** Use `git add <path>` with specific paths only; never `git add -A` or `git add .`.
2. **Commits never use `--no-verify`.** If a hook fails, fix the underlying issue and create a NEW commit (never `--amend` after a hook failure).
3. **Flutter CLI:** the project uses FVM. Run tests via `~/fvm/versions/3.41.5/bin/flutter test <path>` (NOT plain `flutter`).
4. **`flutter build macos` is broken (arm64 destination)** — for native build verification use `xcodebuild ... -destination 'platform=macOS,arch=x86_64' build` per memory `macos_build_verify_command.md`. This plan doesn't touch native code so you should not need it.
5. **No emojis** in code or commit messages.
6. **Equality discipline (post-sub-A):** `EditorProjectState` and `Timeline` have working `==`/`hashCode`. Mutators must no-op when the new value equals the current value, or the state stream emits spurious rebuilds and tests will see "no listener notification expected" failures.

---

## File Structure

### New files

| Path | Responsibility |
|------|---------------|
| `packages/slipreel_engine/lib/state/clip_slice.dart` | `ClipSlice` immutable data class + JSON I/O |
| `packages/slipreel_engine/test/state/clip_slice_test.dart` | Unit tests for `ClipSlice` |
| `packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart` | v6→v7 migration tests (kept separate from existing `editor_project_state_test.dart` so the migration suite is self-contained) |
| `packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart` | `setSliceX` mutator tests |
| `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart` | `SliceEditor` widget |
| `packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart` | Widget tests for `SliceEditor` |
| `packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart` | Preview-pipeline tests for slice speed |

### Modified files

| Path | What changes |
|------|--------------|
| `packages/slipreel_engine/lib/timeline/timeline.dart` | Add `clips: List<ClipSlice>` field, copyWith/toJson/fromJson updated |
| `packages/slipreel_engine/lib/state/editor_project_state.dart` | Remove `playbackSpeed`/`fadeIn`/`fadeOut`/`audioMix` fields; bump `currentSchemaVersion` to 7; add v6→v7 migration; `fromJson` & `migrateEditorProjectJson` gain required `videoDuration` param |
| `packages/slipreel_engine/lib/state/editor_project_store.dart` | `load` gains required `videoDuration` param; seeds single slice for fresh defaults |
| `packages/slipreel_engine/lib/state/editor_project_controller.dart` | Remove `setPlaybackSpeed`/`setFadeIn`/`setFadeOut`/`setMicGain`/`setMicMuted`/`setSystemGain`/`setSystemMuted`; add `setSliceSpeed`/`setSliceFadeIn`/`setSliceFadeOut`/`setSliceMicGain`/`setSliceMicMuted`/`setSliceSystemGain`/`setSliceSystemMuted`/`setSliceHideCursor`/`setSliceDisableSmoothMouse`/`removeSlice` |
| `packages/slipreel_engine/lib/export/export_pipeline.dart` | Read `audioMix`, `playbackSpeed`, `fadeIn`, `fadeOut` from `state.timeline.clips[0]` instead of `state` directly |
| `packages/slipreel_engine/lib/export/gif_export_pipeline.dart` | Same — read from `clips[0]` |
| `packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart` | Add `InspectorToggle` widget |
| `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` | Swap `ClipContextInspector` for `SliceEditor` |
| `packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart` | Read mix from `clips[0]`; write via `setSliceMicGain`/`setSliceMicMuted`/etc. |
| `packages/screen_recorder/lib/ui/widgets/timeline/smooth_playhead_controller.dart` | Read `playbackSpeed` from `state.timeline.clips.isEmpty ? 1.0 : state.timeline.clips[0].playbackSpeed` |
| `packages/screen_recorder/lib/ui/screens/playback_screen.dart` | `_projectStore.load(videoDuration: ...)`; `ref.listen` select reads from `clips[0]`; seed-single-slice on first load |
| `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` | `hideCursor` reads `state.timeline.clips[0].hideCursor || project.hideCursorOverlay`; `disableSmoothMouse` controls whether cursor animation/smoothing is applied |

### Deleted files

| Path | Why |
|------|-----|
| `packages/screen_recorder/lib/ui/widgets/inspector/contexts/clip_context_inspector.dart` | Replaced by `SliceEditor` |
| `packages/screen_recorder/test/ui/widgets/inspector/contexts/clip_context_inspector_test.dart` (if it exists) | Replaced by `slice_editor_test.dart` |

### Test files updated to pass `videoDuration` / construct slices

- `packages/slipreel_engine/test/state/editor_project_state_test.dart`
- `packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart`
- `packages/slipreel_engine/test/state/editor_project_store_test.dart`
- `packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart`
- `packages/slipreel_engine/test/export/gif_export_pipeline_test.dart`
- `packages/screen_recorder/test/ui/screens/playback_screen_preview_speed_test.dart`

---

### Task 0: Branch and verify baseline

**Files:**
- Modify: (none — git ops only)

- [ ] **Step 1: Create feature branch from main**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git status -s            # Verify only `M packages/screen_recorder/lib/debug/debug_probe.dart` and untracked dirs
git checkout -b feat/slice-editor
```

Expected: `Switched to a new branch 'feat/slice-editor'`. `debug_probe.dart` LOCAL-ONLY modification carries over (NOT staged anywhere).

- [ ] **Step 2: Verify the baseline test suite state**

Run: `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && ~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test packages/screen_recorder/test`

Expected (from memory: post-sub-A baseline): 422 pass / 14 skip / 4 fail. The 4 failures are pre-existing — record their names so you can recognize them later and NOT be alarmed when they persist. If the failure count is different from 4, stop and investigate before making any code changes.

---

### Task 1: ClipSlice data class

**Files:**
- Create: `packages/slipreel_engine/lib/state/clip_slice.dart`
- Test: `packages/slipreel_engine/test/state/clip_slice_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `packages/slipreel_engine/test/state/clip_slice_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

void main() {
  group('ClipSlice', () {
    test('constructor clamps gain to 0..200', () {
      final s = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
        micGainPercent: -50,
        systemGainPercent: 300,
      );
      expect(s.micGainPercent, 0);
      expect(s.systemGainPercent, 200);
    });

    test('length returns end - start', () {
      final s = ClipSlice(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 7),
      );
      expect(s.length, const Duration(seconds: 5));
    });

    test('copyWith preserves unchanged fields', () {
      final s = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
        playbackSpeed: 1.5,
        hideCursor: true,
      );
      final next = s.copyWith(playbackSpeed: 2.0);
      expect(next.playbackSpeed, 2.0);
      expect(next.start, s.start);
      expect(next.end, s.end);
      expect(next.hideCursor, true);
    });

    test('== is value-based; equal slices are equal', () {
      final a = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final b = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      expect(a == b, isTrue);
      expect(a.hashCode == b.hashCode, isTrue);
    });

    test('== false when any field differs', () {
      final a = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final b = a.copyWith(playbackSpeed: 2.0);
      expect(a == b, isFalse);
    });

    test('toJson then fromJson round-trips all fields', () {
      final s = ClipSlice(
        start: const Duration(seconds: 1, milliseconds: 500),
        end: const Duration(seconds: 9, milliseconds: 250),
        playbackSpeed: 1.75,
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 250),
        micGainPercent: 120,
        micMuted: true,
        systemGainPercent: 80,
        systemMuted: false,
        hideCursor: true,
        disableSmoothMouse: true,
      );
      final round = ClipSlice.fromJson(s.toJson());
      expect(round, s);
    });

    test('fromJson defaults missing optional keys', () {
      final s = ClipSlice.fromJson({
        'startMicros': 0,
        'endMicros': 10_000_000,
      });
      expect(s.playbackSpeed, 1.0);
      expect(s.fadeIn, Duration.zero);
      expect(s.fadeOut, Duration.zero);
      expect(s.micGainPercent, 100);
      expect(s.micMuted, isFalse);
      expect(s.systemGainPercent, 100);
      expect(s.systemMuted, isFalse);
      expect(s.hideCursor, isFalse);
      expect(s.disableSmoothMouse, isFalse);
    });

    test('fromJson throws when bounds are missing', () {
      expect(
        () => ClipSlice.fromJson({}),
        throwsFormatException,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/clip_slice_test.dart`

Expected: FAIL with "Target of URI doesn't exist: 'package:slipreel_engine/state/clip_slice.dart'".

- [ ] **Step 3: Implement `ClipSlice`**

Create `packages/slipreel_engine/lib/state/clip_slice.dart`:

```dart
/// A temporal segment of the source video with its own playback,
/// audio, fade, and cursor settings. Sliceable timelines are
/// addressed via `Timeline.clips`; in sub-project B every project
/// has exactly one slice covering the whole video, sub-project C
/// introduces the cut tool that splits a slice into multiple.
class ClipSlice {
  ClipSlice({
    required this.start,
    required this.end,
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    int micGainPercent = 100,
    this.micMuted = false,
    int systemGainPercent = 100,
    this.systemMuted = false,
    this.hideCursor = false,
    this.disableSmoothMouse = false,
  })  : micGainPercent = _clampGain(micGainPercent),
        systemGainPercent = _clampGain(systemGainPercent);

  final Duration start;
  final Duration end;
  final double playbackSpeed;
  final Duration fadeIn;
  final Duration fadeOut;
  final int micGainPercent;
  final bool micMuted;
  final int systemGainPercent;
  final bool systemMuted;
  final bool hideCursor;
  final bool disableSmoothMouse;

  Duration get length => end - start;

  static int _clampGain(int v) => v < 0 ? 0 : (v > 200 ? 200 : v);

  ClipSlice copyWith({
    Duration? start,
    Duration? end,
    double? playbackSpeed,
    Duration? fadeIn,
    Duration? fadeOut,
    int? micGainPercent,
    bool? micMuted,
    int? systemGainPercent,
    bool? systemMuted,
    bool? hideCursor,
    bool? disableSmoothMouse,
  }) =>
      ClipSlice(
        start: start ?? this.start,
        end: end ?? this.end,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        micGainPercent: micGainPercent ?? this.micGainPercent,
        micMuted: micMuted ?? this.micMuted,
        systemGainPercent: systemGainPercent ?? this.systemGainPercent,
        systemMuted: systemMuted ?? this.systemMuted,
        hideCursor: hideCursor ?? this.hideCursor,
        disableSmoothMouse: disableSmoothMouse ?? this.disableSmoothMouse,
      );

  Map<String, dynamic> toJson() => {
        'startMicros': start.inMicroseconds,
        'endMicros': end.inMicroseconds,
        'playbackSpeed': playbackSpeed,
        'fadeInMicros': fadeIn.inMicroseconds,
        'fadeOutMicros': fadeOut.inMicroseconds,
        'micGainPercent': micGainPercent,
        'micMuted': micMuted,
        'systemGainPercent': systemGainPercent,
        'systemMuted': systemMuted,
        'hideCursor': hideCursor,
        'disableSmoothMouse': disableSmoothMouse,
      };

  factory ClipSlice.fromJson(Map<String, dynamic> json) {
    final startRaw = json['startMicros'];
    final endRaw = json['endMicros'];
    if (startRaw is! num || endRaw is! num) {
      throw const FormatException(
        'ClipSlice.fromJson: startMicros and endMicros are required',
      );
    }
    return ClipSlice(
      start: Duration(microseconds: startRaw.toInt()),
      end: Duration(microseconds: endRaw.toInt()),
      playbackSpeed: (json['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
      fadeIn: json['fadeInMicros'] is num
          ? Duration(microseconds: (json['fadeInMicros'] as num).toInt())
          : Duration.zero,
      fadeOut: json['fadeOutMicros'] is num
          ? Duration(microseconds: (json['fadeOutMicros'] as num).toInt())
          : Duration.zero,
      micGainPercent: (json['micGainPercent'] as num?)?.toInt() ?? 100,
      micMuted: (json['micMuted'] as bool?) ?? false,
      systemGainPercent: (json['systemGainPercent'] as num?)?.toInt() ?? 100,
      systemMuted: (json['systemMuted'] as bool?) ?? false,
      hideCursor: (json['hideCursor'] as bool?) ?? false,
      disableSmoothMouse: (json['disableSmoothMouse'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipSlice &&
          other.start == start &&
          other.end == end &&
          other.playbackSpeed == playbackSpeed &&
          other.fadeIn == fadeIn &&
          other.fadeOut == fadeOut &&
          other.micGainPercent == micGainPercent &&
          other.micMuted == micMuted &&
          other.systemGainPercent == systemGainPercent &&
          other.systemMuted == systemMuted &&
          other.hideCursor == hideCursor &&
          other.disableSmoothMouse == disableSmoothMouse;

  @override
  int get hashCode => Object.hash(
        start,
        end,
        playbackSpeed,
        fadeIn,
        fadeOut,
        micGainPercent,
        micMuted,
        systemGainPercent,
        systemMuted,
        hideCursor,
        disableSmoothMouse,
      );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/clip_slice_test.dart`

Expected: 8 pass.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/clip_slice.dart \
        packages/slipreel_engine/test/state/clip_slice_test.dart
git commit -m "feat(engine): add ClipSlice data class"
```

---

### Task 2: Timeline gains `clips` field

**Files:**
- Modify: `packages/slipreel_engine/lib/timeline/timeline.dart`
- Test: extend `packages/slipreel_engine/test/state/clip_slice_test.dart` with `Timeline` round-trip cases

- [ ] **Step 1: Write the failing tests**

Append to `packages/slipreel_engine/test/state/clip_slice_test.dart`:

```dart
import 'package:slipreel_engine/timeline/timeline.dart';

// ... add inside main() after the existing group('ClipSlice', ...) block:

  group('Timeline.clips', () {
    test('defaults to an empty clip list', () {
      final t = Timeline.defaults();
      expect(t.clips, isEmpty);
    });

    test('copyWith replaces clips', () {
      final t = Timeline.defaults();
      final clips = [
        ClipSlice(start: Duration.zero, end: const Duration(seconds: 10)),
      ];
      final next = t.copyWith(clips: clips);
      expect(next.clips, hasLength(1));
      expect(next.clips.first.length, const Duration(seconds: 10));
    });

    test('toJson + fromJson round-trip preserves clips', () {
      final clips = [
        ClipSlice(
          start: Duration.zero,
          end: const Duration(seconds: 5),
          playbackSpeed: 1.5,
        ),
        ClipSlice(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
          micMuted: true,
        ),
      ];
      final t = Timeline(clips: clips);
      final round = Timeline.fromJson(t.toJson());
      expect(round.clips, hasLength(2));
      expect(round.clips, equals(clips));
    });

    test('fromJson tolerates a missing clips key', () {
      final t = Timeline.fromJson({'zoomTracks': []});
      expect(t.clips, isEmpty);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/clip_slice_test.dart`

Expected: FAIL — Timeline doesn't have a `clips` parameter on its constructor.

- [ ] **Step 3: Add `clips` field to `Timeline`**

Edit `packages/slipreel_engine/lib/timeline/timeline.dart`. Replace the `Timeline` class with:

```dart
class Timeline {
  const Timeline({
    this.zoomTracks = const <ZoomTrack>[],
    this.clips = const <ClipSlice>[],
  });

  /// Sensible blank slate: one empty zoom track, no clips (the
  /// controller seeds a single slice once it knows the video duration).
  factory Timeline.defaults() => const Timeline(
        zoomTracks: [ZoomTrack()],
      );

  final List<ZoomTrack> zoomTracks;
  final List<ClipSlice> clips;

  /// Convenience read accessor for code that hasn't yet been updated
  /// to pick a specific zoom track. Returns the regions on the first
  /// track, or an empty list if no tracks exist. The editor renders
  /// against this today.
  List<ZoomRegion> get activeZoomRegions =>
      zoomTracks.isEmpty ? const <ZoomRegion>[] : zoomTracks.first.regions;

  Timeline copyWith({
    List<ZoomTrack>? zoomTracks,
    List<ClipSlice>? clips,
  }) =>
      Timeline(
        zoomTracks: zoomTracks ?? this.zoomTracks,
        clips: clips ?? this.clips,
      );

  Map<String, dynamic> toJson() => {
        'zoomTracks': zoomTracks.map((t) => t.toJson()).toList(),
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory Timeline.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['zoomTracks'];
    final tracks = <ZoomTrack>[];
    if (rawTracks is List) {
      for (final t in rawTracks) {
        if (t is Map<String, dynamic>) {
          tracks.add(ZoomTrack.fromJson(t));
        }
      }
    }
    final rawClips = json['clips'];
    final clips = <ClipSlice>[];
    if (rawClips is List) {
      for (final c in rawClips) {
        if (c is Map<String, dynamic>) {
          clips.add(ClipSlice.fromJson(c));
        }
      }
    }
    return Timeline(
      zoomTracks: List.unmodifiable(tracks),
      clips: List.unmodifiable(clips),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Timeline &&
          _listEq(other.zoomTracks, zoomTracks) &&
          _listEq(other.clips, clips);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(zoomTracks),
        Object.hashAll(clips),
      );
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
```

Add the import at the top of `timeline.dart`:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

NOTE: `Timeline` may not currently have `==`/`hashCode`. If it does, replace those bodies with the versions above. If it doesn't, this adds them — which is correct (`EditorProjectState.==` already compares `timeline` so deep equality matters now that `clips` participates).

- [ ] **Step 4: Run tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/clip_slice_test.dart`

Expected: 12 pass (8 ClipSlice + 4 Timeline).

- [ ] **Step 5: Verify the rest of the engine still compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test`

Expected: same pass/fail count as the baseline (Task 0 Step 2). If new failures appear, they're from `Timeline.toJson` now emitting a `clips: []` key that the equality assertions in existing tests didn't expect — check the failure trace and either:
- if the test compares full JSON maps, update the expected to include `'clips': []`;
- if the test compares `Timeline` instances, the new `==` should accept them (empty `clips` on both sides).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/timeline/timeline.dart \
        packages/slipreel_engine/test/state/clip_slice_test.dart
# Plus any test files you had to touch in Step 5:
# git add packages/slipreel_engine/test/...
git commit -m "feat(engine): add clips field to Timeline"
```

---

### Task 3: Schema migration v6 → v7

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Create: `packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart`

This task ONLY adds the migration step and bumps `currentSchemaVersion`. It does NOT remove the project-global fields yet — that's Task 4 — so the migration step's job here is to synthesize the slice AND leave the top-level globals in place. Task 4 will remove them and update the migration to delete them.

Why two steps? It keeps both diffs reviewable in isolation.

- [ ] **Step 1: Write the failing tests**

Create `packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  group('EditorProjectState schema v6 -> v7 migration', () {
    test('currentSchemaVersion is 7', () {
      expect(EditorProjectState.currentSchemaVersion, 7);
    });

    test('migrates v6 globals into a single clip covering the whole video', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'playbackSpeed': 1.5,
        'fadeInMicros': 500_000,
        'fadeOutMicros': 250_000,
        'audioMix': {
          'micGainPercent': 120,
          'micMuted': true,
          'systemGainPercent': 80,
          'systemMuted': false,
        },
        'timeline': {
          'zoomTracks': [
            {'regions': []},
          ],
        },
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 12, milliseconds: 340),
      );
      expect(v7['schemaVersion'], 7);
      final timeline = v7['timeline'] as Map<String, dynamic>;
      final clips = timeline['clips'] as List;
      expect(clips, hasLength(1));
      final clip = ClipSlice.fromJson(clips.first as Map<String, dynamic>);
      expect(clip.start, Duration.zero);
      expect(clip.end, const Duration(seconds: 12, milliseconds: 340));
      expect(clip.playbackSpeed, 1.5);
      expect(clip.fadeIn, const Duration(microseconds: 500_000));
      expect(clip.fadeOut, const Duration(microseconds: 250_000));
      expect(clip.micGainPercent, 120);
      expect(clip.micMuted, isTrue);
      expect(clip.systemGainPercent, 80);
      expect(clip.systemMuted, isFalse);
      expect(clip.hideCursor, isFalse);
      expect(clip.disableSmoothMouse, isFalse);
    });

    test('migrates a v6 without audioMix using default audio values', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'timeline': {'zoomTracks': []},
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 5),
      );
      final clips = (v7['timeline'] as Map<String, dynamic>)['clips'] as List;
      final clip = ClipSlice.fromJson(clips.first as Map<String, dynamic>);
      expect(clip.playbackSpeed, 1.0);
      expect(clip.fadeIn, Duration.zero);
      expect(clip.fadeOut, Duration.zero);
      expect(clip.micGainPercent, 100);
      expect(clip.micMuted, isFalse);
      expect(clip.systemGainPercent, 100);
      expect(clip.systemMuted, isFalse);
    });

    test('v6 without a timeline key still produces a v7 with a clip', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'playbackSpeed': 2.0,
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 3),
      );
      final timeline = v7['timeline'] as Map<String, dynamic>;
      final clips = timeline['clips'] as List;
      expect(clips, hasLength(1));
      final clip = ClipSlice.fromJson(clips.first as Map<String, dynamic>);
      expect(clip.playbackSpeed, 2.0);
      expect(clip.end, const Duration(seconds: 3));
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart`

Expected: FAIL — `currentSchemaVersion` is 6, and `migrateEditorProjectJson` doesn't accept `videoDuration`.

- [ ] **Step 3: Update `EditorProjectState` migration plumbing**

Edit `packages/slipreel_engine/lib/state/editor_project_state.dart`:

a) Change `currentSchemaVersion`:

```dart
static const int currentSchemaVersion = 7;
```

b) Change the `_schemaMigrations` list element type to take a `Duration`:

```dart
final List<Map<String, dynamic> Function(Map<String, dynamic>, Duration)>
    _schemaMigrations = [
  // v0 -> v1
  (json, _) => json,
  // v1 -> v2
  (json, _) => {...json, 'schemaVersion': 2},
  // v2 -> v3
  (json, _) {
    final next = {...json, 'schemaVersion': 3};
    final regions = next.remove('zoomRegions');
    next['timeline'] = {
      'zoomTracks': [
        {'regions': regions is List ? regions : const <dynamic>[]},
      ],
    };
    return next;
  },
  // v3 -> v4
  (json, _) => {...json, 'schemaVersion': 4},
  // v4 -> v5
  (json, _) => {...json, 'schemaVersion': 5},
  // v5 -> v6
  (json, _) => {...json, 'schemaVersion': 6},
  // v6 -> v7: synthesize a single clip from existing globals. The clip
  // covers the whole video; its fields take the values from the
  // top-level globals where present, or ClipSlice defaults where not.
  // The globals stay on the JSON for now — Task 4 removes them once
  // EditorProjectState stops reading them.
  (json, videoDuration) {
    final next = Map<String, dynamic>.from(json);
    final speed = (next['playbackSpeed'] as num?)?.toDouble() ?? 1.0;
    final fadeInMicros = (next['fadeInMicros'] as num?)?.toInt() ?? 0;
    final fadeOutMicros = (next['fadeOutMicros'] as num?)?.toInt() ?? 0;
    final audio = next['audioMix'] as Map<String, dynamic>?;
    final clip = <String, dynamic>{
      'startMicros': 0,
      'endMicros': videoDuration.inMicroseconds,
      'playbackSpeed': speed,
      'fadeInMicros': fadeInMicros,
      'fadeOutMicros': fadeOutMicros,
      'micGainPercent': (audio?['micGainPercent'] as num?)?.toInt() ?? 100,
      'micMuted': (audio?['micMuted'] as bool?) ?? false,
      'systemGainPercent':
          (audio?['systemGainPercent'] as num?)?.toInt() ?? 100,
      'systemMuted': (audio?['systemMuted'] as bool?) ?? false,
      'hideCursor': false,
      'disableSmoothMouse': false,
    };
    final timeline = (next['timeline'] as Map<String, dynamic>?) ?? const {};
    next['timeline'] = {
      ...timeline,
      'clips': [clip],
    };
    next['schemaVersion'] = 7;
    return next;
  },
];
```

c) Update `migrateEditorProjectJson` to take a `Duration videoDuration` and thread it through:

```dart
Map<String, dynamic> migrateEditorProjectJson(
  Map<String, dynamic> json, {
  required Duration videoDuration,
}) {
  final rawVersion = json['schemaVersion'];
  var version = (rawVersion is int && rawVersion >= 0) ? rawVersion : 1;
  var current = json;
  while (version < EditorProjectState.currentSchemaVersion) {
    if (version >= _schemaMigrations.length) {
      throw StateError(
        'No migration step from EditorProjectState v$version — '
        '_schemaMigrations is missing an entry. Add a v$version->v${version + 1} '
        'step or update currentSchemaVersion.',
      );
    }
    current = _schemaMigrations[version](current, videoDuration);
    version++;
  }
  return current;
}
```

d) Update `EditorProjectState.fromJson` to take a `Duration videoDuration`:

```dart
factory EditorProjectState.fromJson(
  Map<String, dynamic> rawJson, {
  required Duration videoDuration,
}) {
  final version = rawJson['schemaVersion'];
  if (version is int && version > currentSchemaVersion) {
    throw FormatException(
      'EditorProjectState: schemaVersion $version is newer than '
      'this build supports ($currentSchemaVersion)',
    );
  }
  final json = migrateEditorProjectJson(rawJson, videoDuration: videoDuration);
  // ... existing body unchanged
}
```

- [ ] **Step 4: Run the migration tests to verify they pass**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart`

Expected: 4 pass.

- [ ] **Step 5: Update all existing call sites that broke**

Compile errors will appear at every `EditorProjectState.fromJson(json)` and `migrateEditorProjectJson(json)` call. Find them:

```bash
grep -rn "EditorProjectState\.fromJson\|migrateEditorProjectJson" \
  packages --include="*.dart"
```

Expected sites:
- `packages/slipreel_engine/lib/state/editor_project_store.dart` — see Task 5 for the proper plumbing. For NOW, pass a placeholder so the engine compiles: `EditorProjectState.fromJson(json, videoDuration: Duration.zero)`. Task 5 fixes it properly.
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` — pass `videoDuration: const Duration(seconds: 60)` (or whatever the test wants — any non-zero duration works for round-trip tests since the round-trip preserves the slice's end value).
- Any other test that calls `fromJson`.

Apply the minimum changes to make them compile. Don't try to make this look beautiful — Task 5 will replumb cleanly.

- [ ] **Step 6: Run the full engine test suite**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test`

Expected: same baseline failure count as Task 0 Step 2 (typically 0–2 new failures from the now-migrated v6 JSON producing `clips: [...]` that round-trip tests don't expect to see; if any pop up, update those tests to either ignore the `clips` key or assert it).

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart \
        packages/slipreel_engine/lib/state/editor_project_store.dart
# Plus any test files you had to touch in Step 5/6.
git commit -m "feat(engine): schema v6->v7 migration synthesizes single clip slice"
```

---

### Task 4: Remove project-global fields from `EditorProjectState`

Now that the migration writes the slice, remove the project-level `playbackSpeed`/`fadeIn`/`fadeOut`/`audioMix` from `EditorProjectState` and update the migration to delete those keys from the v7 JSON.

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Modify: `packages/slipreel_engine/test/state/editor_project_state_test.dart` (and any other test that constructs state with these fields)
- Modify: `packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart` (add an assertion that the v7 JSON does NOT contain the top-level globals)

- [ ] **Step 1: Write the failing test**

Append a new test to `editor_project_state_slice_migration_test.dart` inside the existing group:

```dart
    test('v7 JSON has no top-level playbackSpeed/fade/audioMix', () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'playbackSpeed': 1.5,
        'fadeInMicros': 500_000,
        'fadeOutMicros': 250_000,
        'audioMix': {'micGainPercent': 120, 'micMuted': true},
      };
      final v7 = migrateEditorProjectJson(
        v6,
        videoDuration: const Duration(seconds: 10),
      );
      expect(v7.containsKey('playbackSpeed'), isFalse);
      expect(v7.containsKey('fadeInMicros'), isFalse);
      expect(v7.containsKey('fadeOutMicros'), isFalse);
      expect(v7.containsKey('audioMix'), isFalse);
    });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart`

Expected: the new test FAILS (keys are still present).

- [ ] **Step 3: Update the v6->v7 migration to remove the top-level globals**

Edit `packages/slipreel_engine/lib/state/editor_project_state.dart`. Replace the v6→v7 migration body's `next['playbackSpeed']` reads with `next.remove('playbackSpeed')` etc.:

```dart
  // v6 -> v7
  (json, videoDuration) {
    final next = Map<String, dynamic>.from(json);
    final speed = (next.remove('playbackSpeed') as num?)?.toDouble() ?? 1.0;
    final fadeInMicros = (next.remove('fadeInMicros') as num?)?.toInt() ?? 0;
    final fadeOutMicros = (next.remove('fadeOutMicros') as num?)?.toInt() ?? 0;
    final audio = next.remove('audioMix') as Map<String, dynamic>?;
    // ... rest unchanged
  },
```

- [ ] **Step 4: Remove the fields from `EditorProjectState`**

In the same file:

a) Delete from the constructor params: `playbackSpeed`, `fadeIn`, `fadeOut`, `audioMix`.

b) Delete the fields: `final double playbackSpeed`, `final Duration fadeIn`, `final Duration fadeOut`, `final AudioMix audioMix`.

c) Delete from `EditorProjectState.defaults()` initialization (those fields' defaults already lived in the constructor — no factory body changes needed beyond removing them from `EditorProjectState(...)`).

d) Delete from `copyWith` params and body.

e) Delete from `toJson`:
- `'playbackSpeed': playbackSpeed,`
- `'fadeInMicros': fadeIn.inMicroseconds,`
- `'fadeOutMicros': fadeOut.inMicroseconds,`
- `'audioMix': audioMix.toJson(),`

f) Delete from `fromJson`:
- `playbackSpeed: ...`
- `fadeIn: ...`
- `fadeOut: ...`
- `audioMix: ...`

g) Delete from `==`:
- `other.playbackSpeed == playbackSpeed &&`
- `other.fadeIn == fadeIn &&`
- `other.fadeOut == fadeOut &&`
- `other.audioMix == audioMix &&`

h) Delete from `hashCode`'s `Object.hashAll([...])` list:
- `playbackSpeed,`
- `fadeIn,`
- `fadeOut,`
- `audioMix,`

i) Delete the `audio_mix.dart` import if it's no longer used in this file.

- [ ] **Step 5: Update existing tests that constructed state with these fields**

Compile errors will appear in:
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` — replace any `EditorProjectState(... playbackSpeed: x, fadeIn: y, ...)` with `EditorProjectState(...)` and remove the field arguments. If the test was asserting the field's value, retarget it to assert the slice's value via `state.timeline.clips.first.<field>` — or remove the assertion entirely if it was just checking the default constructor.
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` — JSON round-trip tests that wrote `{'playbackSpeed': 1.5, ...}` need to be rewritten as v7 JSON inputs (no top-level globals; clips inside `timeline.clips`). Update them to construct via `state.toJson()` and assert round-trip.
- `packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart` — `audioMix` is no longer on `EditorProjectState`. Update the assertions to read from `state.timeline.clips.first.<audio fields>`. The test SETUP needs to construct state with `timeline: Timeline(clips: [ClipSlice(start: Duration.zero, end: const Duration(seconds: 60))])` before calling the audio setters. Note: these tests will fully break after Task 6 (controller setters change names), so for now ONLY make them compile — don't restructure their assertions. Leave the test bodies broken if they were calling `setMicGain` etc., a `// TODO migrate to setSliceMicGain in Task 6` comment is acceptable. Skip with `skip: 'migrated in Task 6'` per test.

```dart
// example: at the top of a test:
test('mic gain mutator clamps', () {
  // ... body unchanged
}, skip: 'migrated to setSliceMicGain in Task 6');
```

- [ ] **Step 6: Run engine tests**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test`

Expected: the slice migration test passes including the new assertion; baseline failures unchanged; audio controller tests skipped with reason. If anything else fails, it's likely a test that read `state.playbackSpeed` etc. — update to read from `state.timeline.clips.first`.

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_project_state_test.dart \
        packages/slipreel_engine/test/state/editor_project_state_slice_migration_test.dart \
        packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart
git commit -m "refactor(engine): remove project-global playbackSpeed/fade/audioMix"
```

---

### Task 5: `EditorProjectStore.load` takes `videoDuration`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_store.dart`
- Modify: `packages/slipreel_engine/test/state/editor_project_store_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (one call site)
- Modify: `packages/screen_recorder/lib/ui/screens/recents_screen.dart` (if it calls load — check first)

- [ ] **Step 1: Write a failing test**

Replace any existing `load` test in `editor_project_store_test.dart` (or add this group):

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';

void main() {
  group('EditorProjectStore.load with videoDuration', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('store_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('seeds a single slice covering the duration when sidecar is missing',
        () async {
      final store = EditorProjectStore(videoPath: '${tmp.path}/no_file.mov');
      final state = await store.load(
        videoDuration: const Duration(seconds: 30),
      );
      expect(state.timeline.clips, hasLength(1));
      expect(state.timeline.clips.first.start, Duration.zero);
      expect(state.timeline.clips.first.end, const Duration(seconds: 30));
    });

    test('migrates an existing v6 sidecar through to v7', () async {
      final path = '${tmp.path}/clip.mov';
      await File('$path.editor.json').writeAsString('{'
          '"schemaVersion": 6,'
          '"playbackSpeed": 1.5,'
          '"audioMix": {"micGainPercent": 120, "micMuted": true}'
          '}');
      final store = EditorProjectStore(videoPath: path);
      final state = await store.load(
        videoDuration: const Duration(seconds: 20),
      );
      expect(state.timeline.clips, hasLength(1));
      final clip = state.timeline.clips.first;
      expect(clip.start, Duration.zero);
      expect(clip.end, const Duration(seconds: 20));
      expect(clip.playbackSpeed, 1.5);
      expect(clip.micGainPercent, 120);
      expect(clip.micMuted, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_store_test.dart`

Expected: FAIL — `load()` doesn't accept `videoDuration`.

- [ ] **Step 3: Update `EditorProjectStore.load`**

Edit `packages/slipreel_engine/lib/state/editor_project_store.dart`:

```dart
Future<EditorProjectState> load({required Duration videoDuration}) async {
  final f = File(sidecarPath);
  if (!await f.exists()) {
    return _seedSingleSlice(EditorProjectState.defaults(), videoDuration);
  }
  try {
    final text = await f.readAsString();
    if (text.trim().isEmpty) {
      return _seedSingleSlice(EditorProjectState.defaults(), videoDuration);
    }
    final json = jsonDecode(text) as Map<String, dynamic>;
    return EditorProjectState.fromJson(json, videoDuration: videoDuration);
  } catch (e, stack) {
    AppLogger.ui.w(
      'EditorProjectStore: failed to load $sidecarPath, using defaults',
      error: e,
      stackTrace: stack,
    );
    return _seedSingleSlice(EditorProjectState.defaults(), videoDuration);
  }
}

EditorProjectState _seedSingleSlice(
  EditorProjectState state,
  Duration videoDuration,
) {
  if (state.timeline.clips.isNotEmpty) return state;
  return state.copyWith(
    timeline: state.timeline.copyWith(
      clips: [
        ClipSlice(start: Duration.zero, end: videoDuration),
      ],
    ),
  );
}
```

Add the import:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

- [ ] **Step 4: Update the playback screen call site**

Edit `packages/screen_recorder/lib/ui/screens/playback_screen.dart` at the existing `_projectStore.load()` site (around line 251):

```dart
// before
final saved = await _projectStore.load();

// after
final saved = await _projectStore.load(
  videoDuration: _controller.value.duration,
);
```

Verify `_controller` is initialized before this line — it is (the existing code at lines 304+ already calls `_controller.value.duration` and `_controller.value.position`). The line that calls `EditorProjectStore.load` already runs AFTER `await _controller.initialize()`.

- [ ] **Step 5: Check for other call sites**

```bash
grep -rn "\.load()\s*$\|projectStore\.load\b\|EditorProjectStore.*load" \
  packages --include="*.dart" | grep -v test
```

Update any other site you find — likely `recents_screen.dart` if it pre-loads sidecars for thumbnail/state preview. For sites without a known duration (e.g. background prefetch for the recents list), pass the duration probed from the file or `Duration.zero` if the load result will be discarded for that use case.

Then verify the engine compiles:

```bash
~/fvm/versions/3.41.5/bin/flutter analyze packages/slipreel_engine
~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder
```

Expected: 0 errors related to this change. Existing warnings unrelated to this task may persist.

- [ ] **Step 6: Run tests**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_store_test.dart`

Expected: 2 new tests pass; existing store tests pass.

Then run the full engine + screen_recorder test suite:

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test packages/screen_recorder/test`

Expected: baseline failure count plus tests skipped in Task 4 Step 5.

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_store.dart \
        packages/slipreel_engine/test/state/editor_project_store_test.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
# Plus recents_screen.dart and any other touched sites.
git commit -m "feat(engine): EditorProjectStore.load takes videoDuration to seed first slice"
```

---

### Task 6: Slice-addressed controller mutators

Delete the project-global setters from `EditorProjectController` and add the per-slice equivalents.

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Create: `packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart`
- Modify: `packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart` (unskip and rewrite; or delete if covered by the new file)

- [ ] **Step 1: Write the failing tests**

Create `packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWithOneSlice({
  Duration end = const Duration(seconds: 10),
}) {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [ClipSlice(start: Duration.zero, end: end)],
    ),
  );
}

EditorProjectState _stateWithTwoSlices() {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [
        ClipSlice(start: Duration.zero, end: const Duration(seconds: 5)),
        ClipSlice(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
        ),
      ],
    ),
  );
}

void main() {
  group('EditorProjectController slice mutators', () {
    late EditorProjectController controller;
    setUp(() {
      controller = EditorProjectController(initial: _stateWithOneSlice());
    });

    test('setSliceSpeed updates clip 0 speed', () {
      controller.setSliceSpeed(0, 2.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 2.0);
    });

    test('setSliceSpeed clamps to [0.25, 4.0]', () {
      controller.setSliceSpeed(0, -1.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 0.25);
      controller.setSliceSpeed(0, 99.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 4.0);
    });

    test('setSliceSpeed no-ops on NaN', () {
      controller.setSliceSpeed(0, double.nan);
      expect(controller.current.timeline.clips[0].playbackSpeed, 1.0);
    });

    test('setSliceSpeed no-ops when value equals current', () {
      var notifications = 0;
      controller.addListener((_) => notifications++);
      controller.setSliceSpeed(0, 1.0); // same as default
      expect(notifications, 0);
    });

    test('setSliceMicGain clamps to 0..200', () {
      controller.setSliceMicGain(0, -10);
      expect(controller.current.timeline.clips[0].micGainPercent, 0);
      controller.setSliceMicGain(0, 300);
      expect(controller.current.timeline.clips[0].micGainPercent, 200);
    });

    test('setSliceSystemGain clamps to 0..200', () {
      controller.setSliceSystemGain(0, -10);
      expect(controller.current.timeline.clips[0].systemGainPercent, 0);
      controller.setSliceSystemGain(0, 250);
      expect(controller.current.timeline.clips[0].systemGainPercent, 200);
    });

    test('setSliceMicMuted toggles', () {
      controller.setSliceMicMuted(0, true);
      expect(controller.current.timeline.clips[0].micMuted, isTrue);
    });

    test('setSliceSystemMuted toggles', () {
      controller.setSliceSystemMuted(0, true);
      expect(controller.current.timeline.clips[0].systemMuted, isTrue);
    });

    test('setSliceFadeIn clamps negatives to zero', () {
      controller.setSliceFadeIn(0, const Duration(seconds: -1));
      expect(controller.current.timeline.clips[0].fadeIn, Duration.zero);
    });

    test('setSliceFadeOut accepts a positive duration', () {
      controller.setSliceFadeOut(0, const Duration(milliseconds: 500));
      expect(
        controller.current.timeline.clips[0].fadeOut,
        const Duration(milliseconds: 500),
      );
    });

    test('setSliceHideCursor flips bool', () {
      controller.setSliceHideCursor(0, true);
      expect(controller.current.timeline.clips[0].hideCursor, isTrue);
    });

    test('setSliceDisableSmoothMouse flips bool', () {
      controller.setSliceDisableSmoothMouse(0, true);
      expect(
        controller.current.timeline.clips[0].disableSmoothMouse,
        isTrue,
      );
    });

    test('out-of-range sliceIndex no-ops without throwing', () {
      controller.setSliceSpeed(5, 2.0);
      expect(controller.current.timeline.clips[0].playbackSpeed, 1.0);
    });

    test('removeSlice no-ops when only one slice exists', () {
      controller.removeSlice(0);
      expect(controller.current.timeline.clips, hasLength(1));
    });

    test('removeSlice deletes a slice when more than one exists', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.removeSlice(0);
      expect(controller.current.timeline.clips, hasLength(1));
      expect(
        controller.current.timeline.clips[0].start,
        const Duration(seconds: 5),
      );
    });

    test('removeSlice with out-of-range index no-ops', () {
      controller = EditorProjectController(initial: _stateWithTwoSlices());
      controller.removeSlice(99);
      expect(controller.current.timeline.clips, hasLength(2));
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart`

Expected: FAIL — the slice mutators don't exist.

- [ ] **Step 3: Implement the slice mutators**

Edit `packages/slipreel_engine/lib/state/editor_project_controller.dart`.

a) Delete the deprecated global setters:
- `setPlaybackSpeed`
- `setFadeIn`
- `setFadeOut`
- `setMicGain`
- `setMicMuted`
- `setSystemGain`
- `setSystemMuted`

b) Add the slice mutators. Append to the controller class:

```dart
  // ---- slice mutators ---------------------------------------------------

  ClipSlice? _slice(int sliceIndex) {
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return null;
    return clips[sliceIndex];
  }

  void _replaceSlice(int sliceIndex, ClipSlice next) {
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return;
    final updated = List<ClipSlice>.from(clips);
    updated[sliceIndex] = next;
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }

  void setSliceSpeed(int sliceIndex, double speed) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (speed.isNaN || !speed.isFinite) return;
    final clamped = speed.clamp(0.25, 4.0);
    if (clamped == s.playbackSpeed) return;
    _replaceSlice(sliceIndex, s.copyWith(playbackSpeed: clamped));
  }

  void setSliceFadeIn(int sliceIndex, Duration value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = value < Duration.zero ? Duration.zero : value;
    if (clamped == s.fadeIn) return;
    _replaceSlice(sliceIndex, s.copyWith(fadeIn: clamped));
  }

  void setSliceFadeOut(int sliceIndex, Duration value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = value < Duration.zero ? Duration.zero : value;
    if (clamped == s.fadeOut) return;
    _replaceSlice(sliceIndex, s.copyWith(fadeOut: clamped));
  }

  void setSliceMicGain(int sliceIndex, int percent) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = percent < 0 ? 0 : (percent > 200 ? 200 : percent);
    if (clamped == s.micGainPercent) return;
    _replaceSlice(sliceIndex, s.copyWith(micGainPercent: clamped));
  }

  void setSliceMicMuted(int sliceIndex, bool muted) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (muted == s.micMuted) return;
    _replaceSlice(sliceIndex, s.copyWith(micMuted: muted));
  }

  void setSliceSystemGain(int sliceIndex, int percent) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    final clamped = percent < 0 ? 0 : (percent > 200 ? 200 : percent);
    if (clamped == s.systemGainPercent) return;
    _replaceSlice(sliceIndex, s.copyWith(systemGainPercent: clamped));
  }

  void setSliceSystemMuted(int sliceIndex, bool muted) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (muted == s.systemMuted) return;
    _replaceSlice(sliceIndex, s.copyWith(systemMuted: muted));
  }

  void setSliceHideCursor(int sliceIndex, bool value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (value == s.hideCursor) return;
    _replaceSlice(sliceIndex, s.copyWith(hideCursor: value));
  }

  void setSliceDisableSmoothMouse(int sliceIndex, bool value) {
    final s = _slice(sliceIndex);
    if (s == null) return;
    if (value == s.disableSmoothMouse) return;
    _replaceSlice(sliceIndex, s.copyWith(disableSmoothMouse: value));
  }

  void removeSlice(int sliceIndex) {
    final clips = state.timeline.clips;
    if (clips.length <= 1) return;
    if (sliceIndex < 0 || sliceIndex >= clips.length) return;
    final updated = List<ClipSlice>.from(clips)..removeAt(sliceIndex);
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }
```

Add the import:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

- [ ] **Step 4: Run controller tests**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart`

Expected: 16 pass.

- [ ] **Step 5: Rewrite `editor_project_controller_audio_test.dart`**

Open `packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart`. Either:
- delete it (the new slice test covers the same surface), OR
- rewrite each test to seed `clips` and call `setSliceMicGain`/etc.

The first option is simpler — the new file's coverage is a superset. Run `git rm` on it if you delete.

- [ ] **Step 6: Update remaining `setPlaybackSpeed`/etc. call sites**

Compile errors will appear in:
- `packages/screen_recorder/lib/ui/widgets/inspector/contexts/clip_context_inspector.dart` (deleted in Task 11; can leave broken for now — the file gets deleted)
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart` — covered by Task 10
- Any test stubs that mocked the old setter names

If anything else surfaces, retarget it to `setSliceX(0, ...)`.

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/slipreel_engine`

Expected: 0 errors. screen_recorder analysis is allowed to fail at this point — Tasks 9–11 fix it.

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart \
        packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart
# If you deleted the audio test:
# git rm packages/slipreel_engine/test/state/editor_project_controller_audio_test.dart
git commit -m "feat(engine): add per-slice mutators to EditorProjectController"
```

---

### Task 7: Export pipeline reads from `clips[0]`

**Files:**
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart`
- Modify: `packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart`
- Modify: `packages/slipreel_engine/test/export/gif_export_pipeline_test.dart`

- [ ] **Step 1: Update `export_pipeline.dart`**

At the existing reads (around lines 144–162) replace `projectState.audioMix`, `projectState.playbackSpeed`, `projectState.fadeIn`, `projectState.fadeOut` with `clip0.audioMix`-shape values.

Define a helper at the top of `_buildEncoderConfig` (or wherever the reads happen — match the existing function's body):

```dart
final clip0 = projectState.timeline.clips.isEmpty
    ? null
    : projectState.timeline.clips.first;
final speed = clip0?.playbackSpeed ?? 1.0;
final fadeIn = clip0?.fadeIn ?? Duration.zero;
final fadeOut = clip0?.fadeOut ?? Duration.zero;
```

For `audioMix`, the existing `buildAudioMixArgs` takes an `AudioMix` object. Two options:
- Construct an `AudioMix` from the clip's audio fields at the boundary: `AudioMix(micGainPercent: clip0?.micGainPercent ?? 100, micMuted: clip0?.micMuted ?? false, systemGainPercent: clip0?.systemGainPercent ?? 100, systemMuted: clip0?.systemMuted ?? false)`.
- Change `buildAudioMixArgs` to take the four primitive fields directly.

Prefer the first option (boundary-level construction) — it keeps `buildAudioMixArgs` and `AudioMix` reusable for future per-segment work in sub-project C without changing their signature now.

Update the relevant lines:

```dart
final clip0 = projectState.timeline.clips.isEmpty
    ? null
    : projectState.timeline.clips.first;
final mix = AudioMix(
  micGainPercent: clip0?.micGainPercent ?? 100,
  micMuted: clip0?.micMuted ?? false,
  systemGainPercent: clip0?.systemGainPercent ?? 100,
  systemMuted: clip0?.systemMuted ?? false,
);
final audioMixPlan = buildAudioMixArgs(probed.audioStreams, mix);
final speed = clip0?.playbackSpeed ?? 1.0;
final fadeIn = clip0?.fadeIn ?? Duration.zero;
final fadeOut = clip0?.fadeOut ?? Duration.zero;
final outputDurationSec = inputDurationSec / speed;
// ... pass `speed`, `fadeIn`, `fadeOut` into the encoder config below
```

- [ ] **Step 2: Update `gif_export_pipeline.dart`**

Replace the existing `projectState.playbackSpeed`/`fadeIn`/`fadeOut` reads (around lines 116–131) with the same `clip0`-derived pattern.

- [ ] **Step 3: Update export tests**

In `ffmpeg_encoder_args_test.dart` and `gif_export_pipeline_test.dart`, find every place that constructs `EditorProjectState(... playbackSpeed: x, fadeIn: y, audioMix: z, ...)`. Replace with:

```dart
final state = EditorProjectState.defaults().copyWith(
  timeline: EditorProjectState.defaults().timeline.copyWith(
    clips: [
      ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
        playbackSpeed: 1.5,                  // whatever the test wanted
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 250),
        micGainPercent: 120,
        micMuted: true,
        systemGainPercent: 80,
      ),
    ],
  ),
);
```

Add `import 'package:slipreel_engine/state/clip_slice.dart';` and `import 'package:slipreel_engine/timeline/timeline.dart';` as needed.

The ffmpeg arg list assertions should be unchanged — the export pipeline produces the same filter args from a single-clip state as it did from project-globals.

- [ ] **Step 4: Run tests**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/export`

Expected: all export tests pass with the same filter-arg expectations.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/export_pipeline.dart \
        packages/slipreel_engine/lib/export/gif_export_pipeline.dart \
        packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart \
        packages/slipreel_engine/test/export/gif_export_pipeline_test.dart
git commit -m "refactor(engine): export pipelines read playback/fades/audio from clips[0]"
```

---

### Task 8: Smooth playhead reads `playbackSpeed` from `clips[0]`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/smooth_playhead_controller.dart`

- [ ] **Step 1: Inspect the existing reads**

```bash
grep -n "playbackSpeed" \
  packages/screen_recorder/lib/ui/widgets/timeline/smooth_playhead_controller.dart
```

The reads at lines 77 and 127 are `v.playbackSpeed` where `v` is an `EditorProjectState`. They now need to read from `v.timeline.clips`.

- [ ] **Step 2: Update the reads**

Replace each:

```dart
// before
_scale(DateTime.now().difference(_baseTimestamp), v.playbackSpeed);
```

with:

```dart
// after
_scale(
  DateTime.now().difference(_baseTimestamp),
  v.timeline.clips.isEmpty ? 1.0 : v.timeline.clips.first.playbackSpeed,
);
```

Apply at both call sites.

- [ ] **Step 3: Run any smooth-playhead tests if they exist**

```bash
ls packages/screen_recorder/test/ui/widgets/timeline/ | grep playhead
```

If a test file exists, run it; if it fails because it constructed state with `playbackSpeed:`, update the construction to use `Timeline.clips` (same pattern as Task 7 Step 3).

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/smooth_playhead_controller.dart
# Plus any test files touched.
git commit -m "refactor(app): SmoothPlayheadController reads speed from clips[0]"
```

---

### Task 9: Playback screen listens to slice speed

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Modify: `packages/screen_recorder/test/ui/screens/playback_screen_preview_speed_test.dart`
- Create: `packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart`

- [ ] **Step 1: Find the existing speed-listener wiring**

```bash
grep -n "playbackSpeed\|_applyEffectivePlaybackSpeed\|_lastClipSpeedApplied" \
  packages/screen_recorder/lib/ui/screens/playback_screen.dart
```

Expected sites:
- a `ref.listen<double>` watching `editorProjectControllerProvider.select((s) => s.playbackSpeed)`
- a call `_applyEffectivePlaybackSpeed(restored.playbackSpeed)` near the load completion
- a `setPlaybackSpeed` method called on the video controller via `_applyEffectivePlaybackSpeed`

- [ ] **Step 2: Update the reads**

Replace:

```dart
ref.listen<double>(
  editorProjectControllerProvider.select((s) => s.playbackSpeed),
  (_, next) => _applyEffectivePlaybackSpeed(next),
);
```

with:

```dart
ref.listen<double>(
  editorProjectControllerProvider.select((s) =>
      s.timeline.clips.isEmpty ? 1.0 : s.timeline.clips.first.playbackSpeed),
  (_, next) => _applyEffectivePlaybackSpeed(next),
);
```

Replace:

```dart
_applyEffectivePlaybackSpeed(restored.playbackSpeed);
```

with:

```dart
_applyEffectivePlaybackSpeed(
  restored.timeline.clips.isEmpty
      ? 1.0
      : restored.timeline.clips.first.playbackSpeed,
);
```

Replace any other `project.playbackSpeed` reads in the file with `project.timeline.clips.isEmpty ? 1.0 : project.timeline.clips.first.playbackSpeed`. Use grep to find them all:

```bash
grep -n "\.playbackSpeed" packages/screen_recorder/lib/ui/screens/playback_screen.dart
```

The `playbackSpeedLabel` passed to `EditorTimeline` should also be rebuilt from the slice value.

- [ ] **Step 3: Update `playback_screen_preview_speed_test.dart`**

The existing test constructs state with `playbackSpeed:`; update to construct via `Timeline.clips`. The existing assertions (preview rate × clip speed = effective rate) stay the same.

- [ ] **Step 4: Write the new slice-speed test**

Create `packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart` using the same pattern as the existing `playback_screen_preview_speed_test.dart` (read it first to match its harness). The new tests:

```dart
// (skeleton — match the existing test's setup boilerplate)
test('setSliceSpeed(0, 2.0) updates effective rate to 2.0', () {
  // Pump the playback screen with a state holding one 10s clip @1.0x.
  // Then call ref.read(editorProjectControllerProvider.notifier)
  //   .setSliceSpeed(0, 2.0);
  // Verify _lastClipSpeedApplied (or the public getter) == 2.0.
});

test('setSliceSpeed(0, 1.5) multiplies with preview rate 2x to 3.0', () {
  // Set _previewPlaybackSpeed via the same path the dropdown uses,
  // then setSliceSpeed(0, 1.5) — assert _lastClipSpeedApplied == 3.0.
});

test('resume from pause re-applies effective slice speed', () {
  // Start at 2x slice speed, controller goes paused -> playing,
  // assert the _onPlayStateTick listener calls
  // _applyEffectivePlaybackSpeed(2.0) on the resume edge.
});
```

If `_lastClipSpeedApplied` is private, add a `@visibleForTesting` getter:

```dart
@visibleForTesting
double get lastClipSpeedAppliedForTest => _lastClipSpeedApplied;
```

- [ ] **Step 5: Run tests**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/screens/playback_screen_preview_speed_test.dart packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart`

Expected: existing preview-speed tests pass; new slice-speed tests pass.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/screens/playback_screen_preview_speed_test.dart \
        packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart
git commit -m "feat(app): preview pipeline applies slice 0 playback speed"
```

---

### Task 10: Audio tab reads & writes via slice

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart`

- [ ] **Step 1: Locate the existing reads/writes**

```bash
grep -n "audioMix\|setMicGain\|setMicMuted\|setSystemGain\|setSystemMuted" \
  packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart
```

Existing usage at lines 131, 140, 141, 149, 150.

- [ ] **Step 2: Update the reads/writes**

Replace:

```dart
final mix = ref.watch(editorProjectControllerProvider).audioMix;
```

with:

```dart
final state = ref.watch(editorProjectControllerProvider);
final clip = state.timeline.clips.isEmpty ? null : state.timeline.clips.first;
final micGain = clip?.micGainPercent ?? 100;
final micMuted = clip?.micMuted ?? false;
final systemGain = clip?.systemGainPercent ?? 100;
final systemMuted = clip?.systemMuted ?? false;
```

Replace the slider/toggle callbacks:

```dart
onChanged: ctl.setMicGain,
onMuteToggle: () => ctl.setMicMuted(!mix.micMuted),
```

with:

```dart
onChanged: (v) => ctl.setSliceMicGain(0, v),
onMuteToggle: () => ctl.setSliceMicMuted(0, !micMuted),
```

And the system row:

```dart
onChanged: (v) => ctl.setSliceSystemGain(0, v),
onMuteToggle: () => ctl.setSliceSystemMuted(0, !systemMuted),
```

Update any places that pass `mix.micGainPercent`/etc. to widgets to use the new locals (`micGain`, `micMuted`, etc.).

- [ ] **Step 3: Verify compilation**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart`

Expected: 0 errors.

- [ ] **Step 4: Run any audio-tab widget tests**

```bash
ls packages/screen_recorder/test/ui/widgets/inspector/tabs/ | grep -i audio
```

If a test exists, run it. If it fails because it expected the old setter names on a mock controller, retarget to the new slice setters.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/audio_tab.dart
# Plus any test files touched.
git commit -m "refactor(app): audio tab reads/writes mix via clips[0]"
```

---

### Task 11: SliceEditor widget + InspectorToggle

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart`
- Create: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart`
- Create: `packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
- Delete: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/clip_context_inspector.dart`
- Delete: `packages/screen_recorder/test/ui/widgets/inspector/contexts/clip_context_inspector_test.dart` (if it exists)

- [ ] **Step 1: Add `InspectorToggle` to `inspector_widgets.dart`**

Append to `inspector_widgets.dart`:

```dart
/// A labeled on/off row. Used by the slice editor for the two cursor
/// toggles. Match the visual rhythm of [InspectorSlider] rows.
class InspectorToggle extends StatelessWidget {
  const InspectorToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Write the failing widget tests**

Create `packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/slice_editor.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWithOneSlice({
  ClipSlice? slice,
}) {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [
        slice ??
            ClipSlice(
              start: Duration.zero,
              end: const Duration(seconds: 10),
            ),
      ],
    ),
  );
}

EditorProjectState _stateWithTwoSlices() {
  return EditorProjectState.defaults().copyWith(
    timeline: const Timeline(zoomTracks: []).copyWith(
      clips: [
        ClipSlice(start: Duration.zero, end: const Duration(seconds: 5)),
        ClipSlice(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
        ),
      ],
    ),
  );
}

Widget _host({
  required EditorProjectState initial,
  VoidCallback? onClose,
  int sliceIndex = 0,
}) {
  return ProviderScope(
    overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: initial),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SliceEditor(
          sliceIndex: sliceIndex,
          onClose: onClose ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders header with formatted slice bounds and speed',
      (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice(
      slice: ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 90),
        playbackSpeed: 1.5,
      ),
    )));
    expect(find.textContaining('1:30'), findsOneWidget); // 90s = 1:30
    expect(find.textContaining('1.5'), findsOneWidget);
  });

  testWidgets('Remove slice button is hidden when only one slice',
      (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice()));
    expect(find.text('Remove slice'), findsNothing);
  });

  testWidgets('Remove slice button is visible when multiple slices',
      (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithTwoSlices()));
    expect(find.text('Remove slice'), findsOneWidget);
  });

  testWidgets('tapping Remove slice calls removeSlice and onClose',
      (tester) async {
    var closed = false;
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithTwoSlices()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(
            sliceIndex: 0,
            onClose: () => closed = true,
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Remove slice'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(
      container.read(editorProjectControllerProvider).timeline.clips,
      hasLength(1),
    );
  });

  testWidgets('close button calls onClose without mutating state',
      (tester) async {
    var closed = false;
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithOneSlice()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(sliceIndex: 0, onClose: () => closed = true),
        ),
      ),
    ));
    await tester.tap(find.byTooltip('Close slice editor'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(
      container.read(editorProjectControllerProvider).timeline.clips.first
          .playbackSpeed,
      1.0,
    );
  });

  testWidgets('tapping the 2x speed chip calls setSliceSpeed', (tester) async {
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithOneSlice()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(sliceIndex: 0, onClose: () {}),
        ),
      ),
    ));
    await tester.tap(find.text('2x'));
    await tester.pumpAndSettle();
    expect(
      container.read(editorProjectControllerProvider).timeline.clips.first
          .playbackSpeed,
      2.0,
    );
  });

  testWidgets('toggling Hide cursor calls setSliceHideCursor', (tester) async {
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithOneSlice()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(sliceIndex: 0, onClose: () {}),
        ),
      ),
    ));
    // Find the Hide cursor row's switch (Switch.adaptive renders as Switch on macOS/Linux test env).
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(
      container.read(editorProjectControllerProvider).timeline.clips.first
          .hideCursor,
      isTrue,
    );
  });

  testWidgets('renders gracefully when sliceIndex is out of range',
      (tester) async {
    await tester.pumpWidget(_host(
      initial: EditorProjectState.defaults(), // empty clips
      sliceIndex: 0,
    ));
    expect(find.textContaining('No slice'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart`

Expected: FAIL — `slice_editor.dart` doesn't exist.

- [ ] **Step 4: Implement `SliceEditor`**

Create `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Inspector context shown when a clip slice is selected. Edits one
/// slice's playback, audio, fade, and cursor settings. Initially the
/// project always has exactly one slice (covering the whole video);
/// sub-project C's cut tool introduces multi-slice projects.
class SliceEditor extends ConsumerWidget {
  const SliceEditor({
    super.key,
    required this.sliceIndex,
    required this.onClose,
  });

  final int sliceIndex;
  final VoidCallback onClose;

  static const _speedPresets = <double>[0.5, 1.0, 1.5, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorProjectControllerProvider);
    final notifier = ref.read(editorProjectControllerProvider.notifier);
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) {
      return _MissingSlice(onClose: onClose);
    }
    final clip = clips[sliceIndex];
    final canRemove = clips.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          icon: Icons.content_cut,
          title: 'Slice',
          subtitle:
              '${_fmt(clip.start)} – ${_fmt(clip.end)} · ${clip.playbackSpeed.toStringAsFixed(2)}x',
          onClose: onClose,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const InspectorSectionLabel('Speed'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in _speedPresets)
                    _SpeedChip(
                      label: '${s == 1.0 ? '1' : s}x',
                      isSelected: (clip.playbackSpeed - s).abs() < 0.001,
                      onTap: () => notifier.setSliceSpeed(sliceIndex, s),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              InspectorSlider(
                label: 'Fine-tune',
                subtitle:
                    'Final speed: ${clip.playbackSpeed.toStringAsFixed(2)}x',
                value: clip.playbackSpeed,
                min: 0.25,
                max: 4.0,
                onChanged: (v) => notifier.setSliceSpeed(sliceIndex, v),
                onReset: () => notifier.setSliceSpeed(sliceIndex, 1.0),
                canReset: clip.playbackSpeed != 1.0,
              ),
              const InspectorSectionDivider(),
              const InspectorSectionLabel('Audio'),
              _GainRow(
                label: 'Mic',
                percent: clip.micGainPercent,
                muted: clip.micMuted,
                onPercentChanged: (v) =>
                    notifier.setSliceMicGain(sliceIndex, v),
                onMutedChanged: (v) =>
                    notifier.setSliceMicMuted(sliceIndex, v),
              ),
              const SizedBox(height: 12),
              _GainRow(
                label: 'System',
                percent: clip.systemGainPercent,
                muted: clip.systemMuted,
                onPercentChanged: (v) =>
                    notifier.setSliceSystemGain(sliceIndex, v),
                onMutedChanged: (v) =>
                    notifier.setSliceSystemMuted(sliceIndex, v),
              ),
              const InspectorSectionDivider(),
              const InspectorSectionLabel('Cursor'),
              InspectorToggle(
                label: 'Hide cursor',
                value: clip.hideCursor,
                onChanged: (v) =>
                    notifier.setSliceHideCursor(sliceIndex, v),
              ),
              InspectorToggle(
                label: 'Disable smooth mouse',
                value: clip.disableSmoothMouse,
                onChanged: (v) =>
                    notifier.setSliceDisableSmoothMouse(sliceIndex, v),
              ),
              const InspectorSectionDivider(),
              const InspectorSectionLabel('Fades'),
              InspectorSlider(
                label: 'Fade in',
                subtitle:
                    '${(clip.fadeIn.inMicroseconds / 1000).toInt()} ms',
                value: clip.fadeIn.inMicroseconds / 1e6,
                min: 0,
                max: 2,
                onChanged: (s) => notifier.setSliceFadeIn(
                  sliceIndex,
                  Duration(microseconds: (s * 1e6).round()),
                ),
                onReset: () => notifier.setSliceFadeIn(sliceIndex, Duration.zero),
                canReset: clip.fadeIn != Duration.zero,
              ),
              const SizedBox(height: 12),
              InspectorSlider(
                label: 'Fade out',
                subtitle:
                    '${(clip.fadeOut.inMicroseconds / 1000).toInt()} ms',
                value: clip.fadeOut.inMicroseconds / 1e6,
                min: 0,
                max: 2,
                onChanged: (s) => notifier.setSliceFadeOut(
                  sliceIndex,
                  Duration(microseconds: (s * 1e6).round()),
                ),
                onReset: () =>
                    notifier.setSliceFadeOut(sliceIndex, Duration.zero),
                canReset: clip.fadeOut != Duration.zero,
              ),
              if (canRemove) ...[
                const SizedBox(height: 24),
                _RemoveSliceButton(onTap: () {
                  notifier.removeSlice(sliceIndex);
                  onClose();
                }),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _MissingSlice extends StatelessWidget {
  const _MissingSlice({required this.onClose});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No slice selected',
            style: TextStyle(color: Colors.white70),
          ),
          TextButton(onPressed: onClose, child: const Text('Close')),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onClose,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFB07020).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: const Color(0xFFE0A050), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: kInspectorMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Tooltip(
          message: 'Close slice editor',
          child: InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: kInspectorPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kInspectorBorder),
              ),
              child: const Icon(Icons.close, color: Colors.white70, size: 16),
            ),
          ),
        ),
      ],
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? kInspectorAccent : kInspectorBorder,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _GainRow extends StatelessWidget {
  const _GainRow({
    required this.label,
    required this.percent,
    required this.muted,
    required this.onPercentChanged,
    required this.onMutedChanged,
  });
  final String label;
  final int percent;
  final bool muted;
  final ValueChanged<int> onPercentChanged;
  final ValueChanged<bool> onMutedChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        Expanded(
          child: Slider(
            value: percent.toDouble(),
            min: 0,
            max: 200,
            divisions: 200,
            onChanged: (v) => onPercentChanged(v.round()),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          muted ? 'Muted' : '$percent%',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(width: 8),
        Switch.adaptive(value: muted, onChanged: onMutedChanged),
      ],
    );
  }
}

class _RemoveSliceButton extends StatelessWidget {
  const _RemoveSliceButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
      label: const Text(
        'Remove slice',
        style: TextStyle(color: Colors.redAccent),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF5A2A2A)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}
```

- [ ] **Step 5: Wire `inspector_panel.dart` to use `SliceEditor`**

Edit `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`:

a) Add import:

```dart
import 'package:screen_recorder/ui/widgets/inspector/contexts/slice_editor.dart';
```

b) Remove import for `clip_context_inspector.dart`.

c) Replace the `_clipContext()` method body:

```dart
// before
Widget _clipContext() {
  return ClipContextInspector(
    clipDuration: widget.clipDuration,
    onClose: () => widget.onSelectionCleared?.call(),
  );
}

// after
Widget _clipContext() {
  return SliceEditor(
    sliceIndex: 0,
    onClose: () => widget.onSelectionCleared?.call(),
  );
}
```

(The `widget.clipDuration` prop is no longer needed for the body; the SliceEditor reads bounds from the slice itself. The prop can stay on `InspectorPanel` for callers that pass it — it's now unused inside the widget. Don't remove it as part of this task; it's a separate cleanup.)

- [ ] **Step 6: Delete `clip_context_inspector.dart` and its test**

```bash
git rm packages/screen_recorder/lib/ui/widgets/inspector/contexts/clip_context_inspector.dart
# Only if it exists:
if [ -f packages/screen_recorder/test/ui/widgets/inspector/contexts/clip_context_inspector_test.dart ]; then
  git rm packages/screen_recorder/test/ui/widgets/inspector/contexts/clip_context_inspector_test.dart
fi
```

- [ ] **Step 7: Run all the tests**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart`

Expected: all SliceEditor widget tests pass.

Then run the full screen_recorder suite:

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/screen_recorder/test`

Expected: baseline failure count (4 pre-existing) + 0 new failures.

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/inspector_widgets.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart \
        packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart
git commit -m "feat(app): add SliceEditor widget; replace ClipContextInspector"
```

---

### Task 12: Slice-aware cursor in preview canvas

`hideCursor` and `disableSmoothMouse` need to affect the preview render. With only one slice in B, "the current slice" is always `clips[0]`. The code path should still take a position-driven slice lookup so C's cut tool drops in cleanly.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (the call site that passes `hideCursorOverlay` into `PlaybackCanvas`)

- [ ] **Step 1: Add a slice lookup helper**

Create or extend a helper near where the slice model lives. Append to `packages/slipreel_engine/lib/state/clip_slice.dart`:

```dart
/// Returns the slice covering [position]. Falls back to the last slice
/// when [position] is at or past the final end (final frame); falls
/// back to a fresh empty slice when [clips] is empty. The lookup is
/// linear (O(n)) — fine for B (n=1) and for typical slice counts in C.
ClipSlice clipSliceAt(List<ClipSlice> clips, Duration position) {
  if (clips.isEmpty) {
    return ClipSlice(start: Duration.zero, end: Duration.zero);
  }
  for (final s in clips) {
    if (position >= s.start && position < s.end) return s;
  }
  return clips.last;
}
```

Add unit tests in `packages/slipreel_engine/test/state/clip_slice_test.dart` (append):

```dart
  group('clipSliceAt', () {
    test('returns the slice containing the position', () {
      final clips = [
        ClipSlice(start: Duration.zero, end: const Duration(seconds: 5)),
        ClipSlice(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
        ),
      ];
      expect(
        clipSliceAt(clips, const Duration(seconds: 3)).end,
        const Duration(seconds: 5),
      );
      expect(
        clipSliceAt(clips, const Duration(seconds: 7)).start,
        const Duration(seconds: 5),
      );
    });
    test('returns the last slice when position is past the end', () {
      final clips = [
        ClipSlice(start: Duration.zero, end: const Duration(seconds: 5)),
        ClipSlice(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
        ),
      ];
      expect(
        clipSliceAt(clips, const Duration(seconds: 20)).end,
        const Duration(seconds: 10),
      );
    });
    test('returns an empty fallback when clips is empty', () {
      final s = clipSliceAt(const [], const Duration(seconds: 1));
      expect(s.end, Duration.zero);
    });
  });
```

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/clip_slice_test.dart`

Expected: new tests pass.

- [ ] **Step 2: Wire `playback_canvas.dart` to use the slice's cursor flags**

Find the `hideCursorOverlay` field and the `showCursor` computation (around line 419 today):

```dart
final showCursor = hasCursorData && !widget.hideCursorOverlay;
```

The decision now depends on EITHER the project-global `hideCursorOverlay` OR the current slice's `hideCursor`. Plumb the slice flags in. Two reasonable shapes:

a) Pass slice flags as `bool` parameters into `PlaybackCanvas` and compute the effective hide at the call site (`playback_screen.dart`). PREFERRED — keeps `PlaybackCanvas` UI-agnostic.

Add a new parameter to `PlaybackCanvas`:

```dart
final bool sliceHideCursor;
final bool sliceDisableSmoothMouse;
```

Update the show-cursor calculation:

```dart
final showCursor = hasCursorData
    && !widget.hideCursorOverlay
    && !widget.sliceHideCursor;
```

For `disableSmoothMouse`, the existing code passes `widget.cursorAnimationConfig` into `_scenePassBuilder.build`. When the slice disables smoothing, use a "no smoothing" animation config. The simplest expression: pass `CursorAnimationConfig.preset(CursorAnimationStyle.none)` (or whatever the existing enum names its no-smoothing variant — check `cursor_glyph.dart` / `animation_style.dart`). Wrap the read:

```dart
final cursorAnimationConfig = widget.sliceDisableSmoothMouse
    ? const CursorAnimationConfig.preset(CursorAnimationStyle.none)
    : widget.cursorAnimationConfig;
```

If the existing enum doesn't have a `.none` style, use `CursorAnimationStyle.smooth` with all damping/duration set to instant — but DON'T invent new enum values here; if `.none`/`.raw`/`.linear` exists, use it. If nothing fits, the safest no-op is `widget.cursorAnimationConfig.copyWith(damping: 0, sampleHz: 1000)` or similar (consult `animation_config.dart`). Capture this open question as a comment in the code and pick the most "no smoothing" preset the project already supports.

b) Pass the slice itself into `PlaybackCanvas` and read its flags. Heavier coupling; avoid.

Apply option (a).

- [ ] **Step 3: Pass slice flags from `playback_screen.dart`**

Find the `PlaybackCanvas` construction site (around line 1170 today):

```dart
PlaybackCanvas(
  // ...
  hideCursorOverlay: project.hideCursorOverlay,
  // ...
)
```

Add the slice-flag reads. The current playhead position lives on `_controller.value.position` (or `_smoothPlayhead.position`):

```dart
final currentSlice = clipSliceAt(
  project.timeline.clips,
  _controller.value.position,
);
```

This needs to recompute on each build that depends on position. The existing build already rebuilds on controller ticks (the canvas's hover/play state listens), so the slice lookup runs per build. For B with one slice this is essentially `clips[0]`.

Add the import:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';
```

Pass into the canvas:

```dart
PlaybackCanvas(
  // ...
  hideCursorOverlay: project.hideCursorOverlay,
  sliceHideCursor: currentSlice.hideCursor,
  sliceDisableSmoothMouse: currentSlice.disableSmoothMouse,
  // ...
)
```

- [ ] **Step 4: Verify compilation and run the full suite**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder packages/slipreel_engine`
Expected: 0 errors.

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test packages/screen_recorder/test`

Expected: baseline failure count preserved. If any widget test that pumps `PlaybackCanvas` directly broke because of the new required params, update those tests to pass `sliceHideCursor: false, sliceDisableSmoothMouse: false`. Make these params optional with `false` defaults if there are many call sites:

```dart
this.sliceHideCursor = false,
this.sliceDisableSmoothMouse = false,
```

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/clip_slice.dart \
        packages/slipreel_engine/test/state/clip_slice_test.dart \
        packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): preview canvas applies slice hideCursor + disableSmoothMouse"
```

---

### Task 13: Final verification

**Files:**
- (none — verification only)

- [ ] **Step 1: Run the full test suite**

Run: `~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test packages/screen_recorder/test`

Expected: baseline + new slice tests. The 4 pre-existing failures from sub-A's baseline persist; no new failures. Note the final counts.

- [ ] **Step 2: Static analysis**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/slipreel_engine packages/screen_recorder`

Expected: 0 errors. Warnings unrelated to this branch may persist.

- [ ] **Step 3: Smoke-test the running app**

Use the `mcp__flutter-qa` MCP tools (project convention — see `agent_wires_debug_setup.md` memory) to:

a) `boot_app` and let the app finish onboarding (if needed) and reach the home screen.
b) Open an existing recording from Recents (or record a short clip if none exist).
c) Verify the editor opens, the clip lane is visible, the timeline plays.
d) Click the clip bar in the timeline. Expect: inspector panel shows the SliceEditor (orange "Slice" header, slice bounds + speed, Speed/Audio/Cursor/Fades sections). The "Remove slice" button should NOT be visible.
e) Tap the `2x` speed chip. Expect: the preview playback speeds up to 2x (multiplied by the toolbar's preview rate if it's not at 1x).
f) Toggle "Hide cursor". Expect: the cursor disappears from the preview while playing.
g) Drag the Mic gain slider. Expect: state updates immediately (verify via the inspector's audio tab on the same project — same value).
h) Tap the close `[x]` button on the SliceEditor header. Expect: inspector returns to the default tab (Properties), no state mutation.
i) Restart the app via `hot_restart`. Reopen the same recording. Expect: all slice edits persisted (speed, mic gain, hide cursor) — the SliceEditor reflects them on reopen.
j) `screenshot` the editor at points (d) and (i) for the PR description.

If anything in (a)–(i) fails, the failing piece is a bug in this branch; create a small fix commit before moving on.

- [ ] **Step 4: Confirm `debug_probe.dart` is still untouched**

```bash
git status -s
```

Expected: `M packages/screen_recorder/lib/debug/debug_probe.dart` (carried over from main — LOCAL-ONLY, not committed in this branch).

- [ ] **Step 5: Hand off to finishing-a-development-branch**

Invoke the `superpowers:finishing-a-development-branch` skill. It will run tests once more and present merge/PR/keep/discard options.

---

## Self-Review

**Spec coverage (each spec section → task):**

- Decision 1 (slices replace globals) → Task 4 removes globals.
- Decision 2 (per-slice speed in preview AND export) → Task 7 (export) + Task 9 (preview).
- Decision 3 (cursor scope) → Task 12 (preview canvas wires `sliceHideCursor` + `sliceDisableSmoothMouse`; rest stays project-global, no change).
- Decision 4 (per-slice fades) → Task 6 (`setSliceFadeIn`/`Out`) + Task 7 (export reads from clip0).
- Decision 5 (slices on `Timeline.clips`) → Task 2.
- Decision 6 (hide remove when 1 slice) → Task 11 (SliceEditor's `canRemove`).
- Decision 7 (SliceEditor replaces inspector context) → Task 11.
- Decision 8 (clean migration, move and remove) → Task 3 synthesizes; Task 4 removes globals from JSON shape.
- Decision 9 (explicit [start, end] Durations) → Task 1 fields.
- Decision 10 (multiplicative speed stacking) → Task 9 (existing `_applyEffectivePlaybackSpeed` already multiplies — verified in test).

**Data model in spec section "ClipSlice"** → Task 1.
**Timeline extension** → Task 2.
**EditorProjectState removals** → Task 4.
**Schema migration** → Tasks 3 + 4.
**Controller API** → Task 6. Slice seeding → Task 5 (in `EditorProjectStore.load`).
**SliceEditor widget** → Task 11.
**Preview pipeline (speed + cursor)** → Tasks 9 + 12.
**Export pipeline** → Task 7.
**Smooth playhead** → Task 8 (called out in spec section "Preview Pipeline" indirectly via `playbackSpeed`).
**Tests** → covered per task.

**Type consistency:** mutator names match (`setSliceSpeed`, `setSliceMicGain`, etc.). `ClipSlice` field names match the spec (`micGainPercent`, not `micGainPct`). The migration's clip-JSON keys match `ClipSlice.toJson` (`startMicros`, `endMicros`, `playbackSpeed`, `fadeInMicros`, `fadeOutMicros`, …). `Timeline.clips` is the field name throughout.

**Placeholder scan:** No "TBD"/"implement later"/"similar to Task N". Every code-changing step has full code or a precise grep+replace pattern. Some "if it exists" guards (e.g., the `clip_context_inspector_test.dart` deletion) — those are explicit conditional commands the implementer executes, not undefined holes.

**Known soft spot:** Task 12 Step 2 leaves the `disableSmoothMouse` no-smoothing animation config choice to the implementer ("use `.none` if it exists, else dampen via `copyWith`"). This is a deliberate hand-off because I haven't confirmed the existing enum values from this plan's vantage; the implementer should grep `cursor_animation_config.dart` and pick the correct existing preset. Acceptable given the task is otherwise well-scoped.
