# Recents Grid with Styled Thumbnails — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Recents text list with a responsive grid of cards, each showing a styled (export-accurate) thumbnail of the recording plus a friendly date + duration caption.

**Architecture:** A new `RecordingThumbnailService` lazily generates a styled thumbnail per recording by decoding one frame (ffmpeg) and running it through the existing `FrameCompositor`, caching the result to `recording.mp4.thumb.png` (regenerated when `editor.json` is newer). Duration moves into `meta.json` (`durationMs`, schema v2), written at record-stop and backfilled (via `ffprobe`) for old recordings. `RecentsScreen` swaps its `ListView` for a `GridView` of `RecordingCard`s.

**Tech Stack:** Dart/Flutter; `slipreel_engine` (engine: model, ffmpeg, compositor) + `screen_recorder` (shell: UI, service). Tests via `~/fvm/versions/3.41.5/bin/flutter test`. Spec: `packages/screen_recorder/docs/superpowers/specs/2026-05-24-recents-grid-thumbnails-design.md`.

**Conventions:** flutter binary is `~/fvm/versions/3.41.5/bin/flutter`. Run engine tests from `packages/slipreel_engine`, shell tests from `packages/screen_recorder`. Branch: `feat/recents-grid-thumbnails` (already checked out).

---

## File Structure

- **Modify** `packages/slipreel_engine/lib/models/recording_metadata.dart` — add `duration` field (`durationMs`, schema v2). [Task 1]
- **Modify** `packages/slipreel_engine/test/models/recording_metadata_test.dart` (create if absent) — round-trip + v1-compat. [Task 1]
- **Modify** `packages/screen_recorder/lib/state/recording_state.dart` — pass the live duration into the `RecordingMetadata(...)` saved at record-stop. [Task 2]
- **Create** `packages/screen_recorder/lib/ui/screens/recents/thumbnail_timestamp.dart` — pure `thumbTimestamp(Duration) → Duration` helper. [Task 3]
- **Create** `packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart` — generation/caching/probe/backfill, with injectable seams. [Task 4]
- **Create** `packages/screen_recorder/lib/ui/screens/recents/recording_card.dart` — one grid card (presentation only). [Task 5]
- **Modify** `packages/screen_recorder/lib/ui/screens/recents_screen.dart` — `ListView` → `GridView` of `RecordingCard`. [Task 6]
- Tests created alongside each.

---

## Task 1: `RecordingMetadata` gains duration (schema v2)

**Files:**
- Modify: `packages/slipreel_engine/lib/models/recording_metadata.dart`
- Test: `packages/slipreel_engine/test/models/recording_metadata_test.dart`

**Notes:** Current model has `isPureSource, recordedAt, widthPx, heightPx, fps` and `toJson` writing `schemaVersion: 1`. Add a nullable-on-read `Duration? duration` (a v1 sidecar has no duration → `null`, meaning "unknown, probe later"). Keep all existing fields/behavior.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/models/recording_metadata_test.dart`:

```dart
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';

void main() {
  test('round-trips durationMs and writes schemaVersion 2', () {
    final meta = RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.utc(2026, 5, 14, 19, 33, 40),
      widthPx: 2214,
      heightPx: 1984,
      fps: 60,
      duration: const Duration(milliseconds: 41823),
    );
    final json = meta.toJson();
    expect(json['durationMs'], 41823);
    expect(json['schemaVersion'], 2);

    final back = RecordingMetadata.fromJson(json);
    expect(back.duration, const Duration(milliseconds: 41823));
    expect(back.widthPx, 2214);
    expect(back.isPureSource, isTrue);
  });

  test('v1 sidecar (no durationMs) parses with duration == null', () {
    final v1 = {
      'isPureSource': true,
      'recordedAt': '2026-05-14T19:33:40.000Z',
      'widthPx': 2214,
      'heightPx': 1984,
      'fps': 60,
      'schemaVersion': 1,
    };
    final meta = RecordingMetadata.fromJson(v1);
    expect(meta.duration, isNull);
    expect(meta.fps, 60);
  });

  test('duration defaults to null when constructed without it', () {
    final meta = RecordingMetadata(
      isPureSource: false,
      recordedAt: DateTime.utc(1970),
      widthPx: 0,
      heightPx: 0,
      fps: 30,
    );
    expect(meta.duration, isNull);
    expect(meta.toJson().containsKey('durationMs'), isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/models/recording_metadata_test.dart`
Expected: FAIL — `RecordingMetadata` has no `duration` parameter (compile error).

- [ ] **Step 3: Implement**

In `recording_metadata.dart`: add the field, constructor param, `toJson` (omit `durationMs` when null, bump version to 2), and `fromJson` (read `durationMs` when present). Edit the class:

```dart
  final bool isPureSource;
  final DateTime recordedAt;
  final int widthPx;
  final int heightPx;
  final int fps;

  /// Total recording length. Null for legacy (schema v1) sidecars that
  /// predate this field — callers probe + backfill on demand.
  final Duration? duration;

  const RecordingMetadata({
    required this.isPureSource,
    required this.recordedAt,
    required this.widthPx,
    required this.heightPx,
    required this.fps,
    this.duration,
  });

  Map<String, dynamic> toJson() => {
        'isPureSource': isPureSource,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
        'widthPx': widthPx,
        'heightPx': heightPx,
        'fps': fps,
        if (duration != null) 'durationMs': duration!.inMilliseconds,
        'schemaVersion': 2,
      };

  factory RecordingMetadata.fromJson(Map<String, dynamic> json) {
    final durMs = json['durationMs'] as int?;
    return RecordingMetadata(
      isPureSource: json['isPureSource'] as bool? ?? false,
      recordedAt: DateTime.parse(
          json['recordedAt'] as String? ?? '1970-01-01T00:00:00Z'),
      widthPx: json['widthPx'] as int? ?? 0,
      heightPx: json['heightPx'] as int? ?? 0,
      fps: json['fps'] as int? ?? 30,
      duration: durMs == null ? null : Duration(milliseconds: durMs),
    );
  }
```

Add `duration` to `copyWith` if the class has one (check; add the param if so). Update `operator ==`/`hashCode` if the class defines them to include `duration`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/slipreel_engine && ~/fvm/versions/3.41.5/bin/flutter test test/models/recording_metadata_test.dart`
Expected: PASS (3 tests). Then full engine suite: `~/fvm/versions/3.41.5/bin/flutter test` — green (was 468).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/recording_metadata.dart packages/slipreel_engine/test/models/recording_metadata_test.dart
git commit -m "feat(metadata): add duration to RecordingMetadata (meta.json schema v2)"
```

---

## Task 2: Write duration at record-stop

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart` (~line 194, the `RecordingMetadata(...)` saved on stop)
- Test: `packages/screen_recorder/test/state/recording_meta_duration_test.dart`

**Notes:** `recording_state.dart` tracks elapsed `duration` via a per-second timer (`state.duration`). At record-stop it constructs `RecordingMetadata(...)` and calls `saveForVideo`. Thread the duration in. The exact best duration source is `state.duration` at stop (or `result.duration` if the platform result carries one — confirm; prefer the platform/result duration if present, else `state.duration`). Because the stop path involves the platform recorder, the unit test asserts the wiring structurally (the `RecordingMetadata(...)` call passes a `duration:` argument) rather than driving the recorder.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/recording_meta_duration_test.dart`:

```dart
@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('record-stop writes duration into the RecordingMetadata sidecar', () {
    final src = File('lib/state/recording_state.dart').readAsStringSync();
    // The RecordingMetadata constructed at stop must pass a duration.
    final ctorStart = src.indexOf('RecordingMetadata(');
    expect(ctorStart, greaterThanOrEqualTo(0));
    final ctorEnd = src.indexOf(')', ctorStart);
    final ctor = src.substring(ctorStart, ctorEnd);
    expect(ctor.contains('duration:'), isTrue,
        reason: 'the meta sidecar saved at record-stop must persist the '
            'recording duration so Recents can show it without probing');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/recording_meta_duration_test.dart`
Expected: FAIL — the `RecordingMetadata(...)` call has no `duration:` arg yet.

- [ ] **Step 3: Implement**

Read `recording_state.dart` around line 194. Add `duration: state.duration,` (or the platform result's duration if it exposes one) to the `RecordingMetadata(...)` construction. Example shape (match the real surrounding code):

```dart
      final meta = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.now().toUtc(),
        widthPx: result.width,
        heightPx: result.height,
        fps: result.fps,
        duration: state.duration, // tracked live by _durationTimer
      );
      await meta.saveForVideo(result.outputPath);
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/state/recording_meta_duration_test.dart` → PASS.
`~/fvm/versions/3.41.5/bin/flutter analyze lib/state/recording_state.dart` → no issues.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart packages/screen_recorder/test/state/recording_meta_duration_test.dart
git commit -m "feat(recording): persist duration into meta.json at record-stop"
```

---

## Task 3: `thumbTimestamp` pure helper

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/recents/thumbnail_timestamp.dart`
- Test: `packages/screen_recorder/test/screens/recents/thumbnail_timestamp_test.dart`

**Notes:** Pick a representative frame time: 10% in, but at least 1s, and never past `duration − 200ms`. For very short clips (≤1.2s) fall back to the midpoint; for zero/unknown duration, return `Duration.zero`.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/screens/recents/thumbnail_timestamp_test.dart`:

```dart
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/recents/thumbnail_timestamp.dart';

void main() {
  test('uses 10% in for a normal clip, clamped to >= 1s', () {
    // 41.8s → 10% = 4.18s (>1s) → 4180ms.
    expect(thumbTimestamp(const Duration(milliseconds: 41823)),
        const Duration(milliseconds: 4182));
    // 4s → 10% = 0.4s, floored to 1s.
    expect(thumbTimestamp(const Duration(seconds: 4)),
        const Duration(seconds: 1));
  });

  test('short clip (<=1.2s) uses the midpoint', () {
    expect(thumbTimestamp(const Duration(milliseconds: 800)),
        const Duration(milliseconds: 400));
  });

  test('never past duration - 200ms', () {
    // 1.1s: midpoint 550ms, and < 900ms cap → 550ms.
    final t = thumbTimestamp(const Duration(milliseconds: 1100));
    expect(t.inMilliseconds, lessThanOrEqualTo(900));
  });

  test('zero / unknown duration → zero', () {
    expect(thumbTimestamp(Duration.zero), Duration.zero);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/thumbnail_timestamp_test.dart`
Expected: FAIL — file/function missing.

- [ ] **Step 3: Implement**

Create `thumbnail_timestamp.dart`:

```dart
/// Picks a representative frame time for a recording's thumbnail:
/// 10% in, floored to 1s, and never past `duration - 200ms`. Very short
/// clips use the midpoint; zero/unknown duration returns zero (first
/// frame).
Duration thumbTimestamp(Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  final cap = duration - const Duration(milliseconds: 200);
  if (cap <= Duration.zero) {
    return Duration(microseconds: duration.inMicroseconds ~/ 2);
  }
  if (duration <= const Duration(milliseconds: 1200)) {
    final mid = Duration(microseconds: duration.inMicroseconds ~/ 2);
    return mid <= cap ? mid : cap;
  }
  final tenth = Duration(microseconds: duration.inMicroseconds ~/ 10);
  final floored =
      tenth < const Duration(seconds: 1) ? const Duration(seconds: 1) : tenth;
  return floored <= cap ? floored : cap;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/thumbnail_timestamp_test.dart` → PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/recents/thumbnail_timestamp.dart packages/screen_recorder/test/screens/recents/thumbnail_timestamp_test.dart
git commit -m "feat(recents): thumbTimestamp frame-picker helper"
```

---

## Task 4: `RecordingThumbnailService`

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart`
- Test: `packages/screen_recorder/test/screens/recents/recording_thumbnail_service_test.dart`

**Notes / design:** The service must be testable without shelling to ffmpeg or running the GPU compositor, so the three heavy operations are **injectable seams** (typedefs) defaulting to real implementations:

- `ProbeDuration = Future<Duration?> Function(String videoPath)` — default wraps `ffmpegProbe`.
- `GenerateThumbPng = Future<void> Function(RecordingHistoryEntry entry, Duration at, File outPng)` — default: decode one frame + compose + encode + write. (Built in Task 4 too, but behind the seam so the cache/backfill logic is unit-tested with a fake.)

Public surface:

```dart
class RecordingThumbnail {
  const RecordingThumbnail({required this.pngFile, required this.duration});
  final File pngFile;
  final Duration? duration;
}

class RecordingThumbnailService {
  RecordingThumbnailService({ProbeDuration? probeDuration, GenerateThumbPng? generate, int maxConcurrent = 3});
  Future<RecordingThumbnail> thumbFor(RecordingHistoryEntry entry);
  void clearMemoryCache();
}
```

Behavior of `thumbFor`:
1. `videoFile = File(entry.videoPath)`; if it doesn't exist → throw `RecordingMissingException` (card shows missing state). (Caller already knows existence via `_exists`, but guard anyway.)
2. Resolve duration: `RecordingMetadata.loadForVideo(path)`; if `meta.duration != null` use it. Else `probeDuration(path)`; if non-null, **backfill**: save a v2 meta with the probed duration (`meta` copyWith duration → `saveForVideo`). If probe also null, duration stays null.
3. `thumbPng = File('${entry.videoPath}.thumb.png')`. Stale if: `!thumbPng.exists()` OR `editorJson.exists() && editorJson.lastModified() > thumbPng.lastModified()` where `editorJson = File('${entry.videoPath}.editor.json')`.
4. If stale → `generate(entry, thumbTimestamp(duration ?? Duration.zero), thumbPng)`.
5. Return `RecordingThumbnail(pngFile: thumbPng, duration: <resolved>)`. Memoize per `videoPath` in an in-memory map for the session; the concurrency limiter (a simple counting gate) caps simultaneous `generate` calls at `maxConcurrent`.

This task wires the cache/backfill/concurrency logic and the DEFAULT real seams. Tests inject fakes for `probeDuration`/`generate`.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/screens/recents/recording_thumbnail_service_test.dart`:

```dart
@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/recents/recording_thumbnail_service.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('thumb_svc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  RecordingHistoryEntry entryFor(String mp4) => RecordingHistoryEntry(
        videoPath: mp4,
        recordedAt: DateTime.utc(2026, 5, 14),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );

  test('generates when thumb missing, then caches (no regen on 2nd call)', () async {
    final mp4 = '${tmp.path}/r.mp4';
    File(mp4).writeAsBytesSync([0]); // file must exist
    var gen = 0;
    final svc = RecordingThumbnailService(
      probeDuration: (_) async => const Duration(seconds: 10),
      generate: (entry, at, out) async {
        gen++;
        out.writeAsBytesSync([1, 2, 3]); // fake png
      },
    );

    final t1 = await svc.thumbFor(entryFor(mp4));
    expect(gen, 1);
    expect(t1.pngFile.path, '$mp4.thumb.png');
    expect(t1.duration, const Duration(seconds: 10));

    // 2nd call: png exists, no editor.json → not stale → no regen.
    svc.clearMemoryCache(); // force the disk-cache path, not the memo
    final t2 = await svc.thumbFor(entryFor(mp4));
    expect(gen, 1, reason: 'cached png is reused');
    expect(t2.pngFile.existsSync(), isTrue);
  });

  test('regenerates when editor.json is newer than the thumb', () async {
    final mp4 = '${tmp.path}/r.mp4';
    File(mp4).writeAsBytesSync([0]);
    final thumb = File('$mp4.thumb.png')..writeAsBytesSync([9]);
    final editor = File('$mp4.editor.json')..writeAsStringSync('{}');
    // Make editor.json strictly newer than the thumb.
    final future = DateTime.now().add(const Duration(seconds: 5));
    editor.setLastModifiedSync(future);
    thumb.setLastModifiedSync(DateTime.now().subtract(const Duration(seconds: 5)));

    var gen = 0;
    final svc = RecordingThumbnailService(
      probeDuration: (_) async => const Duration(seconds: 10),
      generate: (e, at, out) async { gen++; out.writeAsBytesSync([1]); },
    );
    await svc.thumbFor(entryFor(mp4));
    expect(gen, 1, reason: 'editor.json newer than thumb → regenerate');
  });

  test('backfills meta.json durationMs when meta lacks it', () async {
    final mp4 = '${tmp.path}/r.mp4';
    File(mp4).writeAsBytesSync([0]);
    // v1 meta (no durationMs).
    await RecordingMetadata(
      isPureSource: true, recordedAt: DateTime.utc(2026), widthPx: 1920,
      heightPx: 1080, fps: 60,
    ).saveForVideo(mp4); // duration null → no durationMs key

    final svc = RecordingThumbnailService(
      probeDuration: (_) async => const Duration(milliseconds: 12345),
      generate: (e, at, out) async => out.writeAsBytesSync([1]),
    );
    await svc.thumbFor(entryFor(mp4));

    final reloaded = await RecordingMetadata.loadForVideo(mp4);
    expect(reloaded.duration, const Duration(milliseconds: 12345),
        reason: 'probed duration is written back into meta.json');
  });

  test('missing video file throws RecordingMissingException', () async {
    final svc = RecordingThumbnailService(
      probeDuration: (_) async => null,
      generate: (e, at, out) async {},
    );
    expect(
      () => svc.thumbFor(entryFor('${tmp.path}/gone.mp4')),
      throwsA(isA<RecordingMissingException>()),
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/recording_thumbnail_service_test.dart`
Expected: FAIL — service/types missing.

- [ ] **Step 3: Implement**

Create `recording_thumbnail_service.dart`. Implement the cache/backfill/concurrency logic and the **default real seams**. The default `generate` decodes one frame via ffmpeg, loads the sidecars, runs `FrameCompositor.compose`, encodes RGBA→PNG (downscaled to ≤640px wide), writes the file. The default `probeDuration` wraps `ffmpegProbe`.

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';
import 'package:flutter/widgets.dart' show Size;

import 'thumbnail_timestamp.dart';

typedef ProbeDuration = Future<Duration?> Function(String videoPath);
typedef GenerateThumbPng = Future<void> Function(
    RecordingHistoryEntry entry, Duration at, File outPng);

class RecordingMissingException implements Exception {
  RecordingMissingException(this.videoPath);
  final String videoPath;
  @override
  String toString() => 'RecordingMissingException($videoPath)';
}

class RecordingThumbnail {
  const RecordingThumbnail({required this.pngFile, required this.duration});
  final File pngFile;
  final Duration? duration;
}

class RecordingThumbnailService {
  RecordingThumbnailService({
    ProbeDuration? probeDuration,
    GenerateThumbPng? generate,
    this.maxConcurrent = 3,
  })  : _probeDuration = probeDuration ?? _defaultProbeDuration,
        _generate = generate ?? _defaultGenerate;

  final ProbeDuration _probeDuration;
  final GenerateThumbPng _generate;
  final int maxConcurrent;

  final Map<String, RecordingThumbnail> _memo = {};
  int _active = 0;
  final _waiters = <Completer<void>>[];

  void clearMemoryCache() => _memo.clear();

  Future<RecordingThumbnail> thumbFor(RecordingHistoryEntry entry) async {
    final memo = _memo[entry.videoPath];
    if (memo != null) return memo;

    if (!File(entry.videoPath).existsSync()) {
      throw RecordingMissingException(entry.videoPath);
    }

    // Resolve duration (meta → probe → backfill).
    final meta = await RecordingMetadata.loadForVideo(entry.videoPath);
    Duration? duration = meta.duration;
    if (duration == null) {
      duration = await _probeDuration(entry.videoPath);
      if (duration != null) {
        await RecordingMetadata(
          isPureSource: meta.isPureSource,
          recordedAt: meta.recordedAt,
          widthPx: meta.widthPx != 0 ? meta.widthPx : entry.widthPx,
          heightPx: meta.heightPx != 0 ? meta.heightPx : entry.heightPx,
          fps: meta.fps,
          duration: duration,
        ).saveForVideo(entry.videoPath);
      }
    }

    final thumb = File('${entry.videoPath}.thumb.png');
    if (_isStale(entry.videoPath, thumb)) {
      await _runGuarded(() =>
          _generate(entry, thumbTimestamp(duration ?? Duration.zero), thumb));
    }

    final result = RecordingThumbnail(pngFile: thumb, duration: duration);
    _memo[entry.videoPath] = result;
    return result;
  }

  bool _isStale(String videoPath, File thumb) {
    if (!thumb.existsSync()) return true;
    final editor = File('$videoPath.editor.json');
    if (editor.existsSync() &&
        editor.lastModifiedSync().isAfter(thumb.lastModifiedSync())) {
      return true;
    }
    return false;
  }

  Future<void> _runGuarded(Future<void> Function() op) async {
    while (_active >= maxConcurrent) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;
    try {
      await op();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }

  // --- default real seams ---

  static Future<Duration?> _defaultProbeDuration(String videoPath) async {
    try {
      final r = await ffmpegProbe(path: videoPath);
      final sec = r.durationSec;
      return sec == null ? null : Duration(microseconds: (sec * 1e6).round());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _defaultGenerate(
      RecordingHistoryEntry entry, Duration at, File outPng) async {
    final videoSize =
        Size(entry.widthPx.toDouble(), entry.heightPx.toDouble());
    final w = entry.widthPx, h = entry.heightPx;

    // 1) decode one BGRA frame at `at`.
    final bgra = await _decodeFrameBgra(entry.videoPath, at, w, h);
    if (bgra == null) {
      throw StateError('thumbnail decode failed for ${entry.videoPath}');
    }

    // 2) load sidecars.
    final projectState =
        await EditorProjectStore(videoPath: entry.videoPath).load();
    final cursor = await CursorRecording.loadFromFile(
            '${entry.videoPath}.cursor.json')
        .catchError((_) => CursorRecording());
    final meta = await RecordingMetadata.loadForVideo(entry.videoPath);

    // 3) compose one styled frame → RGBA at compositor.totalSize.
    final compositor = FrameCompositor(
      projectState: projectState,
      cursorRecording: cursor,
      metadata: meta,
      videoSize: videoSize,
      fps: entry.fps,
    );
    final rgba = await compositor.compose(videoFrameBgra: bgra, position: at);
    final outW = compositor.totalSize.width.toInt();
    final outH = compositor.totalSize.height.toInt();

    // 4) RGBA → ui.Image → downscaled PNG.
    final png = await _encodeDownscaledPng(rgba, outW, outH, maxWidth: 640);
    await outPng.writeAsBytes(png);
  }

  static Future<Uint8List?> _decodeFrameBgra(
      String videoPath, Duration at, int w, int h) async {
    final args = <String>[
      '-loglevel', 'error',
      '-ss', (at.inMicroseconds / 1e6).toStringAsFixed(3),
      '-i', videoPath,
      '-frames:v', '1',
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-',
    ];
    final res = await Process.run('ffmpeg', args, stdoutEncoding: null);
    final out = res.stdout as List<int>;
    final frameSize = w * h * 4;
    if (out.length < frameSize) return null;
    return Uint8List.fromList(out.sublist(0, frameSize));
  }

  static Future<Uint8List> _encodeDownscaledPng(
      Uint8List rgba, int w, int h, {required int maxWidth}) async {
    final src = await _imageFromRgba(rgba, w, h);
    final scale = w > maxWidth ? maxWidth / w : 1.0;
    final dw = (w * scale).round(), dh = (h * scale).round();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final scaled = await recorder.endRecording().toImage(dw, dh);
    final bd = await scaled.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  }

  static Future<ui.Image> _imageFromRgba(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}
```

> IMPLEMENTER: verify `ffmpegProbe`'s real parameter name (`path:` vs positional) and that `FfmpegProbeResult.durationSec` exists (it does per the spec exploration). Verify `FrameCompositor.compose` returns RGBA sized to `compositor.totalSize` (it does). If `ffmpegProbe`'s signature differs, adjust `_defaultProbeDuration`. The default-seam code is exercised in-app (Task 7), not in unit tests; the unit tests inject fakes.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/recording_thumbnail_service_test.dart` → PASS (4 tests).
`~/fvm/versions/3.41.5/bin/flutter analyze lib/ui/screens/recents/recording_thumbnail_service.dart` → no issues.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart packages/screen_recorder/test/screens/recents/recording_thumbnail_service_test.dart
git commit -m "feat(recents): RecordingThumbnailService (lazy styled thumbs + meta duration backfill)"
```

---

## Task 5: `RecordingCard` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/recents/recording_card.dart`
- Test: `packages/screen_recorder/test/screens/recents/recording_card_test.dart`

**Notes:** Presentation only. Inputs: `entry`, `fileExists`, `onOpen`, `onOpenPlayground`, `onRemove`, and a `Future<RecordingThumbnail> thumbnailFuture` (the screen calls `service.thumbFor(entry)` and passes the future, so the card has no service/IO knowledge). Renders a 16:9 area (loading shimmer / `Image.file` when ready / greyed placeholder when `!fileExists` or the future errors), caption (date primary, `duration · WxH` secondary), and a hover-revealed `✕`. Tap → `onOpen`; long-press → `onOpenPlayground`. Caption date formatting: a small private helper `_formatDate(DateTime)` → e.g. `May 14, 2026 · 9:33 PM` (use `intl`-free manual formatting to avoid adding a dep — month names array + 12h clock). Duration `m:ss` via a helper `_fmtDuration(Duration)`.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/screens/recents/recording_card_test.dart`:

```dart
@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/recents/recording_card.dart';
import 'package:screen_recorder/ui/screens/recents/recording_thumbnail_service.dart';

RecordingHistoryEntry _entry() => RecordingHistoryEntry(
      videoPath: '/tmp/recording_1.mp4',
      recordedAt: DateTime(2026, 5, 14, 21, 33),
      widthPx: 2214,
      heightPx: 1984,
      fps: 60,
    );

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 280, child: child))));

void main() {
  testWidgets('missing file → shows placeholder, tap disabled, remove works',
      (tester) async {
    var removed = false;
    await tester.pumpWidget(_host(RecordingCard(
      entry: _entry(),
      fileExists: false,
      thumbnailFuture: Future.error(RecordingMissingException('/tmp/recording_1.mp4')),
      onOpen: () {},
      onOpenPlayground: () {},
      onRemove: () => removed = true,
    )));
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.textContaining('May 14, 2026'), findsOneWidget);
  });

  testWidgets('ready → renders the thumbnail image and caption', (tester) async {
    // Write a tiny valid PNG to a temp file.
    final tmp = File('${Directory.systemTemp.path}/card_thumb.png');
    tmp.writeAsBytesSync(_tinyPng());
    await tester.pumpWidget(_host(RecordingCard(
      entry: _entry(),
      fileExists: true,
      thumbnailFuture: Future.value(RecordingThumbnail(
          pngFile: tmp, duration: const Duration(seconds: 42))),
      onOpen: () {},
      onOpenPlayground: () {},
      onRemove: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('0:42'), findsOneWidget);
  });

  testWidgets('tap fires onOpen, long-press fires onOpenPlayground',
      (tester) async {
    var opened = 0, playground = 0;
    final tmp = File('${Directory.systemTemp.path}/card_thumb2.png')
      ..writeAsBytesSync(_tinyPng());
    await tester.pumpWidget(_host(RecordingCard(
      entry: _entry(),
      fileExists: true,
      thumbnailFuture: Future.value(
          RecordingThumbnail(pngFile: tmp, duration: const Duration(seconds: 1))),
      onOpen: () => opened++,
      onOpenPlayground: () => playground++,
      onRemove: () {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    expect(opened, 1);
    await tester.longPress(find.byType(InkWell).first);
    expect(playground, 1);
  });
}

// 1x1 transparent PNG.
List<int> _tinyPng() => const [
  137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,
  31,21,196,137,0,0,0,13,73,68,65,84,120,156,99,250,207,0,0,3,1,1,0,24,221,
  141,219,0,0,0,0,73,69,78,68,174,66,96,130,
];
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/recording_card_test.dart`
Expected: FAIL — `RecordingCard` missing.

- [ ] **Step 3: Implement**

Create `recording_card.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'recording_thumbnail_service.dart';

class RecordingCard extends StatefulWidget {
  const RecordingCard({
    super.key,
    required this.entry,
    required this.fileExists,
    required this.thumbnailFuture,
    required this.onOpen,
    required this.onOpenPlayground,
    required this.onRemove,
  });

  final RecordingHistoryEntry entry;
  final bool fileExists;
  final Future<RecordingThumbnail> thumbnailFuture;
  final VoidCallback onOpen;
  final VoidCallback onOpenPlayground;
  final VoidCallback onRemove;

  @override
  State<RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends State<RecordingCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.fileExists;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Material(
                    color: const Color(0xFF2B2B3D),
                    child: InkWell(
                      onTap: enabled ? widget.onOpen : null,
                      onLongPress: enabled ? widget.onOpenPlayground : null,
                      child: _thumbArea(enabled),
                    ),
                  ),
                ),
              ),
              if (_hover)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _RemoveButton(onRemove: widget.onRemove),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _formatDate(widget.entry.recordedAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: enabled ? Colors.white : Colors.white38,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          _SubtitleLine(entry: widget.entry, future: widget.thumbnailFuture,
              enabled: enabled),
        ],
      ),
    );
  }

  Widget _thumbArea(bool enabled) {
    if (!enabled) return const _Placeholder();
    return FutureBuilder<RecordingThumbnail>(
      future: widget.thumbnailFuture,
      builder: (context, snap) {
        if (snap.hasError) return const _Placeholder();
        if (!snap.hasData) return const _Shimmer();
        return Image.file(snap.data!.pngFile, fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _Placeholder());
      },
    );
  }
}

class _SubtitleLine extends StatelessWidget {
  const _SubtitleLine(
      {required this.entry, required this.future, required this.enabled});
  final RecordingHistoryEntry entry;
  final Future<RecordingThumbnail> future;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final dims = '${entry.widthPx}×${entry.heightPx}';
    final color = enabled ? Colors.white60 : Colors.white24;
    return FutureBuilder<RecordingThumbnail>(
      future: future,
      builder: (context, snap) {
        final dur = snap.data?.duration;
        final text = dur != null ? '${_fmtDuration(dur)} · $dims' : dims;
        return Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 12));
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();
  @override
  Widget build(BuildContext context) => const Center(
      child: Icon(Icons.broken_image_outlined,
          color: Colors.white24, size: 32));
}

class _Shimmer extends StatelessWidget {
  const _Shimmer();
  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF23232F));
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onRemove});
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(
          icon: const Icon(Icons.close, size: 16, color: Colors.white),
          tooltip: 'Remove from history',
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: onRemove,
        ),
      );
}

const _months = [
  'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
];

String _formatDate(DateTime dt) {
  final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  final min = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day}, ${dt.year} · $h:$min $ampm';
}

String _fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
```

> IMPLEMENTER: the `_formatDate` shows the full `May 14, 2026 · 9:33 PM`; the test only checks substrings `May 14, 2026` and `0:42`. Adjust whitespace freely. The remove button only appears on hover (`_hover`); the missing-file test checks the placeholder + date, not the hover button.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/recording_card_test.dart` → PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/recents/recording_card.dart packages/screen_recorder/test/screens/recents/recording_card_test.dart
git commit -m "feat(recents): RecordingCard grid card (thumbnail + caption + hover remove)"
```

---

## Task 6: Swap RecentsScreen list → grid

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/recents_screen.dart`
- Test: `packages/screen_recorder/test/screens/recents/recents_grid_test.dart`

**Notes:** Keep the existing State (`_store`, `_entries`, `_exists`, `_refresh`, `_remove`, `_open`, `_openPlayground`). Add a `final RecordingThumbnailService _thumbs = RecordingThumbnailService();` field. Replace the `ListView.separated`/`ListView.builder` body with a `GridView.builder` using `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 280, childAspectRatio: 16/13, crossAxisSpacing: 16, mainAxisSpacing: 16)` and `padding: EdgeInsets.all(20)`, building a `RecordingCard` per entry. (The aspect ratio < 16/9 leaves vertical room for the 2-line caption; tune if captions clip.) Pass `thumbnailFuture: _thumbs.thumbFor(entry)` for existing files; for missing files pass `Future.error(RecordingMissingException(entry.videoPath))` and `fileExists: false`. Delete the now-unused `_RecentTile` widget. Keep `_EmptyState`.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/screens/recents/recents_grid_test.dart`:

```dart
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:screen_recorder/ui/screens/recents_screen.dart';
import 'package:screen_recorder/ui/screens/recents/recording_card.dart';

void main() {
  testWidgets('renders a GridView of RecordingCards from the store', (tester) async {
    final store = RecordingHistoryStore.inMemory([
      RecordingHistoryEntry(
          videoPath: '/tmp/a.mp4', recordedAt: DateTime(2026, 5, 14),
          widthPx: 1920, heightPx: 1080, fps: 60),
      RecordingHistoryEntry(
          videoPath: '/tmp/b.mp4', recordedAt: DateTime(2026, 5, 13),
          widthPx: 1280, heightPx: 720, fps: 30),
    ]);
    await tester.pumpWidget(MaterialApp(home: RecentsScreen(store: store)));
    await tester.pump(); // let _refresh's setState land
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(RecordingCard), findsNWidgets(2));
  });
}
```

> IMPLEMENTER: `RecentsScreen` already takes an injected `store` (`_injectedStore`). Confirm the constructor param name (it's `RecentsScreen({Key?, RecordingHistoryStore? store})`). If `RecordingHistoryStore` lacks an `inMemory(List)` test constructor, add a minimal one (or seed a real store via its existing API) — pick whichever the store already supports; do NOT touch SharedPreferences in the test. The two entries point at non-existent files, so cards render in the missing-file state (no ffmpeg) — that's fine for the grid smoke test.

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/recents_grid_test.dart`
Expected: FAIL — still a ListView / no RecordingCard.

- [ ] **Step 3: Implement**

Rewrite the Recents body to a `GridView.builder` of `RecordingCard`s (per Notes). Wire each card's callbacks to the existing `_open(entry)`, `_openPlayground(entry)`, `_remove(entry)`; set `fileExists: _exists[entry.videoPath] ?? false` and the thumbnail future accordingly. Remove `_RecentTile`. Keep `_EmptyState` when `_entries` is empty.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/screens/recents/recents_grid_test.dart` → PASS.
Full shell suite: `~/fvm/versions/3.41.5/bin/flutter test` → green.
`~/fvm/versions/3.41.5/bin/flutter analyze lib/ui/screens/recents_screen.dart` → no issues.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/recents_screen.dart packages/screen_recorder/test/screens/recents/recents_grid_test.dart
git commit -m "feat(recents): grid of RecordingCards (replaces the list)"
```

---

## Task 7: In-app verification

**Files:** none (runtime verification via agent-wires).

- [ ] **Step 1:** `stop_app` + `boot_app` (device `macos`).
- [ ] **Step 2:** Tap the history icon (recording_screen app-bar "Recent recordings" button) to open Recents.
- [ ] **Step 3:** `wait_for_idle`, then `screenshot` (or `snapshot`). Confirm: a grid renders; styled thumbnails appear for existing recordings (after a moment for generation); captions show friendly date + `m:ss · WxH`; the known recording `recording_1778787176946.mp4` (41.8s, 2214×1984) shows a wallpaper+frame styled thumbnail and `0:41 · 2214×1984`.
- [ ] **Step 4:** Hover a card → `✕` appears. Confirm clicking a card opens the editor. Confirm a recording whose file was deleted shows the greyed placeholder.
- [ ] **Step 5:** Verify a `recording_*.mp4.thumb.png` now exists on disk next to a recording, and its `meta.json` has `durationMs` + `schemaVersion: 2` (backfill). Report findings.

---

## Self-Review

- **Spec coverage:** grid + 16:9 uniform tiles (T6); styled thumbnail via FrameCompositor (T4); lazy gen + disk cache + mtime invalidation (T4); duration in meta.json v2 + write-at-stop + ffprobe backfill (T1, T2, T4); caption date+duration+res (T5); click/long-press/hover-✕/missing-file (T5, T6); frame-timestamp clamp (T3). All spec sections mapped. ✓
- **Placeholder scan:** every code step has complete code; the two IMPLEMENTER notes call out real-API confirmations (ffmpegProbe signature, store test ctor) rather than leaving logic vague. ✓
- **Type consistency:** `RecordingThumbnail{pngFile,duration}`, `RecordingThumbnailService.thumbFor`, `RecordingMissingException`, `thumbTimestamp`, `RecordingCard(entry,fileExists,thumbnailFuture,onOpen,onOpenPlayground,onRemove)` are identical across tasks 4/5/6. `RecordingMetadata.duration` (T1) used by T4. ✓
