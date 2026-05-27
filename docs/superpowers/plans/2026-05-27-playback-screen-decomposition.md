# playback_screen Decomposition + Async-Gap Fixes Implementation Plan (Workstream E)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extract three testable units (`HoverScrubController`, `TrimController`, `ExportController`) from the 1277-line `playback_screen.dart` god-widget WITHOUT changing behavior, and fix the async-gap / fire-and-forget patterns in `recording_bar_screen.dart` (Major #9, #12).

**Architecture:** The controllers are plain Dart classes that take the player operations they need as injected closures (`seekTo`, `pause`) and expose state + methods — so they unit-test with no real `VideoPlayerController`. The widget owns `setState` and dialogs; it delegates logic to the controllers and renders from their state. `ExportController` runs the pipeline + delivers and returns a typed result; the widget keeps showDialog/snackbar/Navigator.

**Tech Stack:** Flutter, Riverpod, Flutter test.

**Spec:** `docs/superpowers/specs/2026-05-26-critical-major-remediation-design.md` (Workstream E: E1 #9, E2 #12)

**Branch:** `remediation/critical-major`

## Ground truth (from recon)
- `playback_screen.dart` `_PlaybackScreenState` fields: `_trimSelection` (TrimSelection?, line 75), `_intendedPosition` (Duration, line 113), `_isHovering` (bool, line 118), `late VideoPlayerController _controller`, etc.
- Hover logic: `_trackIntendedPosition()` (624-631, NO setState), `_seekToStart()` (633-639), `_seekToEnd()` (641-652); reads at 949 (`isHoverScrubbing`), 1059-1061 + 1147-1149 (`pos = _isHovering ? _intendedPosition : ...`), and timeline `onSeek` (1161-1166), `onHoverSeek` (1178-1181), `onHoverEnd` (1183-1188). Seed+listener at 233-234; dispose removeListener at 291.
- Trim logic: `_enforceTrimBounds()` (259-268, pauses+seeks at trim.end when playing; NO setState); init at 209-213 + listener at 229; `onTrimChanged` (1220-1222, setState); reads at 542/551 (export), 1219 (timeline). dispose removeListener at 290.
- Export: `_export()` (359-371, `_isExporting` guard) + `_exportBody()` (373-612). The pipeline-run+deliver core is lines 533-608 (construct `ExportPipeline`/`GifExportPipeline` with `trim: _trimSelection`, `.run(onProgress: ...)`, then `store.save`, telemetry normalize, `handler.deliver`, success/failure). The dialogs (settings @408, progress @498), GIF>60s gate (440), destination selection (455-459), filename (462-466), `resolveOutputPath` (474), and snackbars/Navigator are UI and STAY in the widget.
- `recording_bar_screen.dart`: per-build post-frame `_syncMicMonitor` (193-195, re-registered every build); `ref.listen<RecordingState>` (197-208) fires unawaited `_window.showPill()/showBar()` + `_openPanel(...)` with NO mounted check; `_syncMicMonitor` dedups via `_monitoredConfig` (43-45, 69-82); `_openPanel` (87-93); reveal `Process.run('open',...)` in playback_screen at 423 (unguarded, in dialog arg) + 591-593 (Platform.isMacOS-guarded, fire-and-forget).

---

## Task 1: Extract HoverScrubController

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/playback/hover_scrub_controller.dart`
- Create: `packages/screen_recorder/test/ui/screens/playback/hover_scrub_controller_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/screens/playback/hover_scrub_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback/hover_scrub_controller.dart';

void main() {
  group('HoverScrubController', () {
    late List<Duration> seeks;
    late HoverScrubController c;
    setUp(() {
      seeks = [];
      c = HoverScrubController(seekTo: seeks.add);
    });

    test('track updates intendedPosition only when not hovering', () {
      c.track(const Duration(seconds: 1));
      expect(c.intendedPosition, const Duration(seconds: 1));
      c.hoverSeek(const Duration(seconds: 5)); // now hovering
      c.track(const Duration(seconds: 2)); // ignored while hovering
      expect(c.intendedPosition, const Duration(seconds: 1));
    });

    test('seek clears hover, sets intended, and seeks', () {
      c.hoverSeek(const Duration(seconds: 5));
      c.seek(const Duration(seconds: 3));
      expect(c.isHovering, isFalse);
      expect(c.intendedPosition, const Duration(seconds: 3));
      expect(seeks.last, const Duration(seconds: 3));
    });

    test('hoverSeek sets hovering and seeks (preview) without moving anchor', () {
      c.track(const Duration(seconds: 2));
      c.hoverSeek(const Duration(seconds: 8));
      expect(c.isHovering, isTrue);
      expect(c.intendedPosition, const Duration(seconds: 2));
      expect(seeks.last, const Duration(seconds: 8));
    });

    test('hoverEnd restores the anchor and clears hover', () {
      c.track(const Duration(seconds: 2));
      c.hoverSeek(const Duration(seconds: 8));
      c.hoverEnd();
      expect(c.isHovering, isFalse);
      expect(seeks.last, const Duration(seconds: 2));
    });

    test('hoverEnd is a no-op when not hovering', () {
      c.hoverEnd();
      expect(seeks, isEmpty);
    });

    test('seekToStart resets to zero', () {
      c.track(const Duration(seconds: 5));
      c.seekToStart();
      expect(c.isHovering, isFalse);
      expect(c.intendedPosition, Duration.zero);
      expect(seeks.last, Duration.zero);
    });

    test('seekToEnd seeks 1ms before duration, clears hover', () {
      c.hoverSeek(const Duration(seconds: 1));
      c.seekToEnd(const Duration(seconds: 10));
      expect(c.isHovering, isFalse);
      expect(seeks.last, const Duration(seconds: 10) - const Duration(milliseconds: 1));
    });

    test('seekToEnd is a no-op seek when duration is zero', () {
      c.seekToEnd(Duration.zero);
      expect(seeks, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback/hover_scrub_controller_test.dart`
Expected: FAIL (URI doesn't exist).

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/screens/playback/hover_scrub_controller.dart
import 'package:flutter/foundation.dart';

/// Owns hover-scrub state: the user's intended (anchor) position and whether
/// a hover-preview is in progress. Pure logic — the player's seek is injected
/// as [seekTo] so this unit-tests without a real VideoPlayerController.
///
/// The widget owns `setState`: it wraps the mutating methods
/// ([seek]/[hoverSeek]/[hoverEnd]/[seekToStart]/[seekToEnd]) in `setState` and
/// renders from [isHovering]/[intendedPosition]. [track] (driven by the player
/// listener) intentionally does NOT trigger a rebuild — it mirrors the old
/// `_trackIntendedPosition`, which updated the field without `setState`.
class HoverScrubController {
  HoverScrubController({required this.seekTo, Duration initialPosition = Duration.zero})
      : _intendedPosition = initialPosition;

  final void Function(Duration position) seekTo;

  Duration _intendedPosition;
  bool _isHovering = false;

  Duration get intendedPosition => _intendedPosition;
  bool get isHovering => _isHovering;

  /// Follow committed playback/seeks while NOT hovering (freezes the anchor
  /// during a hover preview).
  void track(Duration controllerPosition) {
    if (_isHovering) return;
    _intendedPosition = controllerPosition;
  }

  /// A committed seek: clears hover, moves the anchor, seeks.
  void seek(Duration next) {
    _isHovering = false;
    _intendedPosition = next;
    seekTo(next);
  }

  /// A hover preview: enters hovering (anchor frozen) and seeks to preview.
  void hoverSeek(Duration next) {
    _isHovering = true;
    seekTo(next);
  }

  /// Hover ended: restore the anchor and clear hover. No-op if not hovering.
  void hoverEnd() {
    if (!_isHovering) return;
    seekTo(_intendedPosition);
    _isHovering = false;
  }

  void seekToStart() {
    _isHovering = false;
    _intendedPosition = Duration.zero;
    seekTo(Duration.zero);
  }

  /// 1ms back from [duration] so the player doesn't auto-rewind on the next
  /// tick. No-op when [duration] is zero.
  void seekToEnd(Duration duration) {
    _isHovering = false;
    if (duration > Duration.zero) {
      seekTo(duration - const Duration(milliseconds: 1));
    }
  }
}
```
(Note: `package:flutter/foundation.dart` import is for consistency; if the analyzer flags it as unused, remove it — the class needs no Flutter import.)

- [ ] **Step 4: Run, verify pass**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback/hover_scrub_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire into playback_screen.dart (behavior-preserving)**

In `playback_screen.dart`:
- Add `import 'playback/hover_scrub_controller.dart';`.
- Replace the `_intendedPosition`/`_isHovering` fields with `late final HoverScrubController _hover;`.
- In `_initializeVideo` (replacing lines 230-234): `_hover = HoverScrubController(seekTo: _controller.seekTo, initialPosition: _controller.value.position); _controller.addListener(_onHoverTrack);` and add a private `void _onHoverTrack() => _hover.track(_controller.value.position);`.
- Delete `_trackIntendedPosition`. Replace `_seekToStart`/`_seekToEnd` bodies to delegate within setState: `void _seekToStart() => setState(() => _hover.seekToStart());` and `void _seekToEnd() => setState(() => _hover.seekToEnd(_controller.value.duration));`.
- Replace all reads: `_isHovering` → `_hover.isHovering`; `_intendedPosition` → `_hover.intendedPosition` (lines 949, 1059-1061, 1147-1149).
- Replace the timeline callbacks: `onSeek` (1161-1166) → `setState(() => _hover.seek(next)); ` (drop the now-redundant explicit `_controller.seekTo` — `seek` does it); `onHoverSeek` (1178-1181) → `setState(() => _hover.hoverSeek(next));`; `onHoverEnd` (1183-1188) → `setState(() => _hover.hoverEnd());`.
- In `dispose` (line 291) replace `_controller.removeListener(_trackIntendedPosition)` with `_controller.removeListener(_onHoverTrack)`.

- [ ] **Step 6: Verify analyze + app tests**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/screens/playback_screen.dart lib/ui/screens/playback/hover_scrub_controller.dart`
Expected: no new errors/warnings (no dangling `_isHovering`/`_intendedPosition`/`_trackIntendedPosition`).
Run: `cd packages/screen_recorder && flutter test`
Expected: PASS (report count).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback/hover_scrub_controller.dart packages/screen_recorder/test/ui/screens/playback/hover_scrub_controller_test.dart packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "refactor(app): extract testable HoverScrubController from playback_screen"
```

---

## Task 2: Extract TrimController

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/playback/trim_controller.dart`
- Create: `packages/screen_recorder/test/ui/screens/playback/trim_controller_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/screens/playback/trim_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/trim_selection.dart';
import 'package:screen_recorder/ui/screens/playback/trim_controller.dart';

void main() {
  group('TrimController', () {
    late int pauses;
    late List<Duration> seeks;
    late TrimController c;
    setUp(() {
      pauses = 0;
      seeks = [];
      c = TrimController(pause: () => pauses++, seekTo: seeks.add);
    });

    test('enforce pauses + seeks to end when playing past trim.end', () {
      c.selection = TrimSelection(
          start: Duration.zero, end: const Duration(seconds: 5));
      c.enforce(isPlaying: true, position: const Duration(seconds: 6));
      expect(pauses, 1);
      expect(seeks.last, const Duration(seconds: 5));
    });

    test('enforce does nothing when not playing', () {
      c.selection = TrimSelection(
          start: Duration.zero, end: const Duration(seconds: 5));
      c.enforce(isPlaying: false, position: const Duration(seconds: 6));
      expect(pauses, 0);
      expect(seeks, isEmpty);
    });

    test('enforce does nothing before trim.end', () {
      c.selection = TrimSelection(
          start: Duration.zero, end: const Duration(seconds: 5));
      c.enforce(isPlaying: true, position: const Duration(seconds: 4));
      expect(pauses, 0);
      expect(seeks, isEmpty);
    });

    test('enforce is a no-op when no selection', () {
      c.enforce(isPlaying: true, position: const Duration(seconds: 6));
      expect(pauses, 0);
      expect(seeks, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback/trim_controller_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/screens/playback/trim_controller.dart
import 'package:slipreel_engine/models/trim_selection.dart';

/// Owns the trim selection and soft-enforces it during playback: when the
/// playhead crosses `trim.end` while playing, it pauses and parks at the end.
/// Player ops are injected so this unit-tests without a VideoPlayerController.
class TrimController {
  TrimController({required this.pause, required this.seekTo});

  final void Function() pause;
  final void Function(Duration position) seekTo;

  /// Current trim selection (null until the video initializes / when cleared).
  TrimSelection? selection;

  /// Called on each player tick. Soft-enforces the trim end while playing.
  void enforce({required bool isPlaying, required Duration position}) {
    final trim = selection;
    if (trim == null || !isPlaying) return;
    if (position >= trim.end) {
      pause();
      seekTo(trim.end);
    }
  }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback/trim_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire into playback_screen.dart**

- Add `import 'playback/trim_controller.dart';`.
- Replace the `_trimSelection` field with `late final TrimController _trim;` and a getter `TrimSelection? get _trimSelection => _trim.selection;` (keeps the existing read sites at 542/551/1219 unchanged).
- In `_initializeVideo`: before the trim init, create `_trim = TrimController(pause: _controller.pause, seekTo: _controller.seekTo);`. Replace the `_trimSelection = TrimSelection(...)` (209-213) with `_trim.selection = TrimSelection(start: Duration.zero, end: _controller.value.duration, videoDuration: _controller.value.duration);`. Replace `_controller.addListener(_enforceTrimBounds)` (229) with `_controller.addListener(_onTrimTick)` and add `void _onTrimTick() { final v = _controller.value; _trim.enforce(isPlaying: v.isPlaying, position: v.position); }`.
- Delete `_enforceTrimBounds`.
- The timeline `onTrimChanged` (1220-1222) becomes `setState(() => _trim.selection = next);`.
- In `dispose` (290) replace `_controller.removeListener(_enforceTrimBounds)` with `_controller.removeListener(_onTrimTick)`.

- [ ] **Step 6: Verify + commit**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/screens/playback_screen.dart lib/ui/screens/playback/trim_controller.dart` (no dangling `_enforceTrimBounds`).
Run: `cd packages/screen_recorder && flutter test` → PASS.
```bash
git add packages/screen_recorder/lib/ui/screens/playback/trim_controller.dart packages/screen_recorder/test/ui/screens/playback/trim_controller_test.dart packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "refactor(app): extract testable TrimController from playback_screen"
```

---

## Task 3: Extract ExportController (pipeline run + deliver)

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/playback/export_controller.dart`
- Create: `packages/screen_recorder/test/ui/screens/playback/export_controller_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

**Design:** `ExportController` owns ONLY the headless part: pick the pipeline by format, run it with a progress callback, persist settings + telemetry, deliver via the handler, and return a typed `ExportOutcome` (`success(DeliveryResult)` | `failure(Object error)` | `cancelled`). It does NOT touch BuildContext/Navigator/ScaffoldMessenger — the widget keeps all dialogs/snackbars and only calls `ExportController.run(...)`. The pipelines are injected via a factory so the test runs without ffmpeg.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/screens/playback/export_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';
import 'package:screen_recorder/ui/screens/playback/export_controller.dart';
import 'package:screen_recorder/services/destination_handlers.dart';

ExportPerfSummary _summary() => const ExportPerfSummary(
      inputDurationSeconds: 1,
      wallTimeSeconds: 1,
      decodeMsPerFrame: 1,
      compositeMsPerFrame: 1,
      encodeMsPerFrame: 1,
      outputBytes: 100,
      outputCodec: 'h264',
      usedHardwareEncoder: true,
    );

class _FakeHandler implements DestinationHandler {
  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) async =>
      '/tmp/out.mp4';
  @override
  Future<DeliveryResult> deliver(String path) async =>
      const DeliveryResult(message: 'Saved', revealPath: '/tmp/out.mp4');
}

void main() {
  test('run reports progress, delivers, returns success', () async {
    final progress = <double>[];
    final c = ExportController(
      runPipeline: ({required onProgress, required cancelToken}) async {
        onProgress(0.5);
        onProgress(1.0);
        return _summary();
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _FakeHandler(),
      onProgress: progress.add,
    );
    expect(progress, [0.5, 1.0]);
    expect(outcome, isA<ExportSuccess>());
    expect((outcome as ExportSuccess).result.message, 'Saved');
  });

  test('run returns failure when the pipeline throws', () async {
    final c = ExportController(
      runPipeline: ({required onProgress, required cancelToken}) async {
        throw Exception('boom');
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _FakeHandler(),
      onProgress: (_) {},
    );
    expect(outcome, isA<ExportFailure>());
  });

  test('run returns cancelled on ExportCancelledException', () async {
    final c = ExportController(
      runPipeline: ({required onProgress, required cancelToken}) async {
        throw const ExportCancelledException();
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _FakeHandler(),
      onProgress: (_) {},
    );
    expect(outcome, isA<ExportCancelled>());
  });
}
```

- [ ] **Step 2: Run, verify fail**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback/export_controller_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/screens/playback/export_controller.dart
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';

import '../../../services/destination_handlers.dart';

/// Headless outcome of an export run. The widget maps these to UI.
sealed class ExportOutcome {
  const ExportOutcome();
}

class ExportSuccess extends ExportOutcome {
  const ExportSuccess(this.summary, this.result);
  final ExportPerfSummary summary;
  final DeliveryResult result;
}

class ExportFailure extends ExportOutcome {
  const ExportFailure(this.error);
  final Object error;
}

class ExportCancelled extends ExportOutcome {
  const ExportCancelled();
}

/// Signature for running the chosen export pipeline. Injected so the widget
/// passes a closure that builds the right `ExportPipeline`/`GifExportPipeline`
/// and the test passes a fake.
typedef RunPipeline = Future<ExportPerfSummary> Function({
  required void Function(double progress) onProgress,
  required CancelToken cancelToken,
});

/// Runs an export pipeline and delivers the output, returning a typed outcome.
/// Contains NO UI — dialogs/snackbars stay in the widget.
class ExportController {
  ExportController({required this.runPipeline});

  final RunPipeline runPipeline;
  final CancelToken cancelToken = CancelToken();

  /// Runs the pipeline (reporting progress), then delivers via [handler].
  /// Returns [ExportSuccess], [ExportFailure], or [ExportCancelled].
  Future<ExportOutcome> run({
    required String outputPath,
    required DestinationHandler handler,
    required void Function(double progress) onProgress,
  }) async {
    try {
      final summary = await runPipeline(
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      final result = await handler.deliver(outputPath);
      return ExportSuccess(summary, result);
    } on ExportCancelledException {
      return const ExportCancelled();
    } catch (e) {
      return ExportFailure(e);
    }
  }

  void cancel() => cancelToken.cancel();
}
```
NOTE: confirm `DeliveryResult` has `message` and `revealPath` fields (it's used in playback_screen at result.message/result.revealPath). If `DestinationHandler`/`DeliveryResult` signatures differ, match `lib/services/destination_handlers.dart`.

- [ ] **Step 4: Run, verify pass**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback/export_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire into playback_screen.dart**

Refactor `_exportBody` (lines 533-608, the inner `try { showDialog(progress)... pipeline.run ... deliver ... snackbar } catch ...`) to delegate the run+deliver to `ExportController`:
- Keep everything up to and including showing the progress dialog (line 531) in the widget.
- Build the `RunPipeline` closure capturing the already-resolved locals (`settings`, `meta`, `cursorRec`, `outPath`, `_project`, `_trimSelection`, `widget.videoPath`):
```dart
        final controller = ExportController(
          runPipeline: ({required onProgress, required cancelToken}) {
            return settings!.format == ExportFormat.gif
                ? GifExportPipeline(
                    sourcePath: widget.videoPath,
                    outputPath: outPath!,
                    sourceMetadata: meta,
                    cursorRecording: cursorRec,
                    projectState: _project,
                    settings: settings,
                    trim: _trimSelection,
                  ).run(onProgress: onProgress, cancelToken: cancelToken)
                : ExportPipeline(
                    sourcePath: widget.videoPath,
                    outputPath: outPath,
                    sourceMetadata: meta,
                    cursorRecording: cursorRec,
                    projectState: _project,
                    settings: settings,
                    trim: _trimSelection,
                  ).run(onProgress: onProgress, cancelToken: cancelToken);
          },
        );
        final outcome = await controller.run(
          outputPath: outPath,
          handler: handler,
          onProgress: (p) => progress.value = p,
        );
        if (!mounted) return;
        Navigator.of(context).pop(); // close progress dialog
        switch (outcome) {
          case ExportSuccess(:final summary, :final result):
            // settings + telemetry persistence (moved verbatim from 558-573)
            await store.save(settings.copyWith(clearTitle: true));
            if (settings.format == ExportFormat.mp4 && summary.realtimeMultiple > 0) {
              final outDims = settings.resolution.dimensionsFor(sourceVideoSize);
              final outArea = outDims.width * outDims.height;
              final fpsScale = settings.frameRate / kBaselineFrameRate;
              final areaScale = outArea / kBaselineAreaPixels;
              unawaited(telemetryStore.saveRealtimeMultiplier(
                  summary.realtimeMultiple * fpsScale * areaScale));
            }
            if (!mounted) return;
            setState(() => _lastExportPath = outPath);
            ScaffoldMessenger.of(context).showSnackBar(/* success snackbar, verbatim 582-598 */);
          case ExportFailure(:final error):
            ScaffoldMessenger.of(context).showSnackBar(/* 'Export failed: $error' red snackbar */);
          case ExportCancelled():
            // No snackbar — user-initiated. (Today there's no cancel UI; this
            // arm is here for when a cancel button is wired to controller.cancel().)
            break;
        }
```
- Add `import 'playback/export_controller.dart';`. Remove the now-moved `handler.deliver`/persistence from the old inline path. Keep the `progress` ValueNotifier + its `finally { progress.dispose(); }` and the outer try.
- IMPORTANT: preserve the exact success-snackbar (with the `Platform.isMacOS` reveal action) and failure-snackbar text from lines 582-607 — move them verbatim into the `switch` arms.

- [ ] **Step 6: Verify analyze + app tests**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/screens/playback_screen.dart lib/ui/screens/playback/export_controller.dart`
Expected: no new errors/warnings.
Run: `cd packages/screen_recorder && flutter test`
Expected: PASS — incl. `playback_screen_export_test.dart` (drives the settings ExportDialog; unaffected).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback/export_controller.dart packages/screen_recorder/test/ui/screens/playback/export_controller_test.dart packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "refactor(app): extract testable ExportController (pipeline run + deliver)"
```

---

## Task 4: Fix async-gaps in recording_bar_screen + reveal calls (E2)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

- [ ] **Step 1: Move the recording→pill/panel listener to a guarded, init-registered listener**

In `recording_bar_screen.dart`, the `ref.listen<RecordingState>` is registered inside `build()` and fires unawaited async `_window.*` with no `mounted` guard. Replace the in-`build` registration with `ref.listenManual` registered ONCE in `initState` (Riverpod `ConsumerStatefulWidget`), and add a `mounted` guard + `unawaited` to the fire-and-forget calls. The callback body becomes:
```dart
    (prev, next) {
      if (!mounted) return;
      if (next.status == RecordingStatus.recording ||
          next.status == RecordingStatus.processing) {
        unawaited(_window.showPill());
      } else if (prev?.status != RecordingStatus.completed &&
          next.status == RecordingStatus.completed &&
          next.videoPath != null) {
        unawaited(_openPanel(PlaybackScreen(videoPath: next.videoPath!)));
      } else if (next.status == RecordingStatus.error) {
        unawaited(_window.showBar());
      }
    }
```
Register in initState: `ref.listenManual(recordingControllerProvider, <the callback above>);` (import `dart:async` for `unawaited` if not already). Remove the `ref.listen(...)` from `build()`.

- [ ] **Step 2: Drive _syncMicMonitor from provider listeners, not a per-build post-frame callback**

Replace the per-build `WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _syncMicMonitor(mode, mic); })` (193-195) with `ref.listenManual` registrations in `initState` for the two providers feeding it (window mode + microphone config), plus one initial `_syncMicMonitor(...)` call in initState (read current values). Keep the `_monitoredConfig` dedup. The exact providers: `mode` comes from `windowModeControllerProvider`, `mic` from the microphone provider (confirm the provider names by reading the current `build()` where `mode`/`mic` are computed at ~191-192). Each listener calls `_syncMicMonitor(currentMode, currentMic)`.

- [ ] **Step 3: Guard `_openPanel`'s trailing ref use**

In `_openPanel` (87-93), add a `mounted` check before the final `_window.showBar()` (it uses `ref` after the awaited `Navigator.push`):
```dart
  Future<void> _openPanel(Widget child) async {
    await _window.showPanel();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => child));
    if (!mounted) return;
    await _window.showBar();
  }
```
(The recon shows line 91 already guards before showBar — verify; if the guard is missing immediately before `_window.showBar()`, add it. If already present, no change needed for this step.)

- [ ] **Step 4: unawaited + error-handle the reveal Process.run calls (playback_screen)**

In `playback_screen.dart`:
- Line 423 (dialog arg, unguarded): wrap with `Platform.isMacOS` + unawaited + catch:
```dart
          onRevealLastExport: _lastExportPath == null
              ? null
              : () {
                  if (Platform.isMacOS) {
                    unawaited(Process.run('open', ['-R', _lastExportPath!])
                        .catchError((_) => ProcessResult(0, 1, '', '')));
                  }
                },
```
- The success-snackbar reveal (now in the Task-3 switch arm, formerly 591-593): same `unawaited(Process.run(...).catchError(...))` treatment, keeping the `Platform.isMacOS` guard.
(`unawaited` needs `import 'dart:async';` — add if missing. `ProcessResult` is from `dart:io`, already imported.)

- [ ] **Step 5: Verify + commit**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/bar/recording_bar_screen.dart lib/ui/screens/playback_screen.dart`
Expected: no new errors/warnings (esp. `unawaited_futures` / `use_build_context_synchronously` if those lints are active).
Run: `cd packages/screen_recorder && flutter test`
Expected: PASS (report count). Pay attention to `recording_bar_screen` widget tests if any — confirm the recording→panel transition still works.
```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "fix(app): move ref.listen/mic-sync out of build, guard async gaps + reveal calls"
```

---

## Self-Review

**Spec coverage (E):**
- E1 #9 decomposition → Task 1 (HoverScrubController) + Task 2 (TrimController) + Task 3 (ExportController), each a testable unit with the widget retaining UI. ✓
- E2 #12 async-gaps → Task 4 (ref.listen → init-registered + mounted-guarded; mic-sync off per-build post-frame → provider listeners; _openPanel trailing guard; reveal Process.run unawaited+caught+guarded). ✓

**Placeholder scan:** Tasks 1-2 have complete code. Task 3 Step 5 and Task 4 Step 2 reference "verbatim move from lines N-M" for snackbar bodies / provider names rather than re-pasting large widget literals — the engineer moves the EXISTING code (it's in the file) into the new structure. This is intentional for behavior-preserving extraction; the snackbar/provider code already exists and must be moved unchanged. Flagged so the engineer copies verbatim, not rewrites.

**Type consistency:** `HoverScrubController` (`seekTo`, `track`, `seek`, `hoverSeek`, `hoverEnd`, `seekToStart`, `seekToEnd`, `isHovering`, `intendedPosition`) consistent between Task 1 def and the wiring in Step 5. `TrimController` (`selection`, `enforce(isPlaying, position)`, `pause`, `seekTo`) consistent. `ExportController`/`ExportOutcome`/`ExportSuccess`/`ExportFailure`/`ExportCancelled`/`RunPipeline` consistent between Task 3 def, test, and wiring.

**Risks / confirm during execution:**
- Behavior preservation is paramount — these are refactors. After each task, the FULL app test suite must stay green (204 passed baseline). If any widget test breaks, the extraction changed behavior — fix to match the original.
- Confirm `ref.listenManual` is available (Riverpod ≥2.x — the repo uses flutter_riverpod ^2.5.1, which has it). If the widget isn't already a `ConsumerStatefulWidget` with a ref usable in initState, use the appropriate Riverpod pattern.
- Confirm `DestinationHandler`/`DeliveryResult`/`ExportPerfSummary.realtimeMultiple` field names against the real sources before finalizing Task 3.
- Task 3 is the riskiest; if the switch-arm refactor proves to subtly change behavior, the fallback is to keep the orchestration inline but still route the run+deliver through `ExportController.run` (minimal change), preserving all surrounding UI exactly.
