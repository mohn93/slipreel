# Cut Marker (Slice Divider Pin) — Design

> A pin marker that hangs above every seam between slices on the timeline. Surfaces how much content is hidden at the seam, and provides a two-step click affordance to first restore the hidden content (clear seam trims) and then remove the cut entirely (merge the two slices).

## Goal

Make slice divisions visible and reversible without leaving the timeline. Two motivations:

1. **Discoverability.** Once a user makes cuts, the seams currently have no UI affordance — you can only undo by Cmd+Z (which also unwinds other recent edits) or by trimming back manually. The pin gives a direct, persistent, scoped affordance per seam.
2. **Information.** Hidden source content at a seam is invisible. The pin's badge ("1.0s") makes the cost of each cut legible at a glance.

## UX

### Pin shape

- Orange teardrop pin matching `clipFill` (`Color(0xFFE69E5A)`).
- Tip points down at the seam x in the clip lane.
- Body floats `_kPinHangAbove = 10` px above the top edge of the slice bars, drawn into the clip lane's overlay layer (Stack already uses `Clip.none`).
- White scissors icon centered in the body. Drop shadow for slight elevation.

### Two visual states

| State | Trigger (`hiddenSeconds`) | Pin appearance | Click action |
|---|---|---|---|
| **A** | `> 0` (trim or source gap at seam) | Wider pin (~48 px) with a leading "**1.0s** ✂" badge. Label is hiddenSeconds formatted as `X.Xs` (1 decimal). | First click → clears both seam trims atomically. Pin transitions to State B. |
| **B** | `== 0` (clean cut, nothing hidden) | Compact pin (~22 px) showing only the ✂ icon. | Click → merges the two slices into one. Pin disappears. |

### Hover

- Subtle scale-up (~1.05×) + brightening on hover (springy feel, à la `SpringyIconButton`).
- Tooltip: `"Restore X.Xs of trimmed content"` in State A, `"Remove cut"` in State B.

### Hit area

- Visual pin is 22–48 px wide × 28 px tall, but the hit area is 32×32 minimum (extends invisible padding around the visual). Forgiving clicks at any timeline zoom level.

### Trim drag fade

- While any trim handle is being dragged anywhere in the clip lane, all cut markers fade to ~0.2 opacity. Re-uses the existing `onTrimDragChanged` callback wiring from `ClipLane` → parent. Keeps the seam visually clean during drag.

### Scroll

- Markers live inside the horizontally-scrolling timeline content, so they pan with the slices.

### When markers are not shown

- `clips.length <= 1` → no markers (no seams).
- No marker at the absolute start or end of the timeline (only between slices).
- Markers do not appear in the slice editor inspector — this is a timeline-level affordance only.

## Engine (semantics)

### Math: hidden seconds at seam `i`

A seam between `clips[i]` (left) and `clips[i+1]` (right). The total hidden content is:

```
hidden = (left.cutEnd - left.trimEnd)              // right-trim of left slice
       + (right.trimStart - right.cutStart)        // left-trim of right slice
       + max(0, right.cutStart - left.cutEnd)      // source gap (after slice deletion)
```

State A iff `hidden > Duration.zero`.

### `clearSeamTrims(int seamIndex)` — first click

Resets both adjacent slices' inner trims back to their cut bounds. Single atomic state mutation (one undo step).

```dart
void clearSeamTrims(int seamIndex) {
  final clips = state.timeline.clips;
  if (seamIndex < 0 || seamIndex >= clips.length - 1) return;
  final left = clips[seamIndex];
  final right = clips[seamIndex + 1];
  final newLeft = left.copyWith(trimEnd: left.cutEnd);
  final newRight = right.copyWith(trimStart: right.cutStart);
  if (newLeft == left && newRight == right) return;
  final updated = List<ClipSlice>.from(clips)
    ..[seamIndex] = newLeft
    ..[seamIndex + 1] = newRight;
  state = state.copyWith(timeline: state.timeline.copyWith(clips: updated));
}
```

Note: does NOT restore the source gap between non-adjacent slices — that's only undone by the second click (merge).

### `mergeSeam(int seamIndex)` — second click

Fuses two adjacent slices into one. Single atomic state mutation.

```dart
void mergeSeam(int seamIndex) {
  final clips = state.timeline.clips;
  if (seamIndex < 0 || seamIndex >= clips.length - 1) return;
  final left = clips[seamIndex];
  final right = clips[seamIndex + 1];
  final merged = ClipSlice(
    cutStart: left.cutStart,
    cutEnd: right.cutEnd,
    trimStart: left.trimStart,
    trimEnd: right.trimEnd,
  );
  final updated = List<ClipSlice>.from(clips)
    ..[seamIndex] = merged
    ..removeAt(seamIndex + 1);
  state = state.copyWith(timeline: state.timeline.copyWith(clips: updated));
}
```

For non-adjacent source boundaries (after slice deletion), `cutEnd > cutStart_left + (right.cutStart - left.cutEnd)` — the merged slice covers the entire source span including the previously-deleted gap. `ClipSlice`'s constructor clamps `trimStart`/`trimEnd` into `[cutStart..cutEnd]`, so the merged trim bounds stay valid.

### Selection bookkeeping after merge

In the screen's merge handler, after calling `mergeSeam(seamIndex)`:

- If `_selectedSliceIndex == seamIndex + 1` → set it to `seamIndex` (the right slice index disappeared; selection follows the merged slice).
- If `_selectedSliceIndex == seamIndex` → keep it (the merged slice keeps that index).
- If `_selectedSliceIndex > seamIndex + 1` → decrement by 1 (everything shifted left).
- Otherwise (less than `seamIndex` or null) → leave it.

## File structure

### New

**`packages/screen_recorder/lib/ui/widgets/timeline/cut_marker.dart`** (~120–150 lines)

- `CutMarker` (StatelessWidget): inputs `hiddenSeconds: Duration`, `onTap: VoidCallback`, `tooltipState: _PinTooltipState`. Wraps a `MouseRegion` + spring-scale animation + `Tooltip` + `GestureDetector` + `CustomPaint`.
- `_CutMarkerPainter` (`CustomPainter`): paints the teardrop body + tip + drop shadow + label text.
- Constants: `_kPinHeight = 28`, `_kPinTipHeight = 6`, `_kPinBodyHeight = 22`, `_kPinHangAbove = 10`, `_kCompactWidth = 22`, `_kLabelHPad = 8`, `_kHitInsetMin = 32`.
- Formatter: `_formatHidden(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s'`.

### Modified

**`packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart`**

- Add two new callbacks to `ClipLane`: `final ValueChanged<int> onClearSeamTrims; final ValueChanged<int> onMergeSeam;`.
- After the existing two-pass slice Stack, append a third pass that mounts `clips.length - 1` `CutMarker` widgets, each in a `Positioned` centered horizontally on the seam x. Use a fixed-width container (e.g., 80 px) centered on `editedStarts[i+1] * pixelsPerSecond` (so `left = seamX - 40`), with the painter drawing the pin centered within it. This avoids re-positioning when the pin's visual width changes between State A and State B.
- Compute `hiddenSecondsAt(int seamIndex)` inline via private static helper.
- `Positioned`'s `top = -_kPinHangAbove`.
- Wrap the marker pass in an `AnimatedOpacity(opacity: _draggingIndex != null ? 0.2 : 1.0, duration: 180ms)` for the trim-drag fade.

**`packages/slipreel_engine/lib/state/editor_project_controller.dart`**

- Add `clearSeamTrims(int seamIndex)` and `mergeSeam(int seamIndex)` (code above).

**`packages/screen_recorder/lib/ui/screens/playback_screen.dart`** (the screen that mounts ClipLane)

- Wire `onClearSeamTrims` → `editorProjectController.clearSeamTrims(i)`.
- Wire `onMergeSeam` → adjust `_selectedSliceIndex` per the bookkeeping rules above, then `editorProjectController.mergeSeam(i)` (wrap both in `setState` for the selection update).

## Edge cases

- **Single slice** → no markers rendered.
- **Empty timeline** → no markers rendered.
- **Very short slice between two seams** → markers may visually overlap. Accepted (YAGNI on stagger). The hit areas may also overlap; the topmost in the Stack wins. The third-pass paint order matches list order, so later seams' markers render on top.
- **Idempotent first click**: if a user somehow taps State A but trims are already at cut bounds (shouldn't happen since the badge would not be shown), `clearSeamTrims` early-returns with no state change.
- **Merge when only 2 slices exist** → reduces to 1 slice. All markers disappear.
- **Cmd+Z undo**: each click is a single atomic state mutation, so one Cmd+Z undoes one click. State A → State B → merged is two Cmd+Z presses.

## Out of scope (YAGNI)

- No keyboard shortcut to remove a cut at the playhead.
- No batch "remove all cuts" affordance.
- No right-click context menu — single-click progressive UX is the whole story.
- No marker stagger for overlapping short slices.
- No marker animation when a cut is newly created (cuts appear; nothing fancier).
- No persistence beyond what `EditorProjectState` already persists (cut points are the state, the marker is purely derived).

## Testing

### Engine (`packages/slipreel_engine/test`)

**`hidden_seconds_test.dart`** — pure helper covering math correctness:
- no trim, no gap → 0
- right-trim only → equals right-trim amount
- left-trim only → equals left-trim amount
- both sides trimmed → sum
- source gap (non-adjacent slices) → equals gap
- combined: trim + gap → sum of all

**`clear_seam_trims_test.dart`**:
- restores both `trimEnd` (left) and `trimStart` (right) to cut bounds
- idempotent: clean seam → no state change
- single mutation: `state` reference changes exactly once
- only seams within bounds work; out-of-range index → no-op
- non-adjacent boundary (gap): clears trims but does NOT close the gap

**`merge_seam_test.dart`**:
- adjacent boundary, no trim → merged slice length = sum, cut bounds joined, trim bounds joined
- adjacent boundary, with trim → trim bounds joined (outer trims preserved)
- non-adjacent boundary (gap) → merged slice covers full source span including the gap
- clips.length reduces by 1
- out-of-range index → no-op

### UI (`packages/screen_recorder/test`)

**`cut_marker_test.dart`**:
- compact pin renders when `hiddenSeconds == 0` (no label finder)
- wide pin renders when `hiddenSeconds > 0` (label text matches `1.0s`/`12.4s` format)
- tap fires `onTap`
- tooltip text reflects state

**`clip_lane_cut_markers_test.dart`**:
- N clips → exactly `N - 1` `CutMarker` widgets mounted
- single clip → no markers
- marker x positions match seam edited-time positions
- tapping marker `i` invokes `onClearSeamTrims(i)` (State A) or `onMergeSeam(i)` (State B)
- during a trim drag (simulated via `onTrimDragChanged`), markers fade to ~0.2 opacity
- selection bookkeeping in the screen test: after `mergeSeam(i)`, `_selectedSliceIndex` follows the documented rules

### Screen integration (lightweight)

- One widget test that mounts the playback screen with 3 clips, taps the seam marker between clips 1 and 2 twice, asserts: first tap clears trims, second tap reduces clip count to 2.

## Implementation order (for the plan)

1. **Engine math + methods** — `hiddenSeconds` helper, `clearSeamTrims`, `mergeSeam` (TDD, all engine tests).
2. **`CutMarker` widget** — paint the pin, hit area, tooltip (TDD, widget tests in isolation).
3. **ClipLane integration** — third-pass markers, fade during drag (TDD via `clip_lane_cut_markers_test.dart`).
4. **Screen wiring** — callbacks, selection bookkeeping (TDD with a focused screen test).
5. **Manual verification on running app** — hot reload, cut some slices, observe markers, click twice.
