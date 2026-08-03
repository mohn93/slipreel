# Auto-Zoom Interaction Classifier — Design

**Date:** 2026-08-02
**Branch:** `feat/auto-zoom-interaction-classifier`
**Status:** Approved design, pending implementation plan

## Problem

`AutoZoomDetector` pre-populates the editor's zoom lane on first open. It walks
`isClicked` rising edges, drops any click within 1.5 s of a neighbour, and emits one
fixed-shape region per survivor: 1.5× zoom, 500 ms lead-in + 1.8 s hold + 500 ms
lead-out, anchored at the click pixel, `followCursor: false`.

Three symptoms follow from that:

1. **Too few regions.** The isolation filter is the direct cause. On a form fill —
   five clicks in four seconds — *every* click has a neighbour inside 1.5 s, so the
   filter drops all of them and the editor opens with an empty zoom lane. The busier
   and more interesting the recording, the fewer regions it produces.

2. **Badly shaped regions.** Every interaction gets the same 2.8 s / 1.5× treatment
   regardless of what happened. A click into a text field (where the interesting
   content is the typing that *follows*) and a click on a button (where it's the
   instant of the press) are given identical envelopes.

3. **Regions in the wrong place.** The focal is the press pixel. For a drag or a text
   selection the interesting area is the *swept range*, not where the gesture started,
   so the zoom lands off-target.

### Prior art

Recordly (MIT, `github.com/shabanmohd/recordly`) solves symptoms 2 and 3 with a
post-click trajectory classifier (`src/components/video-editor/timeline/zoomSuggestionUtils.ts`)
that sorts interactions into seven kinds — `dropdown-open`, `text-selection`,
`text-field-click`, `double-click-like`, and others — by measuring cursor movement in
the 100–2000 ms window after each click. It solves symptom 1 by strength-ranking every
candidate and greedily packing with 1800 ms minimum spacing, so it always emits
something.

**We should take their idea, not their implementation.** Their classifier exists to
*infer* facts we already capture: our recorder samples the live `CursorState` from
NSCursor (`packages/screen_recorder_platform_interface/lib/src/models/cursor_state.dart`,
11 values including `iBeam`, `pointingHand`, `closedHand`), and `CursorEventIndex`
already indexes press and release edges. A click while the cursor reads `iBeam` *is* a
text-field click; no trajectory heuristic can beat reading it directly.

Their clustering answer is also weaker than what we can do: strength-ranking picks one
click out of a form fill and gives it 1.1 s, leaving the rest of the sequence unzoomed.

## Goals

- Emit sensible regions on click-dense recordings instead of none.
- Shape each region according to what the user was actually doing.
- Place regions over the swept area of a gesture, not its start pixel.
- Preserve today's exact output for interactions we can't classify.

## Non-goals

- **No new UI.** Both call sites in
  `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (first-open
  detection at :692 and the "Restore default zoom ranges" command at :1256) keep
  calling `const AutoZoomDetector().detect(...)` with an unchanged signature.
- **No migration.** Zoom regions are persisted per project, so existing projects are
  untouched. Only newly-detected regions change.
- **No `pointingHand` / target-click class.** Considered and deliberately dropped to
  keep the tuning surface small; the signal is available if we want it later.
- **No chained-zoom panning.** See Deferred below.

## Architecture

Four files under `packages/slipreel_engine/lib/editor/`. Everything stays inside
`slipreel_engine`; `CursorState` arrives via `screen_recorder_platform_interface`,
which is already an engine dependency and is permitted by
`test/architecture/engine_layer_boundary_test.dart` (that test forbids only
`package:screen_recorder/*`).

### `cursor_interaction.dart` (new)

The shared vocabulary. One recognised gesture:

```dart
enum InteractionKind { click, textEntry, drag, textSelection }

class CursorInteraction {
  final InteractionKind kind;
  final Duration start;      // press (rising edge)
  final Duration end;        // release (falling edge); == start if never released
  final Offset anchor;       // position at press
  final Rect sweptBounds;    // bbox of the cursor path from press to release
  final CursorState state;   // dominant cursor state across the gesture
}
```

`sweptBounds` is what fixes symptom 3. For an instantaneous click it degenerates to a
zero-size rect at the anchor, so every consumer treats clicks and drags uniformly
instead of branching.

### `interaction_classifier.dart` (new)

Pure. `List<CursorInteraction> classify(CursorRecording, Size videoSize)`.

`videoSize` is a scale reference only — it makes thresholds resolution-independent.
The classifier knows nothing about zoom, regions, or the editor.

### `zoom_shape.dart` (new)

A const map from `InteractionKind` to a `ZoomShape` value (zoom level, lead-in, hold,
lead-out, follow policy, rect derivation). Split out because it is the surface that
will actually get tuned, and tuning it should not mean opening the detector.

### `auto_zoom_detector.dart` (modified)

Loses `_findClickRisingEdges` and `_Click`. Gains cluster accumulation and shape
lookup. Its job shrinks to: interactions in, regions out.

This decomposition mirrors the one already chosen for follow modes —
`rendering/follow_strategy.dart:31-37` documents lifting each mode out of an inline
`_resolveTarget` precisely so the modes became unit-testable in isolation and stopped
polluting the controller with per-mode state. Classification has the same shape:
several independent rules feeding one consumer.

### Data flow

```
CursorRecording
  → classify()      → List<CursorInteraction>
  → cluster()       → List<InteractionGroup>
  → shape()         → List<ZoomRegion>
  → resolveOverlaps() → List<ZoomRegion>
```

## Classification rules

### Gesture extraction

Walk press (`isClicked` false→true) and release (true→false) edges into pairs. An
unterminated press at end-of-recording takes the last sample as its release. Per pair:

- `dwell` = release − press
- `displacement` = |pos(release) − pos(press)|
- `sweptBounds` = bbox of all samples in [press, release]
- `state` = modal `CursorState` over [press − 50 ms, press) — **half-open: the press
  sample itself is excluded**

The 50 ms backward window is deliberate. Reading state at exactly the press sample is
vulnerable to the OS swapping the cursor *in response* to the click; sampling just
before captures what the cursor was over when the user decided to click, which is the
signal we want.

The exclusion is load-bearing, not a detail. An earlier draft of this spec wrote the
interval closed, which let the press sample into the modal vote — and on a tie it won,
because the vote breaks ties toward the sample nearest the press. That is exactly the
contaminated reading the window exists to discard. If no sample falls inside the
half-open window, the press sample's own state is the fallback.

### Decision order

First match wins:

```
diagonal = sqrt(videoSize.width² + videoSize.height²)
dx = |pos(release).x − pos(press).x|
dy = |pos(release).y − pos(press).y|

if displacement > 0.02·diagonal and dwell >= 200ms:
    if state == iBeam and dx > 1.8·dy       -> textSelection
    else                                    -> drag
else:
    if state == iBeam                       -> textEntry
    else                                    -> click
```

The 1.8 axis ratio and 200 ms floor are taken from Recordly's
`classifyPostClickBehavior`, which uses them for the same purpose. The
`0.02·diagonal` threshold replaces their `0.03` of *width*, which was
axis-inconsistent on wide displays.

Two of their rules are deliberately absent. `dropdown-open` (downward drift after a
click) and their synthetic double-click pairing both exist to compensate for not
knowing the cursor state. Double-clicks need no class of their own here: two presses
200 ms apart in the same spot merge into one region under clustering, which is the
correct output anyway.

## Shape table

| kind | zoom | lead-in | hold | lead-out | follow | rect |
|---|---|---|---|---|---|---|
| `click` | 1.5× | 500 ms | 1800 ms | 500 ms | off | centred on anchor |
| `textEntry` | 1.8× | 500 ms | 2600 ms | 600 ms | off | centred on anchor |
| `drag` | 1.4× | 450 ms | gesture + 800 ms | 500 ms | bounded | centred on anchor |
| `textSelection` | ≤1.7× | 450 ms | gesture + 700 ms | 500 ms | off | fitted to `sweptBounds` |

`textSelection` is **framed, not followed**, and that combination is not optional:
`ZoomFocalController` reads `rect.center` only when `followCursor` is false (it must
ignore a stale manual rect on a following zoom). A selection with follow on would
therefore compute the fitted centre and discard it, which is what an earlier draft of
this spec specified. The zoom cap already guarantees the whole sweep fits in frame,
so there is nothing for a follow camera to chase.

`gesture` in the hold column means `end − start` for that interaction (zero for an
instantaneous click).

`textEntry` holds nearly a second longer than a plain click because the interesting
content — the typing — happens *after* the click, and it zooms tighter because text is
what the viewer is being asked to read. `drag` zooms *looser* than a plain click
because the gesture covers ground, and its duration tracks the actual gesture rather
than a constant.

Two rules on top of the table:

1. **`textSelection` zoom is capped to fit its sweep:**
   `zoom = min(1.7, videoW/sweptW, videoH/sweptH)`. Without this, a long selection
   produces a region whose own content does not fit the viewport it requests.
   Swept bounds are clipped to the video frame before fitting, because only the
   press anchor is bounds-checked — a selection dragged onto a second monitor would
   otherwise drive the fit below 1.0.
2. **Every region has a zoom floor of `minClusterZoom` (1.25); below it, no region
   is emitted at all.** A sweep too wide to frame yields ~1.01×, which renders as a
   lane entry that visibly does nothing — and because overlap resolution is greedy and
   start-ordered, that no-op can shadow a genuine zoom starting inside its window.
   `ZoomRegion` silently clamps `zoomLevel` to 1.0, so nothing would have flagged
   it. No zoom beats a fake zoom.
3. **Follow regions inherit existing defaults** — `followMode: bounded`,
   `deadzoneRatio: 0.8`. No new tuning surface; they ride the stack that is already
   tuned.

`tilt: Tilt3D(style: ZoomTiltStyle.subtle)` stays on every emitted region, as today.

### Back-compat

`zoomLevel`, `leadIn`, `hold`, and `leadOut` survive as constructor parameters and now
define the `click` shape, so a **solitary unclassified click produces a byte-identical
region to today**.

`isolationWindow` is **removed**, not repurposed. Its semantics invert under this
design — it was a rejection window (drop clicks with close neighbours) and the nearest
new concept is a merge window (join clicks with close neighbours). Keeping the name
for the opposite meaning would be a trap. It is replaced by `clusterGap`
(default 1200 ms). Both call sites construct `const AutoZoomDetector()` with no
arguments, so no caller breaks.

Note the scope of the back-compat claim: individual region *shapes* are preserved, but
the *set* of emitted regions changes by design — that is the fix for symptom 1.

## Clustering

**The isolation filter is deleted.** `_filterIsolated` is the direct cause of symptom 1.
Clustering replaces it, as a generalisation rather than a special path: a cluster of
one is just an interaction.

Greedy accumulation over time-ordered interactions. Extend the current cluster with the
next interaction when both hold:

- time gap (`next.start − current.end`) < `clusterGap` (default 1200 ms)
- the union of `sweptBounds` still fits at ≥ 1.25× zoom, i.e.
  `min(videoW/unionW, videoH/unionH) >= 1.25`

The second condition keeps this honest: clicks scattered across the screen cannot merge,
because merging them would produce a "zoom" so wide it is not one. When adding an
interaction would drop the fit below 1.25×, the cluster closes and a new one starts.

Emission depends on cluster size:

- **Size 1** — shape table above, follow policy included.
- **Size ≥2** — anchored (never follow), rect fitted to the union of swept bounds, with:
  - `zoom = min(widestMemberZoom, fitZoom)` where `widestMemberZoom` is the **lowest**
    zoom level among the member kinds and `fitZoom = min(videoW/unionW, videoH/unionH)`.
    Taking the lowest rather than a "dominant kind" removes a tie-breaking rule and is
    the safe direction: the region has to cover every member, so the widest member's
    framing governs.
  - `start = firstPress − clickLeadIn` (500 ms), `end = lastRelease + clickLeadOut`
    (500 ms), using the `click` shape's lead values rather than any member's.
  - **The held span is floored at the `click` shape's hold (1800 ms).** Without the
    floor, two clicks 500 ms apart merge into a region *shorter* than either would
    have produced alone — it starts ramping out ~50 ms after the second release —
    so the merge actively degrades the click-dense case this design exists to fix.
  - **The held span is also capped at `ZoomShape.maxHold` (6 s), by splitting into a
    new cluster rather than truncating.** An earlier draft argued for no ceiling, on
    the grounds that "a long cluster means the user worked in one small area that
    long, and the fit rule already bounds how wide the region gets." That reasoning
    was wrong: `minClusterZoom` of 1.25 tolerates a union covering roughly 80% of the
    frame, which is not a small area. Without the cap, a 60 s demo with about one
    click per second inside an app window merged into a *single 60 s region* — the
    whole video cropped to one fixed frame. Splitting rather than truncating avoids
    leaving the tail of a long working session unzoomed.

    Cluster span is therefore bounded on both sides: `[1800 ms, 6000 ms]`.

Single gestures may follow; merged clusters stay anchored and widen instead. This is
the deliberate split: following *between* form fields reads as busy, while following
*along* one drag reads as intentional.

**Overlap resolution truncates rather than discards.** When region *n* overlaps
region *n+1*, *n* is shortened to end exactly at *n+1*'s start, so both interactions
stay represented. The exception is when truncating would leave *n* too short for its
own ramps (`enterDuration + exitDuration`); there the old behaviour applies — keep *n*
whole and drop *n+1*.

This changed because regions got substantially longer in this design: a drag can run
6.95 s and a cluster up to 7 s, where the pre-classifier detector emitted a uniform
2.8 s. Discarding the later region unchanged would have suppressed far more genuine
interactions than it used to.

## Edge cases

- **Legacy recordings with no cursor state.** Every sample reads `arrow`, so
  `textEntry` and `textSelection` never fire. The pipeline degrades to click/drag plus
  clustering. No crash, no special-casing.
- **Press with no release** (recording ends mid-drag) — release is the last sample.
- **Very long drags** — hold is capped at 6 s, so a 30-second canvas pan does not zoom
  the entire video.
- **Off-screen clicks.** The existing multi-monitor bounds check moves up to the
  interaction level and drops out-of-bounds anchors before clustering. Behaviour
  preserved (see `auto_zoom_detector_offscreen_test.dart`).
- **Swept bounds exceeding video bounds** — clamped before the fit calculation.
- **Device captures** carry no clicks and are already guarded at the call site.
- **Empty or single-sample recordings** — empty result.

## Testing

TDD, three layers.

**Classifier unit tests** (`test/editor/interaction_classifier_test.dart`, new) — one
test per rule, plus boundary pairs on each threshold: displacement at 0.019 vs 0.021
diagonal, dwell at 199 vs 201 ms, axis ratio at 1.7 vs 1.9. Fixtures are hand-built
`CursorRecording`s with no zoom types involved. This isolation is the payoff for
splitting the classifier out.

**Clustering tests** — a form-fill fixture (5 clicks, 800 ms apart, same area) yields
exactly one region spanning the sequence; spatially scattered clicks at the same
cadence yield separate regions; a cluster that would breach the 1.25× floor splits at
the expected index.

**Shape tests** — each kind maps to its expected zoom, duration, and follow flag; the
`textSelection` fit cap engages on a wide sweep.

**Regression.** Of the 14 existing tests across `auto_zoom_detector_test.dart`,
`auto_zoom_detector_offscreen_test.dart`, and `auto_zoom_detector_tilt_test.dart`, 13
pass unchanged. Exactly one inverts deliberately:

> `two clicks 0.5 s apart → no regions (both fail isolation)`

becomes **one merged region** — the entire point of this change. It is rewritten with
the new expectation and a comment pointing at this spec.

## Deferred

**Chained-zoom panning.** Recordly's `connectZooms` pans the camera directly from
region A's focal to region B's over 1000 ms on a `cubicBezier(0.1, 0, 0.2, 1)` when the
two are within 1500 ms, instead of zooming out and back in
(`src/components/video-editor/videoPlayback/zoomRegionUtils.ts`). We have no
equivalent — overlap resolution truncates the first region so the second can start,
which keeps both interactions but still cuts out and back in between them rather than
panning. It is a genuine gap,
but it is a camera-path feature rather than a detection one, and folding it in would
double this spec. Worth its own sub-project.
