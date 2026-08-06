# Auto-Zoom Region Merging and Click Follow — Design

**Date:** 2026-08-06
**Branch:** `feat/auto-zoom-interaction-classifier` (extends the work in PR #45)
**Status:** Approved design, pending implementation plan
**Supersedes parts of:** `2026-08-02-auto-zoom-interaction-classifier-design.md`

## Problem

Observed by opening a real 30 s recording (1893×986, 11 detected interactions) in the
editor with PR #45's detector.

1. **Zoom bars visibly stick together.** Two pairs of regions abut exactly — one
   region ends at 4890 ms where the next begins, another at 11280 ms — because the
   overlap rule truncates the earlier region to end at the later one's start. The
   camera therefore ramps out to 1.0× and immediately ramps back in, a visible
   "pump" at a seam the viewer has no reason to see.

2. **Click zooms do not follow the cursor.** They are anchored on the click point,
   so the camera cannot track the user after the click.

A third observation, found while diagnosing the first: **five of the eight regions
frame the identical spot** — centre `(631, 329)` — despite their clicks being at
`(108,66)`, `(145,68)`, `(126,72)`, `(542,132)` and `(405,126)`. At 1.5× on a
1893×986 video the un-clamped centre zone is only `cx ∈ [631,1262]`,
`cy ∈ [329,657]`, so every click in the left sidebar clamps to the same framing.
Several bars are not merely adjacent — they are the same shot repeated.

Clustering is working correctly and is not the cause: it already merged two pairs
on its own (press gaps of 243 ms and 351 ms). The abutting pairs are >1200 ms apart
at the press, so they are legitimately separate clusters whose *regions* collide
because each is 2.8 s long.

## Goals

- Merge regions whose seam is not worth rendering, so the camera pans instead of
  pumping.
- Let click-derived zooms track the cursor.

## Non-goals

- No change to classification. The kinds, thresholds, and cluster gates are
  untouched.
- No new UI.
- No attempt to beat the viewport clamp. A click near a corner cannot be centred at
  1.5×; following changes what happens *after* the click, not the framing at it.

## Rules

### 1. Click zooms follow

`kZoomShapes[InteractionKind.click].followCursor` becomes `true`, and so does the
hardcoded `false` in `AutoZoomDetector._shapeFor`'s click override. Both must
change; the shape table alone is not read for `click` (see the pinning test added
in PR #45).

Follow regions inherit the existing defaults — `FollowMode.bounded`,
`deadzoneRatio: 0.8`. The bounded gate holds the camera until the cursor leaves 80%
of the visible viewport, so a click where the pointer stays put produces no motion
at all. Motion happens only when the user actually moves away.

### 2. Merge threshold is ramp-based, not "touching"

Strict abutment is too narrow. In the observed recording the seams are 0 ms, 44 ms
and 518 ms — all read as touching on screen (0, 3 and 33 px at the default timeline
scale) but only one is exactly zero.

**Merge two consecutive regions when the gap between them is smaller than the ramps
that would be spent crossing it:**

```
gap = next.startTime − (prev.startTime + prev.duration)
merge when gap < prev.exitDuration + next.enterDuration
```

`gap` is **negative when the regions overlap**, which is the common case here — a
2.8 s region frequently starts before its predecessor ends. Negative gaps are always
below the threshold, so every overlap merges. This is the measure on *regions*, not
on the press times the clustering step uses; the two are routinely very different
(the observed recording has a pair 1550 ms apart at the press whose regions overlap
by 1200 ms).

For click shapes the threshold is 1000 ms. Below it the camera cannot finish ramping
out and back in before the next zoom starts, so the seam is pure pump with no payoff.
Above it there is genuine room to return to full frame.

This is self-scaling: kinds with shorter ramps merge less eagerly, which is the
correct relationship.

**Chains merge greedily, left to right.** After a merge the result is compared
against the following region using the merged region's own `exitDuration` (its last
member's), so a run of three or more collapses into one span rather than pairs.

### 3. Follow policy after grouping

Two different groupings exist and they are **not** governed by the same rule. Keeping
them distinct matters, because conflating them is what made the first draft of this
spec contradict itself.

**Clustering** (interaction-level, by press gap and spatial fit): the cluster's follow
policy is `true` if **any member kind's shape follows**. A cluster of clicks follows,
because `click` now does. A `textEntry`-only cluster stays anchored, because
`textEntry` does.

This replaces the previous spec's "clusters of 2+ stay anchored" rule, which was
decided when clicks did not follow. Keeping it alongside rule 1 would mean two clicks
300 ms apart produce an anchored region while two clicks 1500 ms apart merge and pan —
a distinction with no basis in what the user did.

**Merging** (region-level, across a small seam — rule 2): the merged region **always**
follows, whatever its members were. Merging exists so the camera can pan across the
seam, and following is the mechanism that pans. An anchored pair that merges has, by
definition, two framings to get between.

Merged region fields:

- `start` = first member's start, `end` = last member's end
- `enterDuration` = first member's, `exitDuration` = last member's
- `zoomLevel` = the **lowest** among members (widest framing), matching the existing
  cluster rule — no tie-break needed, and it errs in the safe direction
- `rect` = union of member rects. Unused while following, but must be valid.

### 4. Overlap resolution is replaced, not extended

Merging subsumes the previous behaviour entirely:

- The Stage D rule (truncate the earlier region to end at the later one's start) is
  removed. Every case it handled now merges.
- Its fallback (keep the earlier region whole and drop the later one when the trim
  would leave less than both ramps) is also removed.

Output remains non-overlapping by construction, since merging consumes both inputs.

### 5. The 6 s ceiling applies to anchored regions only

`ZoomShape.maxHold` exists because an *anchored* cluster whose union covers ~80% of
the frame is not a zoom — it is a crop of the whole video. That failure mode cannot
occur for a following region: it has no union, it tracks the cursor, so it always
frames where the action is however long it runs.

The ceiling therefore applies to **anchored regions only**. Under rule 3 that means
`textEntry`-only clusters keep it; click clusters and every merged region, all of
which follow, do not.

**Accepted consequence:** a dense recording can become one long tracking shot. The
merges in the observed recording are already 7.7 s and 7.8 s, both over the old cap;
capping them would re-create the exact seams this design removes.

**Known open risk, deliberately not designed around:** a video that never returns to
full frame has no rhythm. That is an aesthetic judgement, not a correctness one, and
has not been raised as a problem. If long shots read as monotonous in practice, a
ceiling is a one-line tuning change.

## Expected effect

On the observed recording, 8 regions become 4:

| merged region | source seams | character |
|---|---|---|
| 0–7690 ms | 44 ms, 0 ms | stable shot over five sidebar clicks |
| 9556–17398 ms | 0 ms, 518 ms | pans `(1389,340)` → `(542,132)` → `(683,284)` |
| 19615–22415 ms | — | unchanged |
| 24086–26886 ms | — | unchanged |

Seams above the threshold are left alone: 1866 ms, 2217 ms and 1671 ms gaps remain
separate regions.

## Dependency on the export fix

This makes nearly every auto-detected region a follow region, and follow regions are
exactly the ones where export used to render a different camera than the preview
(issue #46, fixed in PR #47, merged as `1e76cfd7`). Holding PR #45 on that fix was
load-bearing: without it this change would have shipped that divergence to every
recording containing a click, rather than only to manually-added follow zooms.

## Testing

- **Shape:** `click` carries `followCursor: true`, in both the table and what the
  detector actually emits for a solitary click.
- **Merge threshold:** a pair whose gap is just under `exit + enter` merges; a pair
  just over it does not. Both directions, bracketing the boundary closely.
- **Chain:** three regions each within the threshold of the next collapse into one
  spanning region, not two.
- **Merged policy:** a merged region reports `followCursor: true` even when built
  from members that were anchored.
- **Anchored path preserved:** a `textEntry`-only cluster still gets the `maxHold`
  ceiling and the `minClusterZoom` fit floor.
- **Real-recording guard:** the fixture from the observed recording yields 4 regions
  with the spans in the table above.

### Tests that invert deliberately

Two tests from PR #45 assert the behaviour this design replaces, and are rewritten
rather than deleted:

1. `two clicks 1.6 s apart …` (in `auto_zoom_detector_test.dart`) asserts the
   truncation outcome. The clicks are 1600 ms apart at the press, but their regions
   are `[1500, 4300]` and `[3100, 5900]` — a **−1200 ms** gap, i.e. they overlap.
   Under rule 2 they merge into a single following region `[1500, 5900]`. The test
   is rewritten to assert that, and its name updated: the press gap it is named for
   was never what decided the outcome.
2. The `~30 clicks over 40 s` cap test asserts more than one region and none longer
   than `leadIn + maxHold + leadOut`. Under rule 5 that run becomes a single long
   tracking shot; it is rewritten to assert that, and that the region follows.
