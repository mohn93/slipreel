# Timeline Scale Slider — Design Spec

**Date:** 2026-06-01
**Status:** Approved, ready for implementation plan.

## Goal

Add an animated horizontal-zoom slider to the editor's `CanvasToolbar`. Users can scale the entire timeline (ruler, clip lane, zoom lane, playhead) from fit-to-width (1×) up to 8× for fine-grained editing. Three input methods: slider drag, `Cmd +`/`Cmd -` shortcuts, and trackpad pinch over the timeline lanes. Scale is persisted per-project in `.editor.json`.

## Non-Goals

- **No per-clip / per-slice editing.** That is sub-project B.
- **No cut tool, no scissor markers in the toolbar.** That is sub-project C.
- **No move of the existing playback-speed "1×" control.** It stays in `ClipContextInspector` (and will move to per-slice in B).
- **No visible scrollbar.** Horizontal scroll is trackpad two-finger only.
- **No "fit-to-selection" or "zoom-to-clip" commands.** Out of scope for v1.
- **No golden-image tests.** Codebase convention.
- **No new animation framework.** Use Flutter's built-in `TweenAnimationBuilder` + `easeOutQuint` for the 1×-reset animation; everything else is direct value writes (live drag).

## Architecture Summary

`timelineScale` becomes a first-class field on `EditorProjectState`, persisted to `.editor.json`. The editor's geometry helpers (`_timeToX`, `_xToTime`) are refactored to derive from a single `pixelsPerSecond` value computed as `viewportWidth / totalSeconds * timelineScale`. The timeline lanes are wrapped in a horizontal `SingleChildScrollView` so content can overflow when scale > 1. Three input surfaces feed into one controller method, `setTimelineScale(double scale, {Duration? anchorTime})`, which clamps + debounces sidecar writes. The widget's `didUpdateWidget` detects scale changes and adjusts scroll offset to preserve the anchor.

```
                ┌─────────────────────────────────────────┐
                │  EditorProjectController                │
                │    setTimelineScale(scale, anchorTime?) │ ──► state ──► sidecar (debounced 300ms)
                └─────────────────────────────────────────┘
                             ▲          ▲          ▲
                             │          │          │
              ┌──────────────┴───┐  ┌───┴────┐ ┌───┴──────────┐
              │ TimelineScale-   │  │ Cmd ±  │ │ Pinch on     │
              │   Slider (toolbar)│  │shortcut│ │ timeline lane│
              └──────────────────┘  └────────┘ └──────────────┘
                                                       │
                             ┌─────────────────────────┘
                             ▼
                   ┌──────────────────────────────────┐
                   │ EditorTimeline                   │
                   │  • SingleChildScrollView (h)     │
                   │  • _timeToX uses pixelsPerSecond │
                   │  • didUpdateWidget → _applyScale │
                   │     (preserves anchorTime)       │
                   │  • playback tick → auto-follow   │
                   └──────────────────────────────────┘
```

## State Model

### EditorProjectState (engine)

File: `packages/slipreel_engine/lib/state/editor_project_state.dart`

Add one field:

```dart
class EditorProjectState {
  // …existing fields…
  final double timelineScale;  // clamped [1.0, 8.0], default 1.0
}
```

- `copyWith({double? timelineScale, ...})` — include in the existing copyWith.
- `==` and `hashCode` — include the field.
- `toJson()` — emit `"timelineScale": <double>`.
- `fromJson()` — read `timelineScale` with fallback to `1.0` if missing, non-numeric, NaN, infinite, or out-of-range. On invalid input, emit `debugPrint('Invalid timelineScale in project JSON, falling back to 1.0')` and use `1.0`.

**Default:** `1.0` (fit-to-width — visually identical to today's behavior).

### EditorProjectController (engine)

File: `packages/slipreel_engine/lib/state/editor_project_controller.dart`

Add one method:

```dart
/// Set the timeline horizontal scale. Clamped to [1.0, 8.0]. The
/// optional [anchorTime] is a hint passed through to the widget so it
/// can preserve the on-screen x-position of that timestamp across the
/// scale change. (The hint is stored on the state object as
/// `_pendingScaleAnchor`; the widget reads + clears it on rebuild.)
void setTimelineScale(double scale, {Duration? anchorTime});
```

Behavior:
- Clamp `scale` to `[1.0, 8.0]` at the boundary.
- No-op (no state update, no write) if the clamped value equals the current `timelineScale` AND `anchorTime` is `null`. A non-null `anchorTime` ALWAYS emits — even at the same scale — because the widget needs the anchor signal to react.
- Update state via the existing `_emit` pattern, setting both `timelineScale` (clamped) and `pendingScaleAnchor` (the param value, or null).
- Sidecar write is debounced: rapid calls within 300 ms coalesce to one write at `lastCall + 300 ms`. The existing controller already debounces (search for a similar pattern around `audioMix` writes or `_scheduleSave` — the implementer should match the existing convention rather than invent a new debounce primitive).

**`clearPendingScaleAnchor()`** — emits a new state with `pendingScaleAnchor: null`, keeping all other fields. Does NOT trigger a sidecar write (anchor is transient). The widget calls this after applying the anchor.

**Anchor delivery.** The controller does not own scroll behavior. The `anchorTime` is stored in a transient `pendingScaleAnchor: Duration?` field on the state — **NOT included in `==`/`hashCode`** (so Riverpod selectors don't dirty on anchor changes alone) and **NOT persisted to JSON** (omitted in `toJson`, treated as `null` in `fromJson`). The timeline widget reads it inside `didUpdateWidget` whenever `timelineScale` changes, applies it, then calls `controller.clearPendingScaleAnchor()` which sets the field back to `null` via a separate state emit. This keeps anchor-preservation logic in the widget where the scroll controller lives.

Why exclude from equality: a `setTimelineScale(2.0, anchorTime: 5s)` followed by `setTimelineScale(2.0, anchorTime: 7s)` should both reach the widget (different anchors, even at the same scale). The controller signals this by emitting a fresh state object each time. The widget's `didUpdateWidget` keys off `widget.state.timelineScale != oldWidget.state.timelineScale` — but **also** off `widget.state.pendingScaleAnchor != null`, so a re-emit with a fresh anchor at the same scale still fires anchor application. Without this, two same-scale-different-anchor calls collapse and the second anchor is ignored.

## Geometry

File: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`

Replace the existing top-level helpers:

```dart
// BEFORE
double _timeToX(Duration t, double width, Duration total) =>
    t.inMilliseconds / total.inMilliseconds * width;
double _xToTime(double x, double width, Duration total) =>
    Duration(milliseconds: (x / width * total.inMilliseconds).round());

// AFTER
double _pixelsPerSecond(double viewportWidth, Duration total, double scale) {
  if (total.inMilliseconds == 0) return 0.0;
  return viewportWidth / (total.inMilliseconds / 1000.0) * scale;
}
double _timeToX(Duration t, double pixelsPerSecond) =>
    t.inMilliseconds / 1000.0 * pixelsPerSecond;
Duration _xToTime(double x, double pixelsPerSecond) {
  if (pixelsPerSecond <= 0) return Duration.zero;
  return Duration(milliseconds: (x / pixelsPerSecond * 1000.0).round());
}
double _contentWidth(double viewportWidth, double scale) =>
    viewportWidth * scale;
```

All callers in `_TimeRuler`, `_ClipLane`, `_ZoomLane`, and `_PlayheadPainter` compute `pixelsPerSecond` once from `LayoutBuilder` constraints + `timelineScale`, then pass it down.

**Edge cases the helpers handle:**
- `total == Duration.zero` → `pixelsPerSecond = 0`, all positions render at x=0, no division by zero.
- `pixelsPerSecond == 0` in `_xToTime` → returns `Duration.zero`.
- The geometry is unit-tested in isolation (see Testing).

## Scroll Container

The lanes (ruler + clip lane + zoom lane + playhead painter) are wrapped in a single horizontal `SingleChildScrollView` with a `ScrollController` owned by `_EditorTimelineState`:

```dart
LayoutBuilder(builder: (_, c) {
  final pps = _pixelsPerSecond(c.maxWidth, totalDuration, scale);
  final contentWidth = _contentWidth(c.maxWidth, scale);
  return SingleChildScrollView(
    controller: _scrollController,
    scrollDirection: Axis.horizontal,
    physics: scale > 1.0 ? null : const NeverScrollableScrollPhysics(),
    child: SizedBox(
      width: contentWidth,
      child: Column(children: [
        _TimeRuler(pixelsPerSecond: pps, duration: totalDuration),
        _ClipLane(...),
        _ZoomLane(...),
        // playhead painted as Stack overlay; see below
      ]),
    ),
  );
});
```

- At `scale == 1.0`, physics is `NeverScrollable` → can't drag-scroll (no content to scroll). Visually identical to today.
- At `scale > 1.0`, default physics (clamping, no momentum bounce — macOS feel).
- The scrollbar is **not** visible. Two-finger trackpad scroll only.

The playhead overlay is rendered in viewport coordinates outside the scroll view so it can extend above/below all lanes and never get clipped. Position = `playheadTime * pixelsPerSecond - scrollOffset`. The painter listens to `_scrollController` so it repaints on scroll.

## Inputs

### Slider widget — `TimelineScaleSlider`

New file: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart`

```dart
class TimelineScaleSlider extends ConsumerStatefulWidget {
  const TimelineScaleSlider({
    super.key,
    required this.playheadPosition,
    this.width = 120,
  });

  /// Current playhead time, passed in by the parent so the slider
  /// shares the same source as `EditorTimeline.position`. The playhead
  /// is NOT on `EditorProjectState` — it lives on the parent's video
  /// controller (`_controller.value.position`) and is therefore
  /// injected rather than read from a provider.
  final Duration playheadPosition;
  final double width;
}
```

- Reads current scale from `editorProjectControllerProvider`'s state (defined in `slipreel_engine/lib/state/editor_project_controller.dart` as `final editorProjectControllerProvider = StateNotifierProvider<EditorProjectController, EditorProjectState>(...)`).
- Renders a row: `[1× label] [Slider]`.
  - `1×` label: muted `textSecondary` color, 12px font. Tap fires the reset animation (see below).
  - `Slider`: width = `widget.width - 1× label width - gap`. Accent thumb, `dividerStrong` track, `accentMuted` active track. No divisions, no value indicator.
- **Log mapping:** slider value `v ∈ [0,1]` ↔ scale `s = pow(8.0, v)`. Inverse on read: `v = log(s) / log(8.0)`. Stored as `s` in state; UI converts on each rebuild.
- **Live drag:** `onChanged: (v) => controller.setTimelineScale(pow(8, v), anchorTime: widget.playheadPosition)`. Anchor is the current playhead injected from the parent.
- **Tooltip on hover:** `MouseRegion` over the slider area shows a tooltip `"${scale.toStringAsFixed(1)}×"` after 400 ms. Reuses the existing `_LeftTooltip` pattern from `SpringyIconButton` — or inline a minimal version if introducing a dep is too much.
- **1× reset:** tapping the `1×` label calls a `_resetToFit()` method that animates over 200 ms `easeOutQuint` via `TweenAnimationBuilder<double>` from the current scale to `1.0`. Each tween frame fires `setTimelineScale`. This is the **only** path that animates — every other input is direct.

Add to `CanvasToolbar`:

File: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart`

The current `CanvasToolbar` accepts `children: List<Widget>`. The call site in `playback_screen.dart` (~line 1262) becomes:

```dart
CanvasToolbar(children: [
  const AspectRatioPicker(),
  TimelineScaleSlider(playheadPosition: displayedPos),
])
```

`CanvasToolbar` itself does NOT need code changes — the slider is just another child. The 16 px spacing it already applies between children covers separation.

### Cmd + / Cmd − shortcut

File: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Find the existing `Shortcuts` / `Actions` map (already used for play/pause and other shortcuts — `PlayPauseIntent`, etc.). Add:

```dart
const SingleActivator(LogicalKeyboardKey.equal, meta: true): const _ZoomInIntent(),
const SingleActivator(LogicalKeyboardKey.minus, meta: true): const _ZoomOutIntent(),
```

(`LogicalKeyboardKey.equal` is `=`/`+`; macOS Cmd+= == Cmd++.)

```dart
_ZoomInIntent: CallbackAction<_ZoomInIntent>(
  onInvoke: (_) {
    final s = ref.read(editorProjectControllerProvider).timelineScale;
    final playhead = _controller.value.position;  // local video controller
    ref.read(editorProjectControllerProvider.notifier).setTimelineScale(
      s * 1.25,
      anchorTime: playhead,
    );
    return null;
  },
),
// _ZoomOutIntent: same with /1.25
```

The intents live inside `_PlaybackScreenState`, so they can close over `_controller` directly — no need to plumb the playhead through a provider.

At the bounds the controller clamps; no beep, just stays. (`1.25^N` traverses 1.0→8.0 in ~9 steps.)

### Trackpad pinch

File: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`

Wrap the scrollable content in a `GestureDetector`:

```dart
GestureDetector(
  onScaleStart: (d) => _scaleStartValue = currentScale,
  onScaleUpdate: (d) {
    final newScale = (_scaleStartValue * d.scale).clamp(1.0, 8.0);
    final anchorX = d.focalPoint.dx + scrollOffset;  // in content coords
    final anchorTime = _xToTime(anchorX, pixelsPerSecond);
    controller.setTimelineScale(newScale, anchorTime: anchorTime);
  },
  onScaleEnd: (_) => _scaleStartValue = null,
  behavior: HitTestBehavior.translucent,
  child: <existing scrollable lanes>,
)
```

Pinch ignores the playhead — anchor is always under the cursor.

`onScaleStart`/`onScaleEnd` track only `_scaleStartValue` so we multiply against the right baseline. We don't suppress the scroll view; on a single-finger drag `d.scale == 1.0` so `setTimelineScale` is a no-op (the controller's early-return on equal value with null anchor… but anchor isn't null here — see below).

**Subtle:** the no-op check in `setTimelineScale` only fires when both `scale == current` AND `anchorTime == null`. Pinch always passes an anchorTime. So during a one-finger drag (`d.scale = 1.0`), we'd still call `setTimelineScale(currentScale, anchorTime: ...)` every gesture update — which would dirty state every frame. Mitigation: in the pinch handler, **skip the call if `d.scale == 1.0` AND `d.pointerCount < 2`** (i.e., not actually pinching).

## Anchor-Preserving Scale

In `_EditorTimelineState`:

**Constructor params added to `EditorTimeline`:**
- `double timelineScale` (required, threaded down from `playback_screen.dart` reading the provider's state).
- `Duration? pendingScaleAnchor` (also threaded; widget consumes + the parent clears via the controller).

```dart
@override
void didUpdateWidget(EditorTimeline oldWidget) {
  super.didUpdateWidget(oldWidget);
  final newScale = widget.timelineScale;
  final oldScale = oldWidget.timelineScale;
  final anchor = widget.pendingScaleAnchor;  // Duration?

  // Anchor-preserving scale change: fire when scale moved OR when a
  // fresh anchor arrived (same scale + different anchor is a valid
  // re-emit; see "Anchor delivery" above).
  if (newScale != oldScale || anchor != null) {
    _applyScale(oldScale, newScale, anchor);
  }

  // Playback auto-follow: every tick, if scale > 1 and playing.
  if (widget.position != oldWidget.position) {
    _maybeAutoFollow(widget.position);
  }
}

void _applyScale(double oldScale, double newScale, Duration? anchor) {
  if (!mounted) return;
  final viewport = _lastViewportWidth;  // captured by LayoutBuilder
  if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;
  final anchorTime = anchor ?? widget.position;

  final oldPps = _pixelsPerSecond(viewport, widget.duration, oldScale);
  final newPps = _pixelsPerSecond(viewport, widget.duration, newScale);
  final oldOffset = _scrollController.offset;

  // Where was the anchor on screen before?
  final anchorViewportX = _timeToX(anchorTime, oldPps) - oldOffset;
  // Keep it at the same viewport x by computing the new offset.
  final newAnchorContentX = _timeToX(anchorTime, newPps);
  final newOffset = newAnchorContentX - anchorViewportX;

  final maxOffset = _contentWidth(viewport, newScale) - viewport;
  _scrollController.jumpTo(
    newOffset.clamp(0.0, maxOffset.clamp(0.0, double.infinity)),
  );

  // Clear the one-shot anchor hint via the controller. Parent rebuilds
  // with anchor=null on the next frame.
  if (anchor != null) {
    // The widget doesn't hold a ref to the controller; instead it
    // invokes a callback the parent passes in. See
    // `EditorTimeline.onAnchorConsumed` below.
    widget.onAnchorConsumed?.call();
  }
}
```

**`onAnchorConsumed: VoidCallback?` param** on `EditorTimeline` — the parent supplies `() => ref.read(editorProjectControllerProvider.notifier).clearPendingScaleAnchor()`. Keeps the widget free of Riverpod imports (consistent with how the rest of `EditorTimeline` already receives callbacks like `onSeek`).

**Why `jumpTo` (not animateTo):** the slider drag is already updating the scale every frame; the viewport snapping along is the visible animation. An `animateTo` would lag.

## Playback Auto-Follow

Hook into the existing `_smoothPlayhead` listener path in `_PlaybackScreenState` (see `playback_screen.dart:1262` — the `AnimatedBuilder` already rebuilds `EditorTimeline` on each smoothed tick). Inside `_EditorTimelineState`, override `didUpdateWidget` to also check the position delta and invoke `_maybeAutoFollow(newPosition)`:

```dart
void _maybeAutoFollow(Duration playhead) {
  if (!widget.isPlaying) return;
  final scale = widget.timelineScale;  // passed into EditorTimeline
  if (scale == 1.0) return;  // content fits viewport, no scroll

  final viewport = _lastViewportWidth;
  if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;

  final pps = _pixelsPerSecond(viewport, widget.duration, scale);
  final playheadContentX = _timeToX(playhead, pps);
  final playheadViewportX = playheadContentX - _scrollController.offset;

  if (playheadViewportX > 0.8 * viewport || playheadViewportX < 0) {
    final targetOffset = playheadContentX - 0.2 * viewport;
    final maxOffset = _contentWidth(viewport, scale) - viewport;
    _scrollController.jumpTo(
      targetOffset.clamp(0.0, maxOffset.clamp(0.0, double.infinity)),
    );
  }
}
```

Note: `EditorTimeline` already receives `position`, `isPlaying`, and `duration` as constructor params (see `playback_screen.dart:1272-1275`). The widget gains a new `timelineScale` param to thread through. The auto-follow runs on every position update via `didUpdateWidget`.

No tracking of "user manually scrolled" — if the user scrolls during playback, the next tick that finds the playhead off-screen just snaps again. Simple, predictable. Want to scroll-and-stay? Pause first.

## Files Touched

### Created

- `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart`
- `packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart`
- `packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart`
- `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scale_test.dart`

### Modified

- `packages/slipreel_engine/lib/state/editor_project_state.dart` (add field, copyWith, JSON, equality)
- `packages/slipreel_engine/lib/state/editor_project_controller.dart` (add `setTimelineScale`, `clearPendingScaleAnchor`, debounced write)
- `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart` (geometry helpers, scroll wrap, anchor application, pinch, auto-follow)
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (add slider to CanvasToolbar children, Cmd ±  intents/actions)
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` (extend with `timelineScale` JSON/copyWith cases)

## Testing

### Engine — state field (extend existing)

`packages/slipreel_engine/test/state/editor_project_state_test.dart`:

- `EditorProjectState()` default has `timelineScale == 1.0`.
- Round-trip `state.toJson() → fromJson` preserves a non-default scale (e.g., 3.5).
- `fromJson({})` (missing key) returns state with `timelineScale == 1.0`.
- `fromJson({"timelineScale": -1})`, `0`, `100`, `"foo"`, `null`, `double.nan`, `double.infinity` all fall back to `1.0`.
- `copyWith(timelineScale: 4.0)` updates only that field.
- `==` and `hashCode` reflect the field.

### Engine — controller

`packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart` (new):

- `setTimelineScale(2.0)` updates state.
- `setTimelineScale(15.0)` clamps to `8.0`.
- `setTimelineScale(0.5)` clamps to `1.0`.
- `setTimelineScale(2.0)` followed by `setTimelineScale(2.0)` with `anchorTime: null` produces only one state emit.
- `setTimelineScale(2.0, anchorTime: 1s)` followed by `setTimelineScale(2.0, anchorTime: 2s)` produces two state emits (anchor is a fresh signal each time).
- Disk write is debounced: 5 rapid `setTimelineScale` calls produce **one** sidecar write 300 ms after the last call. Use `FakeAsync`.

### Widget — geometry

`packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scale_test.dart` (new):

- `_pixelsPerSecond(600, 10s, 1.0) == 60.0`; with `scale = 2.0` → `120.0`; with `total = 0` → `0.0`.
- `_timeToX(5s, 60) == 300`; `_timeToX(0, 0) == 0`.
- `_xToTime(300, 60) == 5s`; `_xToTime(x, 0) == Duration.zero`.
- `_contentWidth(600, 1.0) == 600`; with `scale = 2.0` → `1200`.

### Widget — anchor preservation

Same file:

- Pump `EditorTimeline` with state `{total: 10s, scale: 1.0, playback: 5s, viewport: 600}`. Playhead viewport-x == 300.
- Update state to `scale: 2.0` with `pendingScaleAnchor = 5s`. After pump, playhead viewport-x is still 300 (within 1 px tolerance).
- Repeat with `pendingScaleAnchor = 7s`: anchor's viewport-x preserved, not playhead.
- At `scale == 1.0` after a scroll-then-pinch sequence, scroll offset is locked at 0.

### Widget — scroll behavior

- With `scale == 1.0`, attempting a horizontal drag inside the scrollable does not move the scroll offset (physics is `NeverScrollable`).
- With `scale > 1.0`, simulating a horizontal trackpad scroll updates the scroll offset.

### Widget — playback auto-follow

- State `{total: 10s, scale: 4.0, viewport: 600}`. Content width = 2400. Scroll to 0.
- Playback tick advances playhead to 2s → playhead viewport-x = `2/10 * 2400 - 0 = 480`. Still ≤ 0.8 × 600 = 480 → no snap (boundary inclusive at 0.8, so use `> 0.8` strict). Actually 480 == 0.8 × 600 exactly; test value should be 2.1s for clarity.
- Playhead at 2.5s → viewport-x = 600. Triggers snap: new offset = `600 - 0.2 × 600 = 480`. Test passes.
- With `isPlaying == false`, no snap regardless of playhead position.
- Snap clamps at the right edge so we don't scroll past content width.

### Widget — slider

`packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart` (new):

- At `state.timelineScale == 1.0`, slider thumb is at value `0.0`.
- At `state.timelineScale == 8.0`, slider thumb is at value `1.0`.
- At `state.timelineScale ≈ 2.83` (`= sqrt(8)`), slider thumb is at `0.5`.
- Dragging the slider thumb fires `controller.setTimelineScale` with the log-mapped value (verify via a fake controller that records calls).
- Each drag call passes `anchorTime` equal to the current `playbackPosition` from state.
- Tapping the `1×` label fires `setTimelineScale(1.0)` (the final tween frame).
- Hovering the slider for >400 ms displays a tooltip containing `"×"` and the formatted scale.

### Widget — Cmd +/- shortcuts

Existing shortcut test pattern (search for `PlayPauseIntent` in the test tree for the convention).

- `Cmd =` invokes `_ZoomInIntent` → `controller.setTimelineScale` called with `currentScale * 1.25`, `anchorTime` = playback position.
- `Cmd -` similarly with `/1.25`.
- At `scale == 8.0`, `Cmd =` calls `setTimelineScale(10.0)` (controller clamps to `8.0` — verify via fake controller).

### Widget — pinch

- Synthesize a two-finger pinch gesture over the lane with `details.scale == 2.0` and `focalPoint = (300, 50)`. Verify `setTimelineScale(currentScale * 2.0, anchorTime: time-at-x-300)` is called.
- Synthesize a single-finger drag over the lane (`details.scale == 1.0`, `pointerCount == 1`). Verify `setTimelineScale` is NOT called.

## Implementation Tracks (Parallelization)

Implementation can fan out across **three independent tracks** after a small sequential foundation. Tracks edit disjoint files, so multiple agents can work in parallel without merge conflicts. Within a track, tasks are sequential.

### Phase 1 — Foundation (SEQUENTIAL, blocks everything else)

| # | Task | Files | Depends on |
|---|---|---|---|
| **F1** | Add `timelineScale` field on `EditorProjectState` (copyWith, JSON, equality, defaulting, validation) + tests | `slipreel_engine/lib/state/editor_project_state.dart`, `slipreel_engine/test/state/editor_project_state_test.dart` | — |
| **F2** | Add `setTimelineScale` and `clearPendingScaleAnchor` to `EditorProjectController` with clamp + debounced sidecar write + tests | `slipreel_engine/lib/state/editor_project_controller.dart`, `slipreel_engine/test/state/editor_project_controller_scale_test.dart` | F1 |
| **F3** | Add `pendingScaleAnchor: Duration?` transient field on state (NOT persisted to JSON — initialized as null on fromJson, omitted on toJson). Tests for the transience. | `slipreel_engine/lib/state/editor_project_state.dart`, `slipreel_engine/test/state/editor_project_state_test.dart` | F1 |

Phase 1 ships as 3 commits. F3 can run in parallel with F2 (they touch different files within the engine; if there's a merge in the state file, F3 happens after F1 only).

### Phase 2 — Three parallel tracks

After Phase 1 is green and merged on the branch, the following three tracks can run in **parallel** (one agent per track). Each track owns a distinct set of files; no two tracks edit the same file.

#### Track G — Geometry, scroll, anchor, auto-follow, pinch

Owns: `screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`, `screen_recorder/test/ui/widgets/timeline/editor_timeline_scale_test.dart`.

Tasks must be done **sequentially within this track** (same file):

| # | Task | Depends on |
|---|---|---|
| **G1** | Refactor `_timeToX` / `_xToTime` into `_pixelsPerSecond`-based helpers; update all in-file callers (`_TimeRuler`, `_ClipLane`, `_ZoomLane`, `_PlayheadPainter`); add unit tests for the helpers. No visible behavior change (scale stays 1.0 throughout, no scroll wrap yet). | F1 |
| **G2** | Wrap the lanes in `SingleChildScrollView` + `ScrollController`. Capture viewport width in state. Render playhead in overlay (outside scroll, listening to controller). At scale==1.0, no visible change. Add scroll-behavior tests. | G1 |
| **G3** | Implement `_applyScale(old, new, anchor)` in `didUpdateWidget`; clear `pendingScaleAnchor` after applying. Add anchor-preservation tests. | G2, F2, F3 |
| **G4** | Add playback auto-follow in the existing playback tick. Tests for the snap. | G3 |
| **G5** | Wrap lanes in `GestureDetector` for trackpad pinch; anchor on cursor x; skip when `pointerCount < 2`. Pinch tests. | G3 |

#### Track S — Slider widget + toolbar integration

Owns: `screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart`, `screen_recorder/lib/ui/widgets/canvas_toolbar/canvas_toolbar.dart` (read-only, no edits — but the call site lives in `playback_screen.dart`), `screen_recorder/lib/ui/screens/playback_screen.dart` (ONE LINE — adding the slider to CanvasToolbar's children), `screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart`.

| # | Task | Depends on |
|---|---|---|
| **S1** | Create `TimelineScaleSlider` widget (log-mapped slider, `1×` reset label with `TweenAnimationBuilder` animation, hover tooltip). Reads state, writes via controller with `anchorTime: playbackPosition`. | F2 |
| **S2** | Add `TimelineScaleSlider` to the `CanvasToolbar` children list at the existing call site in `playback_screen.dart` (~line 1262). Single line addition. | S1 |
| **S3** | Slider widget tests (rendering, drag, reset, tooltip). | S1 |

**Conflict note for Track S:** `playback_screen.dart` is also touched by Track I (shortcuts). The two edits target different sections of the same file. Track S's edit is to the `CanvasToolbar(children: [...])` constructor call (a Column subtree); Track I's edit is to the `Shortcuts`/`Actions` map (likely near the top of the build method or in a parent wrapper). They will merge cleanly if both agents edit by adding lines without restructuring. To eliminate even theoretical conflict: **Track S waits for Track I's edit before applying S2**, OR the merging agent (controller) does S2 as the last step.

#### Track I — Cmd + / Cmd − shortcuts

Owns: `screen_recorder/lib/ui/screens/playback_screen.dart` (specifically the `Shortcuts` and `Actions` maps), `screen_recorder/test/ui/screens/playback_screen_shortcuts_test.dart` (or wherever existing shortcut tests live; subagent should locate via grep for `PlayPauseIntent`).

| # | Task | Depends on |
|---|---|---|
| **I1** | Define `_ZoomInIntent` / `_ZoomOutIntent`. Wire `SingleActivator(LogicalKeyboardKey.equal, meta: true)` and `SingleActivator(LogicalKeyboardKey.minus, meta: true)` to actions that call `controller.setTimelineScale(scale * 1.25 ↑↓, anchorTime: playbackPosition)`. Add shortcut tests. | F2 |

### Phase 3 — Integration verification (SEQUENTIAL)

After all Phase 2 tracks merge:

| # | Task | Depends on |
|---|---|---|
| **V1** | Run full test suite. Manual: launch app, hot reload, exercise slider, shortcuts, pinch, scroll, auto-follow during playback. | All Phase 2 |

### Dependency Graph

```
F1 ──┬── F2 ──┬── G3 ──┬── G4
     │        │        └── G5
     │        ├── S1 ─── S2
     │        │     └── S3
     │        └── I1
     └── F3 ──┘
             │
G1 (depends on F1) ── G2 ── G3 (depends on G2 & F2 & F3)
```

(F3 is independent of F2 within the engine and unblocks Phase 2 along with F2.)

### Suggested Concurrency

- One agent works the Foundation (F1 → F2 → F3 sequentially, or F1 then F2/F3 in parallel).
- Three agents fan out after Foundation:
  - Agent Geometry → G1 → G2 → G3 → G4 → G5
  - Agent Slider → S1 → S3, then S2 (after I1 or last)
  - Agent Shortcuts → I1
- The controller merges all branches and runs V1.

Wall-clock estimate (vs sequential): foundation ≈ 1 unit, Phase 2 parallel ≈ longest track (Track G with 5 tasks) ≈ 5 units, verify ≈ 1 unit. **Total ≈ 7 units vs 11 sequential** (saves Slider + Shortcuts tracks' time).

## Error Handling Summary

- **Invalid JSON `timelineScale`** → fall back to 1.0, log warning.
- **Out-of-range from any input** → controller clamps, no error surfaced.
- **`totalDuration == 0`** → `pixelsPerSecond = 0`, geometry returns 0/Duration.zero, no division by zero.
- **Viewport width unknown before first layout** → return early from `_applyScale` and auto-follow; first `LayoutBuilder` build captures it.
- **Anchor preservation overflow** → scroll offset clamps to `[0, max(0, contentWidth - viewport)]`.
- **Pinch on a 1-finger drag** (`d.scale == 1.0`, `pointerCount < 2`) → skip the controller call to avoid dirtying state every frame.
- **Cmd ± at the bounds** → controller clamps, no beep / no visual feedback (just stays).

## Open Questions

None at spec-approval time. Any surprises uncovered during implementation should be raised as questions before the implementer proceeds, per subagent-driven-development rules.
