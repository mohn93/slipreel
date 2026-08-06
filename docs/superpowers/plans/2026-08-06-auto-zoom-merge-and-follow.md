# Auto-Zoom Region Merging and Click Follow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make click-derived auto-zoom regions follow the cursor, and merge regions whose seam is shorter than the ramps spent crossing it into one following region, so the camera pans instead of ramping out and back in.

**Architecture:** Three localised changes to `packages/slipreel_engine/lib/editor/`: one shape-table flag, one follow-policy rule in the cluster branch of `_buildRegion` (plus making the span ceiling anchored-only), and a rewrite of `_resolveOverlaps` into a merge pass.

**Tech Stack:** Dart / Flutter, `slipreel_engine` package, `flutter_test`, melos workspace.

**Spec:** `docs/superpowers/specs/2026-08-06-auto-zoom-merge-and-follow-design.md`

## Global Constraints

- **Do NOT run `dart format`.** The pinned formatter is tall-style but committed code is not; running it reflows ~50+ unrelated lines and CI does not enforce it. Match surrounding style by hand.
- `slipreel_engine` must never import `package:screen_recorder/*`.
- `AutoZoomDetector.detect({cursor, videoSize, videoDuration})` keeps its signature; the class stays `const`-constructible; both call sites use `const AutoZoomDetector()` and must not need edits.
- **Classification is untouched.** Kinds, thresholds, and the three cluster gates in `_cluster` keep their current behaviour, with the single exception in Task 2 (the span ceiling becomes anchored-only).
- Merge threshold, verbatim from the spec: `gap = next.startTime − (prev.startTime + prev.duration)`, merge when `gap < prev.exitDuration + next.enterDuration`. `gap` is negative when regions overlap.
- Every emitted region keeps `tilt: Tilt3D(style: ZoomTiltStyle.subtle)`.

**Test commands:**
- Single file: `cd packages/slipreel_engine && flutter test test/editor/<file>.dart`
- Package suite: `cd packages/slipreel_engine && flutter test` (baseline **1268** tests)
- Workspace: `melos run test --no-select` then `melos run analyze --no-select` from the repo root (note: bare `melos test` prompts interactively and fails in a non-TTY)

**A note on expected test fallout.** Each task below lists tests I expect to change. Those are predictions from reading the code, not measurements — earlier rounds of this project proved such predictions wrong more than once. Run the suite, compare against the list, and **if anything moves that is not on the list, stop and report rather than adjusting it.**

---

### Task 1: Click zooms follow the cursor

**Files:**
- Modify: `packages/slipreel_engine/lib/editor/zoom_shape.dart` (the `click` row of `kZoomShapes`)
- Modify: `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart:89-102` (`_shapeFor`)
- Modify: `packages/slipreel_engine/test/editor/zoom_shape_test.dart`
- Modify: `packages/slipreel_engine/test/editor/auto_zoom_detector_shape_test.dart`

**Interfaces:**
- Consumes: `ZoomShape`, `kZoomShapes`, `InteractionKind` (all existing).
- Produces: no signature changes. `kZoomShapes[InteractionKind.click].followCursor == true`, and `AutoZoomDetector._shapeFor(InteractionKind.click).followCursor == true`.

**Why two places:** `_shapeFor` short-circuits `click` and rebuilds the shape from the detector's constructor fields, hardcoding `followCursor: false` at line 96. Changing only the table would have no effect on production output — that is the exact divergence the pinning test in `auto_zoom_detector_shape_test.dart` exists to catch, so it will fail loudly if you miss one.

- [ ] **Step 1: Update the two existing tests to the new expectation**

In `packages/slipreel_engine/test/editor/zoom_shape_test.dart`, the test `click shape matches the historic auto-zoom defaults` asserts `expect(shape.followCursor, isFalse);`. Change that line to:

```dart
    // Click zooms follow as of 2026-08-06: the camera tracks the cursor
    // after the click instead of sitting on a clamped box centre. Bounded
    // follow holds until the cursor leaves 80% of the viewport, so a click
    // where the pointer stays put still produces no motion.
    expect(shape.followCursor, isTrue);
```

In `packages/slipreel_engine/test/editor/auto_zoom_detector_shape_test.dart`, the test `arrow click keeps the historic 1.5x / 2.8s anchored shape` asserts `expect(r.followCursor, isFalse);`. Change that line to `expect(r.followCursor, isTrue);` and rename the test to `arrow click keeps the historic 1.5x / 2.8s shape and follows`.

- [ ] **Step 2: Run those two files to verify they fail**

Run: `cd packages/slipreel_engine && flutter test test/editor/zoom_shape_test.dart test/editor/auto_zoom_detector_shape_test.dart`

Expected: FAIL — two failures, both `Expected: true / Actual: <false>`.

- [ ] **Step 3: Flip the shape table**

In `packages/slipreel_engine/lib/editor/zoom_shape.dart`, the `InteractionKind.click` entry of `kZoomShapes` currently has `followCursor: false`. Change it to `followCursor: true` and update the comment above the row so it no longer claims the detector's override is anchored — it must still say that `AutoZoomDetector` overrides this row from its constructor parameters.

- [ ] **Step 4: Flip the detector override**

In `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart`, inside `_shapeFor`, change `followCursor: false` (line 96) to `followCursor: true`.

- [ ] **Step 5: Run the two files to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/editor/zoom_shape_test.dart test/editor/auto_zoom_detector_shape_test.dart`

Expected: PASS.

- [ ] **Step 6: Run the package suite and compare against the prediction**

Run: `cd packages/slipreel_engine && flutter test`

Expected to fail: **nothing beyond what you already fixed.** The click-shape pinning test derives its expectation from `kZoomShapes[click]` rather than hardcoding, so it should track the change automatically. The form-fill cluster test asserts `followCursor isFalse` for a `textEntry` cluster, which is still anchored, so it should stay green.

If any other test fails, stop and report it — do not adjust it.

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/editor/zoom_shape.dart packages/slipreel_engine/lib/editor/auto_zoom_detector.dart packages/slipreel_engine/test/editor/zoom_shape_test.dart packages/slipreel_engine/test/editor/auto_zoom_detector_shape_test.dart
git commit -m "feat(engine): click zooms follow the cursor

The camera tracks the cursor after a click instead of sitting on a box
centre that the viewport clamp often pins far from the click itself."
```

---

### Task 2: Cluster follow policy, and the span ceiling becomes anchored-only

**Files:**
- Modify: `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart` (`_cluster` span gate; `_buildRegion` cluster branch)
- Test: `packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart`

**Interfaces:**
- Consumes: `_shapeFor(InteractionKind) -> ZoomShape` from Task 1.
- Produces: no signature changes. A cluster's `followCursor` is now `true` when any member kind's shape follows.

**Rule (from spec rule 3 and rule 5):** a cluster follows when **any member kind's shape follows**. `ZoomShape.maxHold` is a property of anchored regions only — a following region tracks the cursor and always frames the action, so the ceiling that exists to stop a wide anchored union from cropping the whole video does not apply to it.

- [ ] **Step 1: Write the failing tests**

Add these two tests to `packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart`, after the existing `a single interaction still keeps its own follow policy` test:

```dart
  test('a cluster of clicks follows, because the click shape follows', () {
    // Two clicks close in time and space form one cluster. Since clicks
    // follow as of 2026-08-06, the cluster follows too — the previous
    // "clusters of 2+ are always anchored" rule was decided when clicks
    // did not follow, and keeping it would make two clicks 300ms apart
    // behave differently from two clicks 1500ms apart for no reason the
    // user could observe.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 400),
      ..._clickAt(atMs: 2400, x: 740, y: 420),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
  });

  test('a long click cluster is not capped, because it follows', () {
    // 12 clicks a second apart in a small area. Every gap is under the
    // 1200ms cluster gap and the union stays tiny, so only the span
    // ceiling could split this run — and the ceiling no longer applies to
    // a following cluster. The result is one continuous tracking shot
    // longer than ZoomShape.maxHold.
    final rec = _rec([
      for (var i = 0; i < 12; i++)
        ..._clickAt(atMs: 2000 + i * 1000, x: 800 + i.toDouble(), y: 400),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: const Duration(seconds: 60),
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
    expect(
      out.single.duration,
      greaterThan(const Duration(milliseconds: 7000)),
      reason: 'a following cluster must not be capped at leadIn + maxHold '
          '+ leadOut',
    );
  });
```

- [ ] **Step 2: Run the file to verify the new tests fail**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_cluster_test.dart`

Expected: FAIL — the first new test fails on `followCursor` being false; the second fails because the span ceiling splits the run into more than one region.

- [ ] **Step 3: Make the span ceiling anchored-only**

In `_cluster`, the join predicate currently reads:

```dart
      final prospectiveSpan = next.end - current.first.start;
      final joins = (next.start - lastEnd) < clusterGap &&
          _fitZoom(merged, videoSize) >= minClusterZoom &&
          prospectiveSpan <= ZoomShape.maxHold;
```

Replace those lines with:

```dart
      // The span ceiling is a property of ANCHORED clusters only. It exists
      // because a wide anchored union is a crop of the whole video rather
      // than a zoom; a following cluster has no union to frame — it tracks
      // the cursor — so a long one is a sustained tracking shot, which is
      // the intended result of merging.
      final prospectiveMembers = <CursorInteraction>[...current, next];
      final wouldFollow = prospectiveMembers
          .any((m) => _shapeFor(m.kind).followCursor);
      final prospectiveSpan = next.end - current.first.start;
      final joins = (next.start - lastEnd) < clusterGap &&
          _fitZoom(merged, videoSize) >= minClusterZoom &&
          (wouldFollow || prospectiveSpan <= ZoomShape.maxHold);
```

- [ ] **Step 4: Set the cluster's follow policy from its members**

In `_buildRegion`, the cluster branch (the `else` at line 192) ends with `follow = false;` at line 219. Replace that single line with:

```dart
      follow = group.any((it) => _shapeFor(it.kind).followCursor);
```

Then update the comment block at the top of that branch (lines 193-196), which currently opens `// Merged cluster: anchored, framed over every member.` — it must no longer claim the cluster is anchored. State that the framing below is used only when the cluster does not follow.

- [ ] **Step 5: Add the anchored-path tests**

The ceiling has **no observable effect on region count** — a split it causes is always
re-merged in Task 3, because the two pieces end up under 200ms apart. What is
observable is that a short anchored run stays anchored while a long one comes out
following. Add both to `auto_zoom_detector_cluster_test.dart`:

```dart
  test('a short textEntry cluster stays anchored', () {
    // textEntry is an anchored shape and this run never reaches the span
    // ceiling, so the cluster keeps the anchored path: fitted union centre
    // and the minClusterZoom floor.
    final rec = _rec([
      for (var i = 0; i < 3; i++)
        ..._clickAt(
          atMs: 2000 + i * 700,
          x: 800,
          y: 400 + i * 30.0,
          state: CursorState.iBeam,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isFalse);
  });

  test('a long textEntry run comes out following, not anchored', () {
    // Past the span ceiling the cluster closes, but the piece it starts is
    // contiguous with the previous one, so Task 3's merge pass rejoins them
    // — and merged regions follow. The ceiling's real effect is therefore
    // that a long anchored run stops being one wide anchored crop and
    // becomes a tracking shot. Region COUNT is not what it changes.
    final rec = _rec([
      for (var i = 0; i < 12; i++)
        ..._clickAt(
          atMs: 2000 + i * 1000,
          x: 800,
          y: 400 + i.toDouble(),
          state: CursorState.iBeam,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: const Duration(seconds: 60),
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
  });
```

Note: this second test depends on Task 3's merge pass and will not pass until Task 3
lands. Write it now, mark it `skip: 'depends on Task 3 merge pass'`, and remove the
skip in Task 3 Step 7.

- [ ] **Step 6: Run the file to verify the new tests pass**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_cluster_test.dart`

Expected: PASS, with one test skipped.

- [ ] **Step 7: Run the package suite and compare against the prediction**

Run: `cd packages/slipreel_engine && flutter test`

Expected to stay green, including:
- the form-fill test (a `textEntry` cluster is still anchored, so its `followCursor isFalse` assertion holds)
- `cluster frames every member` (the union centre is still computed; only its follow flag changed)

If anything else fails, stop and report it.

- [ ] **Step 8: Commit**

```bash
git add packages/slipreel_engine/lib/editor/auto_zoom_detector.dart packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart
git commit -m "feat(engine): cluster follow policy comes from member shapes

A cluster follows when any member kind's shape follows, replacing the
blanket 'clusters of 2+ are anchored' rule. The span ceiling becomes
anchored-only: it guards against a wide anchored union cropping the
whole video, which cannot happen to a region that tracks the cursor."
```

---

### Task 3: Merge adjacent regions instead of truncating

**Files:**
- Modify: `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart:75` (call site) and `:258-303` (`_resolveOverlaps`)
- Modify: `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`
- Modify: `packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart`

**Interfaces:**
- Consumes: `_rectFor(Offset center, double zoom, Size videoSize) -> Rect` (existing private helper).
- Produces: `_resolveOverlaps` is replaced by `List<ZoomRegion> _mergeAdjacent(List<ZoomRegion> regions, Size videoSize)`. It takes `videoSize` because a merged region needs a valid rect derived through `_rectFor`.

- [ ] **Step 1: Write the failing test**

Add to `packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart`:

```dart
  test('regions separated by less than their ramps merge and follow', () {
    // Two clicks far enough apart to be separate clusters (gap well over
    // the 1200ms cluster gap) but whose 2800ms regions still collide.
    // Region 1 = [1500, 4300], region 2 = [3100, 5900]: the regions
    // overlap by 1200ms, which is below the 1000ms of ramps that crossing
    // the seam would cost, so they merge rather than the first being
    // truncated.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 3600, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    expect(r.startTime, const Duration(milliseconds: 1500));
    expect(r.startTime + r.duration, const Duration(milliseconds: 5900));
    expect(r.followCursor, isTrue,
        reason: 'merging exists so the camera can pan across the seam');
  });

  test('regions further apart than their ramps stay separate', () {
    // Same shape, but the second click is late enough that the regions
    // are 1400ms apart — above the 1000ms of ramps — so there is genuine
    // room to return to full frame between them.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 6200, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
    expect(out[0].startTime + out[0].duration,
        const Duration(milliseconds: 4300));
    expect(out[1].startTime, const Duration(milliseconds: 5700));
  });

  test('a merged region follows even when both members were anchored', () {
    // Two iBeam clicks 1600ms apart: above the cluster gap, so they form
    // separate textEntry clusters, and textEntry is an ANCHORED shape.
    // Their regions ([1500,5200] and [3100,6800] at textEntry's 500/2600/600
    // envelope) still overlap, so they merge — and a merged region follows
    // regardless of what its members were, because a seam means two
    // framings to travel between.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450, state: CursorState.iBeam),
      ..._clickAt(atMs: 3600, x: 1100, y: 600, state: CursorState.iBeam),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.followCursor, isTrue);
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 6800));
  });

  test('a chain of three collapses into one span, not two', () {
    // Each region is within the merge threshold of the next. Greedy
    // left-to-right merging must carry the accumulated region forward, so
    // the run becomes a single span rather than a merged pair plus a
    // straggler.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 4200, x: 800, y: 500),
      ..._clickAt(atMs: 6400, x: 900, y: 550),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 8700));
  });
```

- [ ] **Step 2: Run the file to verify the new tests fail**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_cluster_test.dart`

Expected: FAIL — the first and third produce 2 and 2-or-3 regions respectively under the current truncation rule.

- [ ] **Step 3: Replace the overlap pass with a merge pass**

In `auto_zoom_detector.dart`, change the call at line 75 from:

```dart
    return _resolveOverlaps(regions);
```

to:

```dart
    return _mergeAdjacent(regions, videoSize);
```

Then replace the entire `_resolveOverlaps` method (its doc comment and body, lines 258-303) with:

```dart
  /// Collapses regions whose seam is not worth rendering into one following
  /// region, so the camera pans across instead of ramping out to 1.0x and
  /// straight back in.
  ///
  /// Two consecutive regions merge when the gap between them is smaller
  /// than the ramps that crossing it would cost:
  ///
  ///     gap = next.startTime - (prev.startTime + prev.duration)
  ///     merge when gap < prev.exitDuration + next.enterDuration
  ///
  /// `gap` is NEGATIVE when the regions overlap, which is the common case —
  /// a 2.8 s region frequently starts before its predecessor ends — so every
  /// overlap merges. Above the threshold there is genuine room to return to
  /// full frame, and the regions are left alone.
  ///
  /// Merging replaces the previous truncate-the-earlier-region rule
  /// entirely; output is non-overlapping by construction because a merge
  /// consumes both inputs. The pass is greedy left to right, comparing the
  /// accumulated region (and therefore its last member's exit ramp) against
  /// the next one, so a run of three or more collapses into one span.
  ///
  /// A merged region always follows: merging exists so the camera can pan
  /// across the seam, and following is the mechanism that pans.
  List<ZoomRegion> _mergeAdjacent(List<ZoomRegion> regions, Size videoSize) {
    if (regions.isEmpty) return const [];
    final sorted = [...regions]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    final out = <ZoomRegion>[];
    for (final r in sorted) {
      if (out.isEmpty) {
        out.add(r);
        continue;
      }
      final prev = out.last;
      final prevEnd = prev.startTime + prev.duration;
      final gap = r.startTime - prevEnd;
      if (gap >= prev.exitDuration + r.enterDuration) {
        out.add(r);
        continue;
      }

      final end = (r.startTime + r.duration) > prevEnd
          ? r.startTime + r.duration
          : prevEnd;
      // Widest of the two, matching the cluster rule: no tie-break needed
      // and it errs in the safe direction when one region has to cover both.
      final zoom = prev.zoomLevel < r.zoomLevel ? prev.zoomLevel : r.zoomLevel;
      final union = prev.rect.expandToInclude(r.rect);
      out[out.length - 1] = prev.copyWith(
        duration: end - prev.startTime,
        exitDuration: r.exitDuration,
        zoomLevel: zoom,
        followCursor: true,
        // Unused while following, but it must stay valid and consistent
        // with `zoom` in case the flag is ever turned off.
        rect: _rectFor(union.center, zoom, videoSize),
      );
    }
    return out;
  }
```

- [ ] **Step 4: Run the file to verify the new tests pass**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_cluster_test.dart`

Expected: PASS for the three new tests. Two pre-existing tests in this file are expected to FAIL — handle them in Step 5.

- [ ] **Step 5: Update the two inverted tests in the cluster file**

Both currently assert the truncation/drop outcome.

`spatially scattered clicks at the same cadence do not merge` — the clicks are at 2000 `(60,60)` and 2800 `(1860,1020)`. They fail the cluster spatial gate, so they stay separate clusters producing regions `[1500, 4300]` and `[2300, 5100]`. Those regions overlap by 2000ms, so under the new rule they merge. Replace the whole test with:

```dart
  test('scattered clicks form separate clusters but their regions merge', () {
    // The two clicks are far enough apart that the union would not fit at
    // 1.25x, so CLUSTERING correctly refuses to group them. Their regions
    // still overlap, though, and an overlap is always below the merge
    // threshold — so the region pass joins them and the camera pans
    // between the two corners rather than cutting out and back in.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 60, y: 60),
      ..._clickAt(atMs: 2800, x: 1860, y: 1020),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 5100));
    expect(out.single.followCursor, isTrue);
  });
```

`a cluster splits when the next click would breach the zoom floor` — its first cluster yields `[1500, 4300]` (rawSpan floored to 1800ms) and the third click yields `[2300, 5100]`, which overlap and now merge. Replace the whole test with:

```dart
  test('a cluster splits at the zoom floor, then the regions merge', () {
    // Clicks 1-2 cluster; adding click 3 would make the union 1600x750,
    // which fits at only 1.2x — below the 1.25x floor — so CLUSTERING
    // closes before it. The two resulting regions overlap, so the region
    // pass merges them. The split still happened: without it the union
    // would have framed all three at once instead of the camera panning.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 300, y: 300),
      ..._clickAt(atMs: 2400, x: 340, y: 320),
      ..._clickAt(atMs: 2800, x: 1900, y: 1050),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 5100));
    expect(out.single.followCursor, isTrue);
  });
```

- [ ] **Step 6: Update the inverted test in the main detector file**

In `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`, the test named `two clicks 1.6 s apart → only the first survives (overlap drops second)` (or whatever it was last renamed to) asserts the truncation outcome. Its regions are `[1500, 4300]` and `[3100, 5900]` — a −1200ms gap. Replace the whole test with:

```dart
  test('two clicks 1.6 s apart → one merged region spanning both', () {
    // The press gap is 1600ms — above the 1200ms cluster gap, so these are
    // two clusters. What decides the outcome is the REGION gap: [1500,4300]
    // and [3100,5900] overlap by 1200ms, which is below the 1000ms of ramps
    // that crossing the seam would cost, so they merge into one following
    // region. The press gap this test is named for was never what decided
    // it. See docs/superpowers/specs/2026-08-06-auto-zoom-merge-and-follow-design.md
    final cursor = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 450),
      ..._clickAt(atMs: 3600, x: 1100, y: 600),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 5900));
    expect(out.single.followCursor, isTrue);
  });
```

- [ ] **Step 7: Un-skip the deferred test from Task 2**

In `auto_zoom_detector_cluster_test.dart`, the test `a long textEntry run comes out
following, not anchored` was written in Task 2 Step 5 with
`skip: 'depends on Task 3 merge pass'`. Remove that skip argument — the merge pass now
exists, so it should pass.

- [ ] **Step 8: Run the package suite and compare against the prediction**

Run: `cd packages/slipreel_engine && flutter test`

Expected: PASS, no skips. The three tests updated in Steps 5-6 are the only pre-existing ones I predict will move. If anything else fails, stop and report it rather than adjusting it.

- [ ] **Step 9: Commit**

```bash
git add packages/slipreel_engine/lib/editor/auto_zoom_detector.dart packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart
git commit -m "feat(engine): merge adjacent zoom regions instead of truncating

Regions whose seam is shorter than the ramps spent crossing it now merge
into one following region, so the camera pans across rather than ramping
out to 1.0x and immediately back in. Replaces the truncate-the-earlier
rule entirely."
```

---

### Task 4: Real-recording guard and workspace verification

**Files:**
- Test: `packages/slipreel_engine/test/editor/auto_zoom_real_recording_test.dart` (new)

**Interfaces:**
- Consumes: the full pipeline as delivered by Tasks 1-3. No production changes in this task.

This pins the end-to-end behaviour against the click timings taken from a real 30 s recording — the case that prompted the change. Under the pre-change rules it produced 8 regions, two pairs of which abutted exactly.

- [ ] **Step 1: Write the test**

Create `packages/slipreel_engine/test/editor/auto_zoom_real_recording_test.dart`:

```dart
@TestOn('vm')
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

/// Press timings and anchors taken from a real 1893x986 screen recording
/// (30 s, 11 detected presses). Under the pre-2026-08-06 rules this produced
/// 8 regions, two pairs of which abutted exactly — the seams that prompted
/// merging. See
/// docs/superpowers/specs/2026-08-06-auto-zoom-merge-and-follow-design.md
void main() {
  const videoSize = Size(1893, 986);

  // (pressMs, x, y). The press at 1699ms is at x=2861, off the captured
  // display — a second monitor. The bounds guard must drop it.
  const presses = <List<double>>[
    [375, 108, 66],
    [1699, 2861, 451],
    [3344, 145, 68],
    [3688, 153, 101],
    [5390, 126, 72],
    [5828, 130, 129],
    [10056, 1389, 340],
    [11780, 542, 132],
    [15098, 683, 284],
    [20115, 405, 126],
    [24586, 148, 919],
  ];

  CursorRecording build() {
    final rec = CursorRecording();
    // 60Hz idle track, with a ~95ms press plateau at each press time.
    for (var ms = 0; ms <= 29627; ms += 16) {
      var x = 900.0;
      var y = 500.0;
      var clicked = false;
      for (final p in presses) {
        if (ms >= p[0] - 200 && ms < p[0] + 200) {
          x = p[1];
          y = p[2];
        }
        if (ms >= p[0] && ms < p[0] + 95) clicked = true;
      }
      rec.addPosition(CursorPosition(
        x: x,
        y: y,
        timestampMicros: ms * 1000,
        isClicked: clicked,
      ));
    }
    return rec;
  }

  test('the real recording yields four merged following regions', () {
    final out = const AutoZoomDetector().detect(
      cursor: build(),
      videoSize: videoSize,
      videoDuration: const Duration(milliseconds: 29627),
    );

    expect(out, hasLength(4));

    // Every region follows: all eleven presses classify as plain clicks
    // (no cursor state in this track, and real presses are far shorter
    // than the 200ms drag dwell floor), and clicks follow.
    for (final r in out) {
      expect(r.followCursor, isTrue);
    }

    // Non-overlapping by construction.
    for (var i = 1; i < out.length; i++) {
      expect(
        out[i].startTime >= out[i - 1].startTime + out[i - 1].duration,
        isTrue,
        reason: 'region $i starts before region ${i - 1} ends',
      );
    }

    // The first region spans the five sidebar clicks that previously
    // produced three regions with two seams between them.
    expect(out.first.startTime, Duration.zero);
    expect(out.first.startTime + out.first.duration,
        greaterThan(const Duration(milliseconds: 7000)));
  });
}
```

- [ ] **Step 2: Run the new test**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_real_recording_test.dart`

Expected: PASS, 1 test.

**If the region count is not 4**, do not change the expectation to match. Print the actual regions (start, duration, zoom, follow) and report them — the count is the headline claim of this change, and a mismatch means either the pipeline or the plan's arithmetic is wrong, both of which the controller needs to know about.

- [ ] **Step 3: Verify the whole workspace**

Run from the repo root:

```bash
melos run test --no-select
```

Then:

```bash
melos run analyze --no-select
```

Expected: SUCCESS for both. Engine suite should be 1268 + 6 new tests = **1274** (2 from Task 2, 3 from Task 3, 1 from Task 4); the tests updated in place do not change the count. Report the actual number and account for any difference.

- [ ] **Step 4: Confirm no formatter damage**

Run: `git diff --stat main...HEAD`

The only files this plan touches are the four production/test files named in Tasks 1-3 plus the new file in Task 4, on top of whatever PR #45 already changed. If any file shows a line delta far larger than the edits described here, `dart format` was run against the global constraint — report it, do not fix it.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/test/editor/auto_zoom_real_recording_test.dart
git commit -m "test(engine): pin the real-recording case that prompted merging

Eight regions with two exact seams become four following regions."
```

---

## Out of scope

- **Rhythm.** Nothing here bounds how long a following region can run, so a dense recording can become one long tracking shot. The spec records this as an accepted consequence and a known open aesthetic risk; a ceiling would be a one-line tuning change if it reads as monotonous in practice.
- **The viewport clamp.** A click near a corner still cannot be centred at 1.5×. Following changes what happens after the click, not the framing at it.
