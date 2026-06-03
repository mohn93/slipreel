# Cut-tool Follow-ups Design

**Date:** 2026-06-03
**Status:** Approved (pending implementation plan)
**Parent backlog:** [[cut-tool-followups]]

Two focused additions to the editor: snap-on-cut and slice keyboard navigation. Both are tightly scoped, share no code with each other, but ship together as one sub-project so the editor's keyboard-driven workflow lands as a single coherent step.

## Background

Sub-project C (cut tool) shipped `Cmd+K` splits, scissors-mode timeline clicks, and the per-slice `ClipSlice` model. Five quality-of-life items were deferred at brainstorm time. Three of those five have since been completed or dropped:

- **Reorder slices** — dropped by user.
- **Multi-select slices** — dropped by user.
- **Undo/redo** — already shipped as `EditorHistoryController` (snapshot-based, 500ms coalesce, 50-entry history, wired in `PlaybackScreen`, exposed via `Cmd+Z` / `Cmd+Shift+Z` + toolbar buttons, 8/8 tests passing). The cut-tool-followups memory note is stale.

That leaves the two items in this spec:

1. **Snap to event marks** — `Cmd+K` and scissors-mode cuts pull to nearby cursor click events and zoom-region edges within a 150ms radius.
2. **Slice keyboard navigation** — `Option+]` / `Option+[` cycle the inspector's currently selected slice forward / back.

Both reuse existing infrastructure (cursor click index, zoom region store, `_selectedSliceIndex` state, `HardwareKeyboard.addHandler` dispatch). No new state machinery.

## Goals

- Cmd+K within 150ms of a recorded click lands exactly on the click, not 22ms past it.
- Cmd+K within 150ms of a zoom region's start/end lands exactly on the edge.
- The user can disable snap per-cut (`Cmd+Option+K`) or globally (timeline toolbar toggle).
- Visual confirmation tells the user *why* the cut landed where it did (brief flash on snap target).
- Option+] / Option+[ navigate slices without leaving the keyboard; the player follows the selection.

## Non-goals

- Reorder slices, multi-select, snap to neighboring slice boundaries, live snap preview while scrubbing, zoom-region keyboard nav, wrap-around at slice boundaries. Each explicitly deferred (see "Deferred" at the end).

## Architecture

```
┌─ EditorProjectController (existing) ─────────────────────────────┐
│  splitSlice(index, sourcePosition)                               │
│  splitAtPlayhead(editedPosition, clips)                          │
└──────────────────────────────────────────────────────────────────┘
        ▲
        │ called with snapped position (or raw, if override / disabled)
        │
┌─ SnapResolver (NEW, pure) ───────────────────────────────────────┐
│  resolveSnap({requestedTime, candidates, radius}) → SnapResult   │
│  Inputs: edited-time Duration + sorted candidates + radius       │
│  Output: { Duration time, Duration? snappedFrom }                │
└──────────────────────────────────────────────────────────────────┘
        ▲                              ▲
        │                              │
┌─ Cmd+K hotkey ──┐          ┌─ Scissors-mode tap ──┐
│ PlaybackScreen  │          │ CutOverlay (timeline)│
│ ._onKey         │          │ .onCommitCut         │
└─────────────────┘          └──────────────────────┘

┌─ SnapPreferenceController (NEW) ──────────────────────────────┐
│ Riverpod StateNotifierProvider<SnapPrefController, bool>      │
│ Backed by SharedPreferences (key: slipreel.snap_enabled)      │
│ Toggle UI: magnet pill in TimelineToolbar                     │
└───────────────────────────────────────────────────────────────┘

┌─ Slice keyboard nav (Option+] / Option+[) ────────────────────┐
│ PlaybackScreen._onKey block                                   │
│   ↓                                                           │
│ nextSliceIndex(currentIndex, sliceCount, direction) → int     │
│ sliceEditedStart(clips, index) → Duration                     │
│   ↓                                                           │
│ setState(_selectedSliceIndex = next, _selectedZoomIndex = null│
│ _controller.seekTo(sliceEditedStart)                          │
└───────────────────────────────────────────────────────────────┘
```

**Key choices:**

- `SnapResolver` is a pure helper with no Flutter imports — drop-in testable, called identically from Cmd+K and scissors-mode.
- Snap preference lives in its own provider, NOT in `EditorProjectState`, because it's a per-user preference (persists across projects) rather than per-project data.
- Snap visual feedback is local `PlaybackScreen` state — mirrors the existing `_playheadFlashOn` pattern.
- Keyboard nav is a pure helper plus a small `_onKey` block; no new widgets.

## Component 1: Snap

### Candidate sources

Snap targets come from two existing data stores. Both are converted to **edited-time** before snapping, because per-slice playback speed warps timing (a click at source 3.0s sits at edited 2.0s if the preceding slice is 1.5×).

| Source | Where it lives | How read |
|---|---|---|
| Cursor click events (rising edges) | `CursorRecording.eventIndex` — pre-cached, sorted by timestamp, binary-searchable | New `cursorClickTimes(recording)` helper extracts press events only (not releases) |
| Zoom region edges | `state.timeline.zoomTracks[0].regions` | `regions.expand((r) => [r.startTime, r.endTime]).toList()..sort()` |

The two lists merge into one sorted `List<Duration>` of edited-time candidates per cut request. Conversion uses the existing `sourceToEdited(clips, sourceTime)` helper.

### SnapResolver contract

```dart
// packages/slipreel_engine/lib/snap/snap_resolver.dart

class SnapResult {
  final Duration time;          // either requestedTime or a candidate
  final Duration? snappedFrom;  // null if no snap occurred
  const SnapResult(this.time, this.snappedFrom);
}

const Duration kDefaultSnapRadius = Duration(milliseconds: 150);

SnapResult resolveSnap({
  required Duration requestedTime,
  required List<Duration> candidates,  // pre-sorted ascending
  Duration radius = kDefaultSnapRadius,
});
```

Implementation: binary-search the sorted candidate list for the insertion point of `requestedTime`, inspect the two immediate neighbors (one before, one after), pick the closer of the two if it's within `radius`. O(log n).

Tie-breaker: when two candidates are equidistant from `requestedTime`, the earlier candidate wins. Deterministic and matches user intuition ("cut at the click that just happened").

### SnapPreferenceStore + SnapPreferenceController

Follows the same Store + StateNotifier + override-in-main pattern as `AppPaletteStore` / `AppPaletteController`. Persistence is via `SharedPreferences` (single bool, simpler than the JSON-sidecar approach the palette uses).

```dart
// packages/screen_recorder/lib/state/snap_preference_store.dart

class SnapPreferenceStore {
  static const _key = 'slipreel.snap_enabled';
  SnapPreferenceStore(this._prefs);
  final SharedPreferences _prefs;

  static Future<SnapPreferenceStore> resolveDefault() async {
    final prefs = await SharedPreferences.getInstance();
    return SnapPreferenceStore(prefs);
  }

  bool load() => _prefs.getBool(_key) ?? true;
  Future<void> save(bool enabled) => _prefs.setBool(_key, enabled);
}
```

```dart
// packages/screen_recorder/lib/state/snap_preference_controller.dart

class SnapPreferenceController extends StateNotifier<bool> {
  SnapPreferenceController({required SnapPreferenceStore store, required bool initial})
      : _store = store,
        super(initial);

  final SnapPreferenceStore _store;

  void setEnabled(bool value) {
    state = value;
    unawaited(_store.save(value));
  }
}

/// Overridden in main.dart with a loaded store + the persisted initial.
/// Default throws to surface missing wiring early.
final snapPreferenceProvider =
    StateNotifierProvider<SnapPreferenceController, bool>(
  (ref) => throw UnimplementedError(
    'Override snapPreferenceProvider in main.dart with a loaded store',
  ),
);
```

`main.dart` is extended to construct the store at startup (alongside `AppPaletteStore.resolveDefault()`) and override the provider with `SnapPreferenceController(store: ..., initial: store.load())`. Default is `true`.

### Toggle UI

A small magnet-icon pill inside the existing `TimelineToolbar`, sitting next to the timeline scale slider. One-click on/off. Tooltip surfaces current state ("Snap to events: On" / "Off"). Uses the same `AppPalette` tokens as the scale slider — no new theming.

### Call sites

Both call sites apply snap before invoking the controller's split method. Sketch (Cmd+K path):

```dart
// In PlaybackScreen._onKey after detecting Cmd+K
final snapEnabled = ref.read(snapPreferenceProvider);
final overrideSnap = HardwareKeyboard.instance.isAltPressed;
final shouldSnap = snapEnabled && !overrideSnap;

Duration cutTime = editedPos;
Duration? snappedFrom;
if (shouldSnap) {
  final candidates = _buildSnapCandidates(clips);
  final result = resolveSnap(
    requestedTime: editedPos,
    candidates: candidates,
  );
  cutTime = result.time;
  snappedFrom = result.snappedFrom;
}
final ok = handleCutKeybind(
  controller: ref.read(editorProjectControllerProvider.notifier),
  currentEditedTime: cutTime,
  clips: clips,
);
if (ok) {
  setState(() => _selectedSliceIndex = null);
  if (snappedFrom != null) _flashSnap(snappedFrom);
} else {
  _flashPlayhead();
}
```

Same shape inside `CutOverlay.onCommitCut`. The Option-modifier override applies to scissors-mode taps too (Option-click while in scissors mode bypasses snap).

`_buildSnapCandidates(clips)` lives in `PlaybackScreen` and is responsible for:
1. Reading the active cursor recording from the project store.
2. Reading the active zoom-track regions from `state.timeline.zoomTracks[0]`.
3. Mapping both to edited-time via `sourceToEdited(clips, ...)`.
4. Returning the sorted merged list.

### Candidate caching

Computing candidates from scratch on every keypress is fine for typical projects (a few hundred click events plus a handful of zoom regions = well under 1ms). We **do not cache** — invalidation would require listening on every zoom mutation and every clip-list change, more code than it saves. Reconsider only if profiling shows a hot spot.

### Snap visual feedback

A brief soft-glow flash on the snap target.

- `PlaybackScreenState` gains: `Duration? _snapFlashTarget;` and `Timer? _snapFlashTimer;`.
- `_flashSnap(Duration target)` sets the field, schedules a 240ms timer to clear it, calls `setState`.
- A new `SnapFlashOverlay` widget paints inside the timeline ruler area: a vertical glow (theme accent color, alpha fading from 0.6 → 0.0 over 240ms) at the edited-time x of `_snapFlashTarget`. Anchored the same way the playhead is, so it follows zoom-anchor math automatically.

The widget is a small `CustomPainter` and lives at `packages/screen_recorder/lib/ui/widgets/timeline/snap_flash_overlay.dart`.

### Edge cases

| Case | Behavior |
|---|---|
| Snap target lands inside the 100ms min-slice guard zone (`splitSlice` would fail) | Fall back to the raw requested time; if that also fails, normal `_flashPlayhead` failure feedback |
| Empty candidate list | `resolveSnap` returns `SnapResult(requestedTime, null)`; no-op fast path |
| `Cmd+Option+K` with snap globally off | Same as `Cmd+K`; modifier is a per-cut override of the global preference, no double-negation surprises |
| Scissors-mode tap with snap globally off | Lands at the tapped position raw; toolbar tooltip explains why no snap is happening |
| Candidate exactly at `requestedTime` | Returned as the snap target with `snappedFrom == requestedTime`; flash still fires (confirms "yes, that was an exact click") |
| Two clicks within 1ms of each other | The earlier one wins (tie-breaker) |

## Component 2: Slice keyboard navigation

### Pure helpers

```dart
// packages/slipreel_engine/lib/timeline/slice_navigation.dart

enum NavDirection { next, previous }

/// Returns the next slice index for keyboard navigation.
/// - currentIndex < 0 means "no selection":
///     next → 0, previous → sliceCount - 1
/// - At boundary (last + next, or first + previous) → returns currentIndex unchanged
/// - Empty slice list → returns -1
int nextSliceIndex({
  required int currentIndex,
  required int sliceCount,
  required NavDirection direction,
});

/// Returns the edited-time start of the given slice (sum of editedLengths
/// of all preceding slices). Used by the screen to seek the player after nav.
Duration sliceEditedStart(List<ClipSlice> clips, int index);
```

Both pure, unit-tested in isolation. No Flutter imports.

### Handler placement

A small block inside the existing `PlaybackScreen._onKey`:

```dart
final isOptBracket = HardwareKeyboard.instance.isAltPressed &&
    (event.logicalKey == LogicalKeyboardKey.bracketRight ||
     event.logicalKey == LogicalKeyboardKey.bracketLeft);
if (isOptBracket) {
  if (!_isInitialized) return false;
  if (_focusedWidgetIsEditable()) return false;  // let bracket type
  final clips = ref.read(editorProjectControllerProvider).timeline.clips;
  if (clips.isEmpty) return true;
  final dir = event.logicalKey == LogicalKeyboardKey.bracketRight
      ? NavDirection.next
      : NavDirection.previous;
  final next = nextSliceIndex(
    currentIndex: _selectedSliceIndex ?? -1,
    sliceCount: clips.length,
    direction: dir,
  );
  if (next == (_selectedSliceIndex ?? -1)) {
    _flashPlayhead();  // brief no-op feedback at boundary
    return true;
  }
  setState(() {
    _selectedSliceIndex = next;
    _selectedZoomIndex = null;  // mutually exclusive (existing rule)
  });
  _controller.seekTo(sliceEditedStart(clips, next));
  return true;
}
```

### Text-field guard

`HardwareKeyboard.addHandler` is global and fires before widget focus dispatches. To guarantee `Option+]` still types `}` in any future text field, `_focusedWidgetIsEditable()` checks `FocusManager.instance.primaryFocus?.context?.widget` and returns `true` if the focused widget is an `EditableText` (or descendant of one). When `true`, the handler returns `false` and lets the keypress propagate.

### Boundary feedback

At the ends of the slice list, the handler reuses the existing `_flashPlayhead()` — same brief pill flash used for failed Cmd+K. Cheap, consistent, no new asset.

## Data model changes

None to `EditorProjectState`. The only new persisted state is `slipreel.snap_enabled` in `SharedPreferences` (per-user, not per-project).

## Testing

### Unit tests (pure helpers — fastest tier)

`packages/slipreel_engine/test/snap/snap_resolver_test.dart`:
- empty candidates → no snap
- exact-hit candidate → snap to it, `snappedFrom == requestedTime`
- candidate at 149ms → snap; at 151ms → no snap (radius boundary)
- candidate at 150ms exactly → snap (`<=` semantics)
- equidistant ties → earlier candidate wins
- multi-candidate → picks nearest
- requestedTime before all candidates → checks only the first
- requestedTime after all candidates → checks only the last
- preserves microsecond precision (no silent ms quantization)
- contract: candidates must be sorted ascending (documented; asserted in debug builds)

`packages/slipreel_engine/test/timeline/slice_navigation_test.dart`:
- `nextSliceIndex` empty list → -1
- from -1 next → 0
- from -1 previous → sliceCount - 1
- at last index + next → unchanged
- at first index + previous → unchanged
- mid-list ± 1
- `sliceEditedStart` index 0 → Duration.zero
- `sliceEditedStart` index N → sum of editedLengths[0..N-1]
- `sliceEditedStart` with speed-warped slices (1.5× → editedLength shorter than effectiveLength)
- out-of-bounds → throws RangeError

`packages/screen_recorder/test/state/snap_preference_store_test.dart`:
- `load()` returns `true` when no stored value (`SharedPreferences.setMockInitialValues({})`)
- `load()` returns the stored value when present
- `save(false)` persists, subsequent `load()` returns `false`

`packages/screen_recorder/test/state/snap_preference_controller_test.dart`:
- constructed with `initial: false` → state is `false`
- `setEnabled(true)` updates state and calls `store.save(true)` (mock store records calls)
- `setEnabled(true)` then `setEnabled(false)` round-trips state

### Integration tests (PlaybackScreen — light widget tests)

`packages/screen_recorder/test/ui/screens/playback_screen_snap_integration_test.dart`:
- With mock cursor recording + zoom regions, Cmd+K within 150ms of a click → `splitSlice` called at the snapped time
- Cmd+Option+K at the same position → `splitSlice` called at the raw time
- Snap globally off → Cmd+K calls `splitSlice` at the raw time, no flash
- Cmd+K with snap target inside min-slice guard zone → falls back to raw time
- `_snapFlashTarget` is non-null for the 240ms following a snapped commit, then clears

`packages/screen_recorder/test/ui/screens/playback_screen_slice_nav_test.dart`:
- Option+] from `_selectedSliceIndex == null` → `_selectedSliceIndex` becomes 0, player seek fires with slice 0's edited start
- Option+[ from `_selectedSliceIndex == null` → `_selectedSliceIndex` becomes last
- Option+] at last slice → `_selectedSliceIndex` unchanged, seek doesn't fire, `_flashPlayhead` fires
- Focus on `EditableText` → handler returns false, no state change
- Option+] clears `_selectedZoomIndex` (mutual exclusivity)

### Manual QA checklist

Surfaces edge cases that aren't worth automating but matter for shipping:
- Cmd+K with playhead ~100ms from a recorded click → cut snaps, target flashes
- Toolbar toggle off → Cmd+K lands at raw playhead, no flash, no `snappedFrom`
- Cmd+Option+K with snap on → lands at raw playhead, no flash
- Scissors-mode Option-click bypasses snap
- Project with 5+ slices: Option+] from no-selection lands on slice 0, video jumps to slice 0's first frame
- Type `}` in any text input (e.g., the recordings list search field, when added) → Option+] still produces the character
- 5+ slices: rapidly tap Option+] → selection advances smoothly, player keeps up
- Re-open the app → snap toggle remembers its last state
- Undo (Cmd+Z) after a snapped cut → restores the pre-cut state correctly (snap doesn't break undo)

## File map

**New files:**
- `packages/slipreel_engine/lib/snap/snap_resolver.dart`
- `packages/slipreel_engine/lib/timeline/slice_navigation.dart`
- `packages/screen_recorder/lib/state/snap_preference_store.dart`
- `packages/screen_recorder/lib/state/snap_preference_controller.dart`
- `packages/screen_recorder/lib/ui/widgets/timeline/snap_flash_overlay.dart`
- Corresponding test files in `packages/*/test/...`

**Modified files:**
- `packages/screen_recorder/lib/main.dart` — bootstrap `SnapPreferenceStore.resolveDefault()` and override `snapPreferenceProvider`, mirroring the existing `appPaletteControllerProvider` override
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — `_onKey` extends to handle Option+] / Option+[; Cmd+K block extends to apply snap and trigger the flash; new `_snapFlashTarget` + `_snapFlashTimer` fields; new `_buildSnapCandidates` and `_flashSnap` helpers; `dispose` cancels `_snapFlashTimer`
- `packages/screen_recorder/lib/ui/widgets/timeline/cut_overlay.dart` — `onCommitCut` extends to thread the snap decision (or the parent intercepts before calling `splitAtPlayhead`)
- `packages/screen_recorder/lib/ui/widgets/timeline/timeline_toolbar.dart` — adds the snap toggle pill next to the scale slider
- `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart` — composes the new `SnapFlashOverlay` into the timeline stack

**Memory note to update post-merge:** `cut_tool_followups.md` — remove undo/redo (already shipped), remove this sub-project's two items.

## Deferred

Items explicitly out of scope, parked for later sub-projects:

- **Reorder slices** — dropped.
- **Multi-select slices** — dropped.
- **Snap to neighboring slice boundaries** — kept snap targets focused on event/zoom marks.
- **Live snap preview while scrubbing** — flash-on-commit is enough.
- **Zoom region keyboard nav** — slices only.
- **Wrap-around at slice boundaries** — stop-at-boundary chosen instead.
- **DMG / sign / notarize / auto-update** — separate sub-project E.
