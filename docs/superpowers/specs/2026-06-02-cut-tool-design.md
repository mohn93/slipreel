# Cut Tool — Design Spec

**Date:** 2026-06-02
**Sub-project:** C (final of the 3-part timeline series: A=scale slider, B=slice editor, C=cut tool)
**Depends on:** Sub-project B (slice editor) — `ClipSlice` data class, per-slice mutators, `SliceEditor` widget.

## 1. Goal

Let the user split a clip into multiple `ClipSlice`s and independently trim each one. Cuts are immutable points; trims are mutable inward/outward adjustments within those cut bounds. The timeline visually collapses trimmed-away regions so the user always sees the edit, not the source.

## 2. Decisions (from brainstorm)

| Topic | Decision |
|---|---|
| Cut activation | `Cmd+K` at playhead **AND** a scissors tool mode for click-anywhere cuts |
| Post-cut selection | Inspector closes (no slice selected) |
| Slice selection | Click slice body → select; re-click → deselect |
| Boundary visuals | Thin seam between slices; selected slice highlighted (`_clipFillTop`) |
| Trim model | Per-slice L+R handles; immutable `cutStart`/`cutEnd` + mutable `trimStart`/`trimEnd`; clamped by neighbors / video bounds |
| Restore affordance | Notched chevron on whichever side has `trim ≠ cut`; hover tooltip "Nms trimmed — drag to restore" |
| Animation polish | Magnetic attraction toward cursor in cut mode; springy commit on split; eased selection highlight |
| Settings on split | Both halves inherit all per-slice settings from parent |
| Remove slice | Drop entirely (content removed from output); restore via neighbor's trim handle |
| Min slice length | 100 ms (matches `_minZoomDurationMs` / `_minTrimDurationMs`) |
| Playback behavior | Skip removed regions during BOTH play and scrub — timeline x-axis is edited time, not source |

## 3. Architecture overview

Three layers:

1. **Engine** (`packages/slipreel_engine`) — `ClipSlice` gains `cutStart`/`cutEnd` (immutable) and `trimStart`/`trimEnd` (mutable). `EditorProjectController` gets `splitSlice`, `setSliceTrimStart`, `setSliceTrimEnd`. `removeSlice` changes semantics: drop the slice entirely (no merge). A new pure-Dart `edited_time.dart` module provides bidirectional mapping between edited time (the timeline x-axis) and source time (the video file).
2. **App UI** (`packages/screen_recorder`) — `editor_timeline.dart` splits into smaller files; new `_SliceBar` per-slice widget, new `_CutOverlay` for the scissors mode, new toolbar scissors button. `Cmd+K` handler at the screen level. Inspector tracks `selectedSliceIndex` and renders `SliceEditor(sliceIndex: idx)` for the selected one.
3. **Preview & export** — Preview's position-tick listener seeks across removed regions. The export pipeline emits one ffmpeg segment per slice and `concat`s them; audio chains generalize from B's single-slice form to N slices.

## 4. Data model

### 4.1 `ClipSlice` (revised)

```dart
class ClipSlice {
  ClipSlice({
    required this.cutStart,
    required this.cutEnd,
    Duration? trimStart,
    Duration? trimEnd,
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    int micGainPercent = 100,
    this.micMuted = false,
    int systemGainPercent = 100,
    this.systemMuted = false,
    this.hideCursor = false,
    this.disableSmoothMouse = false,
  })  : trimStart = _clampTrimStart(cutStart, cutEnd, trimStart ?? cutStart),
        trimEnd = _clampTrimEnd(cutStart, cutEnd,
            trimStart ?? cutStart, trimEnd ?? cutEnd),
        micGainPercent = _clampGain(micGainPercent),
        systemGainPercent = _clampGain(systemGainPercent);

  final Duration cutStart;   // immutable: where this slice was cut from
  final Duration cutEnd;     // immutable: where this slice was cut to
  final Duration trimStart;  // mutable effective left  (cutStart ≤ trimStart)
  final Duration trimEnd;    // mutable effective right (trimEnd ≤ cutEnd)
  // ... all existing per-slice settings unchanged

  // Source-time bounds for the EFFECTIVE (playable) range of this slice.
  Duration get start => trimStart;     // legacy alias for B-era consumers
  Duration get end => trimEnd;         // legacy alias for B-era consumers
  Duration get effectiveLength => trimEnd - trimStart;
  Duration get cutSpan => cutEnd - cutStart;
  bool get isLeftTrimmed => trimStart > cutStart;
  bool get isRightTrimmed => trimEnd < cutEnd;
}
```

The `start` / `end` getters keep all B-era code (which read `clip.start` / `clip.end`) working without churn. Internally, those callers were always asking for "what's the playable range" — `trimStart` / `trimEnd` answer that exactly.

**Static helpers** (private):

```dart
static int _clampGain(int v) => v < 0 ? 0 : (v > 200 ? 200 : v);

static const Duration _minLen = Duration(milliseconds: 100);

static Duration _clampTrimStart(Duration cs, Duration ce, Duration ts) {
  if (ts < cs) return cs;
  if (ts > ce - _minLen) return ce - _minLen < cs ? cs : ce - _minLen;
  return ts;
}

static Duration _clampTrimEnd(Duration cs, Duration ce, Duration ts, Duration te) {
  if (te > ce) te = ce;
  if (te < ts + _minLen) te = ts + _minLen;
  if (te > ce) te = ce; // degenerate cut span < _minLen (corrupt JSON only)
  return te;
}
```

### 4.2 `Timeline.clips` invariants

For consecutive slices `N` and `N+1`:

```
clips[N].cutEnd ≤ clips[N+1].cutStart    // cut bounds never overlap
```

Trim bounds CAN coincide at slice boundaries (`clips[N].trimEnd == clips[N+1].trimStart`) — that's the "touching" case after a fresh cut. Trim bounds CAN'T overlap (`clips[N].trimEnd > clips[N+1].trimStart` is rejected by the trim mutators).

Slices are stored sorted by `cutStart`. Splits insert at the right index; `removeSlice` removes without reordering.

### 4.3 Schema migration v7 → v8

Existing v7 JSON for a slice:
```json
{"startMicros": 0, "endMicros": 12000000, "playbackSpeed": 1.0, ...}
```

v8 form:
```json
{"cutStartMicros": 0, "cutEndMicros": 12000000,
 "trimStartMicros": 0, "trimEndMicros": 12000000,
 "playbackSpeed": 1.0, ...}
```

Migration `_migrateV7ToV8` walks `timeline.clips[]` and rewrites each clip object:
```dart
clip['cutStartMicros'] = clip.remove('startMicros');
clip['cutEndMicros']   = clip.remove('endMicros');
clip['trimStartMicros'] = clip['cutStartMicros'];
clip['trimEndMicros']   = clip['cutEndMicros'];
```

`ClipSlice.fromJson` reads `cutStartMicros` / `trimStartMicros` etc. with the same `is num` guards as B's defensive parser. If `trim*` are missing (defensive: hand-rolled file), defaults to `cut*`.

## 5. Engine API

### 5.1 `EditorProjectController` additions

```dart
bool splitSlice(int sliceIndex, Duration sourcePosition) {
  // returns false if preconditions fail (out of range, too close to edge)
}

void setSliceTrimStart(int sliceIndex, Duration trimStart) {
  // clamped to [cutStart, trimEnd - 100ms]; no-op if unchanged
}

void setSliceTrimEnd(int sliceIndex, Duration trimEnd) {
  // clamped to [trimStart + 100ms, cutEnd]; no-op if unchanged
}
```

`removeSlice` already exists from B — it drops the slice from the list. B never exercised the multi-slice case (there was only ever one). C activates it: with N > 1 slices the surviving slices stay in place; the dropped slice's source range becomes a gap that's skipped on playback/export; the user can restore content via the neighboring slices' trim handles (their `cutEnd` / `cutStart` bounds reach further than their `trimEnd` / `trimStart` after a drop). No B-side code change required.

**`splitSlice` algorithm:**

```
Pre:
  0 ≤ sliceIndex < clips.length
  parent = clips[sliceIndex]
  parent.trimStart + 100ms ≤ sourcePosition ≤ parent.trimEnd - 100ms

Post:
  left  = parent.copyWith(cutEnd: sourcePosition, trimEnd: sourcePosition)
  right = parent.copyWith(cutStart: sourcePosition, trimStart: sourcePosition)
  clips.replaceRange(sliceIndex, sliceIndex+1, [left, right])
```

Settings inheritance is automatic via `copyWith` — only the bounds change.

### 5.2 `EditorProjectController.splitAtPlayhead`

```dart
bool splitAtPlayhead(Duration editedPosition, List<ClipSlice> clips) {
  final sourcePosition = editedToSource(clips, editedPosition);
  final idx = _sliceContaining(clips, sourcePosition);
  if (idx == null) return false;
  return splitSlice(idx, sourcePosition);
}
```

Returns `bool` so the UI can branch on success vs the "can't cut here" flash. `clips` is passed explicitly so the screen layer can call it without re-reading state (avoids races).

### 5.3 `edited_time.dart` helpers

Module: `packages/slipreel_engine/lib/timeline/edited_time.dart`. All pure functions:

```dart
/// Total edited timeline duration: sum of all slices' effectiveLength.
Duration totalEditedDuration(List<ClipSlice> clips) {
  var acc = Duration.zero;
  for (final c in clips) acc += c.effectiveLength;
  return acc;
}

/// Map an edited-time position to its source-time position.
/// Walks slices in order; returns null if editedTime is past the end.
Duration editedToSource(List<ClipSlice> clips, Duration editedTime) {
  var acc = Duration.zero;
  for (final c in clips) {
    final next = acc + c.effectiveLength;
    if (editedTime <= next) {
      return c.trimStart + (editedTime - acc);
    }
    acc = next;
  }
  return clips.isEmpty ? Duration.zero : clips.last.trimEnd;
}

/// Map a source-time position back to edited time. Source positions inside
/// removed regions map to the edited time of the next slice's start.
Duration sourceToEdited(List<ClipSlice> clips, Duration sourceTime) {
  var acc = Duration.zero;
  for (final c in clips) {
    if (sourceTime < c.trimStart) return acc;     // in removed region → next slice's start
    if (sourceTime <= c.trimEnd) return acc + (sourceTime - c.trimStart);
    acc += c.effectiveLength;
  }
  return acc;
}

/// When playback reaches the end of a slice's trim range (or lands in a
/// removed region during a stray seek), return the next valid source
/// position to jump to, or null if the entire timeline has been consumed.
Duration? nextPlayPosition(List<ClipSlice> clips, Duration sourcePosition) {
  for (final c in clips) {
    if (sourcePosition < c.trimStart) return c.trimStart;
    if (sourcePosition < c.trimEnd) return sourcePosition;
  }
  return null;
}
```

## 6. Timeline UI

### 6.1 File reorganization

```
packages/screen_recorder/lib/ui/widgets/timeline/
├── editor_timeline.dart          orchestrator (shrinks substantially)
├── smooth_playhead_controller.dart  (unchanged)
├── time_ruler.dart               extracted: _TimeRuler + _TimeRulerPainter
├── clip_lane.dart                renamed: now multi-slice
├── slice_bar.dart                NEW: per-slice widget
├── cut_overlay.dart              NEW: scissors-mode overlay
└── timeline_constants.dart       extracted: colors, sizes
```

Constants from the original file (`_trackBg`, `_clipFill`, `_handleHitWidth`, etc.) move to `timeline_constants.dart` and become library-private to the directory.

### 6.2 `_SliceBar`

```dart
class _SliceBar extends StatefulWidget {
  final ClipSlice slice;
  final int sliceIndex;
  final bool isSelected;
  final double pixelsPerSecond;
  final Duration editedStart;         // edited-time x-anchor for this slice
  final ValueListenable<double?> cursorXListenable;  // null = not in cut mode
  final ValueChanged<int> onSelectionToggle;
  final ValueChanged<Duration> onTrimStartChanged;
  final ValueChanged<Duration> onTrimEndChanged;
  // ...
}
```

State:
- Paints body covering `[editedStart, editedStart + slice.effectiveLength * pixelsPerSecond]`
- Left trim handle (16px hit area) at `editedStart`; right at `editedStart + width`
- Drag updates use the same anchor-then-drag pattern as B's `_TrimHandle` (anchor = trim value at pointer-down; drag delta in px → delta in `Duration` → `onTrimStartChanged` / `onTrimEndChanged`)
- Notch chevron painted via `CustomPaint` on the left edge if `slice.isLeftTrimmed`, right edge if `slice.isRightTrimmed`. Glyph is a 6×10px inward-pointing chevron, accent-tinted, 0.85 → 1.0 opacity pulse loop while hovered.
- Hover-over-handle tooltip: `"Nms trimmed — drag to restore"`
- Body tap → `onSelectionToggle(sliceIndex)`. Re-tap of the currently-selected slice de-selects.

**Magnetic motion:**

```dart
@override
Widget build(BuildContext context) {
  return ValueListenableBuilder<double?>(
    valueListenable: widget.cursorXListenable,
    builder: (_, cursorX, child) {
      final pull = _computePull(cursorX, sliceCenterX);
      return Transform.translate(
        offset: Offset(pull, 0),
        child: child,
      );
    },
    child: _sliceBody(),
  );
}

double _computePull(double? cursorX, double centerX) {
  if (cursorX == null) return 0;
  final dx = cursorX - centerX;
  if (dx.abs() > 80) return 0;
  final proximity = (1 - (dx.abs() / 80)).clamp(0.0, 1.0);
  return dx.sign * proximity * proximity * 6;  // max 6px, eased
}
```

When `cursorXListenable` is null (cut mode off), pull is 0 — no rebuilds.

### 6.3 `_ClipLane` (multi-slice)

```dart
class _ClipLane extends StatefulWidget {
  final List<ClipSlice> clips;
  final int? selectedSliceIndex;
  final double pixelsPerSecond;
  final bool cutModeActive;
  // ... existing trim-selection + seek props removed; trim is now per-slice
}
```

Layout: walks `clips` and accumulates `editedStart` per slice (each starts where the previous slice ended in edited time). Emits a `_SliceBar` per slice plus thin 2px seam painters between them.

**Edited-time-collapse is automatic** because each `_SliceBar` is positioned by `editedStart`, not `slice.cutStart`. Gaps in source time vanish from the layout.

### 6.4 `_CutOverlay`

```dart
class _CutOverlay extends StatefulWidget {
  final double pixelsPerSecond;
  final Duration totalEditedDuration;
  final ValueNotifier<double?> cursorX;          // null when off-lane
  final ValueChanged<Duration> onCommitCut;      // edited-time position
  final VoidCallback onExitMode;
}
```

- Wraps the clip lane in a `Positioned.fill` `MouseRegion` only when `cutModeActive`
- Tracks pointer x → updates `cursorX`, which all `_SliceBar`s listen to for magnetic pull
- Paints:
  - Custom 14×14 scissors glyph centered on cursor (since Flutter macOS lacks a built-in scissors cursor)
  - 1px dashed accent vertical line at cursor x, full lane height
- Tap → `onCommitCut(_editedTimeAt(cursorX))`
- `Focus` + `RawKeyboardListener` for `Esc` → `onExitMode()`

### 6.5 Cut tool toolbar button

Existing timeline toolbar row (currently hosts the scale slider) gets a small scissors `IconButton` slot:

```dart
IconButton(
  icon: const Icon(Icons.content_cut, size: 18),
  isSelected: cutModeActive,
  onPressed: () => setState(() => cutModeActive = !cutModeActive),
  tooltip: 'Cut tool (Esc to exit)',
)
```

State (`cutModeActive: bool`) lives on `EditorTimelineState`. Exiting via the overlay's `Esc` handler sets it back to false.

### 6.6 `Cmd+K` global handler

Registered in `playback_screen.dart`:

```dart
@override
void initState() {
  super.initState();
  HardwareKeyboard.instance.addHandler(_onKey);
}

bool _onKey(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  final isCmdK = event.logicalKey == LogicalKeyboardKey.keyK &&
      HardwareKeyboard.instance.isMetaPressed;
  if (!isCmdK) return false;
  final editedPos = sourceToEdited(_clips, _controller.value.position);
  final ok = ref
      .read(editorProjectControllerProvider.notifier)
      .splitAtPlayhead(editedPos, _clips);
  if (ok) {
    setState(() => _selectedSliceIndex = null);
  } else {
    _flashPlayhead();  // 120ms accent-color pulse
  }
  return true;
}
```

`_flashPlayhead` toggles a `ValueNotifier<bool>` that the playhead pill listens to for a 120ms `Curves.easeOut` color tween.

### 6.7 Animation curves & durations

| Effect | Curve | Duration |
|---|---|---|
| Slice selection highlight | `Curves.easeOutQuint` | 200ms |
| Trim handle drag | none (direct follow) | — |
| Trim handle release snap | `Curves.easeOutCubic` | 180ms |
| Magnetic pull | implicit via `ValueListenableBuilder` + `AnimatedBuilder` | ~120ms perceived |
| Cut commit (split separation) | `Curves.easeOutBack` | 240ms (left −2px, right +2px, then settle) |
| Chevron notch pulse | `Tween(0.85 → 1.0)` opacity loop | 1200ms |
| Playhead "can't cut" flash | `Curves.easeOut` | 120ms |

## 7. Inspector integration

### 7.1 Selected-slice state

`EditorTimelineState` adds:

```dart
int? _selectedSliceIndex;
```

Exposed via:
```dart
EditorTimeline(
  ...,
  selectedSliceIndex: _selectedSliceIndex,
  onSliceSelected: (idx) => setState(() => _selectedSliceIndex = idx),
)
```

### 7.2 `InspectorPanel` branching

```dart
Widget _inspectorBody() {
  if (selectedSliceIndex == null) return const _EmptyInspector();
  return SliceEditor(
    sliceIndex: selectedSliceIndex!,
    onClose: () => widget.onSliceSelected(null),
  );
}
```

### 7.3 Selection-index decrement after `removeSlice`

In `PlaybackScreen`, after dispatching `removeSlice(idx)`:

```dart
setState(() {
  if (_selectedSliceIndex == idx) {
    _selectedSliceIndex = null;
  } else if (_selectedSliceIndex != null && _selectedSliceIndex! > idx) {
    _selectedSliceIndex = _selectedSliceIndex! - 1;
  }
});
```

### 7.4 `SliceEditor` header subtitle update

When the selected slice has been trimmed (`isLeftTrimmed || isRightTrimmed`), the existing subtitle (e.g. `0:05 – 0:12`) appends `· trimmed Ns` where `N = (cutSpan - effectiveLength).inMilliseconds / 1000`. Muted color, same line.

## 8. Preview & export

### 8.1 Preview playback (`PlaybackScreen`)

Existing position-tick listener gains skip logic:

```dart
void _onPositionTick(VideoPlayerValue v) {
  final pos = v.position;
  final clips = ref.read(editorProjectControllerProvider).timeline.clips;
  final containing = _sliceStrictlyContaining(clips, pos);
  if (containing == null || pos >= containing.trimEnd) {
    final next = nextPlayPosition(clips, pos);
    if (next != null && next != pos) {
      _controller.seekTo(next);
      return;
    }
    if (next == null) {
      _controller.pause();
      _controller.seekTo(clips.last.trimEnd);
      return;
    }
  }
  // existing slice-speed handling from B
  final slice = containing!;
  _applyEffectivePlaybackSpeed(slice.playbackSpeed * _previewPlaybackSpeed);
}
```

`_sliceStrictlyContaining` is a NEW helper (not a modification of B's `clipSliceAt`). It returns `null` when `position` falls in a removed region — used here for the skip decision. B's `clipSliceAt` is unchanged and keeps its "fall back to last slice" semantics for the cursor-overlay path in `PlaybackCanvas` (which always wants a slice to read `hideCursor` / `disableSmoothMouse` from).

### 8.2 Scrub mapping

`onSeek` callback in the timeline now passes edited-time positions. `PlaybackScreen._onSeek`:

```dart
void _onSeek(Duration editedTime) {
  final sourceTime = editedToSource(_clips, editedTime);
  _controller.seekTo(sourceTime);
}
```

Because `editedToSource` only returns source positions inside slice trim ranges, scrubbing can't land in a removed region. "Skip during scrubbing" is free.

### 8.3 Total preview duration

```dart
Duration get _editedDuration => totalEditedDuration(_clips);
```

Used by:
- `_TimeRuler` for label generation (currently uses `widget.totalDuration`)
- Timeline content width: `_editedDuration.inSeconds * pixelsPerSecond * scale`
- Time labels on the playhead pill

### 8.4 Export pipeline (`packages/slipreel_engine/lib/export/export_pipeline.dart`)

Currently reads `clips[0]`. C generalizes to N slices via a per-slice filter chain:

```
For each slice in clips (idx i):
  Video chain:
    [0:v]trim=start={trimStart}:end={trimEnd},
         setpts=(PTS-STARTPTS)/{playbackSpeed}[v{i}]
  Mic audio chain (only if mic track exists):
    [1:a]atrim=start={trimStart}:end={trimEnd},
         asetpts=PTS-STARTPTS,
         atempo={playbackSpeed},
         volume={micGainPercent/100},
         afade=in (if fadeIn > 0),
         afade=out (if fadeOut > 0)[a_mic{i}]
  System audio chain (analogous, [2:a] input)

Concat:
  [v0][v1]...[vN-1]concat=n=N:v=1:a=0[outv]
  [a_mic0][a_mic1]...amix=inputs=N[mic_track]
  [a_sys0][a_sys1]...amix=inputs=N[sys_track]
  [mic_track][sys_track]amix=inputs=2[outa]
```

The existing B code that builds a single-slice chain becomes a per-slice loop with index suffixes. The concat + amix outer wiring is new but mechanical.

Per-slice mute (`micMuted` / `systemMuted`) is implemented as `volume=0` in that slice's chain (rather than dropping the chain entirely, which would break the concat input count).

### 8.5 GIF export (`gif_export_pipeline.dart`)

Same N-slice generalization, video-only:

```
[0:v]trim=start={trimStart_i}:end={trimEnd_i},setpts=(PTS-STARTPTS)/{playbackSpeed_i}[v{i}]
[v0][v1]...concat=n=N:v=1:a=0[outv]
[outv] ... existing palette/dither/fps chain
```

### 8.6 Cursor overlay rendering

`PlaybackCanvas` already takes `sliceHideCursor` and `sliceDisableSmoothMouse` from B, computed via `clipSliceAt(clips, sourcePos)`. With the skip guarantee from §8.1, `sourcePos` always lands in a slice; no defensive `null` handling needed.

## 9. Error handling

By design, error surfaces are minimal:

- `splitSlice` precondition fail → returns `false`; UI plays the 120ms playhead flash
- `setSliceTrimStart` / `setSliceTrimEnd` out-of-range → silently clamped (consistent with B's slice mutators)
- `removeSlice` on out-of-range index → no-op
- `splitAtPlayhead` on empty clips → no-op, returns `false`
- Older schema versions (v6 and earlier) → cascade through existing migrators + new v7→v8
- v8 JSON with broken invariants → constructor clamps to a valid 100ms-min slice and logs a warning via `slipreel_engine`'s logger

No new dialogs, snackbars, or alert surfaces.

## 10. Testing

### 10.1 Engine tests (`packages/slipreel_engine/test/...`)

- **`state/clip_slice_cut_test.dart`** — cutStart/cutEnd/trimStart/trimEnd fields, getters (`effectiveLength`, `cutSpan`, `isLeftTrimmed`, `isRightTrimmed`), `copyWith`, ==/hashCode (with new fields), JSON round-trip, constructor invariant clamping. ~15 tests.
- **`state/editor_project_state_v8_migration_test.dart`** — v7 fixture → v8 round-trip; `trim* == cut*` after migration; migration is idempotent; loads cleanly into a `Timeline` whose slices satisfy invariants. ~5 tests.
- **`state/editor_project_controller_split_test.dart`** — `splitSlice` happy path (both halves correct, inherit settings); precondition fails return `false` and don't mutate state; out-of-range no-ops; `splitAtPlayhead` happy + empty + in-removed-region cases; `removeSlice` drops without merging; `setSliceTrimStart` / `setSliceTrimEnd` clamp + no-op-if-unchanged behavior. ~12 tests.
- **`timeline/edited_time_test.dart`** — pure helpers (`editedToSource`, `sourceToEdited`, `totalEditedDuration`, `nextPlayPosition`) across empty, single-slice, multi-slice, gap-spanning, boundary, beyond-end cases. ~20 tests.
- **`export/export_pipeline_multi_slice_test.dart`** — ffmpeg arg construction for 2-slice and 3-slice projects with mixed speeds, fades, gain; concat + amix wiring; per-slice mute as `volume=0`. ~5 tests.

### 10.2 App tests (`packages/screen_recorder/test/...`)

- **`ui/widgets/timeline/slice_bar_test.dart`** — selection toggle on tap; trim handle drag clamps to neighbor; chevron visibility on trimmed sides only. ~8 tests.
- **`ui/widgets/timeline/clip_lane_multi_slice_test.dart`** — N slices render adjacent in edited-time x; seam positions; selected slice gets `_clipFillTop`. ~6 tests.
- **`ui/widgets/timeline/cut_overlay_test.dart`** — dashed indicator follows cursor; tap triggers `onCommitCut`; Esc triggers `onExitMode`; magnetic pull math (independently testable as a pure function). ~5 tests.
- **`ui/screens/playback_screen_cut_keybind_test.dart`** — `Cmd+K` dispatches `splitAtPlayhead` with current edited-time playhead; success closes inspector; failure triggers `_flashPlayhead`. ~4 tests.
- **`ui/screens/playback_screen_skip_playback_test.dart`** — position-tick listener seeks across removed regions; scrub maps edited-time → source; never lands in trim gap. ~6 tests.
- **`ui/widgets/inspector/slice_editor_multi_test.dart`** — `sliceIndex` prop; subtitle shows "trimmed Ns" suffix when `isLeftTrimmed || isRightTrimmed`; index-decrement-on-removal verified at the screen level. ~5 tests.

### 10.3 No app-launch QA gate

Per the same constraint from B: the flutter-qa MCP probe binds to the recording bar window, the editor opens in a separate window. Probe smoke is documented as nice-to-have but not gating. Widget tests cover real-controller paths.

### 10.4 TDD ordering

The implementation plan will sequence tasks along the dependency chain:

1. `ClipSlice` (cutStart/cutEnd/trimStart/trimEnd, getters, copyWith, JSON)
2. v7→v8 migration
3. `edited_time.dart` helpers
4. Controller mutators (`splitSlice`, `setSliceTrimStart`, `setSliceTrimEnd`, revised `removeSlice`, `splitAtPlayhead`)
5. Export pipeline N-slice generalization
6. GIF export N-slice generalization
7. Timeline file split (`time_ruler.dart`, `clip_lane.dart`, `timeline_constants.dart`)
8. `_SliceBar` widget
9. `_ClipLane` multi-slice rendering + selection wiring
10. `_CutOverlay` + scissors toolbar button + cut-mode state
11. `Cmd+K` global handler + `_flashPlayhead`
12. Inspector glue (selected-slice tracking, index decrement, subtitle trimmed-Ns)
13. Preview skip + scrub mapping in `PlaybackScreen`

Each task writes its tests before implementation. Bridge-code with `TODO(cut-tool TN)` markers can keep intermediate states compilable, same pattern as B.

## 11. Out of scope

Deferred to potential future sub-projects (saved to `memory/cut_tool_followups.md`):

- Reorder slices (drag a slice to swap with neighbor)
- Slice multi-select (shift-click, batch-edit)
- Undo/redo for cuts (and likely all editor mutations) — no undo system exists yet
- Snap to zoom-region boundaries / auto-zoom event marks when cutting
- Keyboard shortcuts for next/prev slice navigation in inspector
