# Slice Editor — Design (Sub-Project B of 3)

**Date:** 2026-06-02
**Sub-project:** B (Slice editor). Predecessor: A (timeline scale slider, merged 89ec9c4). Successor: C (cut tool — splits a slice into multiple, depends on B's data model).

## Goal

Introduce a per-slice editing model and UI that replaces today's `ClipContextInspector`. A `ClipSlice` is a temporal segment of the source video with its own playback speed, fades, audio mix, and cursor flags. In sub-project B the system always has exactly one slice spanning the whole video (so behavior is observably equivalent to today). The data model, controller API, SliceEditor UI, preview pipeline, and export pipeline all move to slice-addressed values, so that C can introduce the cut tool by only touching the cut-creation logic.

## Architecture

```
EditorProjectState
  └─ timeline: Timeline
       ├─ zoomTracks: List<ZoomTrack>      (unchanged)
       └─ clips: List<ClipSlice>           (NEW)
              └─ playbackSpeed, fadeIn, fadeOut, audio…, cursor flags
```

The state-level fields `playbackSpeed`, `fadeIn`, `fadeOut`, `audioMix` move OFF `EditorProjectState` and ONTO `ClipSlice`. Schema bumps v6→v7 with a migration that synthesizes a single slice from those globals.

The preview pipeline reads `state.timeline.clips[0]` (always present, by invariant). The export pipeline does the same. Both code paths look identical to the single-global-value world today; the slice indirection is invisible to behavior in B but unblocks C.

The SliceEditor widget replaces the inspector panel content when a slice is selected (same surface area as today's `ClipContextInspector`).

## Tech Stack

- **Engine:** Dart (existing `slipreel_engine` package), Riverpod 2 (`StateNotifier`), schema-versioned JSON sidecar persistence.
- **UI:** Flutter (existing `screen_recorder` package), Material 3, `AppPalette` theme tokens, existing `InspectorSlider` / `InspectorSectionDivider` widgets.
- **Preview:** `video_player` package (existing). No changes to the package itself; only how we set rate.
- **Export:** ffmpeg pipeline (unchanged for B — reads slice[0] just like it read project globals).

---

## Decisions (locked during brainstorming)

1. **Slices replace globals entirely** — `playbackSpeed`, `fadeIn`, `fadeOut`, `audioMix` leave `EditorProjectState` and move onto `ClipSlice`.
2. **Per-slice speed applies in PREVIEW and EXPORT** — preview's `_applyEffectivePlaybackSpeed(clipSpeed)` reads from `clips[0].playbackSpeed`. Multiplicative with sub-A's preview-rate dropdown (`effective = sliceSpeed × previewRate`).
3. **Cursor scope:** only the two new toggles (`hideCursor`, `disableSmoothMouse`) go per-slice. Existing cursor appearance fields (`cursorStyle`, `cursorSize`, animations, etc.) stay project-global.
4. **Per-slice fades** — `fadeIn`/`fadeOut` move with audio/speed onto `ClipSlice`.
5. **Slices location:** `Timeline.clips: List<ClipSlice>` (alongside `zoomTracks`).
6. **"Remove slice" button hidden** when `clips.length == 1`.
7. **SliceEditor replaces inspector panel content** when a slice is selected — same model as today's `ClipContextInspector`.
8. **Clean migration:** v6→v7 moves globals into the synthesized slice and REMOVES the top-level keys.
9. **Slice bounds:** explicit `[start, end]` Durations per slice. Adjacency invariant: `clips[i].end == clips[i+1].start`; coverage invariant: `clips.first.start == 0 && clips.last.end == videoDuration`. Validated at controller boundary in C; in B with a single slice the invariants are trivially true.
10. **Speed stacking:** multiplicative (`sliceSpeed × previewRate`).

---

## Data Model

### `ClipSlice`

**File:** `packages/slipreel_engine/lib/state/clip_slice.dart` (new)

```dart
class ClipSlice {
  const ClipSlice({
    required this.start,
    required this.end,
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.micGainPercent = 100,
    this.micMuted = false,
    this.systemGainPercent = 100,
    this.systemMuted = false,
    this.hideCursor = false,
    this.disableSmoothMouse = false,
  });

  final Duration start;            // inclusive, source-video time
  final Duration end;              // exclusive
  final double playbackSpeed;      // valid range [0.25, 4.0]; clamp at controller boundary
  final Duration fadeIn;           // ≥ 0
  final Duration fadeOut;          // ≥ 0
  final int micGainPercent;        // 0..200
  final bool micMuted;
  final int systemGainPercent;     // 0..200
  final bool systemMuted;
  final bool hideCursor;           // hide the cursor overlay across this slice's time range
  final bool disableSmoothMouse;   // use raw recorded cursor positions instead of animated

  Duration get length => end - start;

  ClipSlice copyWith({...});       // standard
  Map<String, dynamic> toJson();   // standard
  factory ClipSlice.fromJson(Map<String, dynamic> json);

  @override bool operator ==(Object other);
  @override int get hashCode;
}
```

JSON shape:

```json
{
  "startMicros": 0,
  "endMicros": 12340000,
  "playbackSpeed": 1.0,
  "fadeInMicros": 0,
  "fadeOutMicros": 0,
  "micGainPercent": 100,
  "micMuted": false,
  "systemGainPercent": 100,
  "systemMuted": false,
  "hideCursor": false,
  "disableSmoothMouse": false
}
```

`ClipSlice.fromJson` is defensive: missing keys take defaults; out-of-range values clamp; missing `startMicros`/`endMicros` throw `FormatException` (a slice without bounds is meaningless).

### `Timeline` extension

**File:** `packages/slipreel_engine/lib/timeline/timeline.dart` (modify)

Add `clips: List<ClipSlice>` alongside `zoomTracks`. Default = empty list (the controller seeds the single slice after the video duration is known).

```dart
class Timeline {
  const Timeline({
    this.zoomTracks = const <ZoomTrack>[],
    this.clips = const <ClipSlice>[],
  });

  final List<ZoomTrack> zoomTracks;
  final List<ClipSlice> clips;     // NEW

  Timeline copyWith({List<ZoomTrack>? zoomTracks, List<ClipSlice>? clips});
  Map<String, dynamic> toJson();   // adds "clips": [...]
  factory Timeline.fromJson(Map<String, dynamic> json);
}
```

`Timeline.defaults()` keeps emitting empty `clips` — the seeding happens once the controller knows the video duration.

### `EditorProjectState` removals

**File:** `packages/slipreel_engine/lib/state/editor_project_state.dart` (modify)

Remove fields (and their `copyWith` parameters, `toJson` keys, `fromJson` reads, `==`/`hashCode` participation):
- `playbackSpeed`
- `fadeIn`
- `fadeOut`
- `audioMix`

Keep everything else (cursor appearance, screen/cursor animation configs, window frame, output aspect, timelineScale, etc.).

**No project-level convenience getters for the removed fields.** Every call site updates to read from `timeline.clips[i]` directly. (Convenience shims tend to ossify and undo the migration — better to make the breakage explicit and migrate every consumer in this branch.)

### Schema migration v6 → v7

**File:** `packages/slipreel_engine/lib/state/editor_project_state.dart` (modify `_schemaMigrations`)

The migration needs the source video's duration to synthesize the slice's `end`. The duration isn't on the state today — it's known by `EditorProjectStore.load(videoPath)`. Plumbing:

- `EditorProjectStore.load` gains a required `Duration videoDuration` parameter.
- `EditorProjectState.fromJson` gains a required `Duration videoDuration` parameter; passes it through `migrateEditorProjectJson`.
- `migrateEditorProjectJson` gains a required `Duration videoDuration` parameter; passes it to each migration step that needs it.

Migration step (v6 → v7):

```dart
(json, videoDuration) {
  final next = Map<String, dynamic>.from(json);
  final speed = (next.remove('playbackSpeed') as num?)?.toDouble() ?? 1.0;
  final fadeIn = next.remove('fadeInMicros');
  final fadeOut = next.remove('fadeOutMicros');
  final audio = next.remove('audioMix') as Map<String, dynamic>?;

  final slice = {
    'startMicros': 0,
    'endMicros': videoDuration.inMicroseconds,
    'playbackSpeed': speed,
    'fadeInMicros': fadeIn is num ? fadeIn.toInt() : 0,
    'fadeOutMicros': fadeOut is num ? fadeOut.toInt() : 0,
    'micGainPercent': (audio?['micGainPercent'] as num?)?.toInt() ?? 100,
    'micMuted': (audio?['micMuted'] as bool?) ?? false,
    'systemGainPercent': (audio?['systemGainPercent'] as num?)?.toInt() ?? 100,
    'systemMuted': (audio?['systemMuted'] as bool?) ?? false,
    'hideCursor': false,
    'disableSmoothMouse': false,
  };

  final timeline = (next['timeline'] as Map<String, dynamic>?) ?? const {};
  next['timeline'] = {
    ...timeline,
    'clips': [slice],
  };
  next['schemaVersion'] = 7;
  return next;
},
```

After migration the top-level v7 JSON has no `playbackSpeed`/`fadeInMicros`/`fadeOutMicros`/`audioMix` keys. `EditorProjectState.fromJson` doesn't look for them. Loading a v7-clean JSON without going through migration yields the same result.

`EditorProjectState.currentSchemaVersion` bumps to 7.

---

## Controller API

**File:** `packages/slipreel_engine/lib/state/editor_project_controller.dart` (modify)

### Slice seeding (one-shot)

On the controller's `load(videoPath, videoDuration)` (or wherever the project state first becomes available with a known duration), after `fromJson`:

```dart
if (state.timeline.clips.isEmpty) {
  state = state.copyWith(
    timeline: state.timeline.copyWith(
      clips: [ClipSlice(start: Duration.zero, end: videoDuration)],
    ),
  );
}
```

This handles the brand-new-project case (no sidecar file → defaults → empty `clips`) without bloating `Timeline.defaults()` with a duration parameter.

### New mutators

```dart
void setSliceSpeed(int sliceIndex, double speed);
void setSliceFadeIn(int sliceIndex, Duration value);
void setSliceFadeOut(int sliceIndex, Duration value);
void setSliceMicGain(int sliceIndex, int percent);
void setSliceMicMuted(int sliceIndex, bool muted);
void setSliceSystemGain(int sliceIndex, int percent);
void setSliceSystemMuted(int sliceIndex, bool muted);
void setSliceHideCursor(int sliceIndex, bool value);
void setSliceDisableSmoothMouse(int sliceIndex, bool value);
void removeSlice(int sliceIndex);
```

Each mutator:
1. Returns early if `sliceIndex < 0 || sliceIndex >= state.timeline.clips.length`.
2. Clamps the input at the boundary:
   - speed: clamp `[0.25, 4.0]`; reject NaN/Infinity (no-op).
   - gain: clamp `[0, 200]`.
   - duration: clamp `≥ Duration.zero`.
3. No-ops if the requested value equals the current slice's value (consistent with the post-A `==`/`hashCode` discipline).
4. Emits `state = state.copyWith(timeline: timeline.copyWith(clips: newClips))` where `newClips` is `List.from(clips)..[sliceIndex] = clips[sliceIndex].copyWith(...)`.

`removeSlice(int)`:
- No-op when `clips.length <= 1` (matches the UI hiding the button — defense in depth).
- Removes the slice. **B never calls this**; it exists for C. Spec it anyway so the API is complete and tested.

### Deprecated globals

The old project-global setters (`setPlaybackSpeed`, `setFadeIn`, `setFadeOut`, `setAudioMix`) are DELETED in this branch — not deprecated. Every call site migrates to the slice equivalent. Cleaner than carrying compatibility shims.

---

## SliceEditor Widget

**File:** `packages/screen_recorder/lib/ui/widgets/inspector/contexts/slice_editor.dart` (new — replaces `clip_context_inspector.dart`)

### Props

```dart
class SliceEditor extends ConsumerWidget {
  const SliceEditor({
    super.key,
    required this.sliceIndex,    // always 0 in B
    required this.onClose,
  });
  final int sliceIndex;
  final VoidCallback onClose;
}
```

### Layout

```
┌─────────────────────────────────────────┐
│ [icon] Slice                  [×]       │
│        0:00 – 2:30 · 1.5×               │
├─────────────────────────────────────────┤
│ Speed                                   │
│   [0.5×] [1×] [1.5×] [2×]               │
│   ─── fine-tune slider ───              │
├─────────────────────────────────────────┤
│ Audio                                   │
│   Mic     ─── slider ───  [○ Mute]      │
│   System  ─── slider ───  [○ Mute]      │
├─────────────────────────────────────────┤
│ Cursor                                  │
│   Hide cursor              [ Switch ]   │
│   Disable smooth mouse     [ Switch ]   │
├─────────────────────────────────────────┤
│ Fades                                   │
│   Fade in   ─── slider ───              │
│   Fade out  ─── slider ───              │
├─────────────────────────────────────────┤
│ [ Remove slice ]    ← hidden if 1 slice │
└─────────────────────────────────────────┘
```

### Behavior

- Reads slice from `ref.watch(editorProjectControllerProvider).timeline.clips[sliceIndex]`.
- Returns a "missing slice" placeholder (one line of text) if `sliceIndex >= clips.length` — defensive against late state mutations during unmount.
- Every input wires to its `setSliceX(sliceIndex, …)` mutator on the controller.
- "Remove slice" button:
  - Hidden via `if (clips.length > 1)` in the build.
  - On tap: `controller.removeSlice(sliceIndex)`; then `onClose()` so the inspector reverts to the default tab (slice is gone, nothing to edit).
- Close button (header `[×]`): calls `onClose()` — no state mutation. The parent (`_PlaybackScreenState`) clears its `_selectedSliceIndex` field, which causes `inspector_panel.dart` to render the default tabbed view again.

### Sub-widgets

- Reuse `InspectorSlider`, `InspectorSectionDivider`.
- New `InspectorToggle({required String label, required bool value, required ValueChanged<bool> onChanged})` in `inspector_widgets.dart` — label + `Switch.adaptive`.
- New `_GainRow({required String label, required int percent, required bool muted, required ValueChanged<int> onPercentChanged, required ValueChanged<bool> onMutedChanged})` — internal to `slice_editor.dart`.

### File deletions

- `packages/screen_recorder/lib/ui/widgets/inspector/contexts/clip_context_inspector.dart`
- `packages/screen_recorder/test/ui/widgets/inspector/contexts/clip_context_inspector_test.dart` (if it exists)

`inspector_panel.dart` updates:

```dart
// before
return ClipContextInspector(clipDuration: ..., onClose: ...);
// after
return SliceEditor(sliceIndex: selectedSliceIndex, onClose: ...);
```

`selectedSliceIndex` is owned by `_PlaybackScreenState` and passed down. In B with one slice, the clip lane's existing `onClipTapped` callback sets `_selectedSliceIndex = 0`.

---

## Preview Pipeline

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (modify)

### Speed

Today's listener:

```dart
ref.listen<double>(
  editorProjectControllerProvider.select((s) => s.playbackSpeed),
  (_, next) => _applyEffectivePlaybackSpeed(next),
);
```

Becomes:

```dart
ref.listen<double>(
  editorProjectControllerProvider.select((s) =>
      s.timeline.clips.isEmpty ? 1.0 : s.timeline.clips[0].playbackSpeed),
  (_, next) => _applyEffectivePlaybackSpeed(next),
);
```

`_applyEffectivePlaybackSpeed(clipSpeed)` is unchanged — multiplies by `_previewPlaybackSpeed`, calls `_controller.setPlaybackSpeed(...)`. The existing `_onPlayStateTick` resume-fix also keeps working.

### Cursor

Whichever widget reads cursor state (likely `CursorOverlay` or a sibling in the preview tree) gains a slice-aware lookup:

```dart
ClipSlice currentSlice(EditorProjectState state, Duration position) {
  final clips = state.timeline.clips;
  if (clips.isEmpty) return ClipSlice(start: Duration.zero, end: Duration.zero);
  for (final s in clips) {
    if (position >= s.start && position < s.end) return s;
  }
  return clips.last;  // position at-or-past end
}
```

The overlay:
- Skips rendering the cursor when `currentSlice(...).hideCursor` is true.
- When `currentSlice(...).disableSmoothMouse` is true, reads from the raw recorded cursor positions instead of the animated/smoothed track.

In B with one slice, `currentSlice` always returns `clips[0]`. The position-based lookup exists so C's cut-tool work doesn't need to retouch this code.

### Fades and audio

Unchanged — these are export-only today and stay export-only. The preview ignores them.

---

## Export Pipeline

**File:** wherever the export reads `state.playbackSpeed`, `state.audioMix`, `state.fadeIn`, `state.fadeOut` today.

Replace each read with the equivalent on `state.timeline.clips[0]`. Behavior is identical for B (one slice spanning the whole video).

**Out of scope for B:** the multi-segment export pipeline (concat filter graph with per-slice filter chains). C ships that.

A test asserts the export-input mapper produces the same `setpts`/`atempo`/`afade`/`volume` filters from a single-slice v7 state as it did from a v6 state with matching globals — pins the equivalence.

---

## Testing Scope

### New test files

- `packages/slipreel_engine/test/state/clip_slice_test.dart`
  - Constructor clamps gain (`-50 → 0`, `300 → 200`).
  - `copyWith` preserves unchanged fields, replaces named ones.
  - `==` / `hashCode`: equal slices are equal; one field differing breaks equality.
  - JSON round-trip: `toJson` → `fromJson` reproduces all fields.
  - `fromJson` defaults missing keys; rejects missing bounds.

- `packages/slipreel_engine/test/state/editor_project_state_slice_test.dart`
  - v6 JSON with globals + 12.34s duration migrates to v7 with one slice covering `[0, 12_340_000µs]` and matching field values.
  - v6 JSON without `audioMix` migrates with default audio fields on the slice.
  - v7 JSON round-trips: full state → JSON → state preserves all clip fields.
  - Top-level `playbackSpeed`/`fadeInMicros`/`fadeOutMicros`/`audioMix` are ABSENT from v7's `toJson` output.
  - `currentSchemaVersion == 7`.

- `packages/slipreel_engine/test/state/editor_project_controller_slice_test.dart`
  - `setSliceSpeed(0, 2.0)` updates `clips[0].playbackSpeed`.
  - `setSliceSpeed(0, current)` no-ops (no listener fire).
  - `setSliceSpeed(0, double.nan)` no-ops.
  - `setSliceSpeed(0, -1.0)` clamps to 0.25.
  - `setSliceSpeed(0, 99)` clamps to 4.0.
  - `setSliceMicGain(0, -10)` clamps to 0; `setSliceMicGain(0, 300)` clamps to 200.
  - `setSliceHideCursor(0, true)` flips the bool.
  - `removeSlice(0)` no-ops when `clips.length == 1`.
  - `removeSlice(0)` removes when `clips.length == 2` (controller seeds 2 manually for this test).
  - `setSliceX(99, …)` (out-of-range index) no-ops.

- `packages/screen_recorder/test/ui/widgets/inspector/contexts/slice_editor_test.dart`
  - Renders header with slice bounds + speed.
  - Tapping a speed chip calls `setSliceSpeed(0, chipValue)`.
  - Moving the fine-tune slider calls `setSliceSpeed`.
  - Mic gain slider + mute toggle call the right mutators.
  - System gain slider + mute toggle call the right mutators.
  - hideCursor / disableSmoothMouse toggles call the right mutators.
  - Fade sliders call the right mutators.
  - Remove slice button is HIDDEN when `clips.length == 1`.
  - Remove slice button is VISIBLE when `clips.length == 2`; tapping calls `removeSlice` and then `onClose`.
  - Close button calls `onClose`, no mutation.

- `packages/screen_recorder/test/ui/screens/playback_screen_slice_speed_test.dart`
  - Setting `setSliceSpeed(0, 2.0)` triggers `_applyEffectivePlaybackSpeed(2.0)` (verify via existing `_lastClipSpeedApplied` cache or a `@visibleForTesting` getter).
  - Resume from pause re-applies the slice's speed (the existing `_onPlayStateTick` path).
  - Preview-rate dropdown × slice speed multiplies correctly (slice 1.5× + preview 2× → `setPlaybackSpeed(3.0)`).

### Updated test files

- Any test that constructed `EditorProjectState(playbackSpeed: 1.5, audioMix: AudioMix(...))` updates to construct via `timeline: Timeline(clips: [ClipSlice(start: ..., end: ..., playbackSpeed: 1.5, micGainPercent: ...)])`.
- Export pipeline tests update to feed slice-bearing state and assert the same ffmpeg arg lists.

### Deleted test files

- `packages/screen_recorder/test/ui/widgets/inspector/contexts/clip_context_inspector_test.dart` (if it exists).

---

## Out of Scope (Defer to C)

- Multi-slice export pipeline (concat with per-slice filters).
- Visual slice boundaries on the clip lane.
- Cut tool UI (scissors icon, click-to-split gesture).
- Slice selection visual highlighting in the clip lane.
- Slice drag-to-resize boundaries.
- Boundary-crossing mid-playback rate swap (only matters when there are multiple slices).
- Snapshot/undo integration for slice mutations — uses the existing editor-history mechanism unchanged; the mutations go through the same `state = state.copyWith(...)` pattern as everything else.

---

## Parallelizable Tracks

The plan can split into three roughly independent tracks for parallel implementation:

- **Track E (Engine):** `ClipSlice`, `Timeline.clips`, `EditorProjectState` field removal, v6→v7 migration, controller mutators. Pure dart, no Flutter dependency. Self-contained tests.
- **Track U (UI):** `SliceEditor` widget, `InspectorToggle` widget, `inspector_panel.dart` rewire. Depends on Track E's controller API surface (signatures only — can stub against an interface during dev). Widget tests.
- **Track P (Preview/Export pipelines):** `playback_screen.dart` rewire (speed listener), `CursorOverlay` (or equivalent) slice-aware lookup, export pipeline reads. Depends on Track E's state shape.

Sequencing: E first (everything else needs the types), then U and P in parallel.

---

## Open Questions

None at spec-write time. Anything that surfaces during implementation gets recorded as a plan TODO and bumped up here for the next pass.
