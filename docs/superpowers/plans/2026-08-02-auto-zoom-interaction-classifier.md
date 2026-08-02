# Auto-Zoom Interaction Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `AutoZoomDetector`'s click-only detection with a cursor-state-driven interaction classifier plus cluster merging, so click-dense recordings get sensibly shaped and placed auto-zoom regions instead of none.

**Architecture:** A pure `InteractionClassifier` turns a `CursorRecording` into typed `CursorInteraction` gestures using the natively captured `CursorState` (no trajectory inference). A const `ZoomShape` table maps each interaction kind to region parameters. `AutoZoomDetector` shrinks to: classify → cluster → shape → drop overlaps.

**Tech Stack:** Dart / Flutter, `slipreel_engine` package, `flutter_test`, melos workspace.

**Spec:** `docs/superpowers/specs/2026-08-02-auto-zoom-interaction-classifier-design.md`

## Global Constraints

- All new code lives in `packages/slipreel_engine/`. The engine package must never import `package:screen_recorder/*` — enforced by `test/architecture/engine_layer_boundary_test.dart`. `package:screen_recorder_platform_interface/*` is allowed and already used.
- Do **not** run `dart format` on any file. The pinned formatter is tall-style but committed code is not; it reflows ~50+ unrelated lines and CI does not enforce it. Match surrounding style by hand.
- `AutoZoomDetector.detect(...)` keeps its exact current signature: named params `cursor`, `videoSize`, `videoDuration`, returning `List<ZoomRegion>`. Both call sites in `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (:692 and :1256) construct it as `const AutoZoomDetector()` and must not need edits.
- `AutoZoomDetector` must remain `const`-constructible.
- Every emitted region keeps `tilt: Tilt3D(style: ZoomTiltStyle.subtle)`, as today.
- Threshold constants come from the spec verbatim: displacement `0.02 × diagonal`, dwell floor `200ms`, axis ratio `1.8`, state lookback `50ms`, cluster gap `1200ms`, min cluster zoom `1.25`, max hold `6s`.

**Test commands:**
- Single file: `cd packages/slipreel_engine && flutter test test/editor/<file>.dart`
- Single test: append `--plain-name '<test name>'`
- Package suite: `cd packages/slipreel_engine && flutter test`
- Full workspace: `melos test` from repo root

---

### Task 1: CursorInteraction model and InteractionClassifier

**Files:**
- Create: `packages/slipreel_engine/lib/editor/cursor_interaction.dart`
- Create: `packages/slipreel_engine/lib/editor/interaction_classifier.dart`
- Test: `packages/slipreel_engine/test/editor/interaction_classifier_test.dart`

**Interfaces:**
- Consumes: `CursorRecording` (`lib/models/cursor_recording.dart`), `CursorPosition` and `CursorState` (from `package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart`).
- Produces:
  - `enum InteractionKind { click, textEntry, drag, textSelection }`
  - `class CursorInteraction` with fields `kind`, `start`, `end`, `anchor`, `sweptBounds`, `state`, and getter `Duration get gesture`
  - `class InteractionClassifier` with `const InteractionClassifier()` and `List<CursorInteraction> classify(CursorRecording cursor, Size videoSize)`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/editor/interaction_classifier_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/cursor_interaction.dart';
import 'package:slipreel_engine/editor/interaction_classifier.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  double x = 100,
  double y = 100,
  CursorState state = CursorState.arrow,
}) =>
    CursorPosition(
      x: x,
      y: y,
      timestampMicros: ms * 1000,
      isClicked: clicked,
      state: state,
    );

CursorRecording _rec(List<CursorPosition> positions) {
  final r = CursorRecording();
  for (final p in positions) {
    r.addPosition(p);
  }
  return r;
}

/// A press→release gesture. Emits a pre-press sample (so the state
/// lookback window has something to read), the press, an optional mid
/// sample, and the release.
List<CursorPosition> _gesture({
  required int atMs,
  required double fromX,
  required double fromY,
  double? toX,
  double? toY,
  int durationMs = 50,
  CursorState state = CursorState.arrow,
}) {
  final endX = toX ?? fromX;
  final endY = toY ?? fromY;
  return [
    _p(ms: atMs - 16, clicked: false, x: fromX, y: fromY, state: state),
    _p(ms: atMs, clicked: true, x: fromX, y: fromY, state: state),
    _p(
      ms: atMs + durationMs,
      clicked: true,
      x: endX,
      y: endY,
      state: state,
    ),
    _p(
      ms: atMs + durationMs + 16,
      clicked: false,
      x: endX,
      y: endY,
      state: state,
    ),
  ];
}

void main() {
  const classifier = InteractionClassifier();
  const videoSize = Size(1920, 1080);
  // diagonal = sqrt(1920^2 + 1080^2) ≈ 2202.9
  // drag displacement threshold = 0.02 * 2202.9 ≈ 44.06 px

  test('empty recording yields no interactions', () {
    expect(classifier.classify(CursorRecording(), videoSize), isEmpty);
  });

  test('stationary arrow click is InteractionKind.click', () {
    final out = classifier.classify(
      _rec(_gesture(atMs: 1000, fromX: 500, fromY: 400)),
      videoSize,
    );
    expect(out, hasLength(1));
    expect(out.single.kind, InteractionKind.click);
    expect(out.single.anchor, const Offset(500, 400));
    expect(out.single.start, const Duration(milliseconds: 1000));
  });

  test('stationary iBeam click is InteractionKind.textEntry', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textEntry);
  });

  test('long arrow drag is InteractionKind.drag', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('horizontal iBeam drag is InteractionKind.textSelection', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 400,
        fromY: 400,
        toX: 900,
        toY: 410,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textSelection);
  });

  test('vertical iBeam drag is drag, not textSelection', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 400,
        fromY: 300,
        toX: 410,
        toY: 800,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('displacement below threshold stays a click', () {
    // 40px < 44.06px threshold
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 540,
        toY: 400,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.click);
  });

  test('displacement above threshold becomes a drag', () {
    // 50px > 44.06px threshold
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 550,
        toY: 400,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('dwell below 200ms stays a click even when displaced', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 199,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.click);
  });

  test('dwell at exactly 200ms qualifies as a drag', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 200,
      )),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.drag);
  });

  test('axis ratio below 1.8 is drag, above is textSelection', () {
    // dx = 300, dy = 200 -> ratio 1.5, below threshold
    final shallow = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 300,
        fromY: 300,
        toX: 600,
        toY: 500,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(shallow.single.kind, InteractionKind.drag);

    // dx = 400, dy = 100 -> ratio 4.0, above threshold
    final flat = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 300,
        fromY: 300,
        toX: 700,
        toY: 400,
        durationMs: 400,
        state: CursorState.iBeam,
      )),
      videoSize,
    );
    expect(flat.single.kind, InteractionKind.textSelection);
  });

  test('sweptBounds covers the whole gesture path', () {
    final out = classifier.classify(
      _rec(_gesture(
        atMs: 1000,
        fromX: 500,
        fromY: 400,
        toX: 900,
        toY: 700,
        durationMs: 400,
      )),
      videoSize,
    );
    expect(out.single.sweptBounds, const Rect.fromLTRB(500, 400, 900, 700));
  });

  test('stationary click has a zero-size sweptBounds at the anchor', () {
    final out = classifier.classify(
      _rec(_gesture(atMs: 1000, fromX: 500, fromY: 400)),
      videoSize,
    );
    expect(out.single.sweptBounds, Rect.zero.shift(const Offset(500, 400)));
  });

  test('unterminated press releases at the last sample', () {
    final out = classifier.classify(
      _rec([
        _p(ms: 0, clicked: false, x: 500, y: 400),
        _p(ms: 100, clicked: true, x: 500, y: 400),
        _p(ms: 600, clicked: true, x: 900, y: 700),
      ]),
      videoSize,
    );
    expect(out, hasLength(1));
    expect(out.single.end, const Duration(milliseconds: 600));
    expect(out.single.kind, InteractionKind.drag);
  });

  test('state is read from before the press, not at it', () {
    // Cursor is iBeam while hovering, then the OS swaps to arrow at the
    // instant of the press. We must classify on the pre-press state.
    final out = classifier.classify(
      _rec([
        _p(ms: 970, clicked: false, x: 500, y: 400, state: CursorState.iBeam),
        _p(ms: 985, clicked: false, x: 500, y: 400, state: CursorState.iBeam),
        _p(ms: 1000, clicked: true, x: 500, y: 400, state: CursorState.arrow),
        _p(ms: 1050, clicked: true, x: 500, y: 400, state: CursorState.arrow),
        _p(ms: 1066, clicked: false, x: 500, y: 400, state: CursorState.arrow),
      ]),
      videoSize,
    );
    expect(out.single.kind, InteractionKind.textEntry);
  });

  test('legacy recording with no cursor state degrades to click and drag', () {
    // Recordings predating the state field load every sample as
    // CursorState.arrow, so textEntry and textSelection can never fire.
    // The second gesture here is horizontal enough to be a text
    // selection if the pointer had read iBeam — it must come out as a
    // plain drag instead, not fail.
    final out = classifier.classify(
      _rec([
        ..._gesture(atMs: 1000, fromX: 500, fromY: 400),
        ..._gesture(
          atMs: 3000,
          fromX: 400,
          fromY: 400,
          toX: 900,
          toY: 410,
          durationMs: 400,
        ),
      ]),
      videoSize,
    );
    expect(
      out.map((i) => i.kind).toList(),
      [InteractionKind.click, InteractionKind.drag],
    );
  });

  test('two separate gestures yield two interactions', () {
    final out = classifier.classify(
      _rec([
        ..._gesture(atMs: 1000, fromX: 300, fromY: 300),
        ..._gesture(atMs: 3000, fromX: 800, fromY: 600),
      ]),
      videoSize,
    );
    expect(out, hasLength(2));
    expect(out[0].anchor, const Offset(300, 300));
    expect(out[1].anchor, const Offset(800, 600));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/interaction_classifier_test.dart`

Expected: FAIL at compile time — `Error: Couldn't resolve the package 'slipreel_engine/editor/cursor_interaction.dart'` (target files do not exist yet).

- [ ] **Step 3: Create the model**

Create `packages/slipreel_engine/lib/editor/cursor_interaction.dart`:

```dart
import 'dart:ui';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// What the user was doing during one press→release gesture.
///
/// Kinds are derived from the natively captured [CursorState] plus the
/// gesture's own geometry — never from post-hoc trajectory inference.
/// A click landing while the pointer reads [CursorState.iBeam] *is* a
/// text-field click; no heuristic beats reading it directly.
enum InteractionKind {
  /// Stationary press on something that isn't text.
  click,

  /// Stationary press while the pointer reads I-beam — a text field
  /// gaining focus. The interesting content is the typing that follows.
  textEntry,

  /// Press, travel, release. Slider drags, window moves, canvas panning.
  drag,

  /// A predominantly horizontal drag while the pointer reads I-beam.
  /// The interesting content is the swept line, not the press point.
  textSelection,
}

/// One recognised press→release gesture extracted from a
/// `CursorRecording` by [InteractionClassifier].
class CursorInteraction {
  const CursorInteraction({
    required this.kind,
    required this.start,
    required this.end,
    required this.anchor,
    required this.sweptBounds,
    required this.state,
  });

  final InteractionKind kind;

  /// Press time (isClicked rising edge), in source time.
  final Duration start;

  /// Release time (falling edge). Equal to [start] for a gesture that
  /// begins and ends within one sample; equal to the recording's last
  /// sample time for a press that never releases.
  final Duration end;

  /// Cursor position at the press.
  final Offset anchor;

  /// Bounding box of the cursor path from press to release. Degenerates
  /// to a zero-size rect at [anchor] for a stationary click, so
  /// consumers can treat clicks and drags uniformly instead of branching.
  final Rect sweptBounds;

  /// Dominant pointer state in the window just before the press.
  final CursorState state;

  /// How long the gesture itself lasted. Zero for an instantaneous click.
  Duration get gesture => end - start;
}
```

- [ ] **Step 4: Create the classifier**

Create `packages/slipreel_engine/lib/editor/interaction_classifier.dart`:

```dart
import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../models/cursor_recording.dart';
import 'cursor_interaction.dart';

/// Pure `CursorRecording` → `List<CursorInteraction>` classifier.
///
/// Knows nothing about zoom, regions, or the editor. [videoSize] is a
/// scale reference only, so displacement thresholds are
/// resolution-independent.
class InteractionClassifier {
  const InteractionClassifier({
    this.dragDisplacementRatio = 0.02,
    this.dragMinDwell = const Duration(milliseconds: 200),
    this.horizontalAxisRatio = 1.8,
    this.stateLookback = const Duration(milliseconds: 50),
  });

  /// Press→release displacement, as a fraction of the video diagonal,
  /// above which a gesture counts as travel rather than a click.
  /// Measured against the diagonal rather than the width so the
  /// threshold behaves the same on wide and tall displays.
  final double dragDisplacementRatio;

  /// Minimum press duration for a displaced gesture to count as a drag.
  /// Below this, fast displaced presses are click-with-jitter.
  final Duration dragMinDwell;

  /// How much more horizontal than vertical a drag must be to read as a
  /// text selection rather than a generic drag.
  final double horizontalAxisRatio;

  /// Backward window before the press over which the pointer state is
  /// sampled. Reading state at exactly the press sample is vulnerable to
  /// the OS swapping the cursor *in response* to the click; sampling
  /// just before captures what the pointer was over when the user
  /// decided to click, which is the signal we want.
  final Duration stateLookback;

  List<CursorInteraction> classify(CursorRecording cursor, Size videoSize) {
    final samples = cursor.positions;
    if (samples.length < 2) return const [];

    final diagonal = math.sqrt(
      videoSize.width * videoSize.width + videoSize.height * videoSize.height,
    );

    final out = <CursorInteraction>[];
    var pressIndex = -1;
    var prevClicked = samples.first.isClicked;

    for (var i = 1; i < samples.length; i++) {
      final clicked = samples[i].isClicked;
      if (clicked && !prevClicked) {
        pressIndex = i;
      } else if (!clicked && prevClicked && pressIndex >= 0) {
        out.add(_build(samples, pressIndex, i - 1, diagonal));
        pressIndex = -1;
      }
      prevClicked = clicked;
    }

    // A press still held at end-of-recording releases at the last sample.
    if (pressIndex >= 0) {
      out.add(_build(samples, pressIndex, samples.length - 1, diagonal));
    }

    return out;
  }

  CursorInteraction _build(
    List<CursorPosition> samples,
    int pressIndex,
    int releaseIndex,
    double diagonal,
  ) {
    final press = samples[pressIndex];
    final release = samples[releaseIndex];

    var minX = press.x;
    var maxX = press.x;
    var minY = press.y;
    var maxY = press.y;
    for (var i = pressIndex; i <= releaseIndex; i++) {
      final s = samples[i];
      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
      if (s.y < minY) minY = s.y;
      if (s.y > maxY) maxY = s.y;
    }

    final state = _stateBefore(samples, pressIndex);
    final start = Duration(microseconds: press.timestampMicros);
    final end = Duration(microseconds: release.timestampMicros);

    final dx = (release.x - press.x).abs();
    final dy = (release.y - press.y).abs();
    final displacement = math.sqrt(dx * dx + dy * dy);

    final InteractionKind kind;
    if (displacement > dragDisplacementRatio * diagonal &&
        (end - start) >= dragMinDwell) {
      kind = (state == CursorState.iBeam && dx > horizontalAxisRatio * dy)
          ? InteractionKind.textSelection
          : InteractionKind.drag;
    } else {
      kind = state == CursorState.iBeam
          ? InteractionKind.textEntry
          : InteractionKind.click;
    }

    return CursorInteraction(
      kind: kind,
      start: start,
      end: end,
      anchor: Offset(press.x, press.y),
      sweptBounds: Rect.fromLTRB(minX, minY, maxX, maxY),
      state: state,
    );
  }

  /// Modal pointer state over `[press - stateLookback, press]`. Walking
  /// backwards means that on a count tie the state nearest the press
  /// wins, because Dart maps iterate in insertion order and we insert
  /// nearest-first.
  CursorState _stateBefore(List<CursorPosition> samples, int pressIndex) {
    final windowStart =
        samples[pressIndex].timestampMicros - stateLookback.inMicroseconds;
    final counts = <CursorState, int>{};
    for (var i = pressIndex; i >= 0; i--) {
      final s = samples[i];
      if (s.timestampMicros < windowStart) break;
      counts[s.state] = (counts[s.state] ?? 0) + 1;
    }
    if (counts.isEmpty) return samples[pressIndex].state;

    var best = counts.keys.first;
    var bestCount = counts[best]!;
    counts.forEach((state, count) {
      if (count > bestCount) {
        best = state;
        bestCount = count;
      }
    });
    return best;
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/editor/interaction_classifier_test.dart`

Expected: PASS, 17 tests.

- [ ] **Step 6: Verify the engine layer boundary still holds**

Run: `cd packages/slipreel_engine && flutter test test/architecture/engine_layer_boundary_test.dart`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/editor/cursor_interaction.dart packages/slipreel_engine/lib/editor/interaction_classifier.dart packages/slipreel_engine/test/editor/interaction_classifier_test.dart
git commit -m "feat(engine): cursor interaction classifier

Turns a CursorRecording into typed press-release gestures using the
natively captured CursorState plus gesture geometry. No consumer yet."
```

---

### Task 2: ZoomShape table

**Files:**
- Create: `packages/slipreel_engine/lib/editor/zoom_shape.dart`
- Test: `packages/slipreel_engine/test/editor/zoom_shape_test.dart`

**Interfaces:**
- Consumes: `InteractionKind` from Task 1.
- Produces:
  - `class ZoomShape` with fields `zoomLevel`, `leadIn`, `hold`, `leadOut`, `followCursor`, `holdTracksGesture`, `fitToSweptBounds`; method `Duration effectiveHold(Duration gesture)`; static `ZoomShape.maxHold`
  - `const Map<InteractionKind, ZoomShape> kZoomShapes`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/editor/zoom_shape_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/cursor_interaction.dart';
import 'package:slipreel_engine/editor/zoom_shape.dart';

void main() {
  test('every interaction kind has a shape', () {
    for (final kind in InteractionKind.values) {
      expect(kZoomShapes[kind], isNotNull, reason: 'missing shape for $kind');
    }
  });

  test('click shape matches the historic auto-zoom defaults', () {
    final shape = kZoomShapes[InteractionKind.click]!;
    expect(shape.zoomLevel, 1.5);
    expect(shape.leadIn, const Duration(milliseconds: 500));
    expect(shape.hold, const Duration(milliseconds: 1800));
    expect(shape.leadOut, const Duration(milliseconds: 500));
    expect(shape.followCursor, isFalse);
    expect(shape.holdTracksGesture, isFalse);
    expect(shape.fitToSweptBounds, isFalse);
  });

  test('textEntry zooms tighter and holds longer than a click', () {
    final click = kZoomShapes[InteractionKind.click]!;
    final text = kZoomShapes[InteractionKind.textEntry]!;
    expect(text.zoomLevel, greaterThan(click.zoomLevel));
    expect(text.hold, greaterThan(click.hold));
    expect(text.followCursor, isFalse);
  });

  test('drag zooms looser than a click and follows', () {
    final click = kZoomShapes[InteractionKind.click]!;
    final drag = kZoomShapes[InteractionKind.drag]!;
    expect(drag.zoomLevel, lessThan(click.zoomLevel));
    expect(drag.followCursor, isTrue);
    expect(drag.holdTracksGesture, isTrue);
  });

  test('textSelection follows and fits to the swept bounds', () {
    final sel = kZoomShapes[InteractionKind.textSelection]!;
    expect(sel.followCursor, isTrue);
    expect(sel.fitToSweptBounds, isTrue);
    expect(sel.holdTracksGesture, isTrue);
  });

  test('absolute hold ignores gesture length', () {
    final shape = kZoomShapes[InteractionKind.click]!;
    expect(
      shape.effectiveHold(const Duration(seconds: 4)),
      const Duration(milliseconds: 1800),
    );
  });

  test('gesture-tracking hold adds the gesture duration', () {
    final shape = kZoomShapes[InteractionKind.drag]!;
    expect(
      shape.effectiveHold(const Duration(milliseconds: 1200)),
      const Duration(milliseconds: 2000),
    );
  });

  test('gesture-tracking hold is capped at maxHold', () {
    final shape = kZoomShapes[InteractionKind.drag]!;
    expect(
      shape.effectiveHold(const Duration(seconds: 30)),
      ZoomShape.maxHold,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/zoom_shape_test.dart`

Expected: FAIL at compile time — `Error: Couldn't resolve the package 'slipreel_engine/editor/zoom_shape.dart'`.

- [ ] **Step 3: Write the implementation**

Create `packages/slipreel_engine/lib/editor/zoom_shape.dart`:

```dart
import 'cursor_interaction.dart';

/// Region parameters for one [InteractionKind] — the surface that gets
/// tuned. Kept out of `AutoZoomDetector` so changing the feel of
/// auto-zoom doesn't mean reading the detector's control flow.
class ZoomShape {
  const ZoomShape({
    required this.zoomLevel,
    required this.leadIn,
    required this.hold,
    required this.leadOut,
    required this.followCursor,
    required this.holdTracksGesture,
    required this.fitToSweptBounds,
  });

  /// Preferred magnification. For [fitToSweptBounds] shapes this is an
  /// upper bound — the detector caps it so the swept content fits.
  final double zoomLevel;

  final Duration leadIn;

  /// Held duration between the enter and exit ramps. When
  /// [holdTracksGesture] is true this is a *tail* added to the gesture's
  /// own length rather than the total.
  final Duration hold;

  final Duration leadOut;

  /// Whether the region's camera follows the cursor. Follow regions use
  /// the `ZoomRegion` defaults (`FollowMode.bounded`, deadzone 0.8) —
  /// they ride the stack that is already tuned rather than adding a new
  /// tuning surface.
  final bool followCursor;

  /// True for gesture kinds whose interesting duration is set by the
  /// gesture itself rather than a constant.
  final bool holdTracksGesture;

  /// True when the region should frame the gesture's swept bounds
  /// instead of centring on its press point.
  final bool fitToSweptBounds;

  /// Ceiling on a gesture-tracking hold, so a 30-second canvas pan
  /// doesn't zoom the entire video.
  static const Duration maxHold = Duration(seconds: 6);

  Duration effectiveHold(Duration gesture) {
    if (!holdTracksGesture) return hold;
    final total = gesture + hold;
    return total > maxHold ? maxHold : total;
  }
}

/// Per-kind shapes. `click` mirrors the historic auto-zoom defaults, so a
/// solitary unclassified click produces a byte-identical region to the
/// pre-classifier detector.
const Map<InteractionKind, ZoomShape> kZoomShapes = {
  InteractionKind.click: ZoomShape(
    zoomLevel: 1.5,
    leadIn: Duration(milliseconds: 500),
    hold: Duration(milliseconds: 1800),
    leadOut: Duration(milliseconds: 500),
    followCursor: false,
    holdTracksGesture: false,
    fitToSweptBounds: false,
  ),
  // Tighter and longer than a click: text is what the viewer is being
  // asked to read, and the interesting content — the typing — happens
  // after the click, not at it.
  InteractionKind.textEntry: ZoomShape(
    zoomLevel: 1.8,
    leadIn: Duration(milliseconds: 500),
    hold: Duration(milliseconds: 2600),
    leadOut: Duration(milliseconds: 600),
    followCursor: false,
    holdTracksGesture: false,
    fitToSweptBounds: false,
  ),
  // Looser than a click because the gesture covers ground, and timed off
  // the gesture rather than a constant.
  InteractionKind.drag: ZoomShape(
    zoomLevel: 1.4,
    leadIn: Duration(milliseconds: 450),
    hold: Duration(milliseconds: 800),
    leadOut: Duration(milliseconds: 500),
    followCursor: true,
    holdTracksGesture: true,
    fitToSweptBounds: false,
  ),
  InteractionKind.textSelection: ZoomShape(
    zoomLevel: 1.7,
    leadIn: Duration(milliseconds: 450),
    hold: Duration(milliseconds: 700),
    leadOut: Duration(milliseconds: 500),
    followCursor: true,
    holdTracksGesture: true,
    fitToSweptBounds: true,
  ),
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/editor/zoom_shape_test.dart`

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/editor/zoom_shape.dart packages/slipreel_engine/test/editor/zoom_shape_test.dart
git commit -m "feat(engine): per-interaction-kind zoom shape table"
```

---

### Task 3: Rewire AutoZoomDetector onto interactions

Replaces the click walk and the isolation filter with classifier output. No clustering yet — one region per interaction, `_dropOverlaps` unchanged.

**Files:**
- Modify: `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart` (full rewrite of the class body)
- Modify: `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart:113-125` (the isolation test inverts)
- Test: `packages/slipreel_engine/test/editor/auto_zoom_detector_shape_test.dart` (new)

**Interfaces:**
- Consumes: `InteractionClassifier`, `CursorInteraction`, `InteractionKind` (Task 1); `ZoomShape`, `kZoomShapes` (Task 2).
- Produces: `AutoZoomDetector` with unchanged `detect({cursor, videoSize, videoDuration})`; new constructor params `clusterGap` (default 1200ms), `minClusterZoom` (default 1.25), `classifier` (default `const InteractionClassifier()`); `isolationWindow` **removed**.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/editor/auto_zoom_detector_shape_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  required double x,
  required double y,
  CursorState state = CursorState.arrow,
}) =>
    CursorPosition(
      x: x,
      y: y,
      timestampMicros: ms * 1000,
      isClicked: clicked,
      state: state,
    );

CursorRecording _rec(List<CursorPosition> positions) {
  final r = CursorRecording();
  for (final p in positions) {
    r.addPosition(p);
  }
  return r;
}

List<CursorPosition> _gesture({
  required int atMs,
  required double fromX,
  required double fromY,
  double? toX,
  double? toY,
  int durationMs = 50,
  CursorState state = CursorState.arrow,
}) {
  final endX = toX ?? fromX;
  final endY = toY ?? fromY;
  return [
    _p(ms: atMs - 16, clicked: false, x: fromX, y: fromY, state: state),
    _p(ms: atMs, clicked: true, x: fromX, y: fromY, state: state),
    _p(ms: atMs + durationMs, clicked: true, x: endX, y: endY, state: state),
    _p(
      ms: atMs + durationMs + 16,
      clicked: false,
      x: endX,
      y: endY,
      state: state,
    ),
  ];
}

void main() {
  const detector = AutoZoomDetector();
  const videoSize = Size(1920, 1080);
  const videoDuration = Duration(seconds: 60);

  test('arrow click keeps the historic 1.5x / 2.8s anchored shape', () {
    final out = detector.detect(
      cursor: _rec(_gesture(atMs: 5000, fromX: 900, fromY: 500)),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    expect(r.zoomLevel, 1.5);
    expect(r.duration, const Duration(milliseconds: 2800));
    expect(r.startTime, const Duration(milliseconds: 4500));
    expect(r.followCursor, isFalse);
    expect(r.rect.center, const Offset(900, 500));
  });

  test('iBeam click produces a tighter, longer, anchored region', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 900,
        fromY: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    final r = out.single;
    expect(r.zoomLevel, 1.8);
    expect(r.duration, const Duration(milliseconds: 3700));
    expect(r.followCursor, isFalse);
  });

  test('drag produces a follow region timed off the gesture', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 500,
        fromY: 400,
        toX: 1200,
        toY: 800,
        durationMs: 1000,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    final r = out.single;
    expect(r.zoomLevel, 1.4);
    expect(r.followCursor, isTrue);
    // leadIn 450 + (gesture 1000 + tail 800) + leadOut 500
    expect(r.duration, const Duration(milliseconds: 2750));
    // Follow regions ride the already-tuned defaults rather than
    // introducing a second tuning surface.
    expect(r.followMode, FollowMode.bounded);
    expect(r.deadzoneRatio, 0.8);
  });

  test('text selection frames the swept range, not the press point', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 400,
        fromY: 500,
        toX: 1000,
        toY: 510,
        durationMs: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    final r = out.single;
    expect(r.followCursor, isTrue);
    // Swept centre is x=700, not the press point x=400.
    expect(r.rect.center.dx, closeTo(700, 0.001));
  });

  test('wide text selection caps zoom so the sweep fits', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 100,
        fromY: 500,
        toX: 1820,
        toY: 510,
        durationMs: 500,
        state: CursorState.iBeam,
      )),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    // Sweep is 1720px wide; 1920/1720 ≈ 1.116, below the 1.7 preference.
    expect(out.single.zoomLevel, closeTo(1920 / 1720, 0.01));
  });

  test('very long drag caps hold at 6s', () {
    final out = detector.detect(
      cursor: _rec(_gesture(
        atMs: 5000,
        fromX: 500,
        fromY: 400,
        toX: 1200,
        toY: 800,
        durationMs: 30000,
      )),
      videoSize: videoSize,
      videoDuration: const Duration(seconds: 120),
    );
    // leadIn 450 + capped hold 6000 + leadOut 500
    expect(out.single.duration, const Duration(milliseconds: 6950));
  });

  test('auto-detected regions keep the subtle 3D tilt', () {
    final out = detector.detect(
      cursor: _rec(_gesture(atMs: 5000, fromX: 900, fromY: 500)),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out.single.tilt.style, ZoomTiltStyle.subtle);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_shape_test.dart`

Expected: FAIL — the detector still emits the historic fixed shape, so the iBeam, drag, and text-selection expectations fail on `zoomLevel` / `followCursor` / `duration`.

- [ ] **Step 3: Rewrite the detector**

Replace the entire contents of `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart`:

```dart
import 'dart:math' as math;
import 'dart:ui';

import '../models/cursor_recording.dart';
import '../models/tilt3d.dart';
import '../models/zoom_region.dart';
import 'cursor_interaction.dart';
import 'interaction_classifier.dart';
import 'zoom_shape.dart';

/// Turns a `CursorRecording` into the editor's pre-populated zoom lane.
///
/// Pipeline: classify gestures ([InteractionClassifier]) → merge nearby
/// gestures into clusters → shape each group into a `ZoomRegion` via
/// [kZoomShapes] → drop overlaps.
///
/// Replaces the pre-2026-08 click-only detector, whose isolation filter
/// dropped every click within 1.5 s of a neighbour and so emitted
/// *nothing* on click-dense recordings. See
/// `docs/superpowers/specs/2026-08-02-auto-zoom-interaction-classifier-design.md`.
class AutoZoomDetector {
  const AutoZoomDetector({
    this.zoomLevel = 1.5,
    this.leadIn = const Duration(milliseconds: 500),
    this.hold = const Duration(milliseconds: 1800),
    this.leadOut = const Duration(milliseconds: 500),
    this.clusterGap = const Duration(milliseconds: 1200),
    this.minClusterZoom = 1.25,
    this.classifier = const InteractionClassifier(),
  });

  /// Overrides for the `click` shape, preserved from the historic
  /// constructor so a solitary unclassified click is byte-identical to
  /// the pre-classifier detector's output.
  final double zoomLevel;
  final Duration leadIn;
  final Duration hold;
  final Duration leadOut;

  /// Maximum idle time between two gestures for them to join one
  /// cluster.
  final Duration clusterGap;

  /// A cluster may only absorb another gesture while the union of their
  /// swept bounds still fits at this magnification. Below it, the merged
  /// region would be so wide it isn't a zoom, so the cluster closes.
  final double minClusterZoom;

  final InteractionClassifier classifier;

  List<ZoomRegion> detect({
    required CursorRecording cursor,
    required Size videoSize,
    required Duration videoDuration,
  }) {
    final interactions = classifier
        .classify(cursor, videoSize)
        .where((i) => _inBounds(i.anchor, videoSize))
        .toList();

    final regions = <ZoomRegion>[];
    for (final group in _cluster(interactions, videoSize)) {
      final region = _buildRegion(group, videoSize, videoDuration);
      if (region != null) regions.add(region);
    }
    return _dropOverlaps(regions);
  }

  /// Skip gestures that happened off the captured display. On
  /// multi-monitor setups the cursor lives in global screen space, so a
  /// click on another monitor records as out-of-video-bounds (often
  /// negative). Zooming to a point clamped back in-bounds would land on
  /// a spot where nothing actually happened.
  bool _inBounds(Offset p, Size videoSize) =>
      p.dx >= 0 &&
      p.dy >= 0 &&
      p.dx <= videoSize.width &&
      p.dy <= videoSize.height;

  ZoomShape _shapeFor(InteractionKind kind) {
    if (kind == InteractionKind.click) {
      return ZoomShape(
        zoomLevel: zoomLevel,
        leadIn: leadIn,
        hold: hold,
        leadOut: leadOut,
        followCursor: false,
        holdTracksGesture: false,
        fitToSweptBounds: false,
      );
    }
    return kZoomShapes[kind]!;
  }

  List<List<CursorInteraction>> _cluster(
    List<CursorInteraction> items,
    Size videoSize,
  ) {
    if (items.isEmpty) return const [];
    final sorted = [...items]..sort((a, b) => a.start.compareTo(b.start));

    final groups = <List<CursorInteraction>>[];
    var current = <CursorInteraction>[sorted.first];
    var union = sorted.first.sweptBounds;
    var lastEnd = sorted.first.end;

    for (var i = 1; i < sorted.length; i++) {
      final next = sorted[i];
      final merged = union.expandToInclude(next.sweptBounds);
      final joins = (next.start - lastEnd) < clusterGap &&
          _fitZoom(merged, videoSize) >= minClusterZoom;

      if (joins) {
        current.add(next);
        union = merged;
        if (next.end > lastEnd) lastEnd = next.end;
      } else {
        groups.add(current);
        current = <CursorInteraction>[next];
        union = next.sweptBounds;
        lastEnd = next.end;
      }
    }
    groups.add(current);
    return groups;
  }

  /// Largest magnification at which [bounds] still fits the frame.
  /// A degenerate (zero-size) rect imposes no limit.
  double _fitZoom(Rect bounds, Size videoSize) {
    final fx = bounds.width > 0
        ? videoSize.width / bounds.width
        : double.infinity;
    final fy = bounds.height > 0
        ? videoSize.height / bounds.height
        : double.infinity;
    return math.min(fx, fy);
  }

  ZoomRegion? _buildRegion(
    List<CursorInteraction> group,
    Size videoSize,
    Duration videoDuration,
  ) {
    final double regionZoom;
    final Offset center;
    final Duration enter;
    final Duration exit;
    final Duration span;
    final bool follow;

    if (group.length == 1) {
      final it = group.single;
      final shape = _shapeFor(it.kind);
      enter = shape.leadIn;
      exit = shape.leadOut;
      span = shape.effectiveHold(it.gesture);
      follow = shape.followCursor;
      if (shape.fitToSweptBounds) {
        regionZoom =
            math.min(shape.zoomLevel, _fitZoom(it.sweptBounds, videoSize));
        center = it.sweptBounds.center;
      } else {
        regionZoom = shape.zoomLevel;
        center = it.anchor;
      }
    } else {
      // Merged cluster: anchored, framed over every member. Zoom takes
      // the LOWEST member preference rather than a "dominant kind" —
      // no tie-breaking rule needed, and it errs wide, which is the safe
      // direction when one region has to cover them all.
      var union = group.first.sweptBounds;
      var widest = _shapeFor(group.first.kind).zoomLevel;
      var lastEnd = group.first.end;
      for (final it in group.skip(1)) {
        union = union.expandToInclude(it.sweptBounds);
        final z = _shapeFor(it.kind).zoomLevel;
        if (z < widest) widest = z;
        if (it.end > lastEnd) lastEnd = it.end;
      }
      regionZoom = math.min(widest, _fitZoom(union, videoSize));
      center = union.center;
      enter = leadIn;
      exit = leadOut;
      span = lastEnd - group.first.start;
      follow = false;
    }

    final rawStart = group.first.start - enter;
    final start = rawStart.isNegative ? Duration.zero : rawStart;
    final total = enter + span + exit;
    final duration =
        (start + total) > videoDuration ? videoDuration - start : total;
    if (duration <= Duration.zero) return null;

    return ZoomRegion(
      rect: _rectFor(center, regionZoom, videoSize),
      startTime: start,
      duration: duration,
      zoomLevel: regionZoom,
      enterDuration: enter,
      exitDuration: exit,
      videoBounds: videoSize,
      followCursor: follow,
      tilt: const Tilt3D(style: ZoomTiltStyle.subtle),
    );
  }

  Rect _rectFor(Offset center, double zoom, Size videoSize) {
    final safeZoom = zoom < 1.0 ? 1.0 : zoom;
    final w = videoSize.width / safeZoom;
    final h = videoSize.height / safeZoom;
    final cx = center.dx.clamp(w / 2, videoSize.width - w / 2);
    final cy = center.dy.clamp(h / 2, videoSize.height - h / 2);
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
  }

  List<ZoomRegion> _dropOverlaps(List<ZoomRegion> regions) {
    if (regions.isEmpty) return const [];
    final sorted = [...regions]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final out = <ZoomRegion>[];
    for (final r in sorted) {
      if (out.isEmpty ||
          r.startTime >= out.last.startTime + out.last.duration) {
        out.add(r);
      }
    }
    return out;
  }
}
```

- [ ] **Step 4: Run the new shape tests**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_shape_test.dart`

Expected: PASS, 7 tests.

- [ ] **Step 5: Run the existing detector suites to see what moved**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_test.dart test/editor/auto_zoom_detector_offscreen_test.dart test/editor/auto_zoom_detector_tilt_test.dart`

Expected: exactly one failure — `two clicks 0.5 s apart → no regions (both fail isolation)`, which now returns 1 region (both clicks become interactions; the second region overlaps the first and is dropped). Every other test passes. If anything else fails, stop and diagnose before continuing.

- [ ] **Step 6: Update the one inverted test**

In `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`, replace the test at line 113:

```dart
  test('two clicks 0.5 s apart → one region (isolation filter is gone)', () {
    // Pre-2026-08 this returned zero regions: the isolation filter
    // dropped both clicks for having a close neighbour, which is why
    // click-dense recordings opened with an empty zoom lane. Both clicks
    // now become interactions; Task 4 merges them into one cluster.
    // See docs/superpowers/specs/2026-08-02-auto-zoom-interaction-classifier-design.md
    //
    // Coordinates sit in the non-clamped zone for 1.5× on 1920×1080
    // (cx ∈ [640, 1280], cy ∈ [360, 720]), matching the convention the
    // rest of this file already documents.
    final cursor = _rec([
      ..._clickAt(atMs: 1000, x: 700, y: 450),
      ..._clickAt(atMs: 1500, x: 740, y: 470),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
  });
```

- [ ] **Step 7: Verify the whole package suite is green**

Run: `cd packages/slipreel_engine && flutter test`

Expected: PASS, no failures.

- [ ] **Step 8: Verify the app shell still compiles against the changed constructor**

`isolationWindow` was removed; both call sites use `const AutoZoomDetector()` so
neither should need edits, but confirm nothing else referenced it.

Run: `grep -rn "isolationWindow" packages/ --include="*.dart"`

Expected: no output.

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos 2>&1 | tail -5`

Expected: no errors referencing `auto_zoom_detector` or `AutoZoomDetector`.

- [ ] **Step 9: Commit**

```bash
git add packages/slipreel_engine/lib/editor/auto_zoom_detector.dart packages/slipreel_engine/test/editor/auto_zoom_detector_shape_test.dart packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart
git commit -m "feat(engine): shape auto-zoom regions per interaction kind

Detector now consumes classified interactions instead of raw click
edges. Text entry zooms tighter and holds longer, drags and text
selections follow the cursor, selections frame their swept range.

Removes the isolation filter, which dropped every click with a
neighbour inside 1.5s and so emitted nothing on click-dense
recordings. One existing test inverts accordingly."
```

---

### Task 4: Cluster merging

Task 3 left clustering wired but untested — `_cluster` already runs, so this task is
about proving its behaviour and tightening the inverted test.

**Files:**
- Test: `packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart` (new)
- Modify: `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart` (strengthen the inverted test)

**Interfaces:**
- Consumes: `AutoZoomDetector` as delivered by Task 3. No production signature changes.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  required double x,
  required double y,
  CursorState state = CursorState.arrow,
}) =>
    CursorPosition(
      x: x,
      y: y,
      timestampMicros: ms * 1000,
      isClicked: clicked,
      state: state,
    );

CursorRecording _rec(List<CursorPosition> positions) {
  final r = CursorRecording();
  for (final p in positions) {
    r.addPosition(p);
  }
  return r;
}

List<CursorPosition> _clickAt({
  required int atMs,
  required double x,
  required double y,
  CursorState state = CursorState.arrow,
}) =>
    [
      _p(ms: atMs - 16, clicked: false, x: x, y: y, state: state),
      _p(ms: atMs, clicked: true, x: x, y: y, state: state),
      _p(ms: atMs + 50, clicked: true, x: x, y: y, state: state),
      _p(ms: atMs + 66, clicked: false, x: x, y: y, state: state),
    ];

void main() {
  const detector = AutoZoomDetector();
  const videoSize = Size(1920, 1080);
  const videoDuration = Duration(seconds: 60);

  test('form fill: five nearby clicks merge into one sustained region', () {
    final rec = _rec([
      for (var i = 0; i < 5; i++)
        ..._clickAt(
          atMs: 2000 + i * 800,
          x: 800 + i * 10,
          y: 400 + i * 40,
          state: CursorState.iBeam,
        ),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );

    expect(out, hasLength(1), reason: 'the cluster should be one region');
    final r = out.single;
    // First press 2000ms, minus the 500ms click lead-in.
    expect(r.startTime, const Duration(milliseconds: 1500));
    // Last release is 5200+50 = 5250ms; +500ms lead-out => ends 5750ms.
    expect(r.startTime + r.duration, const Duration(milliseconds: 5750));
    expect(r.followCursor, isFalse, reason: 'clusters stay anchored');
  });

  test('cluster frames every member, not just the first', () {
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 700, y: 400),
      ..._clickAt(atMs: 2800, x: 900, y: 600),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    // Union of the two zero-size swept boxes centres at (800, 500).
    expect(out.single.rect.center, const Offset(800, 500));
  });

  test('spatially scattered clicks at the same cadence do not merge', () {
    // Same 800ms cadence as the form fill, but far apart: merging them
    // would breach the 1.25x floor, so each stands alone.
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 60, y: 60),
      ..._clickAt(atMs: 2800, x: 1860, y: 1020),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    // Two separate clusters; the second region starts inside the first
    // region's span (region 1 = [1500, 4300], region 2 starts 2300), so
    // _dropOverlaps discards it. Assert on startTime rather than the
    // centre: the first click sits outside the non-clamped zone, so its
    // rect centre is pulled to the clamp and says nothing useful.
    expect(out, hasLength(1));
    expect(out.single.startTime, const Duration(milliseconds: 1500));
  });

  test('clicks further apart than the cluster gap do not merge', () {
    final rec = _rec([
      ..._clickAt(atMs: 2000, x: 800, y: 400),
      ..._clickAt(atMs: 9000, x: 820, y: 420),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
  });

  test('a cluster splits when the next click would breach the zoom floor', () {
    // Three clicks 400ms apart — all within the 1200ms cluster gap, so
    // only the zoom floor can separate them. Clicks 1-2 are close
    // together; adding click 3 would make the union 1600x750, which fits
    // at only min(1920/1600, 1080/750) = 1.2x — below the 1.25x floor —
    // so the cluster closes before it.
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
    // The third click starts a second cluster at 2300, inside the first
    // region's span, so _dropOverlaps discards it.
    expect(out, hasLength(1));
    // The surviving region spans clicks 1-2 only: first press 2000, last
    // release 2450 => span 450, total 500 + 450 + 500 = 1450, so it runs
    // [1500, 2950]. Had all three merged, it would end at 3350 instead.
    expect(out.single.startTime, const Duration(milliseconds: 1500));
    expect(out.single.startTime + out.single.duration,
        const Duration(milliseconds: 2950));
  });

  test('a single interaction still keeps its own follow policy', () {
    // Regression guard: clustering must not flatten a lone drag into an
    // anchored region.
    final rec = _rec([
      _p(ms: 2000 - 16, clicked: false, x: 500, y: 400),
      _p(ms: 2000, clicked: true, x: 500, y: 400),
      _p(ms: 2600, clicked: true, x: 1200, y: 800),
      _p(ms: 2616, clicked: false, x: 1200, y: 800),
    ]);
    final out = detector.detect(
      cursor: rec,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out.single.followCursor, isTrue);
  });
}
```

- [ ] **Step 2: Run the test**

Run: `cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_cluster_test.dart`

Expected: PASS, 6 tests — `_cluster` was already implemented in Task 3, so this task
proves it rather than driving new code. **If any test fails, that is a real defect in
Task 3's clustering**; fix `_cluster` / `_buildRegion` in
`packages/slipreel_engine/lib/editor/auto_zoom_detector.dart` rather than weakening
the test.

- [ ] **Step 3: Strengthen the inverted test from Task 3**

In `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`, the test now
reading `two clicks 0.5 s apart → one region (isolation filter is gone)` asserts only
the count. Add the merge assertion so it proves clustering rather than overlap-dropping:

```dart
  test('two clicks 0.5 s apart → one merged region spanning both', () {
    // Pre-2026-08 this returned zero regions: the isolation filter
    // dropped both clicks for having a close neighbour, which is why
    // click-dense recordings opened with an empty zoom lane. They now
    // merge into a single sustained region.
    // See docs/superpowers/specs/2026-08-02-auto-zoom-interaction-classifier-design.md
    //
    // Coordinates sit in the non-clamped zone for 1.5× on 1920×1080
    // (cx ∈ [640, 1280], cy ∈ [360, 720]) so the centre assertion below
    // measures the union, not the clamp.
    final cursor = _rec([
      ..._clickAt(atMs: 1000, x: 700, y: 450),
      ..._clickAt(atMs: 1500, x: 740, y: 470),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.single;
    // Starts 500ms before the first press and outlives the second click,
    // i.e. it spans the pair rather than being one region plus a drop.
    // First press 1000, last release 1550 => span 550;
    // total 500 + 550 + 500 = 1550, so it ends at 2050.
    expect(r.startTime, const Duration(milliseconds: 500));
    expect(r.startTime + r.duration, const Duration(milliseconds: 2050));
    // Framed on the union of both clicks (720, 460), not on the first.
    expect(r.rect.center.dx, closeTo(720, 1.0));
    expect(r.rect.center.dy, closeTo(460, 1.0));
  });
```

- [ ] **Step 4: Run the full package suite**

Run: `cd packages/slipreel_engine && flutter test`

Expected: PASS, no failures.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/test/editor/auto_zoom_detector_cluster_test.dart packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart
git commit -m "test(engine): cover auto-zoom cluster merging

Form-fill clicks merge into one sustained anchored region; scattered
clicks and gap-exceeding clicks stay separate; a lone drag keeps its
follow policy."
```

---

### Task 5: Workspace verification

**Files:** none modified — this task is the gate before review.

- [ ] **Step 1: Run the full workspace suite**

Run: `melos test` from the repo root.

Expected: PASS across all packages. The engine suite should be at its prior count plus
the 38 tests added here (17 classifier + 8 shape + 7 detector shape + 6 cluster).

- [ ] **Step 2: Analyze the workspace**

Run: `melos analyze` from the repo root.

Expected: no errors. Infos are non-fatal per the melos config.

- [ ] **Step 3: Confirm no stray formatter damage**

Run: `git diff --stat main...HEAD`

Expected: only the files this plan names. If any unrelated file shows a large line
delta, `dart format` was run against the global constraint — revert that file.

- [ ] **Step 4: Commit any fixes**

Only if steps 1-3 surfaced problems. Otherwise skip.

---

## Deferred (not in this plan)

**Chained-zoom panning.** Recordly pans the camera directly from one region's focal to
the next over 1000ms when the two are within 1500ms, instead of zooming out and back
in. We have no equivalent — `_dropOverlaps` simply discards the second region, which is
why several tests above assert `hasLength(1)` where two regions were generated. It is a
camera-path feature rather than a detection one and warrants its own sub-project. Per
the spec's Deferred section.
