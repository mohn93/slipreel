# Cut-tool Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add snap-on-cut (Cmd+K and scissors-mode pull to nearby click events + zoom-region edges within 150ms) and slice keyboard navigation (`Option+]` / `Option+[`) to the editor.

**Architecture:** Two independent additions. Snap = a pure `SnapResolver` helper + a `SharedPreferences`-backed `SnapPreferenceController` (Store + Controller pattern, override in `main.dart`) + a flash overlay + call-site integration in `PlaybackScreen._onKey` and `CutOverlay`. Keyboard nav = two pure helpers (`nextSliceIndex`, `sliceEditedStart`) + a small block in `PlaybackScreen._onKey`. Spec: `docs/superpowers/specs/2026-06-03-cut-tool-followups-design.md`.

**Tech Stack:** Flutter 3.41.5 (FVM), Dart 3, Riverpod 2 (`StateNotifier`), `shared_preferences`, `flutter_test`.

**Conventions used throughout this plan:**
- All `fvm flutter` invocations use the project's pinned binary at `~/fvm/versions/3.41.5/bin/flutter`.
- All test commands are run **from inside the package directory** (monorepo). The plan shows the `cd` in each test step.
- Use `git add <specific paths>` — never `git add .` or `-A`.
- No `--no-verify`, no `--amend` (always new commits, even after hook failure).

---

## Task 0: Branch + sanity baseline

**Files:** none (git only)

- [ ] **Step 1: Create feature branch**

```bash
git checkout main
git pull
git checkout -b feat/cut-tool-followups
```

- [ ] **Step 2: Verify baseline tests pass before adding any code**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test
cd ../screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
cd ../..
```

Expected: both suites green. If anything fails on `main` baseline, stop and report — the plan assumes a green starting point.

---

## Task 1: SnapResolver pure helper

Self-contained pure function with sorted-candidates binary search + radius check.

**Files:**
- Create: `packages/slipreel_engine/lib/snap/snap_resolver.dart`
- Test: `packages/slipreel_engine/test/snap/snap_resolver_test.dart`

- [ ] **Step 1: Write the failing test file**

```dart
// packages/slipreel_engine/test/snap/snap_resolver_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/snap/snap_resolver.dart';

void main() {
  Duration ms(int n) => Duration(milliseconds: n);

  group('resolveSnap', () {
    test('empty candidates returns requested time with no snap', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: const []);
      expect(r.time, ms(1000));
      expect(r.snappedFrom, isNull);
    });

    test('exact-hit candidate snaps with snappedFrom == requestedTime', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1000)]);
      expect(r.time, ms(1000));
      expect(r.snappedFrom, ms(1000));
    });

    test('candidate inside radius snaps (149ms away)', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1149)]);
      expect(r.time, ms(1149));
      expect(r.snappedFrom, ms(1149));
    });

    test('candidate exactly at radius (150ms) snaps (<= semantics)', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1150)]);
      expect(r.time, ms(1150));
      expect(r.snappedFrom, ms(1150));
    });

    test('candidate just outside radius (151ms) does not snap', () {
      final r = resolveSnap(requestedTime: ms(1000), candidates: [ms(1151)]);
      expect(r.time, ms(1000));
      expect(r.snappedFrom, isNull);
    });

    test('equidistant ties go to the earlier candidate', () {
      final r = resolveSnap(
        requestedTime: ms(1000),
        candidates: [ms(900), ms(1100)],
      );
      expect(r.time, ms(900));
      expect(r.snappedFrom, ms(900));
    });

    test('picks the nearest of many candidates', () {
      final r = resolveSnap(
        requestedTime: ms(1000),
        candidates: [ms(500), ms(900), ms(1050), ms(2000)],
      );
      expect(r.time, ms(1050));
      expect(r.snappedFrom, ms(1050));
    });

    test('requestedTime before all candidates checks only the first', () {
      final r = resolveSnap(
        requestedTime: ms(10),
        candidates: [ms(50), ms(500), ms(2000)],
      );
      expect(r.time, ms(50));
      expect(r.snappedFrom, ms(50));
    });

    test('requestedTime after all candidates checks only the last', () {
      final r = resolveSnap(
        requestedTime: ms(5000),
        candidates: [ms(100), ms(500), ms(4900)],
      );
      expect(r.time, ms(4900));
      expect(r.snappedFrom, ms(4900));
    });

    test('preserves microsecond precision', () {
      final t = const Duration(microseconds: 1234567);
      final r = resolveSnap(requestedTime: t, candidates: [t]);
      expect(r.time, t);
      expect(r.snappedFrom, t);
    });

    test('custom radius is respected', () {
      // 80ms radius: 100ms candidate is outside, no snap.
      final r = resolveSnap(
        requestedTime: ms(1000),
        candidates: [ms(1100)],
        radius: ms(80),
      );
      expect(r.time, ms(1000));
      expect(r.snappedFrom, isNull);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/snap/snap_resolver_test.dart
```

Expected: compilation error — `snap_resolver.dart` does not exist.

- [ ] **Step 3: Implement SnapResolver**

```dart
// packages/slipreel_engine/lib/snap/snap_resolver.dart

/// Outcome of [resolveSnap].
class SnapResult {
  const SnapResult(this.time, this.snappedFrom);

  /// The chosen cut time — either the original requested time
  /// (no snap) or a candidate from the input list (snapped).
  final Duration time;

  /// The candidate the cut snapped to, or null if no snap occurred.
  /// When equal to [time] AND non-null, the snap landed exactly on
  /// the candidate (informational; the UI uses this for the flash
  /// regardless of whether the candidate equals the request).
  final Duration? snappedFrom;
}

const Duration kDefaultSnapRadius = Duration(milliseconds: 150);

/// Returns the snap decision for a cut at [requestedTime].
///
/// [candidates] MUST be sorted ascending. Behavior is undefined if not.
/// Picks the closest candidate within [radius] of [requestedTime].
/// On ties, the earlier candidate wins.
SnapResult resolveSnap({
  required Duration requestedTime,
  required List<Duration> candidates,
  Duration radius = kDefaultSnapRadius,
}) {
  if (candidates.isEmpty) return SnapResult(requestedTime, null);

  // Floor-style binary search: largest index i with candidates[i] <= requestedTime,
  // or -1 if requestedTime is below all candidates.
  final target = requestedTime.inMicroseconds;
  int lo = 0;
  int hi = candidates.length - 1;
  int floor = -1;
  if (candidates.first.inMicroseconds <= target) {
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (candidates[mid].inMicroseconds <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    floor = lo;
  }
  final ceil = floor + 1; // may be == candidates.length

  Duration? best;
  int bestDist = 1 << 62;
  // Check floor neighbor.
  if (floor >= 0) {
    final c = candidates[floor];
    final d = target - c.inMicroseconds; // >= 0
    if (d < bestDist) {
      bestDist = d;
      best = c;
    }
  }
  // Check ceil neighbor; on equidistant tie the earlier (floor) wins, so use < not <=.
  if (ceil < candidates.length) {
    final c = candidates[ceil];
    final d = c.inMicroseconds - target; // > 0
    if (d < bestDist) {
      bestDist = d;
      best = c;
    }
  }

  if (best == null || bestDist > radius.inMicroseconds) {
    return SnapResult(requestedTime, null);
  }
  return SnapResult(best, best);
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/snap/snap_resolver_test.dart
```

Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/snap/snap_resolver.dart \
        packages/slipreel_engine/test/snap/snap_resolver_test.dart
git commit -m "feat(engine): add SnapResolver for cut-time snapping"
```

---

## Task 2: Expose cursor click times for snap candidate building

`CursorEventIndex._clickMicros` is private. Snap needs a sorted `List<Duration>` of click timestamps to feed `resolveSnap`. Add a public read-only accessor + a top-level helper that converts to `Duration`s.

**Files:**
- Modify: `packages/slipreel_engine/lib/models/cursor_recording.dart` (add `clickTimes` getter to `CursorEventIndex`)
- Test: `packages/slipreel_engine/test/models/cursor_event_index_click_times_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/cursor_event_index_click_times_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

void main() {
  group('CursorEventIndex.clickTimes', () {
    test('empty recording returns empty list', () {
      final rec = CursorRecording();
      expect(rec.eventIndex.clickTimes, isEmpty);
    });

    test('extracts press rising edges in source-time microseconds order', () {
      final rec = CursorRecording();
      // false -> true at 1s = press
      rec.addPosition(const CursorPosition(
        timestampMicros: 0, x: 0, y: 0, isClicked: false,
      ));
      rec.addPosition(const CursorPosition(
        timestampMicros: 1000000, x: 0, y: 0, isClicked: true,
      ));
      // true -> false at 2s = release (NOT a click time)
      rec.addPosition(const CursorPosition(
        timestampMicros: 2000000, x: 0, y: 0, isClicked: false,
      ));
      // false -> true at 3s = another press
      rec.addPosition(const CursorPosition(
        timestampMicros: 3000000, x: 0, y: 0, isClicked: true,
      ));

      expect(rec.eventIndex.clickTimes, [
        const Duration(seconds: 1),
        const Duration(seconds: 3),
      ]);
    });

    test('returned list is unmodifiable', () {
      final rec = CursorRecording();
      rec.addPosition(const CursorPosition(timestampMicros: 0, x: 0, y: 0, isClicked: false));
      rec.addPosition(const CursorPosition(timestampMicros: 1000000, x: 0, y: 0, isClicked: true));
      expect(
        () => rec.eventIndex.clickTimes.add(Duration.zero),
        throwsUnsupportedError,
      );
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/models/cursor_event_index_click_times_test.dart
```

Expected: compilation error — `clickTimes` getter does not exist on `CursorEventIndex`.

- [ ] **Step 3: Add the `clickTimes` getter**

Open `packages/slipreel_engine/lib/models/cursor_recording.dart`. Inside the `CursorEventIndex` class (just before the closing brace at line 252), add:

```dart
  /// All click (press rising edge) timestamps from the recording,
  /// in source-time, sorted ascending. Returned list is unmodifiable.
  /// Cheap to call repeatedly — wraps the underlying cache.
  List<Duration> get clickTimes => List<Duration>.unmodifiable(
        _clickMicros.map((m) => Duration(microseconds: m)),
      );
```

(`addPosition` is the canonical seeding API on `CursorRecording`; `CursorPosition` lives in the `screen_recorder_platform_interface` package, which `slipreel_engine` already depends on.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/models/cursor_event_index_click_times_test.dart
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/cursor_recording.dart \
        packages/slipreel_engine/test/models/cursor_event_index_click_times_test.dart
git commit -m "feat(engine): expose CursorEventIndex.clickTimes for snap candidates"
```

---

## Task 3: Slice navigation pure helpers

`nextSliceIndex` + `sliceEditedStart`. Pure, no Flutter imports.

**Files:**
- Create: `packages/slipreel_engine/lib/timeline/slice_navigation.dart`
- Test: `packages/slipreel_engine/test/timeline/slice_navigation_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/timeline/slice_navigation_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart';

void main() {
  ClipSlice slice({
    required int startMs,
    required int endMs,
    double speed = 1.0,
  }) =>
      ClipSlice(
        cutStart: Duration(milliseconds: startMs),
        cutEnd: Duration(milliseconds: endMs),
        playbackSpeed: speed,
      );

  group('nextSliceIndex', () {
    test('empty list returns -1 regardless of direction', () {
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 0, direction: NavDirection.next),
        -1,
      );
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 0, direction: NavDirection.previous),
        -1,
      );
    });

    test('from no-selection, next jumps to slice 0', () {
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 5, direction: NavDirection.next),
        0,
      );
    });

    test('from no-selection, previous jumps to last slice', () {
      expect(
        nextSliceIndex(currentIndex: -1, sliceCount: 5, direction: NavDirection.previous),
        4,
      );
    });

    test('mid-list advances by one in either direction', () {
      expect(
        nextSliceIndex(currentIndex: 2, sliceCount: 5, direction: NavDirection.next),
        3,
      );
      expect(
        nextSliceIndex(currentIndex: 2, sliceCount: 5, direction: NavDirection.previous),
        1,
      );
    });

    test('at last index, next returns the same index (stop at boundary)', () {
      expect(
        nextSliceIndex(currentIndex: 4, sliceCount: 5, direction: NavDirection.next),
        4,
      );
    });

    test('at first index, previous returns the same index (stop at boundary)', () {
      expect(
        nextSliceIndex(currentIndex: 0, sliceCount: 5, direction: NavDirection.previous),
        0,
      );
    });
  });

  group('sliceEditedStart', () {
    test('index 0 returns Duration.zero', () {
      final clips = [slice(startMs: 0, endMs: 1000)];
      expect(sliceEditedStart(clips, 0), Duration.zero);
    });

    test('sums editedLengths of preceding slices', () {
      final clips = [
        slice(startMs: 0, endMs: 1000),    // editedLength = 1000ms @ 1.0x
        slice(startMs: 1000, endMs: 3000), // editedLength = 2000ms @ 1.0x
        slice(startMs: 3000, endMs: 4000), // editedLength = 1000ms @ 1.0x
      ];
      expect(sliceEditedStart(clips, 0), Duration.zero);
      expect(sliceEditedStart(clips, 1), const Duration(milliseconds: 1000));
      expect(sliceEditedStart(clips, 2), const Duration(milliseconds: 3000));
    });

    test('accounts for per-slice playback speed', () {
      final clips = [
        slice(startMs: 0, endMs: 3000, speed: 1.5),
        slice(startMs: 3000, endMs: 5000),
      ];
      // First slice: 3000ms / 1.5 = 2000ms edited.
      expect(sliceEditedStart(clips, 1), const Duration(milliseconds: 2000));
    });

    test('throws RangeError on out-of-bounds index', () {
      final clips = [slice(startMs: 0, endMs: 1000)];
      expect(() => sliceEditedStart(clips, -1), throwsRangeError);
      expect(() => sliceEditedStart(clips, 1), throwsRangeError);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/timeline/slice_navigation_test.dart
```

Expected: compilation error — `slice_navigation.dart` does not exist.

- [ ] **Step 3: Implement the helpers**

```dart
// packages/slipreel_engine/lib/timeline/slice_navigation.dart
import 'package:slipreel_engine/state/clip_slice.dart';

/// Direction of slice keyboard navigation.
enum NavDirection { next, previous }

/// Returns the next slice index for keyboard navigation.
///
/// - [currentIndex] < 0 means "no selection":
///     [NavDirection.next] -> 0
///     [NavDirection.previous] -> sliceCount - 1
/// - At a boundary (last + next, or first + previous) the [currentIndex]
///   is returned unchanged so the caller can render no-op feedback.
/// - Empty list returns -1.
int nextSliceIndex({
  required int currentIndex,
  required int sliceCount,
  required NavDirection direction,
}) {
  if (sliceCount <= 0) return -1;
  if (currentIndex < 0) {
    return direction == NavDirection.next ? 0 : sliceCount - 1;
  }
  if (direction == NavDirection.next) {
    return currentIndex >= sliceCount - 1 ? currentIndex : currentIndex + 1;
  }
  return currentIndex <= 0 ? currentIndex : currentIndex - 1;
}

/// Returns the edited-time start of the slice at [index] — the sum of
/// `editedLength` for all preceding slices.
///
/// Throws [RangeError] if [index] is out of bounds.
Duration sliceEditedStart(List<ClipSlice> clips, int index) {
  RangeError.checkValidIndex(index, clips);
  var acc = Duration.zero;
  for (var i = 0; i < index; i++) {
    acc += clips[i].editedLength;
  }
  return acc;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/timeline/slice_navigation_test.dart
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/timeline/slice_navigation.dart \
        packages/slipreel_engine/test/timeline/slice_navigation_test.dart
git commit -m "feat(engine): add nextSliceIndex + sliceEditedStart helpers"
```

---

## Task 4: SnapPreferenceStore

`SharedPreferences`-backed persistence. Mirrors `AppPaletteStore.resolveDefault()` pattern.

**Files:**
- Create: `packages/screen_recorder/lib/state/snap_preference_store.dart`
- Test: `packages/screen_recorder/test/state/snap_preference_store_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/snap_preference_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/state/snap_preference_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SnapPreferenceStore', () {
    test('load() defaults to true when no value is stored', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      expect(store.load(), isTrue);
    });

    test('load() returns the stored value when present', () async {
      SharedPreferences.setMockInitialValues({'slipreel.snap_enabled': false});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      expect(store.load(), isFalse);
    });

    test('save(false) persists; subsequent load() returns false', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      await store.save(false);
      expect(store.load(), isFalse);
    });

    test('save(true) round-trips after save(false)', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SnapPreferenceStore(await SharedPreferences.getInstance());
      await store.save(false);
      await store.save(true);
      expect(store.load(), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/snap_preference_store_test.dart
```

Expected: compilation error — `snap_preference_store.dart` does not exist.

- [ ] **Step 3: Implement the store**

```dart
// packages/screen_recorder/lib/state/snap_preference_store.dart
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences-backed persistence for the snap-on-cut toggle.
/// Per-user (not per-project) — the toggle persists across recordings.
class SnapPreferenceStore {
  SnapPreferenceStore(this._prefs);

  static const _key = 'slipreel.snap_enabled';

  final SharedPreferences _prefs;

  /// Construct from a freshly-loaded SharedPreferences instance. Used
  /// by the main.dart bootstrap to mirror [AppPaletteStore.resolveDefault].
  static Future<SnapPreferenceStore> resolveDefault() async {
    final prefs = await SharedPreferences.getInstance();
    return SnapPreferenceStore(prefs);
  }

  /// Defaults to true when no value is stored.
  bool load() => _prefs.getBool(_key) ?? true;

  Future<void> save(bool enabled) => _prefs.setBool(_key, enabled);
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/snap_preference_store_test.dart
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/snap_preference_store.dart \
        packages/screen_recorder/test/state/snap_preference_store_test.dart
git commit -m "feat(app): add SnapPreferenceStore (SharedPreferences-backed)"
```

---

## Task 5: SnapPreferenceController

`StateNotifier<bool>` driven by the store. Override-in-main pattern.

**Files:**
- Create: `packages/screen_recorder/lib/state/snap_preference_controller.dart`
- Test: `packages/screen_recorder/test/state/snap_preference_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/snap_preference_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/state/snap_preference_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SnapPreferenceStore> store([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    return SnapPreferenceStore(await SharedPreferences.getInstance());
  }

  group('SnapPreferenceController', () {
    test('constructs with the given initial value', () async {
      final c = SnapPreferenceController(store: await store(), initial: false);
      expect(c.state, isFalse);
    });

    test('setEnabled(true) updates state to true', () async {
      final c = SnapPreferenceController(store: await store(), initial: false);
      c.setEnabled(true);
      expect(c.state, isTrue);
    });

    test('setEnabled persists to the store', () async {
      final s = await store();
      final c = SnapPreferenceController(store: s, initial: true);
      c.setEnabled(false);
      // The save is unawaited; pump the microtask queue so the SharedPreferences
      // write completes before we re-read.
      await Future<void>.delayed(Duration.zero);
      expect(s.load(), isFalse);
    });

    test('round-trips true -> false -> true', () async {
      final c = SnapPreferenceController(store: await store(), initial: true);
      c.setEnabled(false);
      expect(c.state, isFalse);
      c.setEnabled(true);
      expect(c.state, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/snap_preference_controller_test.dart
```

Expected: compilation error — `snap_preference_controller.dart` does not exist.

- [ ] **Step 3: Implement the controller + provider**

```dart
// packages/screen_recorder/lib/state/snap_preference_controller.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/snap_preference_store.dart';

/// Holds the snap-on-cut toggle and persists it on every change.
/// Mirrors [AppPaletteController].
class SnapPreferenceController extends StateNotifier<bool> {
  SnapPreferenceController({
    required SnapPreferenceStore store,
    required bool initial,
  })  : _store = store,
        super(initial);

  final SnapPreferenceStore _store;

  void setEnabled(bool value) {
    state = value;
    unawaited(_store.save(value));
  }
}

/// Always overridden in main.dart with a loaded store + the persisted
/// initial value. The default throws to surface missing wiring early.
final snapPreferenceProvider =
    StateNotifierProvider<SnapPreferenceController, bool>(
  (ref) => throw UnimplementedError(
    'Override snapPreferenceProvider in main.dart with a loaded store',
  ),
);
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/snap_preference_controller_test.dart
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/snap_preference_controller.dart \
        packages/screen_recorder/test/state/snap_preference_controller_test.dart
git commit -m "feat(app): add SnapPreferenceController + provider"
```

---

## Task 6: Wire SnapPreferenceController in main.dart

Override the provider at startup (alongside `appPaletteControllerProvider`).

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart` (around line 144 where `AppPaletteStore.resolveDefault()` is called and line 175 where the override is set)

- [ ] **Step 1: Open `packages/screen_recorder/lib/main.dart` and locate the existing palette bootstrap**

It looks like:

```dart
final paletteStore = await AppPaletteStore.resolveDefault();
// ... a few lines later ...
return ProviderScope(
  overrides: [
    appPaletteControllerProvider.overrideWith(
      (ref) => AppPaletteController(
        store: paletteStore,
        initial: persistedPalette,
      ),
    ),
    // ... other overrides ...
  ],
  ...
);
```

- [ ] **Step 2: Add the snap store bootstrap and provider override**

Right after the `final paletteStore = ...` line, add:

```dart
final snapPreferenceStore = await SnapPreferenceStore.resolveDefault();
final snapEnabledInitial = snapPreferenceStore.load();
```

Add the import at the top of the file:

```dart
import 'package:screen_recorder/state/snap_preference_store.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
```

Inside the `overrides: [...]` list of the `ProviderScope`, add (after the existing palette override):

```dart
snapPreferenceProvider.overrideWith(
  (ref) => SnapPreferenceController(
    store: snapPreferenceStore,
    initial: snapEnabledInitial,
  ),
),
```

- [ ] **Step 3: Run the app to verify it boots**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter analyze
```

Expected: no analyzer errors related to `snapPreferenceProvider` or imports.

(Manual run-the-app verification deferred to Task 14 since we have no UI consumer yet.)

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(app): bootstrap SnapPreferenceController override in main"
```

---

## Task 7: Snap toggle pill widget

A small magnet-icon toggle to drop into the canvas toolbar.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/canvas_toolbar/snap_toggle_pill.dart`
- Test: `packages/screen_recorder/test/ui/widgets/canvas_toolbar/snap_toggle_pill_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/canvas_toolbar/snap_toggle_pill_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/state/snap_preference_store.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/snap_toggle_pill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Widget> appWith({required bool initial}) async {
    SharedPreferences.setMockInitialValues({});
    final store = SnapPreferenceStore(await SharedPreferences.getInstance());
    return ProviderScope(
      overrides: [
        snapPreferenceProvider.overrideWith(
          (ref) => SnapPreferenceController(store: store, initial: initial),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: SnapTogglePill())),
      ),
    );
  }

  testWidgets('renders with magnet icon and current state in tooltip',
      (tester) async {
    await tester.pumpWidget(await appWith(initial: true));
    expect(find.byTooltip('Snap to events: On'), findsOneWidget);
  });

  testWidgets('tooltip reflects off state', (tester) async {
    await tester.pumpWidget(await appWith(initial: false));
    expect(find.byTooltip('Snap to events: Off'), findsOneWidget);
  });

  testWidgets('tap toggles provider state', (tester) async {
    await tester.pumpWidget(await appWith(initial: true));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SnapTogglePill)),
    );
    expect(container.read(snapPreferenceProvider), isTrue);
    await tester.tap(find.byType(SnapTogglePill));
    await tester.pump();
    expect(container.read(snapPreferenceProvider), isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/canvas_toolbar/snap_toggle_pill_test.dart
```

Expected: compilation error — `snap_toggle_pill.dart` does not exist.

- [ ] **Step 3: Implement the pill**

```dart
// packages/screen_recorder/lib/ui/widgets/canvas_toolbar/snap_toggle_pill.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/snap_preference_controller.dart';

/// Magnet-icon pill that toggles snap-on-cut globally. Sits next to
/// the timeline scale slider in the canvas toolbar.
class SnapTogglePill extends ConsumerWidget {
  const SnapTogglePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(snapPreferenceProvider);
    final tooltip = 'Snap to events: ${enabled ? 'On' : 'Off'}';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => ref
            .read(snapPreferenceProvider.notifier)
            .setEnabled(!enabled),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Icon(
            // `attractions` is the magnet pictogram in Material Icons.
            Icons.attractions,
            size: 18,
            color: enabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/canvas_toolbar/snap_toggle_pill_test.dart
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/canvas_toolbar/snap_toggle_pill.dart \
        packages/screen_recorder/test/ui/widgets/canvas_toolbar/snap_toggle_pill_test.dart
git commit -m "feat(app): add SnapTogglePill widget"
```

---

## Task 8: Mount SnapTogglePill in the canvas toolbar

The `CanvasToolbar` takes a children list. The composition lives in `playback_screen.dart` around lines 1644 and 1714 where `TimelineScaleSlider` is constructed. Add `SnapTogglePill` to that children list.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

- [ ] **Step 1: Locate both CanvasToolbar / TimelineScaleSlider call sites**

```bash
grep -n "TimelineScaleSlider\|CanvasToolbar" packages/screen_recorder/lib/ui/screens/playback_screen.dart
```

There are two — one at ~line 1644 and one at ~line 1714. Both are inside the `CanvasToolbar(children: [...])` composition.

- [ ] **Step 2: Add the import**

At the top of `playback_screen.dart`, add:

```dart
import 'package:screen_recorder/ui/widgets/canvas_toolbar/snap_toggle_pill.dart';
```

- [ ] **Step 3: Add the pill next to TimelineScaleSlider in each call site**

In each `CanvasToolbar(children: [...])` block, alongside the existing `TimelineScaleSlider(...)`, add `const SnapTogglePill()`. Example:

```dart
CanvasToolbar(
  children: [
    // ... existing children (aspect picker etc.) ...
    TimelineScaleSlider(
      // ... existing args ...
    ),
    const SnapTogglePill(),
  ],
),
```

- [ ] **Step 4: Verify the app analyzes cleanly**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter analyze
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): mount SnapTogglePill in canvas toolbar"
```

---

## Task 9: SnapFlashOverlay widget

Brief glow on the snap target after a snapped commit. ~240ms fade.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/timeline/snap_flash_overlay.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/snap_flash_overlay_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/timeline/snap_flash_overlay_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:screen_recorder/ui/widgets/timeline/snap_flash_overlay.dart';

void main() {
  testWidgets('renders nothing when target is null', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 60,
          child: SnapFlashOverlay(
            target: null,
            editedTimeToPx: _identityMapper,
          ),
        ),
      ),
    ));
    // No CustomPaint with a non-null painter dimension when target is null.
    final overlay = tester.widget<SnapFlashOverlay>(find.byType(SnapFlashOverlay));
    expect(overlay.target, isNull);
  });

  testWidgets('renders glow at mapped pixel when target is set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 60,
          child: SnapFlashOverlay(
            target: const Duration(seconds: 2),
            editedTimeToPx: (d) => d.inMilliseconds.toDouble() / 10.0,
          ),
        ),
      ),
    ));
    final overlay = tester.widget<SnapFlashOverlay>(find.byType(SnapFlashOverlay));
    expect(overlay.target, const Duration(seconds: 2));
  });
}

double _identityMapper(Duration d) => d.inMilliseconds.toDouble();
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/snap_flash_overlay_test.dart
```

Expected: compilation error — file doesn't exist.

- [ ] **Step 3: Implement the overlay**

```dart
// packages/screen_recorder/lib/ui/widgets/timeline/snap_flash_overlay.dart
import 'package:flutter/material.dart';

/// Brief vertical glow at the edited-time x of a snap target. The
/// owning screen is responsible for clearing [target] after the fade
/// completes (240ms).
class SnapFlashOverlay extends StatelessWidget {
  const SnapFlashOverlay({
    super.key,
    required this.target,
    required this.editedTimeToPx,
  });

  /// The edited-time of the snap target. Null = render nothing.
  final Duration? target;

  /// Maps an edited-time to the x-pixel inside this widget's local
  /// coordinate space. Caller threads in the same mapper used for the
  /// playhead so the glow lines up exactly.
  final double Function(Duration) editedTimeToPx;

  @override
  Widget build(BuildContext context) {
    final t = target;
    if (t == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SnapFlashPainter(
          x: editedTimeToPx(t),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SnapFlashPainter extends CustomPainter {
  _SnapFlashPainter({required this.x, required this.color});

  final double x;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (x.isNaN || x.isInfinite) return;
    // Vertical glow: 4px-wide rect with a soft horizontal gradient at
    // 60% alpha, centered on `x`.
    final rect = Rect.fromLTWH(x - 2, 0, 4, size.height);
    final paint = Paint()
      ..color = color.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _SnapFlashPainter oldDelegate) =>
      oldDelegate.x != x || oldDelegate.color != color;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/widgets/timeline/snap_flash_overlay_test.dart
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/snap_flash_overlay.dart \
        packages/screen_recorder/test/ui/widgets/timeline/snap_flash_overlay_test.dart
git commit -m "feat(app): add SnapFlashOverlay widget"
```

---

## Task 10: PlaybackScreen snap candidate builder + flash state

Add the `_buildSnapCandidates`, `_flashSnap`, `_snapFlashTarget`, `_snapFlashTimer` to `PlaybackScreenState`. No call-site integration yet — that comes in tasks 11 and 12.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: deferred (covered by the integration tests in tasks 11/12)

- [ ] **Step 1: Add imports at the top of `playback_screen.dart`**

```dart
import 'package:slipreel_engine/snap/snap_resolver.dart';
import 'package:slipreel_engine/timeline/edited_time.dart' show sourceToEdited;
```

(`sourceToEdited` may already be imported indirectly — check the existing imports first; only add if missing.)

- [ ] **Step 2: Add the new fields next to `_history`**

Find the block around line 224 where `_history`, `_selectedZoomIndex`, `_zoomPreviewOverride` live. Add:

```dart
  /// Edited-time of the most recent snap target — drives [SnapFlashOverlay].
  /// Cleared by [_snapFlashTimer] after the fade completes.
  Duration? _snapFlashTarget;
  Timer? _snapFlashTimer;
```

- [ ] **Step 3: Add the candidate builder helper**

Place it near the existing `_currentSelection()` helper (around line 349):

```dart
  /// Returns a sorted ascending list of edited-time snap candidates:
  /// cursor click events plus zoom-region start/end edges. Computed on
  /// demand per cut request — typical projects have a few hundred
  /// candidates and the cost is sub-millisecond.
  List<Duration> _buildSnapCandidates(List<ClipSlice> clips) {
    final candidates = <Duration>[];
    // Clicks come from the cursor recording — convert source-time to edited-time.
    for (final t in _cursorRecording.eventIndex.clickTimes) {
      candidates.add(sourceToEdited(clips, t));
    }
    // Zoom regions are already in source-time; convert both edges.
    final regions =
        ref.read(editorProjectControllerProvider).timeline.activeZoomRegions;
    for (final r in regions) {
      candidates.add(sourceToEdited(clips, r.startTime));
      candidates.add(sourceToEdited(clips, r.endTime));
    }
    candidates.sort();
    return candidates;
  }
```

(`Timeline.activeZoomRegions` is the convenience accessor on `packages/slipreel_engine/lib/timeline/timeline.dart:70` — falls back to empty when no tracks exist.)

- [ ] **Step 4: Add the flash helper**

Next to `_flashPlayhead` (around line 334):

```dart
  void _flashSnap(Duration target) {
    if (!mounted) return;
    setState(() => _snapFlashTarget = target);
    _snapFlashTimer?.cancel();
    _snapFlashTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      setState(() => _snapFlashTarget = null);
    });
  }
```

- [ ] **Step 5: Cancel the timer in dispose**

In the existing `dispose()` method (search for `_flashTimer?.cancel()` to find it), add right after:

```dart
    _snapFlashTimer?.cancel();
```

- [ ] **Step 6: Verify it analyzes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter analyze
```

Expected: no errors. (`_snapFlashTarget` is unused at this point — that's fine; tasks 11 and 13 wire it up. If the analyzer rejects unused fields, you may temporarily suppress with `// ignore: unused_field` and remove the ignore in Task 13.)

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): add snap candidate builder + flash state in PlaybackScreen"
```

---

## Task 11: Integrate snap into the Cmd+K hotkey path

Modify `_onKey` so Cmd+K applies snap (unless `Cmd+Option+K` or globally disabled), and trigger `_flashSnap` on a snapped commit.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (the `_onKey` method around lines 308-332)
- Test: `packages/screen_recorder/test/ui/screens/playback_screen_snap_cmdk_test.dart`

- [ ] **Step 1: Write the failing test**

The test imports `decideCutTime` from a file that doesn't exist yet — Step 2 will fail to compile.

```dart
// packages/screen_recorder/test/ui/screens/playback_screen_snap_cmdk_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';

void main() {
  ClipSlice slice(int startMs, int endMs) => ClipSlice(
        cutStart: Duration(milliseconds: startMs),
        cutEnd: Duration(milliseconds: endMs),
      );

  CursorRecording cursorWithClickAtMs(int ms) {
    final rec = CursorRecording();
    rec.addPosition(const CursorPosition(
      timestampMicros: 0, x: 0, y: 0, isClicked: false,
    ));
    rec.addPosition(CursorPosition(
      timestampMicros: ms * 1000,
      x: 0,
      y: 0,
      isClicked: true,
    ));
    return rec;
  }

  group('decideCutTime', () {
    final clips = [slice(0, 10000)]; // 10s slice, 1x speed -> edited == source

    test('snap on, within radius -> snaps to click', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5000));
    });

    test('snap on, outside radius -> raw playhead', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5200),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5200));
    });

    test('snap off (global) -> raw playhead', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: false,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5050));
    });

    test('snap on, overrideSnap (Option) -> raw playhead', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [],
        snapEnabled: true,
        overrideSnap: true,
      );
      expect(cut, const Duration(milliseconds: 5050));
    });

    test('zoom edge wins when closer than click', () {
      final cut = decideCutTime(
        playheadEdited: const Duration(milliseconds: 5050),
        clips: clips,
        cursor: cursorWithClickAtMs(5000),
        zoomEdgesSource: const [Duration(milliseconds: 5040)],
        snapEnabled: true,
        overrideSnap: false,
      );
      expect(cut, const Duration(milliseconds: 5040));
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/screens/playback_screen_snap_cmdk_test.dart
```

Expected: compilation error — `cut_decision.dart` does not exist.

- [ ] **Step 3: Create the `cut_decision.dart` file**

```dart
// packages/screen_recorder/lib/ui/screens/playback/cut_decision.dart
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/snap/snap_resolver.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

/// Returns the edited-time at which a Cmd+K cut should land, applying
/// snap when enabled and not overridden.
Duration decideCutTime({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required CursorRecording cursor,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) return playheadEdited;
  final candidates = <Duration>[
    for (final t in cursor.eventIndex.clickTimes) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  return resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  ).time;
}

/// Returns the snap target (for [SnapFlashOverlay]) corresponding to the
/// decision above, or null if the cut did NOT snap.
Duration? decideSnapTarget({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required CursorRecording cursor,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) return null;
  final candidates = <Duration>[
    for (final t in cursor.eventIndex.clickTimes) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  return resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  ).snappedFrom;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/screens/playback_screen_snap_cmdk_test.dart
```

Expected: 5 tests pass.

- [ ] **Step 5: Wire `decideCutTime` / `decideSnapTarget` into `_onKey`**

Find the existing Cmd+K block in `_onKey` (around lines 308-332). Replace the body of `if (!isCmdK) return false;` onward with:

```dart
    if (!_isInitialized) return false;
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    final sourcePos = _controller.value.position;
    final editedPos = sourceToEdited(clips, sourcePos);
    final snapEnabled = ref.read(snapPreferenceProvider);
    final overrideSnap = HardwareKeyboard.instance.isAltPressed;
    final zoomEdges = <Duration>[
      for (final r in ref
          .read(editorProjectControllerProvider)
          .timeline
          .activeZoomRegions) ...[r.startTime, r.endTime],
    ];
    final cutTime = decideCutTime(
      playheadEdited: editedPos,
      clips: clips,
      cursor: _cursorRecording,
      zoomEdgesSource: zoomEdges,
      snapEnabled: snapEnabled,
      overrideSnap: overrideSnap,
    );
    final snappedTo = decideSnapTarget(
      playheadEdited: editedPos,
      clips: clips,
      cursor: _cursorRecording,
      zoomEdgesSource: zoomEdges,
      snapEnabled: snapEnabled,
      overrideSnap: overrideSnap,
    );
    final ok = handleCutKeybind(
      controller: ref.read(editorProjectControllerProvider.notifier),
      currentEditedTime: cutTime,
      clips: clips,
    );
    if (ok) {
      setState(() => _selectedSliceIndex = null);
      if (snappedTo != null) _flashSnap(snappedTo);
    } else {
      // If snap pushed us into the min-slice guard zone, retry at raw position.
      if (snappedTo != null) {
        final fallback = handleCutKeybind(
          controller: ref.read(editorProjectControllerProvider.notifier),
          currentEditedTime: editedPos,
          clips: clips,
        );
        if (fallback) {
          setState(() => _selectedSliceIndex = null);
          return true;
        }
      }
      _flashPlayhead();
    }
    return true;
```

Add imports at the top:

```dart
import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
```

- [ ] **Step 6: Run the full screen_recorder test suite to check nothing else broke**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback/cut_decision.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/screens/playback_screen_snap_cmdk_test.dart
git commit -m "feat(app): apply snap on Cmd+K cuts with Cmd+Option+K override"
```

---

## Task 12: Apply snap to scissors-mode (CutOverlay) taps

Scissors-mode splits happen inside `EditorTimeline._attemptSplit` (`editor_timeline.dart:383`), which currently calls `controller.splitAtPlayhead(editedTime, clips)` directly. Push snap awareness into that method by:
1. Threading `cursorClickTimes` (a sorted source-time list) and an optional `onSnapped` callback through `EditorTimeline` as new props.
2. Extending `CutOverlay.onCommitCut` to pass an `overrideSnap` modifier flag.
3. Having `_attemptSplit` apply `decideCutTime` / `decideSnapTarget` using the snap pref from the provider.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/cut_overlay.dart` — pass Alt-pressed state through
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart` — new props `cursorClickTimes`, `onSnapped`; `_attemptSplit` applies snap
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — pass the new props down (two call sites)

- [ ] **Step 1: Extend `CutOverlay.onCommitCut` to include `overrideSnap`**

In `packages/screen_recorder/lib/ui/widgets/timeline/cut_overlay.dart`:

```dart
final void Function(Duration editedTime, {required bool overrideSnap}) onCommitCut;
```

Inside the `GestureDetector.onTapDown` (~line 76), capture the modifier:

```dart
onTapDown: (d) {
  widget.onCommitCut(
    _editedTimeAt(d.localPosition.dx),
    overrideSnap: HardwareKeyboard.instance.isAltPressed,
  );
},
```

Add `import 'package:flutter/services.dart';` if not already imported.

- [ ] **Step 2: Add new props on `EditorTimeline` and update `_attemptSplit`**

In `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`, add to the widget's fields:

```dart
final List<Duration> cursorClickTimes;
final ValueChanged<Duration>? onSnapped;
```

Add to the const constructor with `this.cursorClickTimes = const <Duration>[]` (default empty so callers without cursor data still work) and `this.onSnapped`.

Add imports:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp; // if `ref` isn't already in scope
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';
```

(`ref` is already available because `EditorTimeline` extends `ConsumerStatefulWidget` — verify before adding the riverpod import.)

Replace `_attemptSplit` (currently at line 383):

```dart
bool _attemptSplit(Duration editedTime, {required bool overrideSnap}) {
  final clips = widget.clips;
  final snapEnabled = ref.read(snapPreferenceProvider);
  final zoomEdges = <Duration>[
    for (final r in ref
        .read(editorProjectControllerProvider)
        .timeline
        .activeZoomRegions) ...[r.startTime, r.endTime],
  ];
  // Cursor click times are source-time and need conversion. We borrow
  // the same conversion the Cmd+K path uses by mapping through clips.
  // cursorClickTimes are already sorted ascending in source time.
  // decideCutTime handles the conversion + merge + sort.
  final cutTime = decideCutTimeFromSourceClicks(
    playheadEdited: editedTime,
    clips: clips,
    clickTimesSource: widget.cursorClickTimes,
    zoomEdgesSource: zoomEdges,
    snapEnabled: snapEnabled,
    overrideSnap: overrideSnap,
  );
  final snappedTo = decideSnapTargetFromSourceClicks(
    playheadEdited: editedTime,
    clips: clips,
    clickTimesSource: widget.cursorClickTimes,
    zoomEdgesSource: zoomEdges,
    snapEnabled: snapEnabled,
    overrideSnap: overrideSnap,
  );
  final ok = ref
      .read(editorProjectControllerProvider.notifier)
      .splitAtPlayhead(cutTime, clips);
  if (ok && snappedTo != null) widget.onSnapped?.call(snappedTo);
  if (ok) widget.onSliceSelected?.call(null);
  return ok;
}
```

Update the `CutOverlay`'s `onCommitCut` closure (line 503) to match the new signature:

```dart
onCommitCut: (editedTime, {required bool overrideSnap}) {
  final ok = _attemptSplit(editedTime, overrideSnap: overrideSnap);
  if (ok) {
    widget.onCutModeChanged?.call(false);
  }
},
```

- [ ] **Step 3: Add the source-clicks variants to `cut_decision.dart`**

The existing `decideCutTime` takes a `CursorRecording`. For EditorTimeline's prop-based input, add overloads that take raw `clickTimesSource: List<Duration>`. Append to `packages/screen_recorder/lib/ui/screens/playback/cut_decision.dart`:

```dart
/// Same as [decideCutTime], but takes pre-extracted source-time click
/// timestamps (used when the caller passes them via a widget prop rather
/// than holding a [CursorRecording] reference).
Duration decideCutTimeFromSourceClicks({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required List<Duration> clickTimesSource,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) return playheadEdited;
  final candidates = <Duration>[
    for (final t in clickTimesSource) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  return resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  ).time;
}

Duration? decideSnapTargetFromSourceClicks({
  required Duration playheadEdited,
  required List<ClipSlice> clips,
  required List<Duration> clickTimesSource,
  required Iterable<Duration> zoomEdgesSource,
  required bool snapEnabled,
  required bool overrideSnap,
}) {
  if (!snapEnabled || overrideSnap) return null;
  final candidates = <Duration>[
    for (final t in clickTimesSource) sourceToEdited(clips, t),
    for (final e in zoomEdgesSource) sourceToEdited(clips, e),
  ]..sort();
  return resolveSnap(
    requestedTime: playheadEdited,
    candidates: candidates,
  ).snappedFrom;
}
```

- [ ] **Step 4: Pass the new props from `PlaybackScreen`**

Find each `EditorTimeline(...)` construction in `playback_screen.dart` (same two call sites as Task 8/13). Add:

```dart
cursorClickTimes:
    _cursorRecording.eventIndex.clickTimes,
onSnapped: _flashSnap,
```

- [ ] **Step 5: Verify analyzer + tests**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter analyze
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```

Expected: both green.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/cut_overlay.dart \
        packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/lib/ui/screens/playback/cut_decision.dart
git commit -m "feat(app): apply snap to scissors-mode tap cuts (with Option override)"
```

---

## Task 13: Mount SnapFlashOverlay in the timeline

Drop the flash widget into the editor timeline stack so `_snapFlashTarget` actually renders.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (pass `_snapFlashTarget` down)

- [ ] **Step 1: Add a `snapFlashTarget` param to `EditorTimeline`**

In `editor_timeline.dart`, extend the constructor:

```dart
final Duration? snapFlashTarget;
```

Add it to the const constructor's params + assign as `this.snapFlashTarget`.

- [ ] **Step 2: Render `SnapFlashOverlay` in the timeline stack**

Find the `Stack(...)` that hosts the playhead inside `editor_timeline.dart`. Add a sibling layer near the playhead, using the same edited-time-to-px mapper the playhead uses (you'll see a helper like `_editedToPx` or similar — reuse it):

```dart
SnapFlashOverlay(
  target: widget.snapFlashTarget,
  editedTimeToPx: _editedToPx, // or whatever the existing mapper is
),
```

Add: `import 'package:screen_recorder/ui/widgets/timeline/snap_flash_overlay.dart';`

- [ ] **Step 3: Pass `_snapFlashTarget` from `playback_screen.dart`**

Find each `EditorTimeline(...)` construction (the same two call sites you touched in Task 8). Add:

```dart
snapFlashTarget: _snapFlashTarget,
```

- [ ] **Step 4: Verify it analyzes and tests pass**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter analyze
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```

Expected: both green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): render SnapFlashOverlay in the timeline"
```

---

## Task 14: Wire Option+] / Option+[ keyboard navigation

Add the slice nav block to `_onKey` with text-field guard.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/ui/screens/playback_screen_slice_nav_test.dart`

The text-field guard logic and the boundary-flash logic are non-trivial. We extract them into pure helpers that we can test directly, and the screen calls them.

- [ ] **Step 1: Write the failing test for the pure decision helper**

```dart
// packages/screen_recorder/test/ui/screens/playback_screen_slice_nav_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart';

import 'package:screen_recorder/ui/screens/playback/slice_nav_decision.dart';

void main() {
  ClipSlice slice(int aMs, int bMs) => ClipSlice(
        cutStart: Duration(milliseconds: aMs),
        cutEnd: Duration(milliseconds: bMs),
      );

  group('decideSliceNav', () {
    test('returns null on empty clip list (no-op)', () {
      final d = decideSliceNav(
        currentIndex: null,
        clips: const [],
        direction: NavDirection.next,
      );
      expect(d, isNull);
    });

    test('from null selection -> first slice at edited zero', () {
      final clips = [slice(0, 1000), slice(1000, 3000)];
      final d = decideSliceNav(
        currentIndex: null,
        clips: clips,
        direction: NavDirection.next,
      );
      expect(d!.nextIndex, 0);
      expect(d.seekTo, Duration.zero);
      expect(d.isBoundaryNoOp, isFalse);
    });

    test('mid-list next advances + seeks to next slice start', () {
      final clips = [slice(0, 1000), slice(1000, 3000), slice(3000, 4000)];
      final d = decideSliceNav(
        currentIndex: 1,
        clips: clips,
        direction: NavDirection.next,
      );
      expect(d!.nextIndex, 2);
      expect(d.seekTo, const Duration(milliseconds: 3000));
      expect(d.isBoundaryNoOp, isFalse);
    });

    test('at last index + next -> boundary no-op', () {
      final clips = [slice(0, 1000), slice(1000, 3000)];
      final d = decideSliceNav(
        currentIndex: 1,
        clips: clips,
        direction: NavDirection.next,
      );
      expect(d!.nextIndex, 1);
      expect(d.isBoundaryNoOp, isTrue);
    });

    test('at first index + previous -> boundary no-op', () {
      final clips = [slice(0, 1000), slice(1000, 3000)];
      final d = decideSliceNav(
        currentIndex: 0,
        clips: clips,
        direction: NavDirection.previous,
      );
      expect(d!.nextIndex, 0);
      expect(d.isBoundaryNoOp, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/screens/playback_screen_slice_nav_test.dart
```

Expected: compilation error — `slice_nav_decision.dart` does not exist.

- [ ] **Step 3: Implement the decision helper**

```dart
// packages/screen_recorder/lib/ui/screens/playback/slice_nav_decision.dart
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart';

class SliceNavDecision {
  const SliceNavDecision({
    required this.nextIndex,
    required this.seekTo,
    required this.isBoundaryNoOp,
  });

  final int nextIndex;
  final Duration seekTo;
  final bool isBoundaryNoOp;
}

/// Returns the navigation outcome, or null when the clip list is empty
/// (caller should no-op).
SliceNavDecision? decideSliceNav({
  required int? currentIndex,
  required List<ClipSlice> clips,
  required NavDirection direction,
}) {
  if (clips.isEmpty) return null;
  final from = currentIndex ?? -1;
  final next = nextSliceIndex(
    currentIndex: from,
    sliceCount: clips.length,
    direction: direction,
  );
  if (next == from && from >= 0) {
    return SliceNavDecision(
      nextIndex: from,
      seekTo: sliceEditedStart(clips, from),
      isBoundaryNoOp: true,
    );
  }
  return SliceNavDecision(
    nextIndex: next,
    seekTo: sliceEditedStart(clips, next),
    isBoundaryNoOp: false,
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/screens/playback_screen_slice_nav_test.dart
```

Expected: 5 tests pass.

- [ ] **Step 5: Add the Option+] / Option+[ block to `_onKey`**

In `playback_screen.dart`'s `_onKey`, AFTER the existing Cmd+K block and BEFORE `return false;`, add:

```dart
    final isOptBracket = HardwareKeyboard.instance.isAltPressed &&
        (event.logicalKey == LogicalKeyboardKey.bracketRight ||
         event.logicalKey == LogicalKeyboardKey.bracketLeft);
    if (isOptBracket) {
      if (!_isInitialized) return false;
      if (_focusedWidgetIsEditable()) return false;
      final clips = ref.read(editorProjectControllerProvider).timeline.clips;
      final dir = event.logicalKey == LogicalKeyboardKey.bracketRight
          ? NavDirection.next
          : NavDirection.previous;
      final decision = decideSliceNav(
        currentIndex: _selectedSliceIndex,
        clips: clips,
        direction: dir,
      );
      if (decision == null) return true;
      if (decision.isBoundaryNoOp) {
        _flashPlayhead();
        return true;
      }
      setState(() {
        _selectedSliceIndex = decision.nextIndex;
        _selectedZoomIndex = null;
      });
      _controller.seekTo(decision.seekTo);
      return true;
    }
```

Add the small focus-check helper as a private method on the state class:

```dart
  bool _focusedWidgetIsEditable() {
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    return focused is EditableText;
  }
```

Add imports:

```dart
import 'package:slipreel_engine/timeline/slice_navigation.dart' show NavDirection;
import 'package:screen_recorder/ui/screens/playback/slice_nav_decision.dart';
```

- [ ] **Step 6: Verify the whole suite is green**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter analyze
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
cd ../slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test
cd ../..
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback/slice_nav_decision.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/screens/playback_screen_slice_nav_test.dart
git commit -m "feat(app): Option+]/Option+[ slice keyboard navigation"
```

---

## Task 15: Manual QA pass

The spec's manual QA checklist. Tick each item by running the app and exercising the feature. **No code changes** in this task unless QA surfaces a bug — in which case write a new failing test, fix it, and add the fix as a Task 15a commit.

- [ ] **Step 1: Launch the app**

```bash
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter run -d macos
```

- [ ] **Step 2: Open a recording with at least 5+ recorded clicks and at least one zoom region**

- [ ] **Step 3: Walk the checklist**

For each item, confirm the behavior matches. If anything fails, file as a follow-up fix:

- [ ] Pause playhead ~100ms from a recorded click → Cmd+K snaps + brief glow appears at the click
- [ ] Snap toggle (magnet pill) → click it; Cmd+K now lands at raw playhead, no flash
- [ ] Re-enable snap → Cmd+Option+K lands at raw playhead, no flash (modifier override)
- [ ] Switch to scissors mode, Option-click on the timeline near a click → cut lands at the raw tap position
- [ ] Quit + relaunch the app → snap toggle remembers its last state
- [ ] Project with 5+ slices: with nothing selected, press Option+] → slice 0 is selected, video jumps to slice 0's first frame
- [ ] Press Option+] repeatedly to walk forward; at the last slice the press is a no-op (playhead pill flashes)
- [ ] Press Option+[ from no selection → last slice is selected; press Option+[ at slice 0 → no-op flash
- [ ] Type `}` in some text field (if one exists in this view — otherwise skip this item explicitly) → Option+] still types the character, doesn't navigate
- [ ] Make a snapped cut, then Cmd+Z (undo) → the cut is reverted correctly

- [ ] **Step 4: If QA found bugs, write a failing test, fix, commit as a separate "Task 15a" commit per bug**

(Skip if QA was clean.)

---

## Task 16: Update the stale memory note

Memory file `cut_tool_followups.md` already had its 2026-06-03 triage applied. After this branch merges, retire it or rewrite as a "done" record. Track this as a final task — it's not a code change but it stops the stale-memory class of bug.

- [ ] **Step 1: After merge, edit the memory file**

After the PR merges to main, open `/Users/mohn93/.claude/projects/-Users-mohn93-Desktop-side-projects-screenflow-studio/memory/cut_tool_followups.md` and either delete it entirely or replace its body with a one-paragraph "all five items resolved (1, 2 dropped; 3 already shipped; 4, 5 done in [PR link])" record. Remove the entry from `MEMORY.md`.

(No tests; no commit needed in this repo — the memory lives in the user's home directory.)

---

## Final verification

After all tasks complete, run the full suite from the repo root:

```bash
cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test && cd ../..
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test && cd ../..
```

Expected: both packages all green. Then use the `superpowers:finishing-a-development-branch` skill to wrap up.
