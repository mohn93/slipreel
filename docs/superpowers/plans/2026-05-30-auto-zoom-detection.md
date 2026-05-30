# Click-driven auto-zoom detection (sub-project D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the editor opens a recording with no saved zoom regions and at least one captured click, detect "zoom-worthy" moments from the cursor stream and pre-populate the timeline's zoom lane with `ZoomRegion`s; the user can then edit, drag, trim, or delete them like any other region.

**Architecture:** One pure-function unit `AutoZoomDetector` in `slipreel_engine` that takes a `CursorRecording` + `videoSize` + `videoDuration` and returns a `List<ZoomRegion>`. One block of integration glue in `PlaybackScreen._initializeVideo` that calls it when the saved project state has no zoom regions and persists the result immediately so subsequent opens skip detection.

**Tech Stack:** Dart, `dart:ui` (`Rect`, `Size`), existing `ZoomRegion` model, existing `EditorProjectStore` / `EditorProjectController`.

**Spec:** `docs/superpowers/specs/2026-05-29-auto-zoom-detection-design.md`

---

## File map

### Created
- `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart` — pure detection function
- `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart` — 9 unit tests

### Modified
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — single integration block in `_initializeVideo` between `_projectStore.load()` and `_projectController.replace(...)`

No new providers, no new UI surface, no model changes.

---

## Branch

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git checkout -b feat/auto-zoom-detection
```

Commit after each task. Merge to main after the final task.

---

### Task 1: `AutoZoomDetector` (pure function)

**Files:**
- Create: `packages/slipreel_engine/lib/editor/auto_zoom_detector.dart`
- Test: `packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

CursorPosition _p({
  required int ms,
  required bool clicked,
  double x = 100,
  double y = 100,
}) =>
    CursorPosition(
      x: x,
      y: y,
      timestampMicros: ms * 1000,
      isClicked: clicked,
      state: CursorState.arrow,
    );

CursorRecording _rec(List<CursorPosition> positions) {
  final r = CursorRecording();
  for (final p in positions) {
    r.addPosition(p);
  }
  return r;
}

/// A synthetic isClicked plateau: `down` ms with !clicked, then `hold` ms with
/// clicked, simulating a real mouse-down at the down→up transition we want.
List<CursorPosition> _clickAt({
  required int atMs,
  required double x,
  required double y,
  int holdMs = 50,
}) {
  return [
    _p(ms: atMs - 16, clicked: false, x: x, y: y),
    _p(ms: atMs, clicked: true, x: x, y: y),
    _p(ms: atMs + holdMs, clicked: true, x: x, y: y),
    _p(ms: atMs + holdMs + 16, clicked: false, x: x, y: y),
  ];
}

void main() {
  const detector = AutoZoomDetector();
  const videoSize = Size(1920, 1080);
  const videoDuration = Duration(seconds: 30);

  test('empty recording returns no regions', () {
    final out = detector.detect(
      cursor: CursorRecording(),
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('recording with positions but zero clicks returns no regions', () {
    final cursor = _rec([
      _p(ms: 0, clicked: false),
      _p(ms: 100, clicked: false),
      _p(ms: 200, clicked: false),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('single isolated click → one region centered on click', () {
    final cursor = _rec(_clickAt(atMs: 5000, x: 800, y: 600));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final r = out.first;
    // startTime = 5000 - 400 leadIn = 4600 ms
    expect(r.startTime, const Duration(milliseconds: 4600));
    // duration = 400 + 1800 + 300 = 2500 ms
    expect(r.duration, const Duration(milliseconds: 2500));
    expect(r.zoomLevel, 1.5);
    // rect.center == (800, 600) (no clamping needed for this position)
    expect(r.rect.center, const Offset(800, 600));
    // rect dims = videoSize / zoom
    expect(r.rect.width, closeTo(1920 / 1.5, 0.001));
    expect(r.rect.height, closeTo(1080 / 1.5, 0.001));
    expect(r.followCursor, isFalse);
  });

  test('two clicks 3 s apart → two regions', () {
    final cursor = _rec([
      ..._clickAt(atMs: 2000, x: 400, y: 300),
      ..._clickAt(atMs: 5000, x: 1200, y: 800),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(2));
    expect(out[0].rect.center, const Offset(400, 300));
    expect(out[1].rect.center, const Offset(1200, 800));
  });

  test('two clicks 0.5 s apart → no regions (both fail isolation)', () {
    final cursor = _rec([
      ..._clickAt(atMs: 2000, x: 400, y: 300),
      ..._clickAt(atMs: 2500, x: 800, y: 600),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, isEmpty);
  });

  test('two clicks 1.6 s apart → only the first survives (overlap drops second)', () {
    // Both pass the 1.5 s isolation gate. But region1 = [1600, 4100] (start
    // 1600, duration 2500); region2 = [3200, 5700]. They overlap → second
    // dropped.
    final cursor = _rec([
      ..._clickAt(atMs: 2000, x: 400, y: 300),
      ..._clickAt(atMs: 3600, x: 1200, y: 800),
    ]);
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.first.rect.center, const Offset(400, 300));
  });

  test('click at t=100 ms clamps region start to zero', () {
    final cursor = _rec(_clickAt(atMs: 100, x: 800, y: 600));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.first.startTime, Duration.zero);
  });

  test('click at top-left edge clamps rect center inward', () {
    final cursor = _rec(_clickAt(atMs: 5000, x: 0, y: 0));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    final rect = out.first.rect;
    // rect must stay fully inside the video bounds
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(videoSize.width));
    expect(rect.bottom, lessThanOrEqualTo(videoSize.height));
  });

  test('click near end of video clamps duration', () {
    // Video is 30s; click at 29.0s. start = 29000-400 = 28600 ms.
    // raw duration = 2500 → end = 31100 ms which exceeds 30000.
    // Should clamp to 30000-28600 = 1400 ms.
    final cursor = _rec(_clickAt(atMs: 29000, x: 800, y: 600));
    final out = detector.detect(
      cursor: cursor,
      videoSize: videoSize,
      videoDuration: videoDuration,
    );
    expect(out, hasLength(1));
    expect(out.first.startTime, const Duration(milliseconds: 28600));
    expect(out.first.duration, const Duration(milliseconds: 1400));
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_test.dart
```
Expected: FAIL — `auto_zoom_detector.dart` does not exist.

- [ ] **Step 3: Implement the detector**

```dart
// packages/slipreel_engine/lib/editor/auto_zoom_detector.dart
import 'dart:ui';

import '../models/cursor_recording.dart';
import '../models/zoom_region.dart';

/// Pure-function click→zoom detector. Walks a `CursorRecording`, finds
/// rising edges of `isClicked`, keeps only clicks that are at least
/// `isolationWindow` away from their neighbours, and emits one `ZoomRegion`
/// per surviving click — centred on the click position, sized for `zoomLevel`,
/// clamped to the video bounds, never extending past the recording's edges.
///
/// Defaults: 1.5× zoom, 1.5 s isolation window, 400 ms lead-in + 1.8 s hold
/// + 300 ms lead-out = 2.5 s total duration. `followCursor: false` — the zoom
/// stays anchored at the click; user can flip it on in the inspector.
class AutoZoomDetector {
  const AutoZoomDetector({
    this.zoomLevel = 1.5,
    this.isolationWindow = const Duration(milliseconds: 1500),
    this.leadIn = const Duration(milliseconds: 400),
    this.hold = const Duration(milliseconds: 1800),
    this.leadOut = const Duration(milliseconds: 300),
  });

  final double zoomLevel;
  final Duration isolationWindow;
  final Duration leadIn;
  final Duration hold;
  final Duration leadOut;

  Duration get _totalDuration => leadIn + hold + leadOut;

  List<ZoomRegion> detect({
    required CursorRecording cursor,
    required Size videoSize,
    required Duration videoDuration,
  }) {
    final clicks = _findClickRisingEdges(cursor);
    final isolated = _filterIsolated(clicks);
    final regions = <ZoomRegion>[];
    for (final click in isolated) {
      final region = _buildRegion(click, videoSize, videoDuration);
      if (region != null) regions.add(region);
    }
    return _dropOverlaps(regions);
  }

  List<_Click> _findClickRisingEdges(CursorRecording cursor) {
    final out = <_Click>[];
    var prev = false;
    for (final pos in cursor.positions) {
      if (pos.isClicked && !prev) {
        out.add(_Click(
          t: Duration(microseconds: pos.timestampMicros),
          x: pos.x,
          y: pos.y,
        ));
      }
      prev = pos.isClicked;
    }
    return out;
  }

  List<_Click> _filterIsolated(List<_Click> clicks) {
    if (clicks.isEmpty) return const [];
    final out = <_Click>[];
    // First/last clicks compare against an effectively-infinite gap on the
    // missing side so a deliberate single click at the start or end still
    // counts as isolated.
    const infinite = Duration(days: 1);
    for (var i = 0; i < clicks.length; i++) {
      final c = clicks[i];
      final prevGap = i == 0 ? infinite : c.t - clicks[i - 1].t;
      final nextGap = i == clicks.length - 1 ? infinite : clicks[i + 1].t - c.t;
      if (prevGap >= isolationWindow && nextGap >= isolationWindow) {
        out.add(c);
      }
    }
    return out;
  }

  ZoomRegion? _buildRegion(_Click click, Size videoSize, Duration videoDuration) {
    final raw = click.t - leadIn;
    final start = raw.isNegative ? Duration.zero : raw;
    final endCandidate = start + _totalDuration;
    final duration = endCandidate > videoDuration
        ? videoDuration - start
        : _totalDuration;
    if (duration <= Duration.zero) return null;

    final w = videoSize.width / zoomLevel;
    final h = videoSize.height / zoomLevel;
    final cx = click.x.clamp(w / 2, videoSize.width - w / 2);
    final cy = click.y.clamp(h / 2, videoSize.height - h / 2);
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);

    return ZoomRegion(
      rect: rect,
      startTime: start,
      duration: duration,
      zoomLevel: zoomLevel,
      enterDuration: leadIn,
      exitDuration: leadOut,
      videoBounds: videoSize,
      followCursor: false,
    );
  }

  List<ZoomRegion> _dropOverlaps(List<ZoomRegion> regions) {
    if (regions.isEmpty) return const [];
    final sorted = [...regions]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final out = <ZoomRegion>[];
    for (final r in sorted) {
      if (out.isEmpty || r.startTime >= out.last.startTime + out.last.duration) {
        out.add(r);
      }
    }
    return out;
  }
}

class _Click {
  const _Click({required this.t, required this.x, required this.y});
  final Duration t;
  final double x;
  final double y;
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/slipreel_engine && flutter test test/editor/auto_zoom_detector_test.dart
```
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/editor/auto_zoom_detector.dart \
        packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart
git commit -m "feat(engine): AutoZoomDetector — pure click→ZoomRegion detector"
```

---

### Task 2: Editor integration in `PlaybackScreen._initializeVideo`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (around lines 180-189)

The existing flow is:
```dart
// (line 180ish)
final saved = await _projectStore.load();
_projectController.replace(saved);
```

We insert detection between the load and the replace. If the saved state already has zoom regions OR the cursor recording has no clicks OR `_metadata` is missing, we skip cleanly. The persistence side-effect (`_projectStore.save`) makes auto-placed regions "user-owned" so subsequent opens won't re-detect.

- [ ] **Step 1: Apply the integration block**

Open `packages/screen_recorder/lib/ui/screens/playback_screen.dart`. Find the lines:
```dart
    final saved = await _projectStore.load();
    _projectController.replace(saved);
```
(They are around line 180-189; `_projectStore.load()` is preceded by `_cursorRecording` load and `_metadata = await RecordingMetadata.loadForVideo(...)`.)

Replace those two lines with:

```dart
    final saved = await _projectStore.load();

    EditorProjectState restored = saved;
    try {
      final hasNoZooms = saved.zoomRegions.isEmpty;
      final hasClicks = _cursorRecording.positions.any((p) => p.isClicked);
      if (hasNoZooms && hasClicks && _metadata != null) {
        final detected = const AutoZoomDetector().detect(
          cursor: _cursorRecording,
          videoSize: Size(
            _metadata!.widthPx.toDouble(),
            _metadata!.heightPx.toDouble(),
          ),
          videoDuration: _controller.value.duration,
        );
        if (detected.isNotEmpty) {
          restored = saved.copyWith(zoomRegions: detected);
          // Make auto-placed regions immediately "user-owned" so a
          // subsequent open skips detection — otherwise a user who
          // deletes a region could see it come back next launch.
          await _projectStore.save(restored);
        }
      }
    } catch (e, st) {
      AppLogger.ui.w(
        'Auto-zoom detection failed; opening editor with empty zoom lane: $e',
      );
      // ignore: avoid_redundant_argument_values
      AppLogger.ui.w(st.toString());
    }
    _projectController.replace(restored);
```

Add imports at top of the file (alongside existing imports — the slipreel_engine package likely already exposes these via the barrel; if not, the specific paths are below):

```dart
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
```

NOTE: `EditorProjectState`, `Size`, and `AppLogger` are almost certainly already imported via existing dependencies in this file. If `Size` isn't, add `import 'dart:ui' show Size;`. If `AppLogger.ui.w` isn't accessible, fall back to `AppLogger.platform.w(...)` — both exist in `slipreel_engine/lib/utils/app_logger.dart`.

If the codebase prefers two-arg warning logging (`AppLogger.ui.w(message, error: e, stackTrace: st)`), use that pattern instead — match the closest existing call site.

- [ ] **Step 2: Run the app test suite**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green. There are no widget tests for `PlaybackScreen`'s init flow; this integration is covered by the manual checks in Task 3.

- [ ] **Step 3: Run the engine test suite (no regression)**

```bash
cd packages/slipreel_engine && flutter test
```
Expected: full suite green.

- [ ] **Step 4: Run analyzer**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos run analyze --no-select 2>&1 | tail -5
```
Expected: SUCCESS (only pre-existing info-level findings).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): wire AutoZoomDetector into PlaybackScreen._initializeVideo"
```

---

### Task 3: Manual verification + repo-wide checks

Not a code task — verification.

- [ ] **Repo-wide checks:**
  ```bash
  cd /Users/mohn93/Desktop/side_projects/screenflow_studio
  melos run analyze --no-select
  melos run test --no-select
  cd packages/screen_recorder_macos/example/macos && \
    xcodebuild -workspace Runner.xcworkspace -scheme Runner \
               -configuration Debug -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -3
  ```
  Expected: analyze clean (only pre-existing infos), tests green, xcodebuild SUCCEEDED.

- [ ] **Manual on a real Mac:**
  1. Record a 30-second session with 3 deliberate clicks, each separated by ≥ 2 seconds (e.g., click somewhere at 5 s, click somewhere else at 10 s, click again at 20 s). Open the editor → the zoom lane shows 3 regions centred at the click locations. Play through → the camera zooms in around each click moment.
  2. Record a session with rapid-fire clicks (button-mashing). Open the editor → the zoom lane is empty or has only the very first / last click if those were isolated.
  3. Record a session with no clicks at all (just mouse movement). Open the editor → the zoom lane is empty.
  4. Open a previously-detected recording. Delete one of the auto-placed regions via the timeline. Close the editor. Re-open the same recording → the region comes back. **This is the known v1 wart** from the spec — log it as observed, do not "fix".
  5. Open a recording that already had user-edited zoom regions before this build (or manually add one via tap, save, re-open) → no auto-detect runs; the existing region stays exactly as-is.
  6. Open a recording recovered via sub-project C (a `.recovered.mp4`) whose `.meta.json` was successfully written → auto-detect runs over its cursor data.
  7. Open a recording where the cursor sidecar is missing (manually delete `<videoPath>.cursor.json` before opening) → editor opens with empty zoom lane and no errors in the log.

---

## Self-review

**Spec coverage:**
- `AutoZoomDetector` algorithm (rising edges → isolation filter → region mapping → overlap dedupe) → Task 1 ✓
- Editor integration block with `hasNoZooms`, `hasClicks`, `_metadata != null` guards → Task 2 ✓
- Immediate persistence via `_projectStore.save` → Task 2 ✓
- Top-level try/catch → Task 2 ✓
- All 9 spec-listed unit tests → Task 1 ✓
- Manual verification matrix → Task 3 ✓

**Placeholder scan:** no TBDs, no "implement later" patterns. The only conditional in the plan ("If `Size` isn't imported, add the import") is a real condition the implementer resolves by reading the file.

**Type consistency:**
- `AutoZoomDetector({zoomLevel, isolationWindow, leadIn, hold, leadOut})` defined in Task 1; consumed by Task 2 with `const AutoZoomDetector()`.
- `detect({cursor, videoSize, videoDuration})` defined in Task 1; called identically in Task 2.
- `ZoomRegion(rect, startTime, duration, zoomLevel, enterDuration, exitDuration, videoBounds, followCursor)` — Task 1 only; matches the existing model constructor verbatim per the recon.
- `CursorRecording.positions` (read) — used in Task 1 (`for (final pos in cursor.positions)`) and Task 2 (`_cursorRecording.positions.any(...)`). Consistent.

**Out of scope (per spec):** Settings UI, "Run auto-zoom" button, auto-vs-manual tagging, "remember user cleared the lane" memory, follow-cursor on auto-placed, drag/scroll detection, gaze-modelling. Not in plan; correct.
