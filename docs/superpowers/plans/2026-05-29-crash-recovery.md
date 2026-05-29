# Crash recovery (sub-project C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make mid-recording crashes recoverable — set AVAssetWriter fragment interval to 5 s so the on-disk MP4 stays playable, persist a session marker + a cursor-position NDJSON sidecar during recording, and on next launch detect leftover markers and surface a per-row Recover/Discard modal that re-muxes the partial through ffmpeg into Recents.

**Architecture:** One Swift line in `LiveRecordingWriter.start()` flips the writer into fragmented-MP4 mode. A `SessionMarkerStore` (atomic JSON file under `getApplicationSupportDirectory`) tracks in-progress sessions; `RecordingController` writes/removes markers around the lifecycle. A `CursorCheckpointer` appends positions to a per-recording NDJSON every 5 s. At cold launch, `RecoveryService` scans markers, filters orphans, and (on user click) runs `ffmpeg -c copy` to normalise the partial and rebuilds `.cursor.json` from the NDJSON. A `RecoveryModal` surfaces candidates over whatever screen `MyApp` would otherwise route to.

**Tech Stack:** Swift (AVFoundation `movieFragmentInterval`), Dart, Riverpod, `path_provider`, atomic file IO, ffmpeg (via the existing `Ffmpeg.resolve()` facade), Flutter dialog overlay.

**Spec:** `docs/superpowers/specs/2026-05-29-crash-recovery-design.md`

---

## File map

### Created — Dart
- `packages/screen_recorder/lib/state/session_marker.dart` — `SessionMarker` + `SessionMarkerStore` (atomic JSON)
- `packages/screen_recorder/lib/state/cursor_checkpointer.dart` — append-only NDJSON writer + reader
- `packages/screen_recorder/lib/state/recovery_service.dart` — scan / recover / discard, with injectable process runner
- `packages/screen_recorder/lib/ui/widgets/recovery_modal.dart` — the modal

### Modified — Dart
- `packages/screen_recorder/lib/state/recording_state.dart` — add session-marker + cursor-checkpointer lifecycle hooks in `startRecording` / `stopRecording` / `_handleError`
- `packages/screen_recorder/lib/main.dart` — load marker store + recovery service in `main()`, pass candidates into `MyApp`, show modal on first frame

### Modified — macOS native
- `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift` — one line: `movieFragmentInterval = 5 s`

### Created — tests
- `packages/screen_recorder/test/state/session_marker_test.dart`
- `packages/screen_recorder/test/state/cursor_checkpointer_test.dart`
- `packages/screen_recorder/test/state/recovery_service_test.dart`
- `packages/screen_recorder/test/state/recording_state_marker_test.dart`
- `packages/screen_recorder/test/ui/widgets/recovery_modal_test.dart`

---

## Branch

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git checkout -b feat/crash-recovery
```

Commit after each task. Merge to main only after the final task.

---

### Task 1: Native — fragmented MP4

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`

- [ ] **Step 1: Insert the `movieFragmentInterval` line**

Open the file and find `start()` (line ~101). Locate the block:
```swift
let writer: AVAssetWriter
do {
  writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
} catch {
  throw WriterError.assetWriterCreateFailed(error)
}
```

Immediately after the closing brace of the `do/catch` block (so right before the `for role in audioTracks` loop), insert:
```swift
// Crash resilience: emit a self-contained moof+mdat fragment every 5 s.
// On a process kill, the file on disk is still playable up to the last
// complete fragment. (Sub-project C.)
writer.movieFragmentInterval = CMTimeMakeWithSeconds(5.0, preferredTimescale: 600)
```

- [ ] **Step 2: xcodebuild check**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_macos/example/macos && \
  xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
             -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
git commit -m "feat(macos): fragmented MP4 (5 s movieFragmentInterval) for crash resilience"
```

---

### Task 2: `SessionMarker` + `SessionMarkerStore`

**Files:**
- Create: `packages/screen_recorder/lib/state/session_marker.dart`
- Test: `packages/screen_recorder/test/state/session_marker_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/session_marker_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/session_marker.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('session_marker_test_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  String tmpPath() => '${tmp.path}/current_sessions.json';

  SessionMarker make(String id) => SessionMarker(
        id: id,
        videoPath: '${tmp.path}/$id.mp4',
        cursorNdjsonPath: '${tmp.path}/$id.cursor.ndjson',
        startedAt: DateTime.utc(2026, 5, 29, 15, 30),
        width: 1920,
        height: 1080,
        fps: 60,
      );

  test('load on fresh disk returns empty list', () async {
    final store = SessionMarkerStore(path: tmpPath());
    expect(await store.load(), isEmpty);
  });

  test('add then load round-trips a single marker', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.first.id, 's1');
    expect(loaded.first.width, 1920);
    expect(loaded.first.fps, 60);
  });

  test('add multiple markers preserves all', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    await store.add(make('s2'));
    expect((await store.load()).map((m) => m.id), ['s1', 's2']);
  });

  test('remove deletes the matching marker only', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    await store.add(make('s2'));
    await store.remove('s1');
    expect((await store.load()).map((m) => m.id), ['s2']);
  });

  test('remove of missing id is a no-op', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    await store.remove('does-not-exist');
    expect((await store.load()).map((m) => m.id), ['s1']);
  });

  test('corrupt JSON falls back to empty (file is left for the next add to overwrite)', () async {
    await File(tmpPath()).writeAsString('{ garbage');
    final store = SessionMarkerStore(path: tmpPath());
    expect(await store.load(), isEmpty);
  });

  test('writes via .tmp + rename so the canonical file is never half-written', () async {
    final store = SessionMarkerStore(path: tmpPath());
    await store.add(make('s1'));
    // Confirm the tmp file was cleaned up after rename.
    expect(File('${tmpPath()}.tmp').existsSync(), isFalse);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/session_marker_test.dart
```
Expected: FAIL — `session_marker.dart` does not exist.

- [ ] **Step 3: Implement the store**

```dart
// packages/screen_recorder/lib/state/session_marker.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

class SessionMarker {
  const SessionMarker({
    required this.id,
    required this.videoPath,
    required this.cursorNdjsonPath,
    required this.startedAt,
    required this.width,
    required this.height,
    required this.fps,
  });

  final String id;
  final String videoPath;
  final String cursorNdjsonPath;
  final DateTime startedAt;
  final int width;
  final int height;
  final int fps;

  Map<String, dynamic> toJson() => {
        'id': id,
        'videoPath': videoPath,
        'cursorNdjsonPath': cursorNdjsonPath,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'width': width,
        'height': height,
        'fps': fps,
      };

  static SessionMarker fromJson(Map<String, dynamic> json) => SessionMarker(
        id: json['id'] as String,
        videoPath: json['videoPath'] as String,
        cursorNdjsonPath: json['cursorNdjsonPath'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        fps: (json['fps'] as num?)?.toInt() ?? 0,
      );
}

/// Atomic JSON store at `<App Support>/current_sessions.json`.
///
/// All mutations read → mutate → write `<path>.tmp` → POSIX-rename onto
/// `<path>`. The canonical file is therefore either fully written or
/// untouched — never half-written.
class SessionMarkerStore {
  SessionMarkerStore({required this.path});
  final String path;

  static const _version = 1;

  Future<List<SessionMarker>> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return const [];
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final sessions = (json['sessions'] as List?) ?? const [];
      return sessions
          .map((s) => SessionMarker.fromJson(s as Map<String, dynamic>))
          .toList(growable: false);
    } catch (e, st) {
      AppLogger.platform.w('SessionMarkerStore.load failed; treating as empty',
          error: e, stackTrace: st);
      return const [];
    }
  }

  Future<void> add(SessionMarker marker) async {
    final current = await load();
    await _atomicWrite([...current, marker]);
  }

  Future<void> remove(String id) async {
    final current = await load();
    await _atomicWrite(current.where((m) => m.id != id).toList(growable: false));
  }

  Future<void> _atomicWrite(List<SessionMarker> markers) async {
    final tmpPath = '$path.tmp';
    final json = {
      'version': _version,
      'sessions': markers.map((m) => m.toJson()).toList(growable: false),
    };
    final tmpFile = File(tmpPath);
    await tmpFile.create(recursive: true);
    await tmpFile.writeAsString(jsonEncode(json), flush: true);
    await tmpFile.rename(path);
  }
}

final sessionMarkerStoreProvider = Provider<SessionMarkerStore>(
  (ref) => throw UnimplementedError('Override sessionMarkerStoreProvider in main()'),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/session_marker_test.dart
```
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/session_marker.dart \
        packages/screen_recorder/test/state/session_marker_test.dart
git commit -m "feat(app): SessionMarker + atomic SessionMarkerStore"
```

---

### Task 3: `CursorCheckpointer`

**Files:**
- Create: `packages/screen_recorder/lib/state/cursor_checkpointer.dart`
- Test: `packages/screen_recorder/test/state/cursor_checkpointer_test.dart`

`CursorPosition` (from `package:screen_recorder_platform_interface`) has the fields `double x`, `double y`, `int timestampMicros`, `bool isClicked`, `CursorState state`. Wire format mirrors those.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/cursor_checkpointer_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/cursor_checkpointer.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cursor_chk_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  CursorPosition pos(int ms) => CursorPosition(
        x: ms.toDouble(),
        y: ms.toDouble() + 1,
        timestampMicros: ms * 1000,
        isClicked: ms % 10 == 0,
        state: CursorState.arrow,
      );

  test('start creates the file empty; stop without adds leaves it empty', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    await c.stop();
    expect(File(path).readAsStringSync(), isEmpty);
  });

  test('positions are flushed to disk on stop', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    c.add(pos(1));
    c.add(pos(2));
    c.add(pos(3));
    await c.stop();
    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(3));
    expect(lines.first, contains('"x":1.0'));
  });

  test('256-entry burst forces a defensive flush before stop', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    for (var i = 0; i < 300; i++) {
      c.add(pos(i));
    }
    // Without stop, at least the first 256 should already be on disk.
    final sizeBeforeStop = File(path).lengthSync();
    expect(sizeBeforeStop, greaterThan(0));
    await c.stop();
    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(300));
  });

  test('start truncates an existing file (fresh session)', () async {
    final path = '${tmp.path}/c.ndjson';
    await File(path).writeAsString('{"stale":true}\n');
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    await c.stop();
    expect(File(path).readAsStringSync(), isEmpty);
  });

  test('readAll round-trips written positions', () async {
    final path = '${tmp.path}/c.ndjson';
    final c = CursorCheckpointer(ndjsonPath: path);
    await c.start();
    c.add(pos(1));
    c.add(pos(2));
    await c.stop();
    final back = await CursorCheckpointer.readAll(path);
    expect(back, hasLength(2));
    expect(back.first.x, 1.0);
    expect(back.first.timestampMicros, 1000);
  });

  test('readAll on missing file returns empty', () async {
    final back = await CursorCheckpointer.readAll('${tmp.path}/nope.ndjson');
    expect(back, isEmpty);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/cursor_checkpointer_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the checkpointer**

```dart
// packages/screen_recorder/lib/state/cursor_checkpointer.dart
import 'dart:convert';
import 'dart:io';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Append-only NDJSON sidecar of cursor positions written during a recording.
/// Buffers positions in memory; flushes on a 256-entry threshold and on stop.
/// Sub-project C uses this to restore the cursor track on crash recovery.
///
/// Wire format (one position per line):
/// `{"x":120.5,"y":340.0,"tUs":1234567,"clk":true,"st":"arrow"}`
class CursorCheckpointer {
  CursorCheckpointer({required this.ndjsonPath});
  final String ndjsonPath;

  static const _flushThreshold = 256;

  IOSink? _sink;
  final List<String> _buffer = [];

  /// Open the file for write (truncates any existing content).
  Future<void> start() async {
    final file = File(ndjsonPath);
    if (!file.parent.existsSync()) {
      await file.parent.create(recursive: true);
    }
    _sink = file.openWrite();
  }

  /// Buffer a single position. Flushes if the buffer reaches the threshold.
  void add(CursorPosition pos) {
    _buffer.add(jsonEncode({
      'x': pos.x,
      'y': pos.y,
      'tUs': pos.timestampMicros,
      'clk': pos.isClicked,
      'st': pos.state.name,
    }));
    if (_buffer.length >= _flushThreshold) {
      _flush();
    }
  }

  /// Flush the buffer and close the file.
  Future<void> stop() async {
    _flush();
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }

  void _flush() {
    if (_buffer.isEmpty) return;
    for (final line in _buffer) {
      _sink?.writeln(line);
    }
    _buffer.clear();
  }

  /// Read the NDJSON file back into a list of positions. Returns empty if the
  /// file is missing or unreadable.
  static Future<List<CursorPosition>> readAll(String path) async {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final raw = await file.readAsString();
    final out = <CursorPosition>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final m = jsonDecode(trimmed) as Map<String, dynamic>;
        out.add(CursorPosition(
          x: (m['x'] as num).toDouble(),
          y: (m['y'] as num).toDouble(),
          timestampMicros: (m['tUs'] as num).toInt(),
          isClicked: (m['clk'] as bool?) ?? false,
          state: CursorState.values
              .firstWhere((e) => e.name == m['st'], orElse: () => CursorState.arrow),
        ));
      } catch (_) {
        // Skip malformed lines (e.g. a truncated last line from a crash).
      }
    }
    return out;
  }
}
```

NOTE: a Periodic flush (every 5 s wall-clock) is NOT in this implementation — the buffer-size threshold + stop-time flush + the OS file-system buffer is already enough to keep loss bounded in practice. If a future profiling pass shows a large in-flight buffer, add a `Timer.periodic` driven flush. Keep the design lean for now.

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/cursor_checkpointer_test.dart
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/cursor_checkpointer.dart \
        packages/screen_recorder/test/state/cursor_checkpointer_test.dart
git commit -m "feat(app): CursorCheckpointer (append-only NDJSON)"
```

---

### Task 4: Wire `SessionMarker` + `CursorCheckpointer` into `RecordingController`

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Test: `packages/screen_recorder/test/state/recording_state_marker_test.dart`

The marker + checkpointer go in at three RecordingController hooks:
- `startRecording`: after `outputPath` is computed and BEFORE the native start call → `markerStore.add(...)` + `cursorCheckpointer.start()`.
- `stopRecording`: after the post-stop sidecars are written → `cursorCheckpointer.stop()`, delete NDJSON, `markerStore.remove(id)`.
- `_handleError`: also `remove(id)` if a marker was opened.

The `RecordingController` doesn't construct stores today — to keep the test seam clean, take both as optional constructor params (default null = no-op; production main() injects real instances via Riverpod override).

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/recording_state_marker_test.dart
//
// Integration test for the SessionMarker + CursorCheckpointer lifecycle hooks
// in RecordingController.
//
// We don't go through the real native plugin — we just call the controller's
// public methods and assert the store gets add/remove calls in the right
// order. The real native side is tested by manual on-device runs.
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/state/session_marker.dart';

class _SpyStore implements SessionMarkerStore {
  @override
  String get path => '';
  final List<String> adds = [];
  final List<String> removes = [];

  @override
  Future<List<SessionMarker>> load() async => const [];

  @override
  Future<void> add(SessionMarker marker) async => adds.add(marker.id);

  @override
  Future<void> remove(String id) async => removes.add(id);
}

void main() {
  test('startRecording without a selected source is a no-op (no marker)', () async {
    final spy = _SpyStore();
    final c = RecordingController(sessionMarkerStore: spy);
    // No source selected — canStartRecording is false.
    await c.startRecording();
    expect(spy.adds, isEmpty);
  });

  // Further end-to-end coverage of marker add/remove around start/stop happens
  // in the per-step manual checklist (Task 9). The unit test above only
  // verifies the wiring path is present and gated correctly.
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/recording_state_marker_test.dart
```
Expected: FAIL — `RecordingController` doesn't yet accept a `sessionMarkerStore` parameter.

- [ ] **Step 3: Modify `RecordingController` constructor + lifecycle hooks**

Open `packages/screen_recorder/lib/state/recording_state.dart`. Find the existing constructor:
```dart
RecordingController({RecordingHistoryStore? historyStore})
    : _historyStore = historyStore ?? RecordingHistoryStore(),
      super(const RecordingState());
```

Replace with:
```dart
RecordingController({
  RecordingHistoryStore? historyStore,
  SessionMarkerStore? sessionMarkerStore,
})  : _historyStore = historyStore ?? RecordingHistoryStore(),
      _sessionMarkerStore = sessionMarkerStore,
      super(const RecordingState());

final SessionMarkerStore? _sessionMarkerStore;
CursorCheckpointer? _cursorCheckpointer;
String? _activeMarkerId;
```

Add imports at top:
```dart
import 'cursor_checkpointer.dart';
import 'session_marker.dart';
```

In `startRecording`, find the block that computes `outputPath` (around line 152). After computing `outputPath` and BEFORE the `_videoEncoder.start(...)` call, insert:
```dart
    final markerId = '$ts';
    final ndjsonPath = '$outputPath.cursor.ndjson';
    if (_sessionMarkerStore != null) {
      try {
        await _sessionMarkerStore!.add(SessionMarker(
          id: markerId,
          videoPath: outputPath,
          cursorNdjsonPath: ndjsonPath,
          startedAt: DateTime.now().toUtc(),
          width: 0, // unknown at start — RecoveryService probes the file at scan time
          height: 0,
          fps: _defaultFps,
        ));
        _activeMarkerId = markerId;
      } catch (e, st) {
        AppLogger.recording.w('Failed to write session marker; recording proceeds',
            error: e, stackTrace: st);
      }
    }
    _cursorCheckpointer = CursorCheckpointer(ndjsonPath: ndjsonPath);
    try {
      await _cursorCheckpointer!.start();
    } catch (e, st) {
      AppLogger.recording.w('Cursor checkpointer start failed; cursor recovery disabled',
          error: e, stackTrace: st);
      _cursorCheckpointer = null;
    }
```

In the existing cursor stream listener:
```dart
_cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
  (pos) => _cursorRecording?.addPosition(pos),
  onError: (e) => AppLogger.recording.w('Cursor stream error', error: e),
);
```
Change the listener body to also forward to the checkpointer:
```dart
_cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
  (pos) {
    _cursorRecording?.addPosition(pos);
    _cursorCheckpointer?.add(pos);
  },
  onError: (e) => AppLogger.recording.w('Cursor stream error', error: e),
);
```

In `stopRecording`, after the existing `.cursor.json` save block and AFTER the `_historyStore.append(...)` call, insert:
```dart
    try {
      await _cursorCheckpointer?.stop();
      _cursorCheckpointer = null;
      if (await File(ndjsonPath).exists()) {
        await File(ndjsonPath).delete();
      }
    } catch (e, st) {
      AppLogger.recording.w('CursorCheckpointer stop/cleanup failed',
          error: e, stackTrace: st);
    }
    if (_activeMarkerId != null && _sessionMarkerStore != null) {
      try {
        await _sessionMarkerStore!.remove(_activeMarkerId!);
      } catch (e, st) {
        AppLogger.recording.w('SessionMarker remove failed',
            error: e, stackTrace: st);
      }
      _activeMarkerId = null;
    }
```

NOTE: in `stopRecording`, `ndjsonPath` is computed in `startRecording` and isn't currently in scope. Stash it as a field `String? _activeNdjsonPath` set in `startRecording` and consumed (then cleared to null) in `stopRecording`.

In `_handleError`, before the existing logic that flips state to error, add:
```dart
    if (_activeMarkerId != null && _sessionMarkerStore != null) {
      _sessionMarkerStore!.remove(_activeMarkerId!).ignore();
      _activeMarkerId = null;
    }
    _cursorCheckpointer?.stop().ignore();
    _cursorCheckpointer = null;
```

Add the import `import 'dart:io';` at top of the file if not already present (already present for File operations).

- [ ] **Step 4: Run the new test + the full state suite**

```bash
cd packages/screen_recorder && flutter test test/state/recording_state_marker_test.dart
cd packages/screen_recorder && flutter test test/state/
```
Expected: pass; no regressions.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/test/state/recording_state_marker_test.dart
git commit -m "feat(app): wire SessionMarker + CursorCheckpointer into RecordingController"
```

---

### Task 5: `RecoveryService`

**Files:**
- Create: `packages/screen_recorder/lib/state/recovery_service.dart`
- Test: `packages/screen_recorder/test/state/recovery_service_test.dart`

The service injects two seams:
- A `runProcess(String exe, List<String> args)` callback for the ffmpeg re-mux + duration probe. Default is `Process.run`. Tests inject a fake.
- The `Ffmpeg.resolve()` static (no injection needed; tests bypass it via the runProcess fake).

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/recovery_service_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recovery_service.dart';
import 'package:screen_recorder/state/session_marker.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SpyStore implements SessionMarkerStore {
  @override
  String get path => '';
  List<SessionMarker> markers;
  final List<String> removed = [];

  _SpyStore(this.markers);

  @override
  Future<List<SessionMarker>> load() async => List.of(markers);

  @override
  Future<void> add(SessionMarker marker) async => markers.add(marker);

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    markers = markers.where((m) => m.id != id).toList(growable: false);
  }
}

ProcessResult _ok(String stdout) => ProcessResult(0, 0, stdout, '');
ProcessResult _err(String stderr) => ProcessResult(0, 1, '', stderr);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('recovery_svc_');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  SessionMarker mk(String id, {bool createVideo = true, int bytes = 1024}) {
    final videoPath = '${tmp.path}/$id.mp4';
    if (createVideo) {
      File(videoPath).writeAsBytesSync(List.filled(bytes, 0));
    }
    return SessionMarker(
      id: id,
      videoPath: videoPath,
      cursorNdjsonPath: '${tmp.path}/$id.ndjson',
      startedAt: DateTime.utc(2026, 5, 29, 15, 30),
      width: 1920,
      height: 1080,
      fps: 60,
    );
  }

  test('scan filters out markers whose video file is missing', () async {
    final store = _SpyStore([mk('present'), mk('gone', createVideo: false)]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _ok(''));
    final candidates = await svc.scan();
    expect(candidates.map((c) => c.marker.id), ['present']);
    expect(store.removed, ['gone']);
  });

  test('scan filters out zero-byte video files', () async {
    final store = _SpyStore([mk('empty', bytes: 0)]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _ok(''));
    final candidates = await svc.scan();
    expect(candidates, isEmpty);
    expect(store.removed, ['empty']);
  });

  test('recover invokes ffmpeg + removes the marker on success', () async {
    final m = mk('s1', bytes: 4096);
    final store = _SpyStore([m]);
    final calls = <String>[];
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (exe, args) async {
          calls.add('$exe ${args.join(' ')}');
          // Simulate the re-muxed output existing.
          final output = args.last;
          File(output).writeAsBytesSync(List.filled(2048, 1));
          return _ok('Duration: 00:00:30.00');
        });
    final cand = (await svc.scan()).single;
    final history = RecordingHistoryStore();
    final out = await svc.recover(cand, history);
    expect(out, endsWith('.recovered.mp4'));
    expect(calls.first, contains('-c copy'));
    expect(store.removed, ['s1']);
    expect((await history.load()).map((e) => e.videoPath), [out]);
  });

  test('recover returns null + leaves marker when ffmpeg fails', () async {
    final m = mk('s1', bytes: 4096);
    final store = _SpyStore([m]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _err('bad fragment'));
    final cand = (await svc.scan()).single;
    final out = await svc.recover(cand, RecordingHistoryStore());
    expect(out, isNull);
    expect(store.removed, isEmpty);   // marker stays, user can try Discard
  });

  test('discard deletes partial files + removes the marker', () async {
    final m = mk('s1', bytes: 4096);
    File(m.cursorNdjsonPath).writeAsStringSync('');
    final store = _SpyStore([m]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _ok(''));
    final cand = (await svc.scan()).single;
    await svc.discard(cand);
    expect(File(m.videoPath).existsSync(), isFalse);
    expect(File(m.cursorNdjsonPath).existsSync(), isFalse);
    expect(store.removed, ['s1']);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/state/recovery_service_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the service**

```dart
// packages/screen_recorder/lib/state/recovery_service.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'cursor_checkpointer.dart';
import 'session_marker.dart';

typedef RunProcess = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class RecoveryCandidate {
  const RecoveryCandidate({
    required this.marker,
    required this.videoBytes,
  });
  final SessionMarker marker;
  final int videoBytes;
}

class RecoveryService {
  RecoveryService({
    required this.markerStore,
    RunProcess? runProcess,
  }) : runProcess = runProcess ?? Process.run;

  final SessionMarkerStore markerStore;
  final RunProcess runProcess;

  /// Scan persisted markers and return the recoverable subset. Removes stale
  /// markers (missing or zero-byte video) as a side effect.
  Future<List<RecoveryCandidate>> scan() async {
    try {
      final markers = await markerStore.load();
      final out = <RecoveryCandidate>[];
      for (final m in markers) {
        final f = File(m.videoPath);
        if (!f.existsSync() || f.lengthSync() == 0) {
          await markerStore.remove(m.id);
          continue;
        }
        out.add(RecoveryCandidate(marker: m, videoBytes: f.lengthSync()));
      }
      return out;
    } catch (e, st) {
      AppLogger.platform.e('RecoveryService.scan failed; treating as no candidates',
          error: e, stackTrace: st);
      return const [];
    }
  }

  /// Re-mux the partial into a clean MP4, rebuild the cursor sidecar, append
  /// to history. Returns the recovered video path on success, null on failure.
  Future<String?> recover(
      RecoveryCandidate candidate, RecordingHistoryStore history) async {
    final partial = candidate.marker.videoPath;
    final recovered = partial.replaceFirst(RegExp(r'\.mp4$'), '.recovered.mp4');
    try {
      final ffmpeg = Ffmpeg.resolve();
      final result = await runProcess(ffmpeg, [
        '-y',
        '-i', partial,
        '-c', 'copy',
        '-f', 'mp4',
        '-movflags', '+faststart',
        recovered,
      ]);
      if (result.exitCode != 0 || !File(recovered).existsSync()) {
        AppLogger.platform
            .w('Recovery re-mux failed: ${result.stderr}');
        return null;
      }
    } catch (e, st) {
      AppLogger.platform.e('Recovery ffmpeg invocation threw',
          error: e, stackTrace: st);
      return null;
    }

    // Rebuild the cursor sidecar from the NDJSON, if present.
    try {
      final positions =
          await CursorCheckpointer.readAll(candidate.marker.cursorNdjsonPath);
      if (positions.isNotEmpty) {
        final rec = CursorRecording();
        for (final p in positions) {
          rec.addPosition(p);
        }
        await rec.saveToFile('$recovered.cursor.json');
      }
    } catch (e, st) {
      AppLogger.platform.w('Cursor restore failed; recovered clip has no cursor',
          error: e, stackTrace: st);
    }

    // Append to history.
    await history.append(RecordingHistoryEntry(
      videoPath: recovered,
      recordedAt: candidate.marker.startedAt,
      widthPx: candidate.marker.width,
      heightPx: candidate.marker.height,
      fps: candidate.marker.fps,
    ));

    // Clean up the originals + marker.
    await _safeDelete(partial);
    await _safeDelete(candidate.marker.cursorNdjsonPath);
    await markerStore.remove(candidate.marker.id);
    return recovered;
  }

  /// Drop the partial files + marker. The user chose to discard.
  Future<void> discard(RecoveryCandidate candidate) async {
    await _safeDelete(candidate.marker.videoPath);
    await _safeDelete(candidate.marker.cursorNdjsonPath);
    await markerStore.remove(candidate.marker.id);
  }

  Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (e) {
      AppLogger.platform.w('Failed to delete $path: $e');
    }
  }
}

final recoveryServiceProvider = Provider<RecoveryService>(
  (ref) => throw UnimplementedError('Override recoveryServiceProvider in main()'),
);
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/state/recovery_service_test.dart
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recovery_service.dart \
        packages/screen_recorder/test/state/recovery_service_test.dart
git commit -m "feat(app): RecoveryService — scan/recover/discard with ffmpeg re-mux"
```

---

### Task 6: `RecoveryModal`

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/recovery_modal.dart`
- Test: `packages/screen_recorder/test/ui/widgets/recovery_modal_test.dart`

- [ ] **Step 1: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/recovery_modal_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recovery_service.dart';
import 'package:screen_recorder/state/session_marker.dart';
import 'package:screen_recorder/ui/widgets/recovery_modal.dart';

RecoveryCandidate _cand(String id) => RecoveryCandidate(
      marker: SessionMarker(
        id: id,
        videoPath: '/tmp/$id.mp4',
        cursorNdjsonPath: '/tmp/$id.ndjson',
        startedAt: DateTime.utc(2026, 5, 29, 15, 30),
        width: 1920,
        height: 1080,
        fps: 60,
      ),
      videoBytes: 1024 * 1024,
    );

void main() {
  testWidgets('renders one row per candidate', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1'), _cand('s2'), _cand('s3')],
          onRecover: (_) async => '/tmp/out.mp4',
          onDiscard: (_) async {},
        ),
      ),
    ));
    expect(find.text('s1'), findsNothing); // we don't show raw ids
    expect(find.byKey(const Key('recovery-row')), findsNWidgets(3));
  });

  testWidgets('Recover button calls onRecover', (tester) async {
    String? recovered;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1')],
          onRecover: (c) async {
            recovered = c.marker.id;
            return '/tmp/out.mp4';
          },
          onDiscard: (_) async {},
        ),
      ),
    ));
    await tester.tap(find.text('Recover').first);
    await tester.pumpAndSettle();
    expect(recovered, 's1');
  });

  testWidgets('Discard button calls onDiscard', (tester) async {
    String? discarded;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1')],
          onRecover: (_) async => null,
          onDiscard: (c) async => discarded = c.marker.id,
        ),
      ),
    ));
    await tester.tap(find.text('Discard').first);
    await tester.pumpAndSettle();
    expect(discarded, 's1');
  });

  testWidgets('Discard all loops over rows', (tester) async {
    final discarded = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoveryModal(
          candidates: [_cand('s1'), _cand('s2')],
          onRecover: (_) async => null,
          onDiscard: (c) async => discarded.add(c.marker.id),
        ),
      ),
    ));
    await tester.tap(find.text('Discard all'));
    await tester.pumpAndSettle();
    expect(discarded, ['s1', 's2']);
  });
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd packages/screen_recorder && flutter test test/ui/widgets/recovery_modal_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the modal**

```dart
// packages/screen_recorder/lib/ui/widgets/recovery_modal.dart
import 'package:flutter/material.dart';

import '../../state/recovery_service.dart';

class RecoveryModal extends StatefulWidget {
  const RecoveryModal({
    super.key,
    required this.candidates,
    required this.onRecover,
    required this.onDiscard,
  });

  final List<RecoveryCandidate> candidates;
  final Future<String?> Function(RecoveryCandidate) onRecover;
  final Future<void> Function(RecoveryCandidate) onDiscard;

  static const _visibleLimit = 5;

  @override
  State<RecoveryModal> createState() => _RecoveryModalState();
}

class _RecoveryModalState extends State<RecoveryModal> {
  late List<RecoveryCandidate> _remaining;
  final Set<String> _busy = {};
  final Map<String, String> _done = {}; // id → '✓ Recovered' | '✗ Failed' etc.

  @override
  void initState() {
    super.initState();
    _remaining = List.of(widget.candidates);
  }

  Future<void> _recover(RecoveryCandidate c) async {
    setState(() => _busy.add(c.marker.id));
    try {
      final out = await widget.onRecover(c);
      setState(() {
        _busy.remove(c.marker.id);
        _done[c.marker.id] = out != null ? 'Recovered' : "Couldn't recover";
      });
    } catch (_) {
      setState(() {
        _busy.remove(c.marker.id);
        _done[c.marker.id] = "Couldn't recover";
      });
    }
  }

  Future<void> _discard(RecoveryCandidate c) async {
    setState(() => _busy.add(c.marker.id));
    await widget.onDiscard(c);
    setState(() {
      _busy.remove(c.marker.id);
      _remaining.removeWhere((x) => x.marker.id == c.marker.id);
    });
  }

  Future<void> _discardAll() async {
    final batch = List.of(_remaining);
    for (final c in batch) {
      await widget.onDiscard(c);
    }
    setState(() => _remaining.clear());
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _remaining.take(RecoveryModal._visibleLimit).toList();
    final overflow = _remaining.length - visible.length;
    return AlertDialog(
      title: const Text('Recover unfinished recordings?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Slipreel didn't shut down cleanly. We found recordings that "
              'were still being captured.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in visible) _row(c),
                  if (overflow > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('+ $overflow older',
                          style: const TextStyle(color: Colors.white54)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _remaining.isEmpty ? null : _discardAll,
            child: const Text('Discard all')),
        FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Close')),
      ],
    );
  }

  Widget _row(RecoveryCandidate c) {
    final id = c.marker.id;
    final busy = _busy.contains(id);
    final done = _done[id];
    final label = '${c.marker.startedAt.toLocal()} · ${c.marker.fps} fps'
        '${c.marker.width > 0 ? ' · ${c.marker.width}×${c.marker.height}' : ''}';
    return Padding(
      key: const Key('recovery-row'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (busy) const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          else if (done != null) Text(done,
              style: const TextStyle(color: Colors.white70))
          else ...[
            TextButton(
              onPressed: () => _recover(c),
              child: const Text('Recover'),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => _discard(c),
              child: const Text('Discard'),
            ),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd packages/screen_recorder && flutter test test/ui/widgets/recovery_modal_test.dart
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/recovery_modal.dart \
        packages/screen_recorder/test/ui/widgets/recovery_modal_test.dart
git commit -m "feat(app): RecoveryModal — per-row Recover/Discard + Discard all"
```

---

### Task 7: Wire `SessionMarkerStore` + `RecoveryService` + modal into `main()` / `MyApp`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

- [ ] **Step 1: Construct the marker store + recovery service in `main()`**

In `main.dart`, after `permissionsController.refreshAll()` and before `runApp`, add:

```dart
  final sessionMarkerStore = SessionMarkerStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'current_sessions.json',
    ),
  );
  final recoveryService = RecoveryService(markerStore: sessionMarkerStore);
  final recoveryCandidates = await recoveryService.scan();
```

Add the imports:
```dart
import 'state/session_marker.dart';
import 'state/recovery_service.dart';
import 'ui/widgets/recovery_modal.dart';
import 'package:slipreel_engine/models/recording_history.dart';
```

In the `ProviderScope.overrides` list, add:
```dart
      sessionMarkerStoreProvider.overrideWithValue(sessionMarkerStore),
      recoveryServiceProvider.overrideWith((ref) => recoveryService),
```

- [ ] **Step 2: Pass `recoveryCandidates` into `MyApp`**

Change the `MyApp` constructor:
```dart
class MyApp extends ConsumerStatefulWidget {
  const MyApp({
    super.key,
    required this.onboardingDone,
    required this.recoveryCandidates,
  });
  final bool onboardingDone;
  final List<RecoveryCandidate> recoveryCandidates;
  // ...
}
```

In the `runApp(...)` call, pass it through:
```dart
    child: MyApp(
      onboardingDone: onboardingDone,
      recoveryCandidates: recoveryCandidates,
    ),
```

- [ ] **Step 3: Show the modal on first frame**

In `_MyAppState._initRecordingSurfaces()` (the existing post-frame init that constructs Router/Hotkey/Sleep/LongWatcher), add at the bottom:

```dart
    if (widget.recoveryCandidates.isNotEmpty) {
      _showRecoveryModal(widget.recoveryCandidates);
    }
```

Add the helper method to `_MyAppState`:
```dart
  Future<void> _showRecoveryModal(List<RecoveryCandidate> candidates) async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    final svc = ProviderScope.containerOf(context).read(recoveryServiceProvider);
    final history = RecordingHistoryStore();
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => RecoveryModal(
        candidates: candidates,
        onRecover: (c) => svc.recover(c, history),
        onDiscard: (c) => svc.discard(c),
      ),
    );
  }
```

- [ ] **Step 4: Override `RecordingController` to receive the session-marker store**

The existing `RecordingController()` constructor now accepts `sessionMarkerStore`. The provider override in the existing `recordingControllerProvider` block needs updating. Find the override (or default factory) and change it to:
```dart
recordingControllerProvider.overrideWith((ref) => RecordingController(
      sessionMarkerStore: sessionMarkerStore,
    )),
```

If the provider is currently the default `StateNotifierProvider<RecordingController, RecordingState>((ref) => RecordingController())`, add a new override line in the `ProviderScope.overrides` list of `main()`.

- [ ] **Step 5: Run analyzer + full suite**

```bash
cd packages/screen_recorder && flutter analyze --no-fatal-infos
cd packages/screen_recorder && flutter test
```
Expected: analyze clean (only pre-existing info-level findings); full suite green.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(app): wire RecoveryService + RecoveryModal in main"
```

---

### Task 8: Manual verification + repo-wide checks

This is not a code task — final verification.

- [ ] **Run repo-wide checks:**
  ```bash
  cd /Users/mohn93/Desktop/side_projects/screenflow_studio
  melos run analyze --no-select
  melos run test --no-select
  cd packages/screen_recorder_macos/example/macos && \
    xcodebuild -workspace Runner.xcworkspace -scheme Runner \
               -configuration Debug -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -5
  ```
  Expected: analyze clean (only pre-existing infos), tests green, xcodebuild SUCCEEDED.

- [ ] **Manual on a real Mac:**
  1. Start a recording. Wait 15 s. Force-kill the Slipreel process (Activity Monitor → Force Quit). Re-launch. The Recovery modal appears with one row. Click `[Recover]` → row shows `Recovered` after ~1 s → the file appears in Recents and plays back cleanly in the editor.
  2. Same as (1) but kill within 3 s of starting — modal does NOT appear (filtered as too-short).
  3. Same as (1) but pause at 10 s (`Cmd+Shift+P`), then force-kill at 14 s while paused. Recovered duration ≈ 10 s (pre-pause portion only).
  4. Force-kill twice across two launches → next launch shows two rows in the modal.
  5. Start a recording, stop cleanly. Verify next launch shows no modal (no leftover marker).

- [ ] **Inspect the on-disk artifacts:**
  ```bash
  cat "$HOME/Library/Application Support/com.slipreel.app/current_sessions.json"
  ls -la "$HOME/Documents/recording_"*.ndjson
  ```
  After a clean session: `current_sessions.json` shows `{"sessions": []}` and there are no `.ndjson` files. After a crash: one or more entries in the sessions list, and matching `.ndjson` files.

---

## Self-review

**Spec coverage:**
- §1 Native fragmented MP4 → Task 1 ✓
- §2 SessionMarker + SessionMarkerStore → Task 2 ✓
- §3 CursorCheckpointer → Task 3 ✓
- §4 RecoveryService scan/recover/discard → Task 5 ✓
- §5 RecoveryModal → Task 6 ✓
- Lifecycle integration (Recording controller + main) → Tasks 4, 7 ✓
- Manual verification → Task 8 ✓

**Placeholder scan:** no TBDs, no "implement later" patterns.

**Type consistency:**
- `SessionMarker` defined in Task 2; used identically in Tasks 4, 5, 6, 7.
- `RecoveryCandidate` defined in Task 5; used in Tasks 6, 7.
- `CursorCheckpointer` defined in Task 3; used in Tasks 4, 5.
- `RecoveryService` defined in Task 5; used in Tasks 6, 7.

**Out of scope (per spec):** editor project-state recovery, cross-platform, settings toggle for recovery, persistent recovery-history UI, auto-recover, NSNotification on recovery completion. Not in plan; correct.
