# Export Pipeline Robustness Implementation Plan (Workstream A: A1–A3, A5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the engine's ffmpeg export robust: resolve the ffmpeg binary reliably (so a packaged app finds it), never orphan ffmpeg subprocesses, support cancellation, drain stderr to avoid deadlock, and delete the dead isolate compositor. (Trim/speed/fade is Plan 3, not here.)

**Architecture:** A process-wide `Ffmpeg` resolver replaces bare `Process.start('ffmpeg', …)`. Decoder/encoder/GIF pipeline gain `kill()` + start-time stderr draining. The export pipelines accept a `CancelToken`, kill subprocesses on error/cancel, and throw `ExportCancelledException` on cancel. The unused `IsolateFrameCompositor` is removed.

**Tech Stack:** Dart `dart:io` Process, Flutter test, Melos, ffmpeg.

**Spec:** `docs/superpowers/specs/2026-05-26-critical-major-remediation-design.md` (Workstream A: A1, A2, A3, A5)

**Branch:** `remediation/critical-major` (already checked out)

**Context for the implementer:**
- Package under work: `packages/slipreel_engine`. Run `flutter test` from inside it. Run `melos` from repo root. Do NOT run `flutter build macos` (broken here).
- Existing engine export tests (`test/export/*`) call REAL ffmpeg against `test/fixtures/sample_recording.mp4` (a 320×240 ~1s clip) with no skip guard — ffmpeg is assumed present. Follow that convention; new integration tests may also assume ffmpeg is present.
- The three current call sites use a bare literal: `Process.start('ffmpeg', args)` in `ffmpeg_decoder.dart:46`, `ffmpeg_encoder.dart:137`, and `gif_export_pipeline.dart:119,191`.
- `FfmpegEncoder.start()` tries `h264_videotoolbox` then `libx264`, swallowing `Process.start` failures per codec (`ffmpeg_encoder.dart:132-153`). The resolver must surface "ffmpeg not found" BEFORE that loop so the user doesn't get a misleading "Could not start ffmpeg with any encoder".
- `IsolateFrameCompositor` (`isolate_frame_compositor.dart`, 281 lines) is referenced ONLY by `export_pipeline.dart` (the `useIsolateCompositor` flag + import) and the doc comment in `export_compositor.dart:14`. No test references it. `playback_screen.dart` does not pass the flag (uses the `false` default).

---

## File Structure

- Create `packages/slipreel_engine/lib/export/ffmpeg_resolver.dart` — `FfmpegResolver`, `FfmpegNotFoundException`, `Ffmpeg` facade. One responsibility: locate the ffmpeg binary.
- Create `packages/slipreel_engine/lib/export/export_cancellation.dart` — `CancelToken`, `ExportCancelledException`. One responsibility: cooperative cancellation signalling.
- Modify `ffmpeg_decoder.dart` — resolve binary, hold process handle, `kill()`, start-time stderr drain.
- Modify `ffmpeg_encoder.dart` — resolve binary before codec loop, `kill()`, start-time stderr drain.
- Modify `gif_export_pipeline.dart` — resolve binary, start-time stderr drain, cancellation + process kill.
- Modify `export_pipeline.dart` — `CancelToken` param, kill subprocesses on error/cancel, throw `ExportCancelledException`; remove `useIsolateCompositor` + isolate branch.
- Delete `isolate_frame_compositor.dart`; fix `export_compositor.dart` doc.
- Modify `.github/workflows/test-all-platforms.yml` — install ffmpeg in both jobs.
- Tests: `test/export/ffmpeg_resolver_test.dart`, `test/export/export_cancellation_test.dart`, additions to encoder/pipeline tests.

---

## Task 1: Install ffmpeg in CI

**Files:**
- Modify: `.github/workflows/test-all-platforms.yml`

**Why:** The engine's existing tests (and the new ones in this plan) invoke real ffmpeg. GitHub runners don't ship ffmpeg, so the CI built in the previous plan would fail on the runners (it was only verified locally). Install ffmpeg before bootstrap.

- [ ] **Step 1: Add an ffmpeg install step to the macOS job**

In `.github/workflows/test-all-platforms.yml`, in the `analyze-and-test` (macOS) job, add this step immediately AFTER the `flutter --version` step and BEFORE `dart pub global activate melos`:

```yaml
      - run: brew install ffmpeg
```

- [ ] **Step 2: Add an ffmpeg install step to the Linux job**

In the `test-linux` job, change the existing apt install line to also install ffmpeg. Replace:

```yaml
      - run: |
          sudo apt-get update
          sudo apt-get install -y libpipewire-0.3-dev libx11-dev
```

with:

```yaml
      - run: |
          sudo apt-get update
          sudo apt-get install -y libpipewire-0.3-dev libx11-dev ffmpeg
```

- [ ] **Step 3: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test-all-platforms.yml')); print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/test-all-platforms.yml
git commit -m "ci: install ffmpeg so engine export tests run on CI runners"
```

---

## Task 2: FfmpegResolver + FfmpegNotFoundException

**Files:**
- Create: `packages/slipreel_engine/lib/export/ffmpeg_resolver.dart`
- Test: `packages/slipreel_engine/test/export/ffmpeg_resolver_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/export/ffmpeg_resolver_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

void main() {
  group('FfmpegResolver', () {
    test('prefers the bundled path when it exists', () {
      final r = FfmpegResolver(
        bundledPath: '/app/bundled/ffmpeg',
        fileExists: (p) => p == '/app/bundled/ffmpeg',
        pathEnv: '/usr/bin',
      );
      expect(r.resolve(), '/app/bundled/ffmpeg');
    });

    test('falls through to Homebrew when no bundled path', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/opt/homebrew/bin/ffmpeg',
        pathEnv: '/usr/bin',
      );
      expect(r.resolve(), '/opt/homebrew/bin/ffmpeg');
    });

    test('falls through to /usr/local/bin', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/usr/local/bin/ffmpeg',
        pathEnv: '',
      );
      expect(r.resolve(), '/usr/local/bin/ffmpeg');
    });

    test('falls through to a PATH entry', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/custom/bin/ffmpeg',
        pathEnv: '/nope:/custom/bin',
      );
      expect(r.resolve(), '/custom/bin/ffmpeg');
    });

    test('throws FfmpegNotFoundException listing searched locations', () {
      final r = FfmpegResolver(
        fileExists: (_) => false,
        pathEnv: '/usr/bin',
      );
      expect(
        () => r.resolve(),
        throwsA(isA<FfmpegNotFoundException>().having(
          (e) => e.searchedLocations,
          'searchedLocations',
          contains('/opt/homebrew/bin/ffmpeg'),
        )),
      );
    });

    test('caches the first successful resolution', () {
      var calls = 0;
      final r = FfmpegResolver(
        fileExists: (p) {
          calls++;
          return p == '/opt/homebrew/bin/ffmpeg';
        },
        pathEnv: '',
      );
      r.resolve();
      final callsAfterFirst = calls;
      r.resolve();
      expect(calls, callsAfterFirst, reason: 'second resolve must use cache');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_resolver_test.dart`
Expected: FAIL — URI `package:slipreel_engine/export/ffmpeg_resolver.dart` doesn't exist.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/slipreel_engine/lib/export/ffmpeg_resolver.dart
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Thrown when no ffmpeg binary can be located.
class FfmpegNotFoundException implements Exception {
  FfmpegNotFoundException(this.searchedLocations);

  /// Absolute paths that were checked, in order.
  final List<String> searchedLocations;

  @override
  String toString() => 'FfmpegNotFoundException: ffmpeg binary not found. '
      'Searched: ${searchedLocations.join(", ")}';
}

/// Locates the ffmpeg binary for a packaged app.
///
/// Resolution order: bundled binary (drop-in hook for a future bundled
/// build) → Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`) → `PATH`.
/// A sandboxed/packaged macOS app has a minimal `PATH`, so the well-known
/// install locations are checked before `PATH`.
class FfmpegResolver {
  FfmpegResolver({
    this.bundledPath,
    bool Function(String path)? fileExists,
    String? pathEnv,
  })  : _fileExists = fileExists ?? _defaultFileExists,
        _pathEnv = pathEnv ?? Platform.environment['PATH'] ?? '';

  /// Absolute path to a bundled ffmpeg, when the app ships one. Null today —
  /// this is the hook a future "bundle a static ffmpeg" change wires up.
  final String? bundledPath;

  final bool Function(String path) _fileExists;
  final String _pathEnv;
  String? _cached;

  static bool _defaultFileExists(String p) => File(p).existsSync();

  static const List<String> _wellKnown = [
    '/opt/homebrew/bin/ffmpeg',
    '/usr/local/bin/ffmpeg',
  ];

  /// Returns the absolute path to ffmpeg, caching the first success.
  /// Throws [FfmpegNotFoundException] if none of the candidates exist.
  String resolve() {
    final cached = _cached;
    if (cached != null) return cached;

    final searched = <String>[];
    final candidates = <String>[
      if (bundledPath != null) bundledPath!,
      ..._wellKnown,
      ..._pathCandidates(),
    ];
    for (final candidate in candidates) {
      searched.add(candidate);
      if (_fileExists(candidate)) {
        return _cached = candidate;
      }
    }
    throw FfmpegNotFoundException(searched);
  }

  Iterable<String> _pathCandidates() sync* {
    if (_pathEnv.isEmpty) return;
    final sep = Platform.isWindows ? ';' : ':';
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    for (final dir in _pathEnv.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      yield trimmed.endsWith(Platform.pathSeparator)
          ? '$trimmed$exe'
          : '$trimmed${Platform.pathSeparator}$exe';
    }
  }
}

/// Process-wide ffmpeg-binary facade. All export code resolves through this
/// so every subprocess uses the same absolute path. Override [resolver] in
/// tests or to inject a bundled path.
class Ffmpeg {
  Ffmpeg._();

  static FfmpegResolver resolver = FfmpegResolver();

  /// Absolute path to ffmpeg. Throws [FfmpegNotFoundException] if missing.
  static String resolve() => resolver.resolve();

  @visibleForTesting
  static void resetForTesting() => resolver = FfmpegResolver();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_resolver_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/ffmpeg_resolver.dart packages/slipreel_engine/test/export/ffmpeg_resolver_test.dart
git commit -m "feat(engine): add FfmpegResolver with bundled/Homebrew/PATH resolution"
```

---

## Task 3: Wire the resolver into decoder, encoder, and GIF pipeline

**Files:**
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_decoder.dart:46`
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart:132-153`
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart:119,191`
- Test: `packages/slipreel_engine/test/export/ffmpeg_encoder_test.dart` (add a case)

- [ ] **Step 1: Write the failing test — FfmpegNotFoundException surfaces, not swallowed by codec fallback**

Add this test to `packages/slipreel_engine/test/export/ffmpeg_encoder_test.dart` (inside the existing top-level `main()`'s group, or a new group):

```dart
  group('FfmpegEncoder ffmpeg resolution', () {
    tearDown(Ffmpeg.resetForTesting);

    test('start() throws FfmpegNotFoundException when ffmpeg is absent '
        '(not "Could not start with any encoder")', () async {
      Ffmpeg.resolver = FfmpegResolver(fileExists: (_) => false, pathEnv: '');
      final encoder = FfmpegEncoder(
        outputPath: '${Directory.systemTemp.path}/none.mp4',
        width: 320,
        height: 240,
        fps: 30,
        bitrateKbps: 2000,
      );
      await expectLater(encoder.start(), throwsA(isA<FfmpegNotFoundException>()));
    });
  });
```

Add the imports at the top of the test file if missing:
```dart
import 'dart:io';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_encoder_test.dart`
Expected: FAIL — currently `start()` calls `Process.start('ffmpeg', …)` which throws a `ProcessException` swallowed by `tryCodec`, ending as `Exception('Could not start ffmpeg with any encoder')`, not `FfmpegNotFoundException`.

- [ ] **Step 3: Wire the resolver into the encoder**

In `ffmpeg_encoder.dart`, add the import near the top:
```dart
import 'ffmpeg_resolver.dart';
```
Change `start()` to resolve the binary ONCE before the codec loop, so `FfmpegNotFoundException` propagates:
```dart
  Future<void> start() async {
    final binary = Ffmpeg.resolve(); // throws FfmpegNotFoundException if absent

    Future<bool> tryCodec(String codec) async {
      final args = _argsFor(codec);
      AppLogger.ffmpeg.d('encode ($codec): $binary ${args.join(" ")}');
      try {
        _process = await Process.start(binary, args);
        return true;
      } catch (e) {
        AppLogger.ffmpeg.w('ffmpeg start with $codec failed: $e');
        return false;
      }
    }

    if (await tryCodec('h264_videotoolbox')) {
      _codecUsed = 'h264_videotoolbox';
    } else if (await tryCodec('libx264')) {
      _codecUsed = 'libx264';
    } else {
      throw Exception('Could not start ffmpeg with any encoder');
    }
    _sw.start();
  }
```

- [ ] **Step 4: Wire the resolver into the decoder**

In `ffmpeg_decoder.dart`, add `import 'ffmpeg_resolver.dart';`. In `frames()`, replace:
```dart
    final process = await Process.start('ffmpeg', args);
```
with:
```dart
    final binary = Ffmpeg.resolve();
    final process = await Process.start(binary, args);
```

- [ ] **Step 5: Wire the resolver into the GIF pipeline**

In `gif_export_pipeline.dart`, add `import 'ffmpeg_resolver.dart';`. In `run()`, resolve once near the top of the method (right after `final wallSw = Stopwatch()..start();`):
```dart
    final ffmpegBin = Ffmpeg.resolve();
```
Then replace both `await Process.start('ffmpeg', pass1Args)` → `await Process.start(ffmpegBin, pass1Args)` and `await Process.start('ffmpeg', pass2Args)` → `await Process.start(ffmpegBin, pass2Args)`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_encoder_test.dart test/export/ffmpeg_decoder_test.dart test/export/gif_export_pipeline_test.dart test/export/export_pipeline_test.dart`
Expected: PASS — the new FfmpegNotFoundException test passes; all existing real-ffmpeg tests still pass (resolver finds the local ffmpeg).

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/export/ffmpeg_decoder.dart packages/slipreel_engine/lib/export/ffmpeg_encoder.dart packages/slipreel_engine/lib/export/gif_export_pipeline.dart packages/slipreel_engine/test/export/ffmpeg_encoder_test.dart
git commit -m "feat(engine): resolve ffmpeg binary via FfmpegResolver at all call sites"
```

---

## Task 4: Drain stderr from process start (deadlock fix)

**Files:**
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_decoder.dart`
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart`
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart`

**Why:** stderr is currently read only AFTER the data stream completes. A chatty ffmpeg can fill the ~64KB stderr pipe, blocking ffmpeg, which stops producing stdout, which stalls the Dart reader — a hard hang. Drain stderr concurrently from process start.

- [ ] **Step 1: Decoder — drain stderr concurrently**

In `ffmpeg_decoder.dart` `frames()`, replace the spawn + try/finally body so stderr is consumed concurrently with stdout. Replace:
```dart
    final binary = Ffmpeg.resolve();
    final process = await Process.start(binary, args);
    final frameSize = width * height * 4;
    final buffer = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();

    try {
      await for (final chunk in process.stdout) {
        ...
      }
      final exit = await process.exitCode;
      if (exit != 0) {
        final stderr = await process.stderr
            .transform(SystemEncoding().decoder)
            .join();
        throw Exception('ffmpeg decode exited $exit: $stderr');
      }
    } finally {
      stopwatch.stop();
      totalDecodeMs = stopwatch.elapsedMilliseconds;
    }
```
with:
```dart
    final binary = Ffmpeg.resolve();
    final process = await Process.start(binary, args);
    final frameSize = width * height * 4;
    final buffer = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();

    // Drain stderr concurrently from the start; if we only read it after
    // stdout EOF, a chatty ffmpeg can fill the stderr pipe and deadlock.
    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(stderrBuffer.write);

    try {
      await for (final chunk in process.stdout) {
        buffer.add(chunk);
        while (buffer.length >= frameSize) {
          final all = buffer.takeBytes();
          var offset = 0;
          while (all.length - offset >= frameSize) {
            yield Uint8List.fromList(all.sublist(offset, offset + frameSize));
            offset += frameSize;
          }
          if (offset < all.length) {
            buffer.add(all.sublist(offset));
          }
        }
      }
      final exit = await process.exitCode;
      await stderrDone;
      if (exit != 0) {
        throw Exception('ffmpeg decode exited $exit: $stderrBuffer');
      }
    } finally {
      stopwatch.stop();
      totalDecodeMs = stopwatch.elapsedMilliseconds;
    }
```

- [ ] **Step 2: Encoder — attach stderr listener in start(), consume in finish()**

In `ffmpeg_encoder.dart`, add two fields next to `Process? _process;`:
```dart
  StringBuffer? _stderrBuffer;
  Future<void>? _stderrDone;
```
At the END of `start()` (after the codec is chosen, before/after `_sw.start()`), attach the listener to the chosen process:
```dart
    _sw.start();
    final p = _process!;
    final buffer = StringBuffer();
    _stderrBuffer = buffer;
    _stderrDone =
        p.stderr.transform(const SystemEncoding().decoder).forEach(buffer.write);
```
In `finish()`, replace the lazy stderr read. Replace:
```dart
    await p.stdin.close();
    final exit = await p.exitCode;
    _sw.stop();
    totalEncodeMs = _sw.elapsedMilliseconds;

    final stderr = await p.stderr.transform(SystemEncoding().decoder).join();
```
with:
```dart
    await p.stdin.close();
    final exit = await p.exitCode;
    _sw.stop();
    totalEncodeMs = _sw.elapsedMilliseconds;

    await _stderrDone;
    final stderr = _stderrBuffer?.toString() ?? '';
```

- [ ] **Step 3: GIF pipeline — drain stderr for both passes**

In `gif_export_pipeline.dart`, for pass 1: immediately after `final proc1 = await Process.start(ffmpegBin, pass1Args);` add:
```dart
      final stderr1Buffer = StringBuffer();
      final stderr1Done = proc1.stderr
          .transform(const SystemEncoding().decoder)
          .forEach(stderr1Buffer.write);
```
Replace the lazy error read:
```dart
      final exit1 = await proc1.exitCode;
      if (exit1 != 0) {
        final stderr1 = await proc1.stderr
            .transform(SystemEncoding().decoder)
            .join();
        throw Exception('GIF pass 1 (palettegen) exited $exit1: $stderr1');
      }
```
with:
```dart
      final exit1 = await proc1.exitCode;
      await stderr1Done;
      if (exit1 != 0) {
        throw Exception('GIF pass 1 (palettegen) exited $exit1: $stderr1Buffer');
      }
```
Do the symmetric change for pass 2: after `final proc2 = await Process.start(ffmpegBin, pass2Args);` add a `stderr2Buffer`/`stderr2Done` pair, and replace the pass-2 lazy read:
```dart
        final exit2 = await proc2.exitCode;
        if (exit2 != 0) {
          final stderr2 = await proc2.stderr
              .transform(SystemEncoding().decoder)
              .join();
          throw Exception('GIF pass 2 (paletteuse) exited $exit2: $stderr2');
        }
```
with:
```dart
        final exit2 = await proc2.exitCode;
        await stderr2Done;
        if (exit2 != 0) {
          throw Exception('GIF pass 2 (paletteuse) exited $exit2: $stderr2Buffer');
        }
```

- [ ] **Step 4: Run the full export test suite**

Run: `cd packages/slipreel_engine && flutter test test/export/`
Expected: PASS — all existing export tests (decoder, encoder, pipeline, gif) still green. The stderr behavior change is internal; error messages still include stderr content.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/ffmpeg_decoder.dart packages/slipreel_engine/lib/export/ffmpeg_encoder.dart packages/slipreel_engine/lib/export/gif_export_pipeline.dart
git commit -m "fix(engine): drain ffmpeg stderr from process start to avoid pipe-fill deadlock"
```

---

## Task 5: Process kill() + cancellation

**Files:**
- Create: `packages/slipreel_engine/lib/export/export_cancellation.dart`
- Test: `packages/slipreel_engine/test/export/export_cancellation_test.dart`
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_decoder.dart` (add kill + process field)
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart` (add kill)
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart` (cancel + kill on teardown)
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart` (cancel + kill)
- Test: `packages/slipreel_engine/test/export/export_pipeline_cancel_test.dart`

- [ ] **Step 1: Write the failing test for CancelToken**

```dart
// packages/slipreel_engine/test/export/export_cancellation_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';

void main() {
  group('CancelToken', () {
    test('starts not cancelled', () {
      expect(CancelToken().isCancelled, isFalse);
    });

    test('cancel() flips isCancelled and completes whenCancelled', () async {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(token.isCancelled, isTrue);
      await token.whenCancelled; // must complete
    });

    test('cancel() is idempotent', () {
      final token = CancelToken()..cancel();
      token.cancel(); // must not throw
      expect(token.isCancelled, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/export_cancellation_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Implement CancelToken + ExportCancelledException**

```dart
// packages/slipreel_engine/lib/export/export_cancellation.dart
import 'dart:async';

/// Thrown by an export pipeline's `run()` when its [CancelToken] was
/// cancelled. Lets callers distinguish a user-cancel from a real failure.
class ExportCancelledException implements Exception {
  const ExportCancelledException();
  @override
  String toString() => 'ExportCancelledException: export was cancelled';
}

/// Cooperative cancellation signal passed into an export pipeline.
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called. Used to interrupt blocked stages.
  Future<void> get whenCancelled => _completer.future;

  /// Requests cancellation. Idempotent.
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/export_cancellation_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Add kill() to decoder and encoder**

In `ffmpeg_decoder.dart`, promote the local process to a field and add `kill()`. Add a field near the top of the class:
```dart
  Process? _process;
```
In `frames()`, change `final process = await Process.start(binary, args);` to `final process = _process = await Process.start(binary, args);` (keep the local `process` for the rest of the method). Add this method to the class:
```dart
  /// Terminates the ffmpeg subprocess if running. Safe before start / after
  /// exit. Used by the pipeline to avoid orphaning ffmpeg on error/cancel.
  void kill() {
    _process?.kill(ProcessSignal.sigkill);
  }
```

In `ffmpeg_encoder.dart`, add the same method (it already has `Process? _process;`):
```dart
  /// Terminates the ffmpeg subprocess if running. Safe before start / after
  /// finish. Used to avoid orphaning ffmpeg on error/cancel.
  void kill() {
    _process?.kill(ProcessSignal.sigkill);
  }
```

- [ ] **Step 6: Wire cancellation + kill into ExportPipeline**

In `export_pipeline.dart`, add the import:
```dart
import 'export_cancellation.dart';
```
Change the `run` signature to accept a token:
```dart
  Future<ExportPerfSummary> run({
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
```
After `await encoder.start();` add the cancel wiring (kills subprocesses and unblocks parked stages):
```dart
    cancelToken?.whenCancelled.then((_) {
      decoder.kill();
      encoder.kill();
      decodedQueue.close();
      composedQueue.close();
    });
```
NOTE: `decodedQueue`/`composedQueue` are declared a few lines below in the current code; MOVE the two `final ...Queue = BoundedAsyncQueue...` declarations to ABOVE this `cancelToken` block so they're in scope (they have no dependency on `encoder.start()`).
Replace the existing `catch (_) { … }` teardown block:
```dart
    } catch (_) {
      decodedQueue.close();
      composedQueue.close();
      await Future.wait(
        stageFutures.map((f) => f.then<void>((_) {}, onError: (_) {})),
      );
      await compositor.dispose();
      rethrow;
    }
```
with one that kills the subprocesses and distinguishes cancel:
```dart
    } catch (_) {
      // Kill ffmpeg so a failed/cancelled export never orphans a subprocess.
      decoder.kill();
      encoder.kill();
      decodedQueue.close();
      composedQueue.close();
      await Future.wait(
        stageFutures.map((f) => f.then<void>((_) {}, onError: (_) {})),
      );
      await compositor.dispose();
      if (cancelToken?.isCancelled ?? false) {
        throw const ExportCancelledException();
      }
      rethrow;
    }
```

- [ ] **Step 7: Wire cancellation + kill into GifExportPipeline**

In `gif_export_pipeline.dart`, add `import 'export_cancellation.dart';`. Add `CancelToken? cancelToken` to the `run({...})` signature. Add two fields to the class to track the active subprocess/decoder for the cancel callback:
```dart
  Process? _activeProc;
  FfmpegDecoder? _activeDecoder;
```
After `final ffmpegBin = Ffmpeg.resolve();` add:
```dart
    cancelToken?.whenCancelled.then((_) {
      _activeProc?.kill(ProcessSignal.sigkill);
      _activeDecoder?.kill();
    });
```
For pass 1: after `final proc1 = await Process.start(ffmpegBin, pass1Args);` set `_activeProc = proc1;`, and after `final decoder1 = FfmpegDecoder(...)` set `_activeDecoder = decoder1;`. Inside the pass-1 `await for` loop, at the top of the loop body add a cancel check:
```dart
          if (cancelToken?.isCancelled ?? false) {
            throw const ExportCancelledException();
          }
```
Do the symmetric thing for pass 2 (`_activeProc = proc2; _activeDecoder = decoder2;` and the same cancel check at the top of its loop body). `FfmpegDecoder` already has `kill()` from Step 5; ensure the import for `ProcessSignal` is covered by `dart:io` (already imported).

- [ ] **Step 8: Write an integration test for cancellation (real ffmpeg + fixture)**

```dart
// packages/slipreel_engine/test/export/export_pipeline_cancel_test.dart
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling before run throws ExportCancelledException and writes no output',
      () async {
    final tmp = Directory.systemTemp.createTempSync('cancel_test');
    final outPath = '${tmp.path}/out.mp4';

    final state = EditorProjectState.defaults().copyWith(
      windowFrame: const WindowFrame(
        name: 'None',
        padding: EdgeInsets.zero,
        cornerRadius: 0,
        shadowBlur: 0,
        shadowOffset: Offset.zero,
        shadowColor: Color(0x00000000),
        borderWidth: 0,
      ),
    );
    const settings = ExportSettings(
      format: ExportFormat.mp4,
      resolution: ExportResolution.r720p,
      compression: CompressionTier.web,
      frameRate: 30,
      destination: ExportDestination.file,
    );

    final pipeline = ExportPipeline(
      sourcePath: 'test/fixtures/sample_recording.mp4',
      outputPath: outPath,
      sourceMetadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.now(),
        widthPx: 320,
        heightPx: 240,
        fps: 30,
      ),
      cursorRecording: CursorRecording(),
      projectState: state,
      settings: settings,
    );

    final token = CancelToken()..cancel(); // cancel up front

    await expectLater(
      pipeline.run(cancelToken: token),
      throwsA(isA<ExportCancelledException>()),
    );

    // No orphaned full output written (a kill mid-stream leaves at most a
    // partial/zero file; assert we didn't produce a complete export).
    final f = File(outPath);
    if (f.existsSync()) {
      expect(await f.length(), lessThan(100000),
          reason: 'cancelled export must not produce a full MP4');
    }
    tmp.deleteSync(recursive: true);
  });
}
```

- [ ] **Step 9: Run the cancellation tests + full export suite**

Run: `cd packages/slipreel_engine && flutter test test/export/`
Expected: PASS — cancellation test throws `ExportCancelledException`; all existing export tests still green.

- [ ] **Step 10: Commit**

```bash
git add packages/slipreel_engine/lib/export/export_cancellation.dart packages/slipreel_engine/lib/export/ffmpeg_decoder.dart packages/slipreel_engine/lib/export/ffmpeg_encoder.dart packages/slipreel_engine/lib/export/export_pipeline.dart packages/slipreel_engine/lib/export/gif_export_pipeline.dart packages/slipreel_engine/test/export/export_cancellation_test.dart packages/slipreel_engine/test/export/export_pipeline_cancel_test.dart
git commit -m "feat(engine): cancellable exports that kill ffmpeg subprocesses on error/cancel"
```

---

## Task 6: Delete the isolate compositor

**Files:**
- Delete: `packages/slipreel_engine/lib/export/isolate_frame_compositor.dart`
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Modify: `packages/slipreel_engine/lib/export/export_compositor.dart`

- [ ] **Step 1: Remove the isolate branch and flag from export_pipeline.dart**

In `export_pipeline.dart`:
- Delete the import `import 'isolate_frame_compositor.dart';`.
- Delete the `useIsolateCompositor` doc comment + field (lines ~48-54) and the `this.useIsolateCompositor = false,` constructor parameter.
- Replace the compositor construction:
```dart
    final ExportCompositor compositor = useIsolateCompositor
        ? await IsolateFrameCompositor.spawn(
            projectState: projectState,
            cursorRecording: cursorRecording,
            metadata: sourceMetadata,
            videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
            fps: pipelineFps,
          )
        : InProcessExportCompositor(FrameCompositor(
            projectState: projectState,
            cursorRecording: cursorRecording,
            metadata: sourceMetadata,
            videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
            fps: pipelineFps,
          ));
```
with:
```dart
    final ExportCompositor compositor = InProcessExportCompositor(FrameCompositor(
      projectState: projectState,
      cursorRecording: cursorRecording,
      metadata: sourceMetadata,
      videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
      fps: pipelineFps,
    ));
```

- [ ] **Step 2: Delete the file**

```bash
git rm packages/slipreel_engine/lib/export/isolate_frame_compositor.dart
```

- [ ] **Step 3: Fix the export_compositor.dart doc**

In `export_compositor.dart`, replace the class doc comment (lines ~7-16) that describes two implementations / "production default" with one that matches reality:
```dart
/// Per-frame compositor interface used by the export pipeline.
///
/// The sole implementation, [InProcessExportCompositor], runs
/// [FrameCompositor.compose] inline on the calling isolate. (An
/// isolate-based compositor was removed: `Picture.toImage` in a
/// background isolate crashes the Flutter engine on macOS.)
```

- [ ] **Step 4: Verify analyze + full engine test suite**

Run: `cd packages/slipreel_engine && flutter analyze --no-fatal-infos`
Expected: no errors/warnings (no dangling references to `IsolateFrameCompositor`/`useIsolateCompositor`).
Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS — entire engine suite green.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/export_pipeline.dart packages/slipreel_engine/lib/export/export_compositor.dart
git commit -m "refactor(engine): delete dead isolate compositor; fix compositor doc"
```

---

## Self-Review

**Spec coverage (Workstream A: A1, A2, A3, A5):**
- A1 ffmpeg resolution → Task 2 (resolver) + Task 3 (wired into all 3 call sites; FfmpegNotFoundException surfaces). ✓
- A2 process lifecycle + cancellation → Task 5 (kill() on decoder/encoder; CancelToken; kill on error/cancel; ExportCancelledException; gif + mp4). ✓
- A3 stderr drain → Task 4 (concurrent drain in decoder/encoder/gif). ✓
- A5 delete isolate compositor → Task 6. ✓
- Plus Task 1 (CI ffmpeg install) — required for the engine tests (existing + new) to run on CI runners; discovered during planning.
- NOT here: A4 trim/speed/fade (Plan 3, coupled with E1). ✓ (intentional)

**Placeholder scan:** No TBD/TODO/"handle errors". All steps show concrete code or exact before/after edits. ✓

**Type consistency:** `Ffmpeg.resolve()` / `FfmpegResolver` / `FfmpegNotFoundException` used identically in Tasks 2–3. `CancelToken` (`isCancelled`, `whenCancelled`, `cancel()`) and `ExportCancelledException` defined in Task 5 Step 3 and used in Steps 6–8 with matching members. `kill()` added in Task 5 Step 5 and called in Steps 6–7. `ProcessSignal.sigkill` from `dart:io` (already imported in all three files). ✓

**Assumptions to confirm during execution:**
- `package:flutter/foundation.dart`'s `visibleForTesting` is importable from the engine (it depends on flutter). If not, drop the annotation (keep `resetForTesting`).
- The `cancelToken.whenCancelled.then(...)` fire-and-forget in the pipelines is intentionally not awaited; on normal completion it never fires.
- The cancellation integration test (Task 5 Step 8) cancels up-front for determinism; mid-stream cancellation is covered behaviorally by the same teardown path. If a future task needs mid-stream timing, add a delayed-cancel variant.
