# Click-driven auto-zoom detection (sub-project D)

**Date:** 2026-05-29
**Status:** Approved (design)
**Scope:** When the editor opens a fresh recording (one with no saved zoom regions yet), detect "zoom-worthy" moments from the captured cursor stream and pre-populate the timeline's existing zoom lane with `ZoomRegion`s the user can then edit, drag, trim, or delete like any other. No new settings, no new toggles, no new buttons.

Sub-project D of the five-part 2026-05-28 backlog; B (first-run & permissions), A (recording UX bundle), and C (crash recovery) have shipped; E (distribution) follows.

## Background

The editor (`packages/screen_recorder/lib/ui/screens/playback_screen.dart`) already loads a `CursorRecording` sidecar at line 169 when a recording is opened, and the timeline (`packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart:753+`) already renders a `_ZoomLane` that displays `ZoomRegion`s and lets the user place new ones by hover-then-tap (`onZoomAdded(start, end)`). Manual regions default to ~2 s duration.

The `CursorPosition` model (`packages/screen_recorder_platform_interface/lib/src/models/cursor_position.dart:5-23`) carries `isClicked` as per-frame state at 60 Hz. The native `CursorTracker` populates this without requiring the Accessibility permission (NSEvent global monitors).

The rich `ZoomRegion` model (`packages/slipreel_engine/lib/models/zoom_region.dart:37-122`) supports `rect`, `startTime`, `duration`, `zoomLevel`, `enterDuration`, `exitDuration`, `followCursor`, follow modes, deadzones, and predictive windows. The auto-detector only needs the first six.

There's no existing auto-placement code. `EditorProjectState.zoomRegions` writes through to `Timeline.zoomTracks[0].regions`; the editor's project store persists the full `EditorProjectState`.

## Decisions (from brainstorming)

- **Run trigger:** Automatically once on editor open, only if `saved.zoomRegions.isEmpty` AND the recording has at least one `isClicked: true` position.
- **Heuristic:** Walk `isClicked` rising edges (one event per discrete mouse-down). Keep only clicks that are ≥ 1.5 s from both the previous AND the next click. First and last click compare against an effectively infinite gap on the missing side.
- **Output:** A `ZoomRegion` per surviving click, with `zoomLevel = 1.5`, `enterDuration = 400 ms`, hold ≈ 1800 ms, `exitDuration = 300 ms` (≈ 2.5 s total), `rect` centered on the click and clamped to video bounds, `followCursor = false`.
- **Persistence:** Detected regions are saved to the project store immediately so subsequent opens see them as "user-owned" and skip re-detection.

## System overview

```
   Editor opens for a recording
            │
            ▼
   _initializeVideo()  ──── existing; loads .cursor.json + .meta.json
            │
            ▼
   _projectStore.load() ──── existing; returns the user's saved edits
            │
            ▼
   if saved.zoomRegions.isEmpty:
        ┌───────────────────────────────────┐
        │  AutoZoomDetector.detect()        │
        │  ─────────────────────            │
        │  in:  CursorRecording             │
        │       videoSize, videoDuration    │
        │  out: List<ZoomRegion>            │
        └───────────────────────────────────┘
            │
            ▼
   _projectController.replace(saved.copyWith(zoomRegions: detected))
   _projectStore.save(...)
            │
            ▼
   Editor renders zoom lane with auto-placed regions.
   User edits/deletes them like any other.
```

One new pure-function unit; one block of integration glue in `PlaybackScreen._initializeVideo`. No new model fields, no new UI surface.

## Components

### 1. `AutoZoomDetector`
`packages/slipreel_engine/lib/editor/auto_zoom_detector.dart` (new)

Pure function. No Riverpod, no async, no editor dependencies. Lives next to the other editor logic in the engine package so it can be unit-tested without the Flutter app shell.

```dart
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

  List<ZoomRegion> detect({
    required CursorRecording cursor,
    required Size videoSize,
    required Duration videoDuration,
  });
}
```

Constructor params are present so unit tests can override; production code uses the defaults exclusively.

### Algorithm

**Step 1: Walk cursor positions for `isClicked` rising edges.**
```dart
final clicks = <_Click>[];
bool prev = false;
for (final pos in cursor.positions) {
  if (pos.isClicked && !prev) {
    clicks.add(_Click(
      t: Duration(microseconds: pos.timestampMicros),
      x: pos.x,
      y: pos.y,
    ));
  }
  prev = pos.isClicked;
}
```
The `isClicked` plateau during a mouse-down hold collapses to one event at the down moment.

**Step 2: Filter to isolated clicks.**
```dart
final isolated = <_Click>[];
for (var i = 0; i < clicks.length; i++) {
  final c = clicks[i];
  final prevGap = i == 0 ? const Duration(days: 1) : c.t - clicks[i - 1].t;
  final nextGap = i == clicks.length - 1 ? const Duration(days: 1) : clicks[i + 1].t - c.t;
  if (prevGap >= isolationWindow && nextGap >= isolationWindow) {
    isolated.add(c);
  }
}
```
First and last clicks compare against `Duration(days: 1)` so they're treated as effectively isolated on the missing side.

**Step 3: Map each isolated click to a `ZoomRegion`.**
```dart
final totalDuration = leadIn + hold + leadOut;
for (final click in isolated) {
  final raw = click.t - leadIn;
  final start = raw.isNegative ? Duration.zero : raw;
  final endCandidate = start + totalDuration;
  final duration = endCandidate > videoDuration ? videoDuration - start : totalDuration;
  if (duration <= Duration.zero) continue;  // click is past the video end

  final w = videoSize.width / zoomLevel;
  final h = videoSize.height / zoomLevel;
  final cx = click.x.clamp(w / 2, videoSize.width - w / 2);
  final cy = click.y.clamp(h / 2, videoSize.height - h / 2);
  final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);

  regions.add(ZoomRegion(
    rect: rect,
    startTime: start,
    duration: duration,
    zoomLevel: zoomLevel,
    enterDuration: leadIn,
    exitDuration: leadOut,
    videoBounds: videoSize,
    followCursor: false,
  ));
}
```

**Step 4: Drop overlapping regions.**
```dart
regions.sort((a, b) => a.startTime.compareTo(b.startTime));
final out = <ZoomRegion>[];
for (final r in regions) {
  if (out.isEmpty || r.startTime >= out.last.startTime + out.last.duration) {
    out.add(r);
  }
}
return out;
```
Cheap guard for edge cases where two clicks exactly 1.5 s apart pass the isolation filter but their 2.5 s regions still touch via the 400 ms lead-in.

### 2. Editor integration
`packages/screen_recorder/lib/ui/screens/playback_screen.dart` (modify `_initializeVideo`)

In the existing flow, after `_projectStore.load()` and before the trim/playhead controllers are set up, add:

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
      await _projectStore.save(restored);
    }
  }
} catch (e, st) {
  AppLogger.platform.w('Auto-zoom detection failed; opening editor with empty zoom lane',
      error: e, stackTrace: st);
}
_projectController.replace(restored);
```

**Why save immediately:** the detector is meant to run exactly once per recording. Saving makes the auto-placed regions instantly "user-owned" state so subsequent opens skip detection — otherwise a user who deletes a region might see it come back next launch.

**Why the `_metadata != null` guard:** the detector needs `videoSize` for rect clamping. If meta is missing (recovered file from sub-project C with a broken meta sidecar, or a very old recording), we'd zoom past edges. Better to skip than place bad regions.

**Why the top-level try/catch:** the editor must always open. Any unexpected throw from the detector or store falls through to an empty zoom lane + a logged warning.

## Data flow

```
PlaybackScreen.initState
   │
   ▼
_initializeVideo()
   ├─ VideoPlayerController.file(...) → init
   ├─ RecordingMetadata.loadForVideo(...) → _metadata
   ├─ CursorRecording.loadFromFile(.cursor.json) → _cursorRecording
   ├─ _projectStore.load() → saved
   │
   ├─ if saved.zoomRegions.isEmpty && hasClicks && metadata available:
   │     detected = AutoZoomDetector().detect(cursor, size, duration)
   │     restored = saved.copyWith(zoomRegions: detected)
   │     _projectStore.save(restored)   // make auto-placed regions "user-owned"
   │
   └─ _projectController.replace(restored)
        │
        ▼
   Timeline renders _ZoomLane with the regions.
   Existing tap/drag/trim/delete interactions apply uniformly.
```

## Error handling / edge cases

| Scenario | Behavior |
|---|---|
| `.cursor.json` missing or empty | `_cursorRecording` is empty (existing `try/catch` at line 169). `hasClicks` is false → detector skipped. |
| Cursor positions present but zero `isClicked` (idle demo) | `hasClicks` false → skipped. |
| `_metadata` null (recovered file with broken meta sidecar) | Skipped — no rect clamp possible without `videoSize`. Empty zoom lane; user places manually. |
| Two isolated clicks 1.6 s apart (overlap region duration) | Step 4 overlap filter drops the second one. User gets one region; can place a second manually. |
| Click at `t = 100 ms` (lead-in 400 ms would go negative) | `startTime` clamped to `Duration.zero`. |
| Click at `t = videoDuration - 500 ms` | Region `duration` clamped to `videoDuration - startTime`. |
| Click at the far edge of the screen | `rect` center clamped inward; rect stays fully inside video bounds. |
| `_projectStore.save()` throws | Logged via project-store's existing error path; in-memory state is still injected. Next open re-detects — acceptable. |
| Detector throws unexpectedly | Top-level try/catch in `_initializeVideo`; logged; editor opens with empty zoom lane. |
| User deletes all auto-placed regions, closes the editor, re-opens | `saved.zoomRegions` is empty again → detector re-runs and re-places them. **Known v1 wart.** A permanent "user cleared the lane" memory is future work. |
| Recording from before this sub-project shipped (already has manual zooms) | `saved.zoomRegions` non-empty → detector skipped. Existing user edits preserved. |
| Recording from before this sub-project shipped (no zoom regions, has clicks) | Detector runs on first open under the new build. User gets a pre-populated zoom lane. Acceptable — they can delete the ones they don't want. |

## Testing

**Pure unit tests** (no Flutter widget runtime, no async):
`packages/slipreel_engine/test/editor/auto_zoom_detector_test.dart`

- empty `CursorRecording` → `[]`
- recording with positions but zero clicks → `[]`
- single isolated click far from edges → one region: rect center at click, duration 2.5 s, zoom 1.5
- two clicks 3 s apart → two regions
- two clicks 0.5 s apart → no regions (both fail isolation)
- two clicks 1.6 s apart → only the first survives (second drops via overlap filter)
- click at `t = 100 ms` → region `startTime == Duration.zero`
- click at video edge (0, 0) → rect center clamped inward; rect fully inside `videoSize`
- click near end of video → region `duration` clamped to `videoDuration - startTime`

No widget tests for the integration step. The detector is pure; the editor wiring is one block that calls it. Manual smoke covers the wiring.

**Manual on-device:**

1. Record a 30 s session with 3 deliberate clicks (each ≥ 2 s apart). Open the editor → zoom lane shows 3 regions at the click moments. Play through → camera zooms to each click moment.
2. Record a button-mashing session (rapid clicks). Open the editor → zoom lane is empty or has very few regions (heuristic filtered them out).
3. Open a previously-detected recording, delete one region, close, re-open → that region comes back (the v1 wart).
4. Open a recording with pre-existing manual zooms (or where the user has already edited the lane) → no auto-detect runs.

## Out of scope

- Settings UI to tune zoom level / isolation window / duration — none in v1.
- "Run auto-zoom" button for re-detection — none in v1.
- Auto-vs-manual tagging on `ZoomRegion` — no model change; auto-placed regions are indistinguishable from manual ones.
- "Don't re-detect after I deleted everything" memory — known v1 wart per the error table.
- Follow-cursor for auto-placed regions — they're locked to the click location. User can flip to follow in the inspector.
- Drag / scroll detection — only clicks. Drag is a held click; rising-edge collapses it to one event at the down moment, which is correct.
- Smart edge-of-screen "shift toward where the user looked" — the rect clamp shifts toward center geometrically, no gaze modeling.

## Success criteria

- Opening a fresh recording with isolated clicks produces a zoom lane pre-populated with regions matching the click moments.
- Auto-placed regions are first-class — the user can drag, trim, change zoom level, or delete them via existing inspector + timeline interactions.
- A recording with no clicks (or no cursor data) opens with an empty zoom lane and no errors.
- A recording the user has already edited (zoom regions present) opens without the detector touching anything.
- `melos run analyze --no-select` clean; `melos run test --no-select` green with the new detector tests.
