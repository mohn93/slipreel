# Cut Marker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a clickable pin marker above every seam between adjacent slices on the timeline. The marker shows "X.Xs" hidden seconds when there's trim at the seam, and supports a two-step click affordance: first click clears the seam trims, second click merges the two slices into one.

**Architecture:** Engine-level pure math + two new controller methods, a self-contained `CutMarker` widget composed of a `Container`-decorated body and a `CustomPaint` tip, mounted as a third pass inside `ClipLane`. Callbacks plumb up through `EditorTimeline` to `PlaybackScreen` where the selected-slice index is adjusted post-merge.

**Tech Stack:** Flutter 3.41.5 (FVM at `~/fvm/versions/3.41.5/bin/flutter`), Dart 3, Riverpod, Material 3. Tests use `flutter_test`; engine tests live in `packages/slipreel_engine/test/state/`, UI tests in `packages/screen_recorder/test/ui/widgets/timeline/`. Run tests from inside each package directory.

**Spec reference:** `docs/superpowers/specs/2026-06-04-cut-marker-design.md`.

---

## File Structure

### New files

- **`packages/slipreel_engine/lib/state/seam_metrics.dart`** — pure top-level function `hiddenSecondsAtSeam(List<ClipSlice> clips, int seamIndex)`. No state, no controller dependency. Returns the total source-duration hidden at the seam between `clips[seamIndex]` and `clips[seamIndex + 1]`.
- **`packages/screen_recorder/lib/ui/widgets/timeline/cut_marker.dart`** — `CutMarker` stateless widget. Composed of a decorated `Container` body (rounded pill, orange fill, white border, drop shadow) holding the label + scissors icon, with a tiny downward-pointing tip painted via `CustomPainter` below.

### Modified files

- **`packages/slipreel_engine/lib/state/editor_project_controller.dart`** — add `clearSeamTrims(int seamIndex)` and `mergeSeam(int seamIndex)` methods.
- **`packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart`** — append a third pass to the build Stack rendering one `CutMarker` per seam. Add `onClearSeamTrims` and `onMergeSeam` callbacks to `ClipLane`.
- **`packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`** — pipe `onClearSeamTrims` and `onMergeSeam` through from outside.
- **`packages/screen_recorder/lib/ui/screens/playback_screen.dart`** — wire callbacks to controller methods. Adjust `_selectedSliceIndex` after merge.

### Test files

- **`packages/slipreel_engine/test/state/seam_metrics_test.dart`** — pure math tests.
- **`packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart`** — `clearSeamTrims` and `mergeSeam` tests.
- **`packages/screen_recorder/test/ui/widgets/timeline/cut_marker_test.dart`** — widget tests for `CutMarker` (compact vs labeled, tap, fade).
- **`packages/screen_recorder/test/ui/widgets/timeline/clip_lane_cut_markers_test.dart`** — integration tests for marker count, x positions, callback wiring, drag fade.

---

## Task 1: Engine — hidden seconds math

**Files:**
- Create: `packages/slipreel_engine/lib/state/seam_metrics.dart`
- Create: `packages/slipreel_engine/test/state/seam_metrics_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `packages/slipreel_engine/test/state/seam_metrics_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/seam_metrics.dart';

ClipSlice _slice({
  required int cs,
  required int ce,
  int? ts,
  int? te,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

void main() {
  group('hiddenSecondsAtSeam', () {
    test('no trim, adjacent cut boundary -> Duration.zero', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), Duration.zero);
    });

    test('right-side trim on left slice only', () {
      final clips = [
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 1));
    });

    test('left-side trim on right slice only', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10, ts: 6),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 1));
    });

    test('trim on both sides sums', () {
      final clips = [
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10, ts: 7),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 3));
    });

    test('non-adjacent source boundary contributes gap', () {
      final clips = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ];
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 3));
    });

    test('trim and gap combine', () {
      final clips = [
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 8, ce: 12, ts: 9),
      ];
      // (5-4) + (9-8) + (8-5) = 1 + 1 + 3 = 5
      expect(hiddenSecondsAtSeam(clips, 0), const Duration(seconds: 5));
    });

    test('out-of-range index returns Duration.zero', () {
      final clips = [_slice(cs: 0, ce: 5)];
      expect(hiddenSecondsAtSeam(clips, 0), Duration.zero);
      expect(hiddenSecondsAtSeam(clips, -1), Duration.zero);
      expect(hiddenSecondsAtSeam(clips, 5), Duration.zero);
    });

    test('empty clips returns Duration.zero', () {
      expect(hiddenSecondsAtSeam(<ClipSlice>[], 0), Duration.zero);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
~/fvm/versions/3.41.5/bin/flutter test test/state/seam_metrics_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:slipreel_engine/state/seam_metrics.dart'`.

- [ ] **Step 3: Implement the helper**

Create `packages/slipreel_engine/lib/state/seam_metrics.dart`:

```dart
import 'package:slipreel_engine/state/clip_slice.dart';

/// Returns the total source-duration "hidden" at the seam between
/// `clips[seamIndex]` and `clips[seamIndex + 1]`. Sums:
///   1. The left slice's right-side trim (cutEnd - trimEnd).
///   2. The right slice's left-side trim (trimStart - cutStart).
///   3. Any source-time gap between the two slices' cut bounds
///      (right.cutStart - left.cutEnd), clamped to non-negative.
///
/// Returns Duration.zero for out-of-range seamIndex or empty clips.
Duration hiddenSecondsAtSeam(List<ClipSlice> clips, int seamIndex) {
  if (seamIndex < 0 || seamIndex >= clips.length - 1) return Duration.zero;
  final left = clips[seamIndex];
  final right = clips[seamIndex + 1];
  final leftTrim = left.cutEnd - left.trimEnd;
  final rightTrim = right.trimStart - right.cutStart;
  final gap = right.cutStart - left.cutEnd;
  final gapClamped = gap.isNegative ? Duration.zero : gap;
  return leftTrim + rightTrim + gapClamped;
}
```

- [ ] **Step 4: Run test to verify it passes**

```
~/fvm/versions/3.41.5/bin/flutter test test/state/seam_metrics_test.dart
```
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/state/seam_metrics.dart packages/slipreel_engine/test/state/seam_metrics_test.dart
git commit -m "feat(engine): hiddenSecondsAtSeam helper for cut-marker badge"
```

---

## Task 2: Engine — clearSeamTrims

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart` (add method after `setSliceTrimEnd`, around line 332)
- Create: `packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

EditorProjectController _controllerWithClips(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return EditorProjectController(
    initial: base.copyWith(
      timeline: base.timeline.copyWith(clips: clips),
    ),
  );
}

ClipSlice _slice({
  required int cs,
  required int ce,
  int? ts,
  int? te,
}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

void main() {
  group('clearSeamTrims', () {
    test('restores both seam trims to their cut bounds', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10, ts: 7),
      ]);
      c.clearSeamTrims(0);
      final clips = c.current.timeline.clips;
      expect(clips[0].trimEnd, const Duration(seconds: 5));
      expect(clips[1].trimStart, const Duration(seconds: 5));
    });

    test('preserves the outer trims (left.trimStart, right.trimEnd)', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, ts: 1, te: 4),
        _slice(cs: 5, ce: 10, ts: 7, te: 9),
      ]);
      c.clearSeamTrims(0);
      final clips = c.current.timeline.clips;
      expect(clips[0].trimStart, const Duration(seconds: 1));
      expect(clips[1].trimEnd, const Duration(seconds: 9));
    });

    test('idempotent when seam already clean', () {
      final initial = [
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ];
      final c = _controllerWithClips(initial);
      final before = c.current;
      c.clearSeamTrims(0);
      expect(identical(c.current, before), true);
    });

    test('does not change clip count', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 5, ce: 10, ts: 7),
        _slice(cs: 10, ce: 15),
      ]);
      c.clearSeamTrims(0);
      expect(c.current.timeline.clips.length, 3);
    });

    test('out-of-range index is a no-op', () {
      final initial = [_slice(cs: 0, ce: 5)];
      final c = _controllerWithClips(initial);
      final before = c.current;
      c.clearSeamTrims(-1);
      c.clearSeamTrims(0);
      c.clearSeamTrims(5);
      expect(identical(c.current, before), true);
    });

    test('non-adjacent source boundary: clears trims but keeps the gap', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, te: 4),
        _slice(cs: 8, ce: 12, ts: 9),
      ]);
      c.clearSeamTrims(0);
      final clips = c.current.timeline.clips;
      expect(clips[0].trimEnd, const Duration(seconds: 5));
      expect(clips[0].cutEnd, const Duration(seconds: 5));
      expect(clips[1].trimStart, const Duration(seconds: 8));
      expect(clips[1].cutStart, const Duration(seconds: 8));
      // Gap still present.
      expect(clips[1].cutStart - clips[0].cutEnd, const Duration(seconds: 3));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine
~/fvm/versions/3.41.5/bin/flutter test test/state/editor_project_controller_seam_test.dart
```
Expected: FAIL — `The method 'clearSeamTrims' isn't defined for the type 'EditorProjectController'`.

- [ ] **Step 3: Add the controller method**

In `packages/slipreel_engine/lib/state/editor_project_controller.dart`, add this method just after `setSliceTrimEnd` (around line 332):

```dart
  /// First-click action for a cut marker: resets the inner trims of
  /// both slices adjacent to the seam at [seamIndex] back to their cut
  /// bounds. Atomic — one state mutation, one undo step.
  ///
  /// Idempotent: if both inner trims are already at their cut bounds,
  /// the state reference is left unchanged.
  void clearSeamTrims(int seamIndex) {
    final clips = state.timeline.clips;
    if (seamIndex < 0 || seamIndex >= clips.length - 1) return;
    final left = clips[seamIndex];
    final right = clips[seamIndex + 1];
    final newLeft = left.trimEnd == left.cutEnd
        ? left
        : left.copyWith(trimEnd: left.cutEnd);
    final newRight = right.trimStart == right.cutStart
        ? right
        : right.copyWith(trimStart: right.cutStart);
    if (identical(newLeft, left) && identical(newRight, right)) return;
    final updated = List<ClipSlice>.from(clips)
      ..[seamIndex] = newLeft
      ..[seamIndex + 1] = newRight;
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

```
~/fvm/versions/3.41.5/bin/flutter test test/state/editor_project_controller_seam_test.dart
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/state/editor_project_controller.dart packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart
git commit -m "feat(engine): clearSeamTrims controller method"
```

---

## Task 3: Engine — mergeSeam

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart` (add method just after `clearSeamTrims`)
- Modify: `packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart` (add a second group)

- [ ] **Step 1: Add failing tests**

In `packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart`, append a second group inside `void main()`:

```dart
  group('mergeSeam', () {
    test('adjacent boundary, no trim: merges into a single slice covering full source', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
      ]);
      c.mergeSeam(0);
      final clips = c.current.timeline.clips;
      expect(clips.length, 1);
      expect(clips[0].cutStart, Duration.zero);
      expect(clips[0].cutEnd, const Duration(seconds: 10));
      expect(clips[0].trimStart, Duration.zero);
      expect(clips[0].trimEnd, const Duration(seconds: 10));
    });

    test('adjacent boundary, with trim: keeps outer trims, drops inner trims', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5, ts: 1, te: 4),
        _slice(cs: 5, ce: 10, ts: 7, te: 9),
      ]);
      c.mergeSeam(0);
      final clips = c.current.timeline.clips;
      expect(clips.length, 1);
      expect(clips[0].cutStart, Duration.zero);
      expect(clips[0].cutEnd, const Duration(seconds: 10));
      expect(clips[0].trimStart, const Duration(seconds: 1));
      expect(clips[0].trimEnd, const Duration(seconds: 9));
    });

    test('non-adjacent source boundary: merged slice covers the gap', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 8, ce: 12),
      ]);
      c.mergeSeam(0);
      final clips = c.current.timeline.clips;
      expect(clips.length, 1);
      expect(clips[0].cutStart, Duration.zero);
      expect(clips[0].cutEnd, const Duration(seconds: 12));
      // Trim bounds clamped to the new cut bounds.
      expect(clips[0].trimStart, Duration.zero);
      expect(clips[0].trimEnd, const Duration(seconds: 12));
    });

    test('reduces clip count by exactly 1', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
        _slice(cs: 10, ce: 15),
      ]);
      c.mergeSeam(0);
      expect(c.current.timeline.clips.length, 2);
    });

    test('preserves the third (untouched) slice verbatim', () {
      final c = _controllerWithClips([
        _slice(cs: 0, ce: 5),
        _slice(cs: 5, ce: 10),
        _slice(cs: 10, ce: 15, ts: 11),
      ]);
      c.mergeSeam(0);
      final last = c.current.timeline.clips.last;
      expect(last.cutStart, const Duration(seconds: 10));
      expect(last.cutEnd, const Duration(seconds: 15));
      expect(last.trimStart, const Duration(seconds: 11));
    });

    test('out-of-range index is a no-op', () {
      final initial = [_slice(cs: 0, ce: 5)];
      final c = _controllerWithClips(initial);
      final before = c.current;
      c.mergeSeam(-1);
      c.mergeSeam(0);
      c.mergeSeam(5);
      expect(identical(c.current, before), true);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

```
~/fvm/versions/3.41.5/bin/flutter test test/state/editor_project_controller_seam_test.dart
```
Expected: FAIL — `The method 'mergeSeam' isn't defined`.

- [ ] **Step 3: Add the controller method**

In `packages/slipreel_engine/lib/state/editor_project_controller.dart`, add this method just after `clearSeamTrims`:

```dart
  /// Second-click action for a cut marker: fuses the two slices
  /// adjacent to the seam at [seamIndex] into a single slice covering
  /// the full source range from `left.cutStart` to `right.cutEnd`. The
  /// outer trim bounds (left.trimStart, right.trimEnd) are preserved
  /// where possible — `ClipSlice`'s constructor clamps them into the
  /// new cut span if a non-adjacent source boundary pulls them out of
  /// range. Atomic — one state mutation, one undo step.
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
      playbackSpeed: left.playbackSpeed,
      fadeIn: left.fadeIn,
      fadeOut: right.fadeOut,
      micGainPercent: left.micGainPercent,
      micMuted: left.micMuted,
      systemGainPercent: left.systemGainPercent,
      systemMuted: left.systemMuted,
      hideCursor: left.hideCursor,
      disableSmoothMouse: left.disableSmoothMouse,
    );
    final updated = List<ClipSlice>.from(clips)
      ..[seamIndex] = merged
      ..removeAt(seamIndex + 1);
    state = state.copyWith(
      timeline: state.timeline.copyWith(clips: updated),
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

```
~/fvm/versions/3.41.5/bin/flutter test test/state/editor_project_controller_seam_test.dart
```
Expected: PASS (all 12 tests across the two groups).

- [ ] **Step 5: Full engine test sweep — confirm no regressions**

```
~/fvm/versions/3.41.5/bin/flutter test
```
Expected: PASS (everything green).

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/lib/state/editor_project_controller.dart packages/slipreel_engine/test/state/editor_project_controller_seam_test.dart
git commit -m "feat(engine): mergeSeam controller method"
```

---

## Task 4: UI — CutMarker widget (visual + tap)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/timeline/cut_marker.dart`
- Create: `packages/screen_recorder/test/ui/widgets/timeline/cut_marker_test.dart`

- [ ] **Step 1: Write the failing widget tests**

Create `packages/screen_recorder/test/ui/widgets/timeline/cut_marker_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';

Widget _harness(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('CutMarker', () {
    testWidgets('compact state: no label when hiddenSeconds is zero',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(hiddenSeconds: Duration.zero, onTap: () {}),
      ));
      expect(find.byKey(const ValueKey('cut-marker-label')), findsNothing);
      expect(find.byKey(const ValueKey('cut-marker-scissors')), findsOneWidget);
    });

    testWidgets('labeled state: label shows X.Xs when hiddenSeconds > 0',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
            hiddenSeconds: const Duration(milliseconds: 1000),
            onTap: () {}),
      ));
      expect(find.text('1.0s'), findsOneWidget);
      expect(find.byKey(const ValueKey('cut-marker-scissors')), findsOneWidget);
    });

    testWidgets('label formats sub-second values with 1 decimal',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
            hiddenSeconds: const Duration(milliseconds: 250),
            onTap: () {}),
      ));
      expect(find.text('0.3s'), findsOneWidget);
    });

    testWidgets('label formats multi-second values with 1 decimal',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
            hiddenSeconds: const Duration(milliseconds: 12400),
            onTap: () {}),
      ));
      expect(find.text('12.4s'), findsOneWidget);
    });

    testWidgets('tap fires onTap callback', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_harness(
        CutMarker(hiddenSeconds: Duration.zero, onTap: () => tapped++),
      ));
      await tester.tap(find.byKey(const ValueKey('cut-marker-hit')));
      expect(tapped, 1);
    });

    testWidgets('dragFade collapses the marker opacity',
        (tester) async {
      await tester.pumpWidget(_harness(
        CutMarker(
          hiddenSeconds: Duration.zero,
          onTap: () {},
          dragFade: true,
        ),
      ));
      await tester.pumpAndSettle();
      final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('cut-marker-fade')),
      );
      expect(opacity.opacity, lessThan(0.5));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/cut_marker_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart'`.

- [ ] **Step 3: Create the CutMarker widget**

Create `packages/screen_recorder/lib/ui/widgets/timeline/cut_marker.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Pin marker that hangs above a seam between two adjacent slices on
/// the clip lane.
///
/// Two visual states, driven by [hiddenSeconds]:
///   - `Duration.zero` → compact pin with just the scissors icon.
///   - `> Duration.zero` → wider pin with a leading "X.Xs" label.
///
/// Tap fires [onTap]. The parent (`ClipLane`) chooses what the tap
/// means based on the hidden-seconds value at the seam: > 0 → clear
/// seam trims; == 0 → merge the two slices.
///
/// [dragFade] is true while any trim handle in the lane is being
/// dragged; the marker fades out so the seam region stays visually
/// uncluttered during the drag.
class CutMarker extends StatelessWidget {
  const CutMarker({
    super.key,
    required this.hiddenSeconds,
    required this.onTap,
    this.dragFade = false,
  });

  final Duration hiddenSeconds;
  final VoidCallback onTap;
  final bool dragFade;

  static const double kHitWidth = 64;
  static const double kHitHeight = 36;
  static const double kBodyHeight = 22;
  static const double kTipHeight = 6;
  static const double kHangAbove = 10;
  // y to pass to a Positioned wrapper so the tip point sits exactly
  // kHangAbove px above the parent's top edge. Derived from the body
  // and tip heights plus the vertical centering padding inside the
  // fixed-size hit box (kHitHeight - kBodyHeight - kTipHeight) / 2.
  // = -(10 + 22 + 6 + (36-22-6)/2) = -42.
  static const double kPositionedTop = -42;
  static const Color _fill = clipFill;
  static const Color _border = Color(0xFFFFFFFF);
  static const Color _shadow = Color(0x66000000);
  static const Duration _fadeDuration = Duration(milliseconds: 180);

  bool get _showLabel => hiddenSeconds > Duration.zero;

  String _formatLabel() {
    final s = hiddenSeconds.inMilliseconds / 1000.0;
    return '${s.toStringAsFixed(1)}s';
  }

  String _tooltipText() {
    if (_showLabel) return 'Restore ${_formatLabel()} of trimmed content';
    return 'Remove cut';
  }

  @override
  Widget build(BuildContext context) {
    final body = Container(
      height: kBodyHeight,
      padding: EdgeInsets.symmetric(horizontal: _showLabel ? 8 : 4),
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(kBodyHeight / 2),
        border: Border.all(color: _border, width: 1),
        boxShadow: const [
          BoxShadow(
            color: _shadow,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showLabel)
            Padding(
              key: const ValueKey('cut-marker-label'),
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                _formatLabel(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
            ),
          const Icon(
            Icons.content_cut,
            key: ValueKey('cut-marker-scissors'),
            color: Colors.white,
            size: 12,
          ),
        ],
      ),
    );

    final pin = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        SizedBox(
          height: kTipHeight,
          width: 8,
          child: CustomPaint(
            painter: const _PinTipPainter(fill: _fill, border: _border),
          ),
        ),
      ],
    );

    return AnimatedOpacity(
      key: const ValueKey('cut-marker-fade'),
      duration: _fadeDuration,
      curve: Curves.easeOut,
      opacity: dragFade ? 0.2 : 1.0,
      child: Tooltip(
        message: _tooltipText(),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('cut-marker-hit'),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox(
              width: kHitWidth,
              height: kHitHeight,
              child: Center(child: pin),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinTipPainter extends CustomPainter {
  const _PinTipPainter({required this.fill, required this.border});

  final Color fill;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _PinTipPainter old) =>
      old.fill != fill || old.border != border;
}
```

- [ ] **Step 4: Run test to verify it passes**

```
~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/cut_marker_test.dart
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/widgets/timeline/cut_marker.dart packages/screen_recorder/test/ui/widgets/timeline/cut_marker_test.dart
git commit -m "feat(app): CutMarker widget (pin + label + tip)"
```

---

## Task 5: UI — ClipLane integration

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart`
- Create: `packages/screen_recorder/test/ui/widgets/timeline/clip_lane_cut_markers_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `packages/screen_recorder/test/ui/widgets/timeline/clip_lane_cut_markers_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/clip_lane.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';

ClipSlice _slice({int cs = 0, int ce = 10, int? ts, int? te}) =>
    ClipSlice(
      cutStart: Duration(seconds: cs),
      cutEnd: Duration(seconds: ce),
      trimStart: ts == null ? null : Duration(seconds: ts),
      trimEnd: te == null ? null : Duration(seconds: te),
    );

Widget _harness(ClipLane lane) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 800, height: 60, child: lane),
      ),
    );

void main() {
  group('ClipLane cut markers', () {
    testWidgets('renders N-1 markers for N clips', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
          _slice(cs: 10, ce: 15),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.byType(CutMarker), findsNWidgets(2));
    });

    testWidgets('no markers when only one clip', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [_slice(cs: 0, ce: 5)],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.byType(CutMarker), findsNothing);
    });

    testWidgets('marker shows X.Xs label when seam has trim', (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5, te: 4),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.text('1.0s'), findsOneWidget);
    });

    testWidgets('marker compact (no label) when seam has no trim',
        (tester) async {
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (_) {},
        onMergeSeam: (_) {},
      )));
      expect(find.text('1.0s'), findsNothing);
      expect(find.byType(CutMarker), findsOneWidget);
    });

    testWidgets('tap on marker with trim fires onClearSeamTrims', (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5, te: 4),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
      )));
      await tester.tap(find.byType(CutMarker));
      expect(clearedSeam, 0);
      expect(mergedSeam, null);
    });

    testWidgets('tap on marker without trim fires onMergeSeam', (tester) async {
      int? clearedSeam;
      int? mergedSeam;
      await tester.pumpWidget(_harness(ClipLane(
        clips: [
          _slice(cs: 0, ce: 5),
          _slice(cs: 5, ce: 10),
        ],
        selectedSliceIndex: null,
        pixelsPerSecond: 50,
        onSliceSelected: (_) {},
        onSliceTrimStartChanged: (_, __) {},
        onSliceTrimEndChanged: (_, __) {},
        onClearSeamTrims: (i) => clearedSeam = i,
        onMergeSeam: (i) => mergedSeam = i,
      )));
      await tester.tap(find.byType(CutMarker));
      expect(clearedSeam, null);
      expect(mergedSeam, 0);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/clip_lane_cut_markers_test.dart
```
Expected: FAIL — `The named parameter 'onClearSeamTrims' isn't defined`.

- [ ] **Step 3: Extend ClipLane**

Edit `packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart`.

Add the two new imports and the helper at the top of the file:

```dart
import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/seam_metrics.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart';
```

In the `ClipLane` class, add two new required callbacks (alongside the existing trim ones):

```dart
class ClipLane extends StatefulWidget {
  const ClipLane({
    super.key,
    required this.clips,
    required this.selectedSliceIndex,
    required this.pixelsPerSecond,
    required this.onSliceSelected,
    required this.onSliceTrimStartChanged,
    required this.onSliceTrimEndChanged,
    required this.onClearSeamTrims,
    required this.onMergeSeam,
    this.onTrimDragChanged,
  });

  final List<ClipSlice> clips;
  final int? selectedSliceIndex;
  final double pixelsPerSecond;
  final ValueChanged<int?> onSliceSelected;
  final void Function(int sliceIndex, Duration trimStart) onSliceTrimStartChanged;
  final void Function(int sliceIndex, Duration trimEnd) onSliceTrimEndChanged;
  final ValueChanged<int> onClearSeamTrims;
  final ValueChanged<int> onMergeSeam;
  final ValueChanged<bool>? onTrimDragChanged;

  @override
  State<ClipLane> createState() => _ClipLaneState();
}
```

Append a third pass to the Stack inside `build()` (just before the closing `],` of `children:`):

```dart
        // Pass 3: cut markers per seam. Marker i sits above the seam
        // between clips[i] and clips[i+1]. Hidden-seconds drives the
        // compact-vs-labeled visual; tap routes through to
        // clearSeamTrims (label > 0) or mergeSeam (== 0).
        for (var i = 0; i < widget.clips.length - 1; i++)
          _buildCutMarker(i, editedStarts),
```

And add the helper method on `_ClipLaneState` just below `_buildSlice`:

```dart
  Widget _buildCutMarker(int seamIndex, List<Duration> editedStarts) {
    final seamX = editedStarts[seamIndex + 1].inMilliseconds /
        1000.0 *
        widget.pixelsPerSecond;
    final hidden = hiddenSecondsAtSeam(widget.clips, seamIndex);
    return Positioned(
      key: ValueKey('clip-lane-cut-marker-$seamIndex'),
      left: seamX - CutMarker.kHitWidth / 2,
      top: CutMarker.kPositionedTop,
      width: CutMarker.kHitWidth,
      height: CutMarker.kHitHeight,
      child: CutMarker(
        hiddenSeconds: hidden,
        dragFade: _draggingIndex != null,
        onTap: () {
          if (hidden > Duration.zero) {
            widget.onClearSeamTrims(seamIndex);
          } else {
            widget.onMergeSeam(seamIndex);
          }
        },
      ),
    );
  }
```

- [ ] **Step 4: Run the new test to verify it passes**

```
~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/clip_lane_cut_markers_test.dart
```
Expected: PASS (6 tests).

- [ ] **Step 5: Run the existing `clip_lane_multi_slice_test.dart` — confirm not broken**

```
~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/clip_lane_multi_slice_test.dart
```
Expected: FAIL — every existing call to `ClipLane(...)` in that file is missing the new required `onClearSeamTrims` and `onMergeSeam` callbacks.

- [ ] **Step 6: Update the existing test to pass the new callbacks**

In `packages/screen_recorder/test/ui/widgets/timeline/clip_lane_multi_slice_test.dart`, every `ClipLane(...)` constructor call needs two added named arguments:

```dart
onClearSeamTrims: (_) {},
onMergeSeam: (_) {},
```

Add them to all 6 `ClipLane(...)` calls in that file (one per `testWidgets`).

- [ ] **Step 7: Run the existing test to verify it passes now**

```
~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/clip_lane_multi_slice_test.dart
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart packages/screen_recorder/test/ui/widgets/timeline/clip_lane_cut_markers_test.dart packages/screen_recorder/test/ui/widgets/timeline/clip_lane_multi_slice_test.dart
git commit -m "feat(app): mount CutMarker per seam in ClipLane"
```

---

## Task 6: UI — EditorTimeline plumb-through

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`

- [ ] **Step 1: Add the new callback props on EditorTimeline**

In `editor_timeline.dart`, add to `EditorTimeline`'s constructor (alongside `onSliceTrimEndChanged`):

```dart
    this.onClearSeamTrims,
    this.onMergeSeam,
```

And as fields (alongside `onSliceTrimEndChanged`):

```dart
  final ValueChanged<int>? onClearSeamTrims;
  final ValueChanged<int>? onMergeSeam;
```

- [ ] **Step 2: Pass them through to ClipLane**

In `editor_timeline.dart`, find the `ClipLane(...)` call (~line 645) and add:

```dart
                                ClipLane(
                                  clips: widget.clips,
                                  selectedSliceIndex:
                                      widget.selectedSliceIndex,
                                  pixelsPerSecond: pps,
                                  onSliceSelected: (i) =>
                                      widget.onSliceSelected?.call(i),
                                  onSliceTrimStartChanged: (i, v) =>
                                      widget.onSliceTrimStartChanged
                                          ?.call(i, v),
                                  onSliceTrimEndChanged: (i, v) =>
                                      widget.onSliceTrimEndChanged
                                          ?.call(i, v),
                                  onClearSeamTrims: (i) =>
                                      widget.onClearSeamTrims?.call(i),
                                  onMergeSeam: (i) =>
                                      widget.onMergeSeam?.call(i),
                                  onTrimDragChanged: (active) {
                                    if (_trimDragging != active) {
                                      setState(
                                          () => _trimDragging = active);
                                    }
                                  },
                                ),
```

- [ ] **Step 3: Run the full screen_recorder test suite — confirm no regressions**

```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
~/fvm/versions/3.41.5/bin/flutter test
```
Expected: PASS (the pre-existing `test/debug/debug_probe_test.dart::NoopDebugProbe` failure can be ignored per project convention). Any other failures must be addressed before continuing.

- [ ] **Step 4: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart
git commit -m "feat(app): plumb cut-marker callbacks through EditorTimeline"
```

---

## Task 7: UI — playback_screen wiring + selection bookkeeping

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

- [ ] **Step 1: Add the two new handlers near the existing slice handlers (~line 1945)**

In `playback_screen.dart`, find the `EditorTimeline(...)` constructor call. Adjacent to `onSliceTrimEndChanged`, add:

```dart
                onClearSeamTrims: (seamIndex) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .clearSeamTrims(seamIndex),
                onMergeSeam: (seamIndex) {
                  // Adjust selection BEFORE merging, while indices still
                  // reflect the pre-merge clip list:
                  //  - selection == seamIndex + 1 → moves to seamIndex
                  //    (the merged slice keeps the left index).
                  //  - selection > seamIndex + 1 → shifts left by 1.
                  //  - selection == seamIndex → unchanged.
                  //  - selection < seamIndex or null → unchanged.
                  setState(() {
                    final sel = _selectedSliceIndex;
                    if (sel != null) {
                      if (sel == seamIndex + 1) {
                        _selectedSliceIndex = seamIndex;
                      } else if (sel > seamIndex + 1) {
                        _selectedSliceIndex = sel - 1;
                      }
                    }
                  });
                  ref
                      .read(editorProjectControllerProvider.notifier)
                      .mergeSeam(seamIndex);
                },
```

- [ ] **Step 2: Build the screen_recorder package to confirm it compiles**

```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
~/fvm/versions/3.41.5/bin/flutter analyze lib/ui/screens/playback_screen.dart
```
Expected: no errors.

- [ ] **Step 3: Run the screen_recorder test suite — confirm no regressions**

```
~/fvm/versions/3.41.5/bin/flutter test
```
Expected: PASS (pre-existing debug_probe failure ignored).

- [ ] **Step 4: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): wire cut-marker callbacks in PlaybackScreen + selection bookkeeping"
```

---

## Task 8: Manual verification on the running app

**Note:** `flutter build macos` is broken here (arm64 destination). Use the existing dev workflow — `flutter run` or hot reload an already-running session via flutter-qa MCP tools.

- [ ] **Step 1: Launch (or hot-reload) the app**

Either start a fresh session:
```
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
~/fvm/versions/3.41.5/bin/flutter run -d macos
```

Or, if a session is already running, hot-reload via the flutter-qa MCP `hot_reload` tool.

- [ ] **Step 2: Record a short clip and open it in the editor**

Use the existing recording flow to get a clip into the editor with at least 5 seconds of content.

- [ ] **Step 3: Verify markers — no cuts**

Single slice → no `CutMarker` visible above the clip lane.

- [ ] **Step 4: Verify markers — one cut, no trim**

Use the cut tool to split the slice once. Expected: one compact `CutMarker` (just scissors, no label) appears above the seam.

- [ ] **Step 5: Verify markers — labeled state**

Trim one side at the seam (drag the right edge of slice 1 inward by ~1 second). Expected: marker widens, label reads `1.0s`.

- [ ] **Step 6: Verify first-click action**

Click the marker. Expected: the trim collapses (slice 1's right edge returns to its cut bound), the marker reverts to compact form (no label).

- [ ] **Step 7: Verify second-click action**

Click the (now compact) marker again. Expected: the two slices merge into one. No marker remains. Edited duration unchanged from "after first click" (no content lost).

- [ ] **Step 8: Verify drag fade**

Make another cut and trim it. Start dragging a trim handle anywhere in the lane. Expected: all visible markers fade to ~20% opacity while the drag is active; fade back in when the drag ends.

- [ ] **Step 9: Verify Cmd+Z undo**

After a merge, press Cmd+Z. Expected: the two slices come back. Press Cmd+Z again. Expected: the seam's trims come back too.

- [ ] **Step 10: Commit (only if behavior tweaks were made)**

If no code changes were needed during manual verification, skip. Otherwise commit per the existing conventions.

---

## Self-review notes

- Engine-level math (Task 1) and controller methods (Tasks 2–3) cover the spec's "Engine" section.
- Widget visual + states (Task 4) cover the spec's "UX" section (compact vs labeled, tap, fade).
- ClipLane integration (Task 5) covers "where the marker lives" (third pass, scrolls with content).
- EditorTimeline (Task 6) and PlaybackScreen (Task 7) cover the spec's "Selection bookkeeping after merge" rule.
- All YAGNI exclusions from the spec (no batch remove, no marker stagger, no right-click menu, no animation when a cut is created) remain absent.
- No placeholders: every step has the exact code, file path, or command needed.
