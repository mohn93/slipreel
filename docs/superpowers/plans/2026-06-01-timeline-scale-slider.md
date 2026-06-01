# Timeline Scale Slider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an animated horizontal-zoom slider (1×–8×) to the editor's `CanvasToolbar`. The slider, plus `Cmd +`/`Cmd −` shortcuts and trackpad pinch on the timeline lanes, scales the entire timeline (ruler + clip lane + zoom lane + playhead) with anchor preservation. Scale is persisted per-project in `.editor.json`.

**Architecture:** `timelineScale: double` becomes a field on `EditorProjectState` (clamped `[1.0, 8.0]`, default `1.0`). A transient `pendingScaleAnchor: Duration?` on the same state carries one-shot anchor hints from input handlers to the timeline widget (excluded from JSON + equality). `EditorTimeline` gets new params `timelineScale` + `pendingScaleAnchor` + `onAnchorConsumed` so it stays Riverpod-free. The widget refactors `_timeToX`/`_xToTime` into `_pixelsPerSecond`-based helpers, wraps lanes in a horizontal `SingleChildScrollView`, applies anchor-preserving scroll in `didUpdateWidget`, auto-follows the playhead during playback, and handles trackpad pinch via `GestureDetector(onScaleStart/Update)`. The existing `_persistProject` debouncer in `playback_screen.dart` picks up state changes automatically (no controller-level debounce needed).

**Tech Stack:** Flutter 3.41.5 / Dart 3 / Riverpod 2 (`StateNotifier`). `TweenAnimationBuilder` + `Curves.easeOutQuint` for the 1× reset animation. `SingleChildScrollView` + `ScrollController`. `GestureDetector.onScaleStart/Update/End` for pinch. `Shortcuts`/`Actions`/`Intent` for keyboard shortcuts. JSON sidecar via existing `EditorProjectStore`.

**Conventions referenced throughout:**

- Test runner: `~/fvm/versions/3.41.5/bin/flutter test <path>`
- Engine tests live under `packages/slipreel_engine/test/`; app tests under `packages/screen_recorder/test/`.
- All test widgets that read `context.palette` must wrap in `MaterialApp(theme: ThemeData(extensions: const [AppPalette.midnight], useMaterial3: true), home: ...)`.
- Commit messages follow the existing project style: `<type>(<scope>): <subject>` then a body. Use `feat`, `fix`, `refactor`, `test`.

**Spec:** `docs/superpowers/specs/2026-06-01-timeline-scale-slider-design.md`

---

## Phase Map

```
Phase 1 (sequential):    F1 ──► F2
                                │
Phase 2 (3 parallel):           ├── G1 ── G2 ── G3 ── G4 ── G5    (Track G)
                                ├── S1 ──── S3                    (Track S)
                                ├──   ────── S2  (waits for I1)
                                └── I1                             (Track I)
Phase 3 (sequential):                              V1
```

Phase 1 = 2 tasks. Phase 2 = 9 tasks across 3 tracks. Phase 3 = 1 task. Total 12 tasks.

The plan merges the spec's F3 (transient anchor field) into F1 because both fields live in the same file and the controller (F2) needs both. The remaining parallelism is unchanged.

---

# Phase 1 — Foundation (sequential)

## Task F1: Add `timelineScale` and `pendingScaleAnchor` to `EditorProjectState`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_state_test.dart`

### Steps

- [ ] **Step 1: Write failing tests for the new fields.**

Open `packages/slipreel_engine/test/state/editor_project_state_test.dart`. Add at the bottom of the existing `main()` body:

```dart
group('timelineScale field', () {
  test('default is 1.0', () {
    expect(EditorProjectState.defaults().timelineScale, 1.0);
  });

  test('copyWith updates only timelineScale', () {
    final base = EditorProjectState.defaults();
    final next = base.copyWith(timelineScale: 4.0);
    expect(next.timelineScale, 4.0);
    expect(next.cursorSize, base.cursorSize);
    expect(next.audioMix, base.audioMix);
  });

  test('round-trips through toJson/fromJson', () {
    final base = EditorProjectState.defaults().copyWith(timelineScale: 3.5);
    final decoded = EditorProjectState.fromJson(base.toJson());
    expect(decoded.timelineScale, 3.5);
  });

  test('missing key in JSON falls back to 1.0', () {
    final json = EditorProjectState.defaults().toJson()
      ..remove('timelineScale');
    expect(EditorProjectState.fromJson(json).timelineScale, 1.0);
  });

  test('invalid JSON values fall back to 1.0', () {
    final base = EditorProjectState.defaults().toJson();
    for (final bad in <Object?>[-1, 0, 100, 'foo', null, double.nan, double.infinity]) {
      final json = {...base, 'timelineScale': bad};
      expect(
        EditorProjectState.fromJson(json).timelineScale,
        1.0,
        reason: 'bad input: $bad',
      );
    }
  });

  test('equality and hashCode include timelineScale', () {
    final a = EditorProjectState.defaults().copyWith(timelineScale: 2.0);
    final b = EditorProjectState.defaults().copyWith(timelineScale: 2.0);
    final c = EditorProjectState.defaults().copyWith(timelineScale: 3.0);
    expect(a == b, isTrue);
    expect(a.hashCode == b.hashCode, isTrue);
    expect(a == c, isFalse);
  });
});

group('pendingScaleAnchor field (transient)', () {
  test('defaults to null', () {
    expect(EditorProjectState.defaults().pendingScaleAnchor, isNull);
  });

  test('copyWith sets and clears via clearPendingScaleAnchor flag', () {
    final base = EditorProjectState.defaults();
    final withAnchor =
        base.copyWith(pendingScaleAnchor: const Duration(seconds: 3));
    expect(withAnchor.pendingScaleAnchor, const Duration(seconds: 3));
    final cleared = withAnchor.copyWith(clearPendingScaleAnchor: true);
    expect(cleared.pendingScaleAnchor, isNull);
  });

  test('NOT serialized to JSON', () {
    final state = EditorProjectState.defaults()
        .copyWith(pendingScaleAnchor: const Duration(seconds: 5));
    expect(state.toJson().containsKey('pendingScaleAnchor'), isFalse);
  });

  test('NOT read from JSON (always starts null after fromJson)', () {
    final base = EditorProjectState.defaults().toJson();
    final hostile = {...base, 'pendingScaleAnchor': 12345};
    expect(EditorProjectState.fromJson(hostile).pendingScaleAnchor, isNull);
  });

  test('NOT included in equality or hashCode', () {
    final a = EditorProjectState.defaults()
        .copyWith(pendingScaleAnchor: const Duration(seconds: 1));
    final b = EditorProjectState.defaults()
        .copyWith(pendingScaleAnchor: const Duration(seconds: 9));
    final c = EditorProjectState.defaults();
    expect(a == b, isTrue, reason: 'anchor must not affect ==');
    expect(a == c, isTrue);
    expect(a.hashCode == c.hashCode, isTrue);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_test.dart
```

Expected: failures because `timelineScale` and `pendingScaleAnchor` getters don't exist; `copyWith` doesn't accept them.

- [ ] **Step 3: Add the fields, constructor params, copyWith plumbing, and equality.**

Edit `packages/slipreel_engine/lib/state/editor_project_state.dart`.

Add constructor params (insert after `this.audioMix = const AudioMix(),` on line ~43):

```dart
this.timelineScale = 1.0,
this.pendingScaleAnchor,
```

Add fields after `final AudioMix audioMix;` (line ~141):

```dart
/// Horizontal timeline zoom. 1.0 = fit-to-width (default; visually
/// identical to pre-feature behavior). Up to 8.0 = 8× wider content.
/// Clamped at the controller boundary; this field assumes a valid
/// value.
final double timelineScale;

/// Transient one-shot anchor hint set by [EditorProjectController.
/// setTimelineScale] and consumed by the timeline widget. The widget
/// preserves the on-screen x-position of this timestamp across a
/// scale change, then calls [EditorProjectController.
/// clearPendingScaleAnchor] to reset to null.
///
/// Excluded from `==`/`hashCode` so a re-emit at the same scale with
/// a different anchor still drives the widget. Excluded from JSON
/// so a project file never reflects a transient UI signal.
final Duration? pendingScaleAnchor;
```

Update copyWith — add to the parameter list (alphabetical-ish):

```dart
double? timelineScale,
Duration? pendingScaleAnchor,
bool clearPendingScaleAnchor = false,
```

And in the returned `EditorProjectState(...)`:

```dart
timelineScale: timelineScale ?? this.timelineScale,
pendingScaleAnchor: clearPendingScaleAnchor
    ? null
    : (pendingScaleAnchor ?? this.pendingScaleAnchor),
```

Update `toJson()` — append before the closing brace, before the final `};`:

```dart
'timelineScale': timelineScale,
// pendingScaleAnchor is transient; not serialized.
```

Update `fromJson()` — inside the `return EditorProjectState(...)` block, add:

```dart
timelineScale: _readTimelineScale(json['timelineScale']),
// pendingScaleAnchor is transient; always null after load.
```

Add the helper method right above `_decodeEnum` (so it sits next to the other private parsing helpers):

```dart
static double _readTimelineScale(Object? raw) {
  if (raw is num) {
    final v = raw.toDouble();
    if (v.isFinite && v >= 1.0 && v <= 8.0) return v;
  }
  return 1.0;
}
```

Add `==` and `hashCode` overrides. The class currently has none — check first by searching for `bool operator ==` in the file. If absent, add them at the end of the class body. For brevity (the class has ~22 fields), use the constructor-arg list — generate a precise override that excludes `pendingScaleAnchor`:

```dart
@override
bool operator ==(Object other) {
  if (identical(this, other)) return true;
  return other is EditorProjectState &&
      other.timeline == timeline &&
      other.screenAnimationConfig == screenAnimationConfig &&
      other.cursorAnimationConfig == cursorAnimationConfig &&
      other.cursorSize == cursorSize &&
      other.cursorStyle == cursorStyle &&
      other.cursorClickEffect == cursorClickEffect &&
      other.hideCursorOverlay == hideCursorOverlay &&
      other.motionBlur == motionBlur &&
      other.cursorMovementBlur == cursorMovementBlur &&
      other.screenMovementBlur == screenMovementBlur &&
      other.screenZoomBlur == screenZoomBlur &&
      other.cursorShadow == cursorShadow &&
      other.clickSpring == clickSpring &&
      other.cursorDelay == cursorDelay &&
      other.cursorPostProcess == cursorPostProcess &&
      other.windowFrame == windowFrame &&
      other.playbackSpeed == playbackSpeed &&
      other.fadeIn == fadeIn &&
      other.fadeOut == fadeOut &&
      other.outputAspect == outputAspect &&
      other.audioMix == audioMix &&
      other.timelineScale == timelineScale;
  // pendingScaleAnchor intentionally excluded.
}

@override
int get hashCode => Object.hashAll([
      timeline,
      screenAnimationConfig,
      cursorAnimationConfig,
      cursorSize,
      cursorStyle,
      cursorClickEffect,
      hideCursorOverlay,
      motionBlur,
      cursorMovementBlur,
      screenMovementBlur,
      screenZoomBlur,
      cursorShadow,
      clickSpring,
      cursorDelay,
      cursorPostProcess,
      windowFrame,
      playbackSpeed,
      fadeIn,
      fadeOut,
      outputAspect,
      audioMix,
      timelineScale,
      // pendingScaleAnchor intentionally excluded.
    ]);
```

**Important:** if the class already has `==`/`hashCode`, EDIT the existing ones to add `timelineScale` (and leave `pendingScaleAnchor` out). Use grep first to confirm.

- [ ] **Step 4: Run tests to verify they pass.**

```bash
~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_state_test.dart
```

Expected: all tests green, including the existing tests that already lived in the file.

- [ ] **Step 5: Bump schema version + add migration.**

In `editor_project_state.dart`, change:

```dart
static const int currentSchemaVersion = 5;
```

to:

```dart
static const int currentSchemaVersion = 6;
```

Add a new entry to the `_schemaMigrations` list (at the bottom of the file). Following the existing comment style:

```dart
  // v5 → v6: add the per-project timelineScale (no value transform —
  // fromJson fills 1.0 when the key is absent).
  (json) => {...json, 'schemaVersion': 6},
```

- [ ] **Step 6: Run the engine test suite to confirm no other state tests broke.**

```bash
~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/
```

Expected: all green.

- [ ] **Step 7: Commit.**

```bash
git add packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_project_state_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(engine): timelineScale + pendingScaleAnchor on EditorProjectState

Adds two new fields to per-recording editor state:

- `timelineScale: double` (1.0..8.0, default 1.0) — horizontal timeline
  zoom. Persisted to .editor.json. Invalid/missing values fall back to
  1.0. Included in == / hashCode. Schema bumped v5 → v6 with an
  additive migration.

- `pendingScaleAnchor: Duration?` (transient) — one-shot anchor hint
  set by the controller, consumed by the timeline widget. EXCLUDED
  from JSON and ==/hashCode so it can't accidentally dirty selectors
  or persist a UI signal.

Part of sub-project A (timeline scale slider). See spec:
docs/superpowers/specs/2026-06-01-timeline-scale-slider-design.md
EOF
)"
```

---

## Task F2: `setTimelineScale` + `clearPendingScaleAnchor` on `EditorProjectController`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart` (new)

### Steps

- [ ] **Step 1: Write failing tests.**

Create `packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  group('setTimelineScale', () {
    test('updates state when value differs', () {
      final c = EditorProjectController();
      c.setTimelineScale(2.0);
      expect(c.current.timelineScale, 2.0);
    });

    test('clamps above 8.0', () {
      final c = EditorProjectController();
      c.setTimelineScale(15.0);
      expect(c.current.timelineScale, 8.0);
    });

    test('clamps below 1.0', () {
      final c = EditorProjectController();
      c.setTimelineScale(0.25);
      expect(c.current.timelineScale, 1.0);
    });

    test('no-op when scale equals current and anchor is null', () {
      final c = EditorProjectController();
      final before = c.current;
      c.setTimelineScale(1.0);  // already 1.0
      expect(identical(c.current, before), isTrue,
          reason: 'no state object should be emitted');
    });

    test('emits when scale equals current but anchor is non-null', () {
      final c = EditorProjectController();
      final before = c.current;
      c.setTimelineScale(1.0, anchorTime: const Duration(seconds: 3));
      expect(identical(c.current, before), isFalse);
      expect(c.current.pendingScaleAnchor, const Duration(seconds: 3));
    });

    test('successive calls with different anchors at same scale both emit', () {
      final c = EditorProjectController();
      c.setTimelineScale(2.0, anchorTime: const Duration(seconds: 1));
      final after1 = c.current;
      c.setTimelineScale(2.0, anchorTime: const Duration(seconds: 5));
      final after2 = c.current;
      expect(identical(after1, after2), isFalse);
      expect(after2.pendingScaleAnchor, const Duration(seconds: 5));
    });

    test('null anchor on the call sets pendingScaleAnchor to null', () {
      final c = EditorProjectController();
      c.setTimelineScale(2.0, anchorTime: const Duration(seconds: 3));
      c.setTimelineScale(3.0);  // no anchor
      expect(c.current.timelineScale, 3.0);
      expect(c.current.pendingScaleAnchor, isNull);
    });
  });

  group('clearPendingScaleAnchor', () {
    test('clears the anchor without changing scale', () {
      final c = EditorProjectController();
      c.setTimelineScale(4.0, anchorTime: const Duration(seconds: 2));
      c.clearPendingScaleAnchor();
      expect(c.current.timelineScale, 4.0);
      expect(c.current.pendingScaleAnchor, isNull);
    });

    test('no-op when anchor is already null', () {
      final c = EditorProjectController();
      final before = c.current;
      c.clearPendingScaleAnchor();
      expect(identical(c.current, before), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart
```

Expected: failures because `setTimelineScale` and `clearPendingScaleAnchor` methods don't exist on the controller.

- [ ] **Step 3: Implement the methods.**

Edit `packages/slipreel_engine/lib/state/editor_project_controller.dart`. Add after the existing single-field mutators (after `void setSystemMuted(bool value) => ...`, line ~109):

```dart
/// Set the timeline horizontal scale. Clamped to [1.0, 8.0]. The
/// optional [anchorTime] is a one-shot hint stored on the next
/// state's [EditorProjectState.pendingScaleAnchor] for the timeline
/// widget to consume; the widget then calls
/// [clearPendingScaleAnchor]. Persistence is handled by the
/// playback screen's debounced `ref.listen` — no need to debounce
/// here.
void setTimelineScale(double scale, {Duration? anchorTime}) {
  final clamped = scale.isNaN ? 1.0 : scale.clamp(1.0, 8.0);
  if (clamped == state.timelineScale && anchorTime == null) return;
  state = state.copyWith(
    timelineScale: clamped,
    pendingScaleAnchor: anchorTime,
    clearPendingScaleAnchor: anchorTime == null,
  );
}

/// Reset the transient anchor hint. Called by the timeline widget
/// after applying an anchor-preserving scale change. No-ops when
/// the anchor is already null so it doesn't dirty the state stream.
void clearPendingScaleAnchor() {
  if (state.pendingScaleAnchor == null) return;
  state = state.copyWith(clearPendingScaleAnchor: true);
}
```

- [ ] **Step 4: Run tests to verify they pass.**

```bash
~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart
```

Expected: all green.

- [ ] **Step 5: Run the broader engine test suite.**

```bash
~/fvm/versions/3.41.5/bin/flutter test packages/slipreel_engine/test/
```

Expected: all green.

- [ ] **Step 6: Commit.**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart \
        packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(engine): setTimelineScale + clearPendingScaleAnchor on controller

Clamps incoming scale to [1.0, 8.0]. NaN falls back to 1.0. Same-scale
+ null-anchor calls are a no-op (no state emit). Same-scale + non-null
anchor still emits so the widget's anchor-preservation logic fires.

Persistence is unchanged — playback_screen.dart's existing
`ref.listen → _persistProject` (500ms debounce) picks up state
emissions automatically.

Part of sub-project A.
EOF
)"
```

---

# Phase 2 — Track G (Geometry, scroll, anchor, auto-follow, pinch)

**Owns:** `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart` + its test file.
Tasks G1 → G5 are **sequential within this track**. They edit the same file.

## Task G1: Refactor `_timeToX` / `_xToTime` to use `_pixelsPerSecond`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_geometry_test.dart` (new)

### Steps

- [ ] **Step 1: Write failing tests for the new helpers.**

Create `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_geometry_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart'
    show pixelsPerSecondForTest, timeToXForTest, xToTimeForTest,
         contentWidthForTest;

void main() {
  group('_pixelsPerSecond', () {
    test('viewport=600, total=10s, scale=1.0 → 60 px/s', () {
      expect(
        pixelsPerSecondForTest(600, const Duration(seconds: 10), 1.0),
        60.0,
      );
    });

    test('scale=2.0 doubles it', () {
      expect(
        pixelsPerSecondForTest(600, const Duration(seconds: 10), 2.0),
        120.0,
      );
    });

    test('total=Duration.zero returns 0 (no division by zero)', () {
      expect(
        pixelsPerSecondForTest(600, Duration.zero, 1.0),
        0.0,
      );
    });
  });

  group('_timeToX', () {
    test('5s at 60 px/s → 300 px', () {
      expect(timeToXForTest(const Duration(seconds: 5), 60.0), 300.0);
    });

    test('any time at 0 px/s → 0', () {
      expect(timeToXForTest(const Duration(seconds: 5), 0.0), 0.0);
    });
  });

  group('_xToTime', () {
    test('300 px at 60 px/s → 5s', () {
      expect(xToTimeForTest(300.0, 60.0), const Duration(seconds: 5));
    });

    test('any px at 0 px/s → Duration.zero', () {
      expect(xToTimeForTest(300.0, 0.0), Duration.zero);
    });
  });

  group('_contentWidth', () {
    test('viewport=600, scale=1.0 → 600', () {
      expect(contentWidthForTest(600, 1.0), 600.0);
    });

    test('viewport=600, scale=2.0 → 1200', () {
      expect(contentWidthForTest(600, 2.0), 1200.0);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_geometry_test.dart
```

Expected: compile failures because the `*ForTest` symbols don't exist.

- [ ] **Step 3: Replace existing helpers in `editor_timeline.dart`.**

Open `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`. Locate the top-level helpers (around line 54–65):

```dart
double _timeToX(Duration t, double width, Duration total) =>
    t.inMilliseconds / total.inMilliseconds * width;
Duration _xToTime(double x, double width, Duration total) =>
    Duration(milliseconds: (x / width * total.inMilliseconds).round());
```

Replace with:

```dart
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

// Test-only re-exports (private helpers in lib code can't be reached
// from `test/`; these proxies keep the helpers private to lib but
// addressable from unit tests).
@visibleForTesting
double pixelsPerSecondForTest(double v, Duration t, double s) =>
    _pixelsPerSecond(v, t, s);
@visibleForTesting
double timeToXForTest(Duration t, double pps) => _timeToX(t, pps);
@visibleForTesting
Duration xToTimeForTest(double x, double pps) => _xToTime(x, pps);
@visibleForTesting
double contentWidthForTest(double v, double s) => _contentWidth(v, s);
```

Add the import for `@visibleForTesting` at the top of the file if missing:

```dart
import 'package:flutter/foundation.dart' show visibleForTesting;
```

(Probably already imported transitively — check before adding.)

- [ ] **Step 4: Update all in-file callers to use the new signatures.**

Find every call to `_timeToX(...)` and `_xToTime(...)` (there are several inside `_TimeRuler`, `_ClipLane`, `_ZoomLane`, `_PlayheadPainter`, and `_seek`). For each call site, replace the `width, total` args with a single `pps` value. Pattern:

**Before:**
```dart
final x = _timeToX(time, width, totalDuration);
```

**After (at each call site):**
```dart
final pps = _pixelsPerSecond(width, totalDuration, 1.0);  // scale=1.0 for now
final x = _timeToX(time, pps);
```

For this task only, hard-code `scale: 1.0` everywhere. Subsequent tasks (G3 onward) wire the real scale through. The goal of G1 is "geometry refactored, visible behavior unchanged".

Use grep to enumerate call sites: `grep -n "_timeToX\|_xToTime" packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`. Fix every one.

- [ ] **Step 5: Run geometry tests.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_geometry_test.dart
```

Expected: all green.

- [ ] **Step 6: Run the full screen_recorder test suite to make sure no caller broke.**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test 2>&1 | tail -30
```

Expected: same number of pass/fail as before this task (pre-existing failures in `audio_tab_mix_test.dart` stay; nothing NEW fails).

- [ ] **Step 7: Commit.**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_geometry_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
refactor(timeline): introduce _pixelsPerSecond geometry helpers

Replaces inline (time/total)*width math with explicit pixelsPerSecond
+ contentWidth helpers. All call sites pass scale=1.0 for now, so
visible behavior is unchanged. Sets up timeline-scale-slider (G2..G5
threading the real scale through). Pure refactor with unit tests for
the helpers.

Part of sub-project A.
EOF
)"
```

---

## Task G2: Wrap lanes in `SingleChildScrollView` + introduce `timelineScale` param

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (single change to the EditorTimeline call site to pass the new params)
- Test: `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scroll_test.dart` (new)

### Steps

- [ ] **Step 1: Write failing tests for the scroll-wrap behavior.**

Create `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scroll_test.dart`:

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SizedBox(width: width, height: 200, child: child),
      ),
    );

void main() {
  testWidgets('at scale=1.0, content width equals viewport width',
      (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 1.0,
    )));
    await tester.pumpAndSettle();

    final scrollFinder = find.byType(SingleChildScrollView);
    expect(scrollFinder, findsOneWidget);

    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    expect(scroll.physics, isA<NeverScrollableScrollPhysics>());

    // Content width should equal the viewport (600).
    final sized = tester.widgetList<SizedBox>(
      find.descendant(
        of: scrollFinder,
        matching: find.byType(SizedBox),
      ),
    );
    final widths = sized.map((s) => s.width).whereType<double>();
    expect(widths.any((w) => (w - 600).abs() < 0.5), isTrue,
        reason: 'expected a 600px-wide content child at scale=1.0');
  });

  testWidgets('at scale=2.0, content width is 2× viewport width',
      (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 2.0,
    )));
    await tester.pumpAndSettle();

    final scroll =
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.physics, isNot(isA<NeverScrollableScrollPhysics>()));

    final sized = tester.widgetList<SizedBox>(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(SizedBox),
      ),
    );
    final widths = sized.map((s) => s.width).whereType<double>();
    expect(widths.any((w) => (w - 1200).abs() < 0.5), isTrue,
        reason: 'expected a 1200px-wide content child at scale=2.0');
  });

  testWidgets('at scale=1.0, horizontal drag does not change scroll offset',
      (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 1.0,
    )));
    await tester.pumpAndSettle();

    // Drag inside the scrollable. NeverScrollable means offset stays 0.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final scroll =
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.controller!.offset, 0.0);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scroll_test.dart
```

Expected: compile failure on the `timelineScale:` constructor argument (doesn't exist yet).

- [ ] **Step 3: Add new constructor params to `EditorTimeline`.**

In `editor_timeline.dart`, edit the `EditorTimeline` constructor. Add (after `this.isPlaying = false,`):

```dart
this.timelineScale = 1.0,
this.pendingScaleAnchor,
this.onAnchorConsumed,
```

Add the matching field declarations next to the others:

```dart
/// Horizontal zoom: 1.0 = fit-to-width, up to 8.0 = 8× wider.
/// Threaded down from EditorProjectState so the widget stays
/// Riverpod-free.
final double timelineScale;

/// One-shot anchor hint. When set + when [timelineScale] changes,
/// the widget preserves this timestamp's on-screen x-position by
/// adjusting its scroll offset. Cleared via [onAnchorConsumed].
final Duration? pendingScaleAnchor;

/// Invoked by the widget after consuming a non-null
/// [pendingScaleAnchor]. The parent should reset the anchor via
/// `EditorProjectController.clearPendingScaleAnchor()`.
final VoidCallback? onAnchorConsumed;
```

- [ ] **Step 4: Add `ScrollController` + scroll wrap to `_EditorTimelineState`.**

In `_EditorTimelineState`, add:

```dart
final ScrollController _scrollController = ScrollController();
double _lastViewportWidth = 0;

@override
void dispose() {
  _scrollController.dispose();
  super.dispose();
}
```

Locate the `build` method's `LayoutBuilder` (around line 174). Rewrite the inner body so the lanes are inside a horizontal `SingleChildScrollView`. Replace the existing `SizedBox(height: totalHeight, width: width, ...)` block with:

```dart
return LayoutBuilder(
  builder: (context, constraints) {
    final width = constraints.maxWidth;
    _lastViewportWidth = width;
    final pps = _pixelsPerSecond(width, widget.duration, widget.timelineScale);
    final contentWidth = _contentWidth(width, widget.timelineScale);

    final zoomLaneHeight = _laneHeight + _zoomBadgeAreaHeight;
    final totalHeight = _rulerHeight +
        _laneSpacing +
        _laneHeight +
        _laneSpacing +
        zoomLaneHeight;

    return SizedBox(
      height: totalHeight,
      width: width,
      child: MouseRegion(
        opaque: false,
        onHover: (e) => _updateHover(e.localPosition, width),
        onExit: (_) => _clearHover(),
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: widget.timelineScale > 1.0
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: contentWidth,
            height: totalHeight,
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: _rulerHeight,
                      child: _TimeRuler(
                          duration: widget.duration,
                          pixelsPerSecond: pps,
                          onSeek: widget.onSeek),
                    ),
                    const SizedBox(height: _laneSpacing),
                    SizedBox(
                      height: _laneHeight,
                      child: _ClipLane(
                        duration: widget.duration,
                        pixelsPerSecond: pps,
                        onSeek: widget.onSeek,
                        speedLabel: widget.playbackSpeedLabel,
                        isSelected: widget.clipSelected,
                        onTap: () => widget.onClipSelected
                            ?.call(!widget.clipSelected),
                        trimSelection: widget.trimSelection,
                        onTrimChanged: widget.onTrimChanged,
                      ),
                    ),
                    // ... (rest of the existing lane children, swapping
                    // `width:` for `pixelsPerSecond: pps`)
                  ],
                ),
                // Existing playhead/hover overlays stay HERE but are
                // wrapped in a Positioned that reads scroll offset.
                // For G2 we leave the playhead inline; G3 will lift it
                // to a fixed overlay if needed.
              ],
            ),
          ),
        ),
      ),
    );
  },
);
```

Update `_TimeRuler`, `_ClipLane`, `_ZoomLane`, `_PlayheadPainter` constructors to accept `double pixelsPerSecond` instead of `double width` + `Duration total`. At each internal call site within those widgets, replace `_timeToX(t, width, total)` → `_timeToX(t, pixelsPerSecond)` (already partially done in G1; this task removes the residual `width`/`total` params on the lane constructors).

- [ ] **Step 5: Update the call site in `playback_screen.dart`.**

Edit `packages/screen_recorder/lib/ui/screens/playback_screen.dart` around line 1272. Currently:

```dart
return EditorTimeline(
  duration: _controller.value.duration,
  position: displayedPos,
  isPlaying: _controller.value.isPlaying,
  onSeek: (next) { /* ... */ },
  // ...
);
```

Add the new params:

```dart
return EditorTimeline(
  duration: _controller.value.duration,
  position: displayedPos,
  isPlaying: _controller.value.isPlaying,
  timelineScale: ref.watch(editorProjectControllerProvider).timelineScale,
  pendingScaleAnchor:
      ref.watch(editorProjectControllerProvider).pendingScaleAnchor,
  onAnchorConsumed: () => ref
      .read(editorProjectControllerProvider.notifier)
      .clearPendingScaleAnchor(),
  onSeek: (next) { /* ... */ },
  // ...
);
```

If the surrounding builder is inside an `AnimatedBuilder` (which it is — line 1262), `ref` needs to be accessible. Search for how other places in `playback_screen.dart` access `ref.watch` inside this builder — there are existing uses of `ref` in this file. Follow the same pattern (the file uses `ConsumerStatefulWidget` so `ref` is on the State class).

- [ ] **Step 6: Run scroll tests to verify they pass.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scroll_test.dart
```

Expected: all green.

- [ ] **Step 7: Run the full timeline test suite to confirm no regression.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/
```

Expected: green or same-as-before failures.

- [ ] **Step 8: Commit.**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scroll_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(timeline): wrap lanes in horizontal SingleChildScrollView

EditorTimeline gains three params:
  - timelineScale (default 1.0)
  - pendingScaleAnchor (Duration?, default null)
  - onAnchorConsumed (VoidCallback?, default null)

Lanes now live inside a SingleChildScrollView whose physics flips
between NeverScrollable (scale==1) and Clamping (scale>1). Content
width = viewport * scale. At scale==1.0, visible behavior is
unchanged.

playback_screen.dart's EditorTimeline call site threads the new
params via the editorProjectControllerProvider.

Part of sub-project A.
EOF
)"
```

---

## Task G3: Anchor-preserving scale change in `didUpdateWidget`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_anchor_test.dart` (new)

### Steps

- [ ] **Step 1: Write the failing test.**

Create `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_anchor_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SizedBox(width: width, height: 200, child: child),
      ),
    );

double _scrollOffset(WidgetTester tester) {
  final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView));
  return scroll.controller!.offset;
}

void main() {
  testWidgets('scale 1→2 with anchor=playhead keeps playhead viewport-x', (tester) async {
    var consumed = 0;
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 5),
      onSeek: (_) {},
      timelineScale: 1.0,
      onAnchorConsumed: () => consumed++,
    )));
    await tester.pumpAndSettle();

    // At scale=1, playhead at 5s (mid of 10s) → viewport-x = 300 of 600.
    // (Visual check happens by computing what offset we expect after scale.)
    // Now scale to 2.0 with anchor=5s. Content width = 1200. New
    // content-x of 5s = 600. Viewport-x should stay 300 → offset = 300.
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 5),
      onSeek: (_) {},
      timelineScale: 2.0,
      pendingScaleAnchor: const Duration(seconds: 5),
      onAnchorConsumed: () => consumed++,
    )));
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), closeTo(300.0, 1.0));
    expect(consumed, 1, reason: 'anchor must be consumed exactly once');
  });

  testWidgets('different anchor (e.g. 7s) preserves the anchor, not playhead',
      (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 5),
      onSeek: (_) {},
      timelineScale: 1.0,
    )));
    await tester.pumpAndSettle();

    // Scale to 2.0 with anchor at 7s.
    // At scale=1: 7s viewport-x = 420.
    // At scale=2: content-x of 7s = 840. To keep viewport-x at 420,
    // offset = 840 - 420 = 420.
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 5),
      onSeek: (_) {},
      timelineScale: 2.0,
      pendingScaleAnchor: const Duration(seconds: 7),
    )));
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), closeTo(420.0, 1.0));
  });

  testWidgets('scroll offset clamps at 0 when computed offset is negative',
      (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 1),
      onSeek: (_) {},
      timelineScale: 1.0,
    )));
    await tester.pumpAndSettle();

    // Anchor at 1s, scale to 2.0. content-x of 1s = 120.
    // viewport-x before = 60. New offset = 120 - 60 = 60 → positive, clamps fine.
    // Use anchor=0 to force clamp: content-x = 0, viewport-x = 0 → offset = 0.
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 1),
      onSeek: (_) {},
      timelineScale: 2.0,
      pendingScaleAnchor: Duration.zero,
    )));
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), 0.0);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_anchor_test.dart
```

Expected: the offset assertions fail (the widget doesn't reposition on scale changes yet).

- [ ] **Step 3: Implement `didUpdateWidget` + `_applyScale`.**

In `_EditorTimelineState` (file `editor_timeline.dart`), find the existing `didUpdateWidget`:

```dart
@override
void didUpdateWidget(EditorTimeline old) {
  super.didUpdateWidget(old);
  if (widget.isPlaying && _hoverProgress != null) {
    _hoverProgress = null;
  }
}
```

Extend it:

```dart
@override
void didUpdateWidget(EditorTimeline old) {
  super.didUpdateWidget(old);
  if (widget.isPlaying && _hoverProgress != null) {
    _hoverProgress = null;
  }

  final scaleChanged = widget.timelineScale != old.timelineScale;
  final anchorPresent = widget.pendingScaleAnchor != null;
  if (scaleChanged || anchorPresent) {
    // Defer to post-frame so LayoutBuilder has run and the
    // SingleChildScrollView's content has been measured with the new
    // width before we jumpTo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyScale(old.timelineScale, widget.timelineScale,
          widget.pendingScaleAnchor);
    });
  }
}

void _applyScale(double oldScale, double newScale, Duration? anchor) {
  final viewport = _lastViewportWidth;
  if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;
  final anchorTime = anchor ?? widget.position;

  final oldPps = _pixelsPerSecond(viewport, widget.duration, oldScale);
  final newPps = _pixelsPerSecond(viewport, widget.duration, newScale);
  final oldOffset = _scrollController.hasClients
      ? _scrollController.offset
      : 0.0;

  final anchorViewportX = _timeToX(anchorTime, oldPps) - oldOffset;
  final newAnchorContentX = _timeToX(anchorTime, newPps);
  final newOffset = newAnchorContentX - anchorViewportX;

  final maxOffset = (_contentWidth(viewport, newScale) - viewport)
      .clamp(0.0, double.infinity);
  final clamped = newOffset.clamp(0.0, maxOffset);

  if (_scrollController.hasClients) {
    _scrollController.jumpTo(clamped);
  }

  if (anchor != null) {
    widget.onAnchorConsumed?.call();
  }
}
```

- [ ] **Step 4: Run the anchor test.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_anchor_test.dart
```

Expected: all green.

- [ ] **Step 5: Run all timeline tests.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/
```

Expected: all green or same as pre-task baseline.

- [ ] **Step 6: Commit.**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_anchor_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(timeline): anchor-preserving scale changes

didUpdateWidget detects scale or anchor changes and, post-frame,
jumps the horizontal scroll offset so the anchor's viewport-x is
unchanged. After consuming a non-null anchor, fires
onAnchorConsumed (parent clears state.pendingScaleAnchor).

Falls back to widget.position when anchor is null (slider/shortcut
inputs default to playhead anchoring).

Part of sub-project A.
EOF
)"
```

---

## Task G4: Playback auto-follow

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_autofollow_test.dart` (new)

### Steps

- [ ] **Step 1: Write the failing test.**

Create `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_autofollow_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SizedBox(width: width, height: 200, child: child),
      ),
    );

double _scrollOffset(WidgetTester tester) {
  final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView));
  return scroll.controller!.offset;
}

void main() {
  testWidgets('playhead crossing 80% viewport while playing triggers snap',
      (tester) async {
    // scale=4.0, total=10s, viewport=600 → content=2400, pps=240.
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 4.0,
      isPlaying: true,
    )));
    await tester.pumpAndSettle();

    // Advance position to 2s → content-x = 480. With offset=0,
    // viewport-x = 480. That's exactly 0.8 * 600. Not yet > 0.8, no snap.
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 2),
      onSeek: (_) {},
      timelineScale: 4.0,
      isPlaying: true,
    )));
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), 0.0);

    // Advance to 2.5s → content-x = 600 → viewport-x = 600 > 480 → snap.
    // Target offset = 600 - 0.2 * 600 = 480.
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(milliseconds: 2500),
      onSeek: (_) {},
      timelineScale: 4.0,
      isPlaying: true,
    )));
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), closeTo(480.0, 1.0));
  });

  testWidgets('no snap when isPlaying=false', (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 4.0,
      isPlaying: false,
    )));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 8),  // way past 80%
      onSeek: (_) {},
      timelineScale: 4.0,
      isPlaying: false,
    )));
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), 0.0);
  });

  testWidgets('no snap at scale==1.0', (tester) async {
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 1.0,
      isPlaying: true,
    )));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: const Duration(seconds: 9),
      onSeek: (_) {},
      timelineScale: 1.0,
      isPlaying: true,
    )));
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester), 0.0,
        reason: 'NeverScrollable physics — offset stays 0');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_autofollow_test.dart
```

Expected: the first test fails because there's no auto-follow yet.

- [ ] **Step 3: Implement `_maybeAutoFollow` and call it from `didUpdateWidget`.**

In `_EditorTimelineState` (file `editor_timeline.dart`), add:

```dart
void _maybeAutoFollow(Duration playhead) {
  if (!widget.isPlaying) return;
  if (widget.timelineScale == 1.0) return;

  final viewport = _lastViewportWidth;
  if (viewport <= 0 || widget.duration.inMilliseconds == 0) return;

  final pps = _pixelsPerSecond(viewport, widget.duration, widget.timelineScale);
  final playheadContentX = _timeToX(playhead, pps);
  final offset = _scrollController.hasClients
      ? _scrollController.offset
      : 0.0;
  final playheadViewportX = playheadContentX - offset;

  if (playheadViewportX > 0.8 * viewport || playheadViewportX < 0) {
    final targetOffset = playheadContentX - 0.2 * viewport;
    final maxOffset = (_contentWidth(viewport, widget.timelineScale) - viewport)
        .clamp(0.0, double.infinity);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(targetOffset.clamp(0.0, maxOffset));
    }
  }
}
```

Add the call to `didUpdateWidget` (insert at the end, after the existing G3 block):

```dart
if (widget.position != old.position) {
  // Defer to post-frame so the new scale (if it changed in the same
  // build) has been applied first.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    _maybeAutoFollow(widget.position);
  });
}
```

- [ ] **Step 4: Run the auto-follow test.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_autofollow_test.dart
```

Expected: all green.

- [ ] **Step 5: Re-run anchor + scroll tests to catch regressions.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/
```

Expected: all green or same as baseline.

- [ ] **Step 6: Commit.**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_autofollow_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(timeline): playback auto-follow at scale > 1

When isPlaying=true and timelineScale > 1, snap the scroll viewport
whenever the playhead crosses the right (80%) or left (0%) edge of the
visible window. Target landing position: 20% of viewport from the left.
Snap uses jumpTo, not animateTo — the playback tick is already the
visible motion source.

Part of sub-project A.
EOF
)"
```

---

## Task G5: Trackpad pinch on the timeline lanes (anchor on cursor)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_pinch_test.dart` (new)

### Steps

- [ ] **Step 1: Write the failing test.**

Create `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_pinch_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SizedBox(width: width, height: 200, child: child),
      ),
    );

void main() {
  testWidgets('two-finger pinch fires onPinchScale with cursor anchor',
      (tester) async {
    double? gotScale;
    Duration? gotAnchor;
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 1.0,
      onPinchScale: (s, a) {
        gotScale = s;
        gotAnchor = a;
      },
    )));
    await tester.pumpAndSettle();

    // Synthesize a two-finger pinch centered at x=300, scale=2.0.
    final center = tester.getCenter(find.byType(EditorTimeline));
    final p1 = await tester.startGesture(center - const Offset(20, 0));
    final p2 = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await p1.moveBy(const Offset(-20, 0));
    await p2.moveBy(const Offset(20, 0));
    await tester.pump();
    await p1.up();
    await p2.up();
    await tester.pumpAndSettle();

    expect(gotScale, isNotNull);
    expect(gotScale, greaterThan(1.0));
    expect(gotAnchor, isNotNull);
    // Anchor should be near the time corresponding to center-x (~5s).
    expect(gotAnchor!.inMilliseconds, closeTo(5000, 1500));
  });

  testWidgets('single-finger drag does NOT fire onPinchScale',
      (tester) async {
    var fires = 0;
    await tester.pumpWidget(_host(EditorTimeline(
      duration: const Duration(seconds: 10),
      position: Duration.zero,
      onSeek: (_) {},
      timelineScale: 1.0,
      onPinchScale: (_, __) => fires++,
    )));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(EditorTimeline));
    await tester.dragFrom(center, const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(fires, 0);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_pinch_test.dart
```

Expected: compile failure on `onPinchScale` (doesn't exist yet).

- [ ] **Step 3: Add the `onPinchScale` callback param + gesture wiring.**

In `EditorTimeline`'s constructor, add (next to `onAnchorConsumed`):

```dart
this.onPinchScale,
```

Add the field declaration:

```dart
/// Fires on each trackpad-pinch update over the timeline lanes.
/// Args: `(newScale, anchorTime)`. The caller routes through
/// `EditorProjectController.setTimelineScale(newScale, anchorTime:
/// anchorTime)`. Single-finger drags are filtered out.
final void Function(double scale, Duration anchorTime)? onPinchScale;
```

In `_EditorTimelineState`, add:

```dart
double? _pinchStartScale;
```

In the `build` method, wrap the `SingleChildScrollView` (or the outer `MouseRegion` — whichever is more convenient) with a `GestureDetector`:

```dart
child: GestureDetector(
  behavior: HitTestBehavior.translucent,
  onScaleStart: (_) => _pinchStartScale = widget.timelineScale,
  onScaleUpdate: (d) {
    // Filter out single-finger gestures: pointerCount<2 OR scale==1
    // (one-finger drag reports scale==1.0).
    if (d.pointerCount < 2 || d.scale == 1.0) return;
    final start = _pinchStartScale ?? widget.timelineScale;
    final next = (start * d.scale).clamp(1.0, 8.0);

    final viewport = _lastViewportWidth;
    if (viewport <= 0) return;
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final pps = _pixelsPerSecond(viewport, widget.duration, widget.timelineScale);
    final anchorContentX = d.localFocalPoint.dx + offset;
    final anchorTime = _xToTime(anchorContentX, pps);
    widget.onPinchScale?.call(next, anchorTime);
  },
  onScaleEnd: (_) => _pinchStartScale = null,
  child: <existing MouseRegion + SingleChildScrollView>,
),
```

- [ ] **Step 4: Wire `onPinchScale` at the call site in `playback_screen.dart`.**

In `playback_screen.dart` near line 1272 (the `EditorTimeline(...)` call), add:

```dart
onPinchScale: (newScale, anchor) => ref
    .read(editorProjectControllerProvider.notifier)
    .setTimelineScale(newScale, anchorTime: anchor),
```

- [ ] **Step 5: Run pinch tests.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_pinch_test.dart
```

Expected: green.

- [ ] **Step 6: Run full timeline suite + relevant playback_screen tests.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/timeline/
```

Expected: green or same-as-baseline.

- [ ] **Step 7: Commit.**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_pinch_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(timeline): trackpad pinch zooms timeline anchored on cursor

GestureDetector wraps the lanes. onScaleStart captures baseline
scale; onScaleUpdate computes next = (baseline * d.scale) clamped to
[1, 8] and an anchor time at the cursor (focal point in content
coords). Single-finger drags (pointerCount < 2 or d.scale == 1) are
filtered out so plain horizontal scroll doesn't dirty state.

The new onPinchScale callback routes to setTimelineScale at the
call site in playback_screen.dart.

Part of sub-project A.
EOF
)"
```

---

# Phase 2 — Track S (Slider widget + toolbar)

**Owns:** `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart` (new).
Tasks S1 → S3 inside the track; S2 (toolbar wire-up) waits for Track I to land its `playback_screen.dart` edits to avoid textual merges.

## Task S1: Build `TimelineScaleSlider` widget (log mapping + reset + tooltip)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart`
- Test: `packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart` (new)

### Steps

- [ ] **Step 1: Write the failing widget tests.**

Create `packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/timeline_scale_slider.dart';

Widget _host({
  required EditorProjectController controller,
  Duration playhead = Duration.zero,
}) =>
    ProviderScope(
      overrides: [
        editorProjectControllerProvider
            .overrideWith((ref) => controller),
      ],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: Center(
            child: TimelineScaleSlider(playheadPosition: playhead),
          ),
        ),
      ),
    );

void main() {
  testWidgets('thumb sits at left edge at scale=1.0', (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 0.0);
  });

  testWidgets('thumb sits at right edge at scale=8.0', (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(8.0);
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 1.0);
  });

  testWidgets('thumb sits near 0.5 at scale=sqrt(8) ≈ 2.83',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(math.sqrt(8.0));
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, closeTo(0.5, 0.01));
  });

  testWidgets('drag updates controller with log-mapped value and anchor',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(_host(
      controller: c,
      playhead: const Duration(seconds: 4),
    ));
    await tester.pumpAndSettle();

    final sliderFinder = find.byType(Slider);
    // Drag the thumb to about the middle.
    final center = tester.getCenter(sliderFinder);
    await tester.dragFrom(center, Offset.zero);  // no-op start
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged?.call(0.5);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(math.sqrt(8.0), 0.01));
    expect(c.current.pendingScaleAnchor, const Duration(seconds: 4));
  });

  testWidgets('tapping the "1×" reset label animates back to 1.0',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(5.0);
    await tester.pumpWidget(_host(controller: c));
    await tester.pumpAndSettle();

    // Tap the reset label.
    await tester.tap(find.text('1×'));
    // Pump through the animation (200ms easeOutQuint).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(1.0, 0.01));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart
```

Expected: compile failure (the slider file doesn't exist).

- [ ] **Step 3: Create `timeline_scale_slider.dart`.**

Create `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Toolbar control for the editor timeline's horizontal zoom.
///
/// Slider position is log-mapped: `slider [0..1] ↔ scale [1..8]` via
/// `scale = pow(8, slider)`. Drag fires
/// `controller.setTimelineScale(newScale, anchorTime: playheadPosition)`.
/// Tapping the "1×" label on the left animates the scale back to 1.0
/// over 200 ms easeOutQuint — the one place this widget animates.
class TimelineScaleSlider extends ConsumerStatefulWidget {
  const TimelineScaleSlider({
    super.key,
    required this.playheadPosition,
    this.width = 140,
  });

  /// Current playhead time. Passed in by the parent (lives on the
  /// playback screen's video controller, not on EditorProjectState).
  final Duration playheadPosition;
  final double width;

  @override
  ConsumerState<TimelineScaleSlider> createState() =>
      _TimelineScaleSliderState();
}

class _TimelineScaleSliderState
    extends ConsumerState<TimelineScaleSlider> {
  AnimationController? _resetAc;
  Animation<double>? _resetAnim;

  static double _scaleToSlider(double scale) =>
      math.log(scale) / math.log(8.0);
  static double _sliderToScale(double v) => math.pow(8.0, v).toDouble();

  void _resetToFit() {
    final ctl = ref.read(editorProjectControllerProvider.notifier);
    final from = ref.read(editorProjectControllerProvider).timelineScale;
    if (from == 1.0) return;
    _resetAc?.dispose();
    final ac = AnimationController(
      vsync: ScaffoldMessenger.of(context),  // any Ticker provider
      duration: const Duration(milliseconds: 200),
    );
    final tween = Tween<double>(begin: from, end: 1.0)
        .chain(CurveTween(curve: Curves.easeOutQuint));
    final anim = ac.drive(tween);
    anim.addListener(() {
      ctl.setTimelineScale(anim.value, anchorTime: widget.playheadPosition);
    });
    ac.forward().whenComplete(ac.dispose);
    _resetAc = ac;
    _resetAnim = anim;
  }

  @override
  void dispose() {
    _resetAc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scale = ref.watch(editorProjectControllerProvider).timelineScale;
    final sliderValue = _scaleToSlider(scale).clamp(0.0, 1.0);

    return SizedBox(
      width: widget.width,
      height: 32,
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _resetToFit,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '1×',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbColor: palette.accent,
                activeTrackColor: palette.accentMuted,
                inactiveTrackColor: palette.dividerStrong,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Tooltip(
                message: '${scale.toStringAsFixed(1)}×',
                waitDuration: const Duration(milliseconds: 400),
                child: Slider(
                  value: sliderValue,
                  onChanged: (v) {
                    final next = _sliderToScale(v);
                    ref
                        .read(editorProjectControllerProvider.notifier)
                        .setTimelineScale(
                          next,
                          anchorTime: widget.playheadPosition,
                        );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

**Note:** `vsync: ScaffoldMessenger.of(context)` is a hack; replace with proper TickerProviderStateMixin. Edit `_TimelineScaleSliderState` to:

```dart
class _TimelineScaleSliderState extends ConsumerState<TimelineScaleSlider>
    with SingleTickerProviderStateMixin {
```

And in `_resetToFit`, replace `vsync: ScaffoldMessenger.of(context)` with `vsync: this`.

- [ ] **Step 4: Run the slider tests.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart
```

Expected: green. If the drag test fails because `Slider.onChanged` isn't directly invocable, refactor the test to use `tester.tap` on the slider thumb or `tester.drag` with calibrated offsets.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart \
        packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(toolbar): TimelineScaleSlider widget

Log-mapped Slider (1×..8×) + tappable "1×" reset label.
Drag fires controller.setTimelineScale with playhead anchor.
Reset label animates back to 1.0 over 200ms easeOutQuint — the one
place this widget animates. Hover tooltip shows the current value.

Wire-up to CanvasToolbar comes in S2 (after Track I lands).

Part of sub-project A.
EOF
)"
```

---

## Task S3: Slider hover/tooltip + reset polish tests

**Files:**
- Test only: `packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart` (add cases)

S1's tests cover the main interactions. S3 adds polish/regression coverage. This task is small.

### Steps

- [ ] **Step 1: Add tests for tooltip wait and reset re-press.**

In the existing `main()` of `timeline_scale_slider_test.dart`, append:

```dart
testWidgets('reset is no-op when already at 1.0', (tester) async {
  final c = EditorProjectController();
  await tester.pumpWidget(_host(controller: c));
  await tester.pumpAndSettle();

  final beforeRef = c.current;
  await tester.tap(find.text('1×'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();

  expect(identical(c.current, beforeRef), isTrue,
      reason: 'no state emit expected when already at fit');
});

testWidgets('tooltip waitDuration is 400ms', (tester) async {
  final c = EditorProjectController();
  await tester.pumpWidget(_host(controller: c));
  await tester.pumpAndSettle();

  final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
  expect(tooltip.waitDuration, const Duration(milliseconds: 400));
});
```

- [ ] **Step 2: Run + commit.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart
```

Expected: green.

```bash
git add packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart
git -c commit.gpgsign=false commit -m "test(toolbar): TimelineScaleSlider reset+tooltip polish"
```

---

## Task S2: Add `TimelineScaleSlider` to `CanvasToolbar` call site

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (one line)

**Depends on:** S1 + I1 (so the `Shortcuts`/`Actions` edits land first and there's no textual conflict).

### Steps

- [ ] **Step 1: Locate the `CanvasToolbar(children: [...])` call.**

```bash
grep -n "CanvasToolbar" packages/screen_recorder/lib/ui/screens/playback_screen.dart
```

Expected: one match around line 1262.

- [ ] **Step 2: Add the slider to the children list.**

Find the current call:

```dart
CanvasToolbar(children: [
  const AspectRatioPicker(),
])
```

Add the new child. Use the `displayedPos` variable that's already in scope (computed at line 1269–1271):

```dart
CanvasToolbar(children: [
  const AspectRatioPicker(),
  TimelineScaleSlider(playheadPosition: displayedPos),
])
```

If `TimelineScaleSlider` isn't imported, add at the top of the file:

```dart
import 'package:screen_recorder/ui/widgets/canvas_toolbar/timeline_scale_slider.dart';
```

- [ ] **Step 3: Run the screen_recorder test suite (smoke).**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test 2>&1 | tail -20
```

Expected: green or same-as-baseline failures.

- [ ] **Step 4: Commit.**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git -c commit.gpgsign=false commit -m "feat(toolbar): wire TimelineScaleSlider into CanvasToolbar"
```

---

# Phase 2 — Track I (Cmd ± shortcuts)

**Owns:** the `Shortcuts`/`Actions` map in `playback_screen.dart`.

## Task I1: `Cmd =`/`Cmd −` shortcuts step scale by 1.25×

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/ui/screens/playback_screen_zoom_shortcuts_test.dart` (new)

### Steps

- [ ] **Step 1: Locate the existing `Shortcuts` / `Actions` setup.**

```bash
grep -n "Shortcuts\|Actions\|Intent" packages/screen_recorder/lib/ui/screens/playback_screen.dart | head -20
```

Identify the file's existing intent classes (probably `_PlayPauseIntent` or similar) and the place where the `Shortcuts(...)` widget wraps the build tree. Follow the same indentation and ordering.

- [ ] **Step 2: Write the failing test.**

Create `packages/screen_recorder/test/ui/screens/playback_screen_zoom_shortcuts_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

// The shortcut intents are private to playback_screen.dart, so we test
// via the public LogicalKeyboardKey paths instead of invoking the
// Intent classes directly. Pump the relevant subtree (or, for v1, a
// minimal wrapper that registers the same Shortcuts/Actions map).

// The shortcut intents + activator/action factories live in
// zoom_shortcuts.dart (created in Step 4 below) so this test can wire
// them up without spinning the playback screen. Closures inject the
// scale getter/setter — no provider needed in the test.

import 'package:screen_recorder/ui/screens/zoom_shortcuts.dart';

void main() {
  testWidgets('Cmd = invokes setTimelineScale with currentScale * 1.25',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s,
                  anchorTime: const Duration(seconds: 2)),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(1.25, 0.001));
  });

  testWidgets('Cmd - invokes setTimelineScale with currentScale / 1.25',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(4.0);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s,
                  anchorTime: const Duration(seconds: 2)),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(3.2, 0.001));
  });

  testWidgets('Cmd = at scale=8.0 clamps to 8.0 (no overshoot)',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(8.0);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, 8.0);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/screens/playback_screen_zoom_shortcuts_test.dart
```

Expected: compile failure on `zoom_shortcuts.dart` import.

- [ ] **Step 4: Extract `zoom_shortcuts.dart`.**

Create `packages/screen_recorder/lib/ui/screens/zoom_shortcuts.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Intent fired by `Cmd =`. Steps timeline scale UP by *1.25.
class ZoomTimelineInIntent extends Intent {
  const ZoomTimelineInIntent();
}

/// Intent fired by `Cmd -`. Steps timeline scale DOWN by /1.25.
class ZoomTimelineOutIntent extends Intent {
  const ZoomTimelineOutIntent();
}

/// Activator map. Lives in its own module so it's reachable from
/// tests without spinning up the whole playback screen.
Map<ShortcutActivator, Intent> buildZoomShortcuts() => const {
      SingleActivator(LogicalKeyboardKey.equal, meta: true):
          ZoomTimelineInIntent(),
      SingleActivator(LogicalKeyboardKey.minus, meta: true):
          ZoomTimelineOutIntent(),
    };

/// Action map. Caller injects the read/write closures so the action
/// doesn't depend on a provider directly — testable.
Map<Type, Action<Intent>> buildZoomActions({
  required double Function() getScale,
  required void Function(double next) setScale,
}) =>
    <Type, Action<Intent>>{
      ZoomTimelineInIntent: CallbackAction<ZoomTimelineInIntent>(
        onInvoke: (_) {
          setScale(getScale() * 1.25);
          return null;
        },
      ),
      ZoomTimelineOutIntent: CallbackAction<ZoomTimelineOutIntent>(
        onInvoke: (_) {
          setScale(getScale() / 1.25);
          return null;
        },
      ),
    };
```

- [ ] **Step 5: Wire the maps into `playback_screen.dart`.**

In `playback_screen.dart`, find the existing `Shortcuts(...)` widget or build-tree wrapper. If shortcuts already exist for play/pause, MERGE the new map in. Pseudocode:

```dart
import 'package:screen_recorder/ui/screens/zoom_shortcuts.dart';

// inside build, where the existing Shortcuts/Actions live:
Shortcuts(
  shortcuts: {
    ...existingShortcuts,
    ...buildZoomShortcuts(),
  },
  child: Actions(
    actions: {
      ...existingActions,
      ...buildZoomActions(
        getScale: () => ref.read(editorProjectControllerProvider).timelineScale,
        setScale: (next) => ref
            .read(editorProjectControllerProvider.notifier)
            .setTimelineScale(
              next,
              anchorTime: _controller.value.position,
            ),
      ),
    },
    child: <existing child tree>,
  ),
)
```

If no shortcuts/actions wrappers exist yet, ADD them at the appropriate level (usually around the playback canvas + timeline subtree so they have keyboard focus when the editor is active).

- [ ] **Step 6: Run the shortcuts test.**

```bash
~/fvm/versions/3.41.5/bin/flutter test \
  packages/screen_recorder/test/ui/screens/playback_screen_zoom_shortcuts_test.dart
```

Expected: green.

- [ ] **Step 7: Commit.**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/lib/ui/screens/zoom_shortcuts.dart \
        packages/screen_recorder/test/ui/screens/playback_screen_zoom_shortcuts_test.dart
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
feat(shortcuts): Cmd =/Cmd - step timeline zoom by 1.25x

New ZoomTimelineInIntent and ZoomTimelineOutIntent live in
ui/screens/zoom_shortcuts.dart with buildZoomShortcuts() +
buildZoomActions() helpers. Closures inject the getter/setter so the
actions are testable without spinning up the whole playback screen.

playback_screen.dart merges the new maps with the existing
Shortcuts/Actions wrappers. anchorTime = current playhead.

Part of sub-project A.
EOF
)"
```

---

# Phase 3 — Verify

## Task V1: Full-suite green + manual sanity check

### Steps

- [ ] **Step 1: Full test suite.**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test 2>&1 | tail -30
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test 2>&1 | tail -30
```

Expected: green except pre-existing failures (`audio_tab_mix_test.dart`, plus anything documented on main before this branch started).

- [ ] **Step 2: Hot reload the running app.**

```bash
# In the conversation, use the flutter-qa MCP probe:
# - mcp__flutter-qa__hot_reload
# - then mcp__flutter-qa__screenshot to inspect the toolbar
```

If you're running this plan via subagent-driven-development, the controller agent should invoke the MCP probe; if running standalone, ask the user to hot reload + open the editor.

- [ ] **Step 3: Manual checklist (run in the app).**

Open a recording, then verify:

1. The slider appears in the CanvasToolbar to the right of `AspectRatioPicker`.
2. Default state: thumb at left edge, no horizontal scroll on the timeline.
3. Drag the thumb halfway — timeline scales smoothly during drag (live update), playhead stays at the same on-screen x.
4. Drag to the right edge — content is ~8× as wide; two-finger scroll moves the viewport.
5. Press `Cmd =` repeatedly — zoom steps up; each step keeps playhead pinned.
6. Press `Cmd -` until you're at 1× — no overshoot; thumb sits at left edge.
7. Two-finger pinch on the clip lane — zooms anchored on the cursor, not the playhead.
8. Single-finger drag (or trackpad two-finger scroll) at scale>1 — scroll viewport without dirtying state. After a pause, the scale value persists across restart.
9. Tap the `1×` reset label — animates back to 1.0 over ~200 ms.
10. Reload the editor — `timelineScale` is restored from `.editor.json`.
11. Start playback at scale=4× — playhead crosses 80% viewport mark → viewport snaps so playhead lands at 20%. Pause → scroll freely; resume → next snap kicks in only when needed.

- [ ] **Step 4: If anything from the checklist fails, file the gap as a follow-up commit or open a question for the user.**

This plan is "shipped" once steps 1-3 are green and the user signs off.

---

# Appendix: File Manifest

**Created:**
- `packages/slipreel_engine/test/state/editor_project_controller_scale_test.dart` (F2)
- `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_geometry_test.dart` (G1)
- `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_scroll_test.dart` (G2)
- `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_anchor_test.dart` (G3)
- `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_autofollow_test.dart` (G4)
- `packages/screen_recorder/test/ui/widgets/timeline/editor_timeline_pinch_test.dart` (G5)
- `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/timeline_scale_slider.dart` (S1)
- `packages/screen_recorder/test/ui/widgets/canvas_toolbar/timeline_scale_slider_test.dart` (S1+S3)
- `packages/screen_recorder/lib/ui/screens/zoom_shortcuts.dart` (I1)
- `packages/screen_recorder/test/ui/screens/playback_screen_zoom_shortcuts_test.dart` (I1)

**Modified:**
- `packages/slipreel_engine/lib/state/editor_project_state.dart` (F1)
- `packages/slipreel_engine/lib/state/editor_project_controller.dart` (F2)
- `packages/slipreel_engine/test/state/editor_project_state_test.dart` (F1)
- `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart` (G1, G2, G3, G4, G5)
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (G2, S2, I1)
