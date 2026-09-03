# Native Crash Scanner (v1b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward native crashes (bundled helper binaries and in-process native code) to the existing PostHog Error Tracking pipeline at next launch, carrying the crashed session's breadcrumb trail so each crash correlates with what the user was doing.

**Architecture:** A next-launch `NativeCrashScanner` reads new `~/Library/Logs/DiagnosticReports/*.ips` reports, filters to our app + bundled helpers, parses minimal fields into a `NativeCrashReport`, and emits a native `$exception` through v1a's `DiagnosticsService` → `PostHogSink`. A `PersistentCrumbStore` mirrors the in-memory breadcrumb ring + a small activity record to disk during each session (scrubbed, throttled) and deletes it on clean exit — so a surviving file marks an unclean crash and supplies the trail to attach. No new vendor/SDK, no symbolication, no in-process signal handler.

**Tech Stack:** Dart / Flutter, Riverpod, `melos` monorepo, `dart:io` file access, existing v1a diagnostics types (`DiagnosticsService`, `ExceptionEventBuilder`, `PiiScrubber`, `PostHogSink`, `Breadcrumbs`). Tests use `flutter_test` with in-memory temp dirs and fake sinks — no real crashes.

**Spec:** `docs/superpowers/specs/2026-09-03-native-crash-scanner-v1b-design.md`

## Global Constraints

- Package: all new code under `packages/screen_recorder/`. Diagnostics code in `lib/diagnostics/`, tests in `test/diagnostics/`.
- One consent gate: `shareDiagnostics`. When false, nothing is written to disk, scanned, parsed, or sent.
- Everything best-effort: a failure in any v1b component must be swallowed and must never block launch or crash the app (mirror v1a's `try/catch (_) {}` pattern).
- All PII leaves only through `PiiScrubber` — home dir → `~`, file paths redacted. Never upload a raw `.ips`.
- `mechanism` stays `{handled, synthetic}` (v1a shape). Nativeness is marked by per-frame `lang: 'native'` and a top-level `exception_platform: 'native'` property. Do NOT add `mechanism.type`.
- Run `flutter analyze` over the whole `screen_recorder` package (not per-file) before each commit — CI uses a newer Flutter than local and fails on warnings.
- Follow existing style by hand; never run `dart format` on existing files.

## File Structure

New (`packages/screen_recorder/lib/diagnostics/`):
- `native_crash_report.dart` — `NativeCrashReport` + `NativeFrame` models and the `.ips` / `.crash` parser (pure, no I/O).
- `persistent_crumb_store.dart` — `PersistentCrumbStore`: mirror crumbs + activity to `session.json`, throttled; read previous; clean-exit delete; gated.
- `native_crash_scanner.dart` — `NativeCrashScanner` + `NativeCrashWatermarkStore`: scan dir, filter, parse, emit, advance watermark.

Modified:
- `lib/diagnostics/exception_event_builder.dart` — add `fromNative(...)`.
- `lib/diagnostics/diagnostics_service.dart` — add `captureNativeCrash(...)`.
- `lib/main.dart` — generate per-launch `session_id`, add it to `diagnosticsMeta`, construct the crumb store, feed activity/flush, run the scanner post-first-frame, delete `session.json` on clean shutdown.

New tests (`packages/screen_recorder/test/diagnostics/`):
- `native_crash_report_test.dart` (+ fixtures under `test/diagnostics/fixtures/`)
- `persistent_crumb_store_test.dart`
- `native_crash_scanner_test.dart`
- additions to `exception_event_builder_test.dart`

---

## Task 1: `NativeCrashReport` model + `.ips` / `.crash` parser

**Files:**
- Create: `packages/screen_recorder/lib/diagnostics/native_crash_report.dart`
- Create: `packages/screen_recorder/test/diagnostics/native_crash_report_test.dart`
- Create fixtures: `packages/screen_recorder/test/diagnostics/fixtures/ips_sigsegv.ips`, `fixtures/legacy.crash`, `fixtures/garbage.ips`

**Interfaces:**
- Consumes: `PiiScrubber` (from v1a) — `scrub(String)`.
- Produces:
  - `class NativeFrame { const NativeFrame({required this.binary, required this.offset}); final String binary; final String offset; }`
  - `class NativeCrashReport { final String signal; final String faultingBinary; final List<NativeFrame> frames; final String? osVersion; final String? appVersion; final DateTime? crashedAt; final String reportFileName; }`
  - `NativeCrashReport? parseCrashReport(String contents, {required String fileName, required PiiScrubber scrubber})` — returns `null` when the file cannot be parsed into at least a signal + faulting binary. Handles modern `.ips` (JSON summary line + JSON body) and legacy `.crash` (plain text). Top 15 frames of the triggered thread; frames resolved via `usedImages[imageIndex].name` + hex `imageOffset`. Every string field is scrubbed before it is stored.

- [ ] **Step 1: Create the three fixtures**

`fixtures/ips_sigsegv.ips` — a realistic modern report: line 1 a JSON summary, then a JSON body. Include a username in a path so scrubbing is exercised:

```
{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000","app_version":"1.0.6","bug_type":"309","os_version":"macOS 15.5 (24F74)","incident_id":"ABC"}
{"procName":"ffmpeg","procPath":"/Users/alice/Slipreel.app/Contents/Helpers/ffmpeg","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"osVersion":{"train":"macOS 15.5"},"usedImages":[{"index":0,"name":"ffmpeg","base":4294967296},{"index":1,"name":"libsystem_kernel.dylib","base":8589934592}],"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":4660},{"imageIndex":1,"imageOffset":291}]},{"triggered":false,"frames":[{"imageIndex":1,"imageOffset":1}]}]}
```

`fixtures/legacy.crash` — plain-text legacy form:

```
Process:               whisper-cli [123]
Path:                  /Users/alice/Slipreel.app/Contents/Helpers/whisper-cli
OS Version:            macOS 13.2 (22D49)
Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
Thread 0 Crashed:
0   whisper-cli   0x000000010000abcd 0x100000000 + 43981
1   libsystem.dylib 0x00007fff20000000 0x7fff20000000 + 291
```

`fixtures/garbage.ips` — not a crash report at all:

```
this is not json and not a crash report
```

- [ ] **Step 2: Write the failing tests**

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final scrubber = PiiScrubber(homeDir: '/Users/alice');
  String fixture(String name) =>
      File('test/diagnostics/fixtures/$name').readAsStringSync();

  test('parses a modern .ips into signal + binary + frames', () {
    final r = parseCrashReport(fixture('ips_sigsegv.ips'),
        fileName: 'ips_sigsegv.ips', scrubber: scrubber)!;
    expect(r.signal, 'SIGSEGV');
    expect(r.faultingBinary, 'ffmpeg');
    expect(r.frames.first.binary, 'ffmpeg');
    expect(r.frames.first.offset, contains('0x'));
    // Only the triggered thread's frames, capped.
    expect(r.frames.length, 2);
    expect(r.osVersion, contains('15.5'));
    expect(r.reportFileName, 'ips_sigsegv.ips');
  });

  test('scrubs paths out of every parsed field', () {
    final r = parseCrashReport(fixture('ips_sigsegv.ips'),
        fileName: 'ips_sigsegv.ips', scrubber: scrubber)!;
    final blob = '${r.signal} ${r.faultingBinary} '
        '${r.frames.map((f) => '${f.binary} ${f.offset}').join(' ')}';
    expect(blob, isNot(contains('/Users/alice')));
    expect(blob, isNot(contains('alice')));
  });

  test('parses a legacy .crash file', () {
    final r = parseCrashReport(fixture('legacy.crash'),
        fileName: 'legacy.crash', scrubber: scrubber)!;
    expect(r.signal, 'SIGSEGV');
    expect(r.faultingBinary, 'whisper-cli');
    expect(r.frames, isNotEmpty);
  });

  test('returns null for an unparseable file, without throwing', () {
    expect(
        parseCrashReport(fixture('garbage.ips'),
            fileName: 'garbage.ips', scrubber: scrubber),
        isNull);
  });
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/native_crash_report_test.dart`
Expected: FAIL — `parseCrashReport` / `NativeCrashReport` not defined.

- [ ] **Step 4: Implement the model + parser**

```dart
import 'dart:convert';

import 'pii_scrubber.dart';

/// One resolved-but-unsymbolicated native frame: the image (binary) it lives in
/// and a hex offset within it. No function name — native reports carry only
/// binary + offset unless a dSYM is applied, which we do not do.
class NativeFrame {
  const NativeFrame({required this.binary, required this.offset});
  final String binary;
  final String offset;
}

/// A minimal, scrubbed view of one macOS crash report (`.ips` or legacy
/// `.crash`). We extract only what we forward; the raw report is never uploaded.
class NativeCrashReport {
  const NativeCrashReport({
    required this.signal,
    required this.faultingBinary,
    required this.frames,
    required this.reportFileName,
    this.osVersion,
    this.appVersion,
    this.crashedAt,
  });

  final String signal;
  final String faultingBinary;
  final List<NativeFrame> frames;
  final String reportFileName;
  final String? osVersion;
  final String? appVersion;
  final DateTime? crashedAt;
}

const int _maxFrames = 15;

/// Parses a crash report into a [NativeCrashReport], or returns null if it does
/// not look like one. Defensive by construction: any parse failure yields null
/// rather than throwing, so a format we cannot read is skipped, never fatal.
/// Every stored string is scrubbed.
NativeCrashReport? parseCrashReport(String contents,
    {required String fileName, required PiiScrubber scrubber}) {
  try {
    final trimmed = contents.trimLeft();
    if (trimmed.startsWith('{')) {
      final r = _parseIps(contents, fileName: fileName, scrubber: scrubber);
      if (r != null) return r;
    }
    return _parseLegacy(contents, fileName: fileName, scrubber: scrubber);
  } catch (_) {
    return null;
  }
}

NativeCrashReport? _parseIps(String contents,
    {required String fileName, required PiiScrubber scrubber}) {
  final lines = const LineSplitter().convert(contents);
  if (lines.isEmpty) return null;
  Map<String, dynamic>? summary;
  try {
    summary = jsonDecode(lines.first) as Map<String, dynamic>;
  } catch (_) {
    summary = null;
  }
  // Body is the rest of the file (everything after the summary line).
  final bodyText =
      lines.length > 1 ? lines.sublist(1).join('\n') : lines.first;
  final Map<String, dynamic> body;
  try {
    body = jsonDecode(bodyText) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }

  final exception = body['exception'];
  final signal = exception is Map
      ? (exception['signal'] ?? exception['type'])?.toString()
      : null;
  final procName = body['procName']?.toString();
  if (signal == null || procName == null) return null;

  final images = (body['usedImages'] as List?) ?? const [];
  String imageName(int i) {
    if (i < 0 || i >= images.length) return 'unknown';
    final img = images[i];
    return (img is Map ? img['name']?.toString() : null) ?? 'unknown';
  }

  final threads = (body['threads'] as List?) ?? const [];
  final triggered = threads.cast<dynamic>().firstWhere(
        (t) => t is Map && t['triggered'] == true,
        orElse: () => null,
      );
  final frames = <NativeFrame>[];
  if (triggered is Map) {
    final raw = (triggered['frames'] as List?) ?? const [];
    for (final f in raw.take(_maxFrames)) {
      if (f is! Map) continue;
      final idx = (f['imageIndex'] as num?)?.toInt() ?? -1;
      final off = (f['imageOffset'] as num?)?.toInt() ?? 0;
      frames.add(NativeFrame(
        binary: scrubber.scrub(imageName(idx)),
        offset: '0x${off.toRadixString(16)}',
      ));
    }
  }

  final os = (summary?['os_version'] ?? _train(body))?.toString();
  final appVersion = summary?['app_version']?.toString();
  final ts = summary?['timestamp']?.toString();

  return NativeCrashReport(
    signal: scrubber.scrub(signal),
    faultingBinary: scrubber.scrub(procName),
    frames: frames,
    reportFileName: fileName,
    osVersion: os == null ? null : scrubber.scrub(os),
    appVersion: appVersion,
    crashedAt: ts == null ? null : DateTime.tryParse(ts.replaceFirst(' ', 'T')),
  );
}

String? _train(Map<String, dynamic> body) {
  final os = body['osVersion'];
  return os is Map ? os['train']?.toString() : null;
}

// Legacy plain-text `.crash`: scan for the labelled lines and the frame table.
final RegExp _procLine = RegExp(r'^Process:\s+(\S+)');
final RegExp _excLine = RegExp(r'^Exception Type:\s+\S+\s*\((SIG\w+)\)');
final RegExp _osLine = RegExp(r'^OS Version:\s+(.+)$');
final RegExp _frameLine =
    RegExp(r'^\s*\d+\s+(\S+)\s+(0x[0-9a-fA-F]+)\s');

NativeCrashReport? _parseLegacy(String contents,
    {required String fileName, required PiiScrubber scrubber}) {
  final lines = const LineSplitter().convert(contents);
  String? proc, signal, os;
  final frames = <NativeFrame>[];
  for (final line in lines) {
    proc ??= _procLine.firstMatch(line)?.group(1);
    signal ??= _excLine.firstMatch(line)?.group(1);
    os ??= _osLine.firstMatch(line)?.group(1);
    final fm = _frameLine.firstMatch(line);
    if (fm != null && frames.length < _maxFrames) {
      frames.add(NativeFrame(
        binary: scrubber.scrub(fm.group(1)!),
        offset: fm.group(2)!,
      ));
    }
  }
  if (proc == null || signal == null) return null;
  return NativeCrashReport(
    signal: scrubber.scrub(signal),
    faultingBinary: scrubber.scrub(proc),
    frames: frames,
    reportFileName: fileName,
    osVersion: os == null ? null : scrubber.scrub(os),
  );
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/native_crash_report_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/diagnostics/native_crash_report.dart packages/screen_recorder/test/diagnostics/native_crash_report_test.dart packages/screen_recorder/test/diagnostics/fixtures/
git commit -m "feat: parse macOS .ips/.crash reports into NativeCrashReport"
```

---

## Task 2: `ExceptionEventBuilder.fromNative`

**Files:**
- Modify: `packages/screen_recorder/lib/diagnostics/exception_event_builder.dart`
- Modify: `packages/screen_recorder/test/diagnostics/exception_event_builder_test.dart`

**Interfaces:**
- Consumes: `NativeCrashReport`, `NativeFrame` (Task 1); existing `scrubber`, `meta`, `_scrubValue`, `PostHogEvent`.
- Produces on `ExceptionEventBuilder`:
  - `PostHogEvent fromNative(NativeCrashReport report, {List<String> breadcrumbs = const [], Map<String, Object?>? activity, String? sessionId, DateTime? now})`
  - `String fingerprintForNative(NativeCrashReport report)` → `'<signal>|<binary>|<topOffset>'`.

- [ ] **Step 1: Write the failing tests** (append to `exception_event_builder_test.dart`)

```dart
  test('fromNative builds a native \$exception with v1a mechanism shape', () {
    final report = NativeCrashReport(
      signal: 'SIGSEGV',
      faultingBinary: 'ffmpeg',
      frames: const [
        NativeFrame(binary: 'ffmpeg', offset: '0x1234'),
        NativeFrame(binary: 'libsystem.dylib', offset: '0x1'),
      ],
      reportFileName: 'x.ips',
      osVersion: 'macOS 15.5',
    );
    final e = builder.fromNative(report,
        breadcrumbs: ['event:export_started'],
        activity: {'op': 'export'},
        sessionId: 'sess-1');
    expect(e.name, r'$exception');
    expect(e.properties['exception_platform'], 'native');
    expect(e.properties['session_id'], 'sess-1');
    expect(e.properties['breadcrumbs'], ['event:export_started']);
    expect((e.properties['context'] as Map)['op'], 'export');
    final item = (e.properties[r'$exception_list'] as List).single as Map;
    expect(item['type'], 'SIGSEGV');
    expect(item['mechanism'], {'handled': false, 'synthetic': false});
    final frames = (item['stacktrace'] as Map)['frames'] as List;
    final f0 = frames.first as Map;
    expect(f0['platform'], 'custom');
    expect(f0['lang'], 'native');
    expect(f0['resolved'], false);
    expect(f0['function'], 'ffmpeg');
    expect(f0['instruction_addr'], contains('0x1234'));
  });

  test('fromNative fingerprint is stable for same signal+binary+top offset', () {
    NativeCrashReport r() => const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1234')],
        reportFileName: 'a.ips');
    expect(builder.fromNative(r()).properties[r'$exception_fingerprint'],
        builder.fromNative(r()).properties[r'$exception_fingerprint']);
    expect(builder.fromNative(r()).properties[r'$exception_fingerprint'],
        'SIGSEGV|ffmpeg|0x1234');
  });

  test('fromNative omits context when no activity', () {
    final e = builder.fromNative(const NativeCrashReport(
        signal: 'SIGABRT',
        faultingBinary: 'whisper-cli',
        frames: [],
        reportFileName: 'a.ips'));
    expect(e.properties.containsKey('context'), false);
  });
```

Add the import at the top of the test file:

```dart
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/exception_event_builder_test.dart`
Expected: FAIL — `fromNative` not defined.

- [ ] **Step 3: Implement `fromNative` + `fingerprintForNative`**

Add the import at the top of `exception_event_builder.dart`:

```dart
import 'native_crash_report.dart';
```

Add these methods inside the class (after `fromDart`):

```dart
  /// Builds a native `$exception` from a parsed crash report. Marked native by
  /// per-frame `lang: 'native'` and the top-level `exception_platform`; the
  /// `mechanism` keeps v1a's `{handled, synthetic}` shape. Crumbs + activity +
  /// session id come from the crashed session (persisted across the crash).
  PostHogEvent fromNative(
    NativeCrashReport report, {
    List<String> breadcrumbs = const [],
    Map<String, Object?>? activity,
    String? sessionId,
    DateTime? now,
  }) {
    final frames = report.frames
        .map((f) => <String, Object?>{
              'platform': 'custom',
              'lang': 'native',
              'resolved': false,
              'function': f.binary,
              'instruction_addr': '${f.binary}+${f.offset}',
              'in_app': _isBundledBinary(f.binary),
            })
        .toList();
    final item = <String, Object?>{
      'type': report.signal,
      'value': scrubber.scrub('${report.signal} in ${report.faultingBinary}'),
      'mechanism': {'handled': false, 'synthetic': false},
      'stacktrace': {'type': 'raw', 'frames': frames},
    };
    return PostHogEvent(
      name: r'$exception',
      timestamp: now ?? report.crashedAt ?? DateTime.now(),
      properties: {
        r'$exception_list': [item],
        r'$exception_fingerprint': fingerprintForNative(report),
        'exception_platform': 'native',
        if (report.osVersion != null) 'native_os': report.osVersion,
        ...meta,
        if (sessionId != null) 'session_id': sessionId,
        'breadcrumbs': breadcrumbs,
        if (activity != null && activity.isNotEmpty)
          'context': _scrubValue(activity),
      },
    );
  }

  String fingerprintForNative(NativeCrashReport report) {
    final top = report.frames.isNotEmpty ? report.frames.first.offset : 'no-frame';
    return '${report.signal}|${report.faultingBinary}|$top';
  }

  static bool _isBundledBinary(String name) =>
      name == 'ffmpeg' || name == 'ffprobe' || name == 'whisper-cli';
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/exception_event_builder_test.dart`
Expected: PASS (all, including the pre-existing Dart tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/diagnostics/exception_event_builder.dart packages/screen_recorder/test/diagnostics/exception_event_builder_test.dart
git commit -m "feat: ExceptionEventBuilder.fromNative for native crash events"
```

---

## Task 3: `PersistentCrumbStore`

**Files:**
- Create: `packages/screen_recorder/lib/diagnostics/persistent_crumb_store.dart`
- Create: `packages/screen_recorder/test/diagnostics/persistent_crumb_store_test.dart`

**Interfaces:**
- Consumes: `Breadcrumbs` (`snapshot()`), `PiiScrubber` (`scrub`, `scrubAll`).
- Produces:
  - `class PersistedSession { final String sessionId; final List<String> breadcrumbs; final Map<String, Object?>? activity; }`
  - `class PersistentCrumbStore` constructed with `{required String path, required String sessionId, required Breadcrumbs breadcrumbs, required PiiScrubber scrubber, required bool enabled, DateTime Function() now = DateTime.now}`.
  - `PersistedSession? readPrevious()` — reads and parses the file left by the previous session (call BEFORE the first write of this session), or null if absent/unreadable/disabled.
  - `void setActivity(Map<String, Object?>? activity)` — set/clear the current activity record (marks dirty).
  - `void writeIfDirty()` — synchronously write `session.json` when dirty and enabled (the throttle timer and the pre-handoff flush both call this; tests call it directly).
  - `void flushNow()` — force a synchronous write (pre-handoff), enabled-gated.
  - `void start()` / `void stop()` — start/stop the ~2s periodic `writeIfDirty` timer.
  - `void clearOnCleanExit()` — delete the file (clean shutdown, or `shareDiagnostics` turned off at runtime).

- [ ] **Step 1: Write the failing tests**

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/persistent_crumb_store.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory dir;
  late String path;
  final scrubber = PiiScrubber(homeDir: '/Users/alice');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crumbstore');
    path = '${dir.path}/session.json';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  PersistentCrumbStore make(Breadcrumbs b, {bool enabled = true}) =>
      PersistentCrumbStore(
          path: path,
          sessionId: 'sess-1',
          breadcrumbs: b,
          scrubber: scrubber,
          enabled: enabled);

  test('writes crumbs + activity, scrubbed', () {
    final b = Breadcrumbs()..dropEvent('export_started');
    final store = make(b)..setActivity({'op': 'export', 'path': '/Users/alice/x.mov'});
    store.writeIfDirty();
    final json = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(json['session_id'], 'sess-1');
    expect((json['breadcrumbs'] as List), contains('event:export_started'));
    expect((json['activity'] as Map)['op'], 'export');
    expect(jsonEncode(json), isNot(contains('/Users/alice')));
  });

  test('writeIfDirty is a no-op when nothing changed since last write', () {
    final b = Breadcrumbs()..dropEvent('a');
    final store = make(b)..writeIfDirty();
    final mtime1 = File(path).lastModifiedSync();
    store.writeIfDirty(); // not dirty
    expect(File(path).lastModifiedSync(), mtime1);
  });

  test('readPrevious returns the file a prior session left', () {
    File(path).writeAsStringSync(jsonEncode({
      'session_id': 'old',
      'launched_at': '2026-09-01T00:00:00Z',
      'breadcrumbs': ['event:recording_started'],
      'activity': {'op': 'record'},
    }));
    final prev = make(Breadcrumbs()).readPrevious()!;
    expect(prev.sessionId, 'old');
    expect(prev.breadcrumbs, ['event:recording_started']);
    expect(prev.activity!['op'], 'record');
  });

  test('clearOnCleanExit deletes the file', () {
    final store = make(Breadcrumbs()..dropEvent('a'))..writeIfDirty();
    expect(File(path).existsSync(), true);
    store.clearOnCleanExit();
    expect(File(path).existsSync(), false);
  });

  test('disabled store never writes and clears any existing file', () {
    File(path).writeAsStringSync('{}');
    final store = make(Breadcrumbs()..dropEvent('a'), enabled: false)
      ..setActivity({'op': 'x'});
    store.writeIfDirty();
    store.flushNow();
    expect(store.readPrevious(), isNull);
    store.clearOnCleanExit();
    expect(File(path).existsSync(), false);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/persistent_crumb_store_test.dart`
Expected: FAIL — `PersistentCrumbStore` not defined.

- [ ] **Step 3: Implement `PersistentCrumbStore`**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/breadcrumbs.dart';

import 'pii_scrubber.dart';

/// The trail a crashed session left behind, read at next launch.
class PersistedSession {
  const PersistedSession({
    required this.sessionId,
    required this.breadcrumbs,
    this.activity,
  });
  final String sessionId;
  final List<String> breadcrumbs;
  final Map<String, Object?>? activity;
}

/// Mirrors the in-memory breadcrumb ring plus a small "current activity" record
/// to `session.json`, scrubbed and throttled, so a full-app crash leaves a trail
/// for the next-launch scanner. Deleting the file on clean exit is what marks an
/// unclean crash: a surviving file means the app died mid-session.
///
/// Gated by `enabled` (`shareDiagnostics`): disabled means never write, and
/// delete any file that exists.
class PersistentCrumbStore {
  PersistentCrumbStore({
    required this.path,
    required this.sessionId,
    required Breadcrumbs breadcrumbs,
    required PiiScrubber scrubber,
    required bool enabled,
    DateTime Function() now = DateTime.now,
    this.flushInterval = const Duration(seconds: 2),
  })  : _breadcrumbs = breadcrumbs,
        _scrubber = scrubber,
        _enabled = enabled,
        _now = now;

  final String path;
  final String sessionId;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  final bool _enabled;
  final DateTime Function() _now;
  final Duration flushInterval;

  Map<String, Object?>? _activity;
  String? _lastWritten; // serialized payload of the last successful write
  Timer? _timer;

  PersistedSession? readPrevious() {
    if (!_enabled) return null;
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final crumbs = (json['breadcrumbs'] as List?)?.cast<String>() ?? const [];
      final activity = (json['activity'] as Map?)?.cast<String, Object?>();
      return PersistedSession(
        sessionId: json['session_id']?.toString() ?? 'unknown',
        breadcrumbs: crumbs,
        activity: activity,
      );
    } catch (_) {
      return null;
    }
  }

  void setActivity(Map<String, Object?>? activity) => _activity = activity;

  void start() {
    if (!_enabled) return;
    _timer ??= Timer.periodic(flushInterval, (_) => writeIfDirty());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void flushNow() => writeIfDirty();

  void writeIfDirty() {
    if (!_enabled) return;
    try {
      final payload = _serialize();
      if (payload == _lastWritten) return; // nothing changed
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(payload, flush: true);
      _lastWritten = payload;
    } catch (_) {
      // Best-effort: persisting crumbs must never break the app.
    }
  }

  void clearOnCleanExit() {
    stop();
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    _lastWritten = null;
  }

  String _serialize() {
    final crumbs = _scrubber.scrubAll(_breadcrumbs.snapshot());
    final activity = _activity == null
        ? null
        : _activity!.map((k, v) => MapEntry(k, _scrubValue(v)));
    return jsonEncode({
      'session_id': sessionId,
      'launched_at': _now().toUtc().toIso8601String(),
      'breadcrumbs': crumbs,
      if (activity != null) 'activity': activity,
    });
  }

  Object? _scrubValue(Object? v) {
    if (v is String) return _scrubber.scrub(v);
    if (v is Map) return v.map((k, val) => MapEntry(k, _scrubValue(val)));
    if (v is List) return v.map(_scrubValue).toList();
    return v;
  }
}
```

Note on the disabled test: `clearOnCleanExit` must delete the file even when disabled (it calls `deleteSync` unconditionally), and `writeIfDirty`/`flushNow` early-return — matching the "disabled clears any existing file" assertion.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/persistent_crumb_store_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/diagnostics/persistent_crumb_store.dart packages/screen_recorder/test/diagnostics/persistent_crumb_store_test.dart
git commit -m "feat: PersistentCrumbStore mirrors crumbs+activity across a crash"
```

---

## Task 4: `DiagnosticsService.captureNativeCrash`

**Files:**
- Modify: `packages/screen_recorder/lib/diagnostics/diagnostics_service.dart`
- Modify: `packages/screen_recorder/test/diagnostics/diagnostics_service_test.dart` (existing v1a test file; if the exact name differs, use the existing diagnostics service test file)

**Interfaces:**
- Consumes: `ExceptionEventBuilder.fromNative` (Task 2), `NativeCrashReport` (Task 1).
- Produces on `DiagnosticsService`:
  - `void captureNativeCrash(NativeCrashReport report, {List<String> breadcrumbs = const [], Map<String, Object?>? activity, String? sessionId})` — gated by `_enabled` + `_sink.isConfigured`; applies the same per-session cap and fingerprint dedupe as `captureException`; enqueues `_builder.fromNative(...)`. Best-effort (never throws).

- [ ] **Step 1: Write the failing tests** (append to `diagnostics_service_test.dart`)

The existing tests use a real `PostHogSink` over a `MockClient` and assert on the POSTed request body via `svc.flush()` — follow that exact pattern (there is no fake-sink `.enqueued` accessor). Reuse the file's existing `build({required bool enabled, required MockClient client})` helper.

```dart
  test('captureNativeCrash sends a native \$exception when enabled', () async {
    String? body;
    final svc = build(enabled: true,
        client: MockClient((req) async {
          body = req.body;
          return http.Response('{}', 200);
        }));
    svc.captureNativeCrash(
      const NativeCrashReport(
        signal: 'SIGSEGV',
        faultingBinary: 'ffmpeg',
        frames: [NativeFrame(binary: 'ffmpeg', offset: '0x1234')],
        reportFileName: 'x.ips',
      ),
      breadcrumbs: ['event:export_started'],
      sessionId: 'sess-1',
    );
    await svc.flush();
    expect(body, isNotNull);
    final batch = jsonDecode(body!)['batch'] as List;
    final props = (batch.single as Map)['properties'] as Map;
    expect((batch.single as Map)['event'], r'$exception');
    expect(props['exception_platform'], 'native');
    expect(props['session_id'], 'sess-1');
  });

  test('captureNativeCrash sends nothing when diagnostics disabled', () async {
    var calls = 0;
    final svc = build(enabled: false,
        client: MockClient((_) async { calls++; return http.Response('{}', 200); }));
    svc.captureNativeCrash(const NativeCrashReport(
        signal: 'SIGSEGV', faultingBinary: 'ffmpeg', frames: [], reportFileName: 'x.ips'));
    await svc.flush();
    expect(calls, 0);
  });
```

Add the import at the top of the test file:

```dart
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/diagnostics_service_test.dart`
Expected: FAIL — `captureNativeCrash` not defined.

- [ ] **Step 3: Implement `captureNativeCrash`**

Add the import to `diagnostics_service.dart`:

```dart
import 'native_crash_report.dart';
```

Add the method after `captureException`:

```dart
  /// Forwards a parsed native crash (from the next-launch scanner) as a native
  /// `$exception`. Same gating, cap, and dedupe as [captureException]; the
  /// crumbs/activity/session id belong to the crashed (previous) session.
  void captureNativeCrash(NativeCrashReport report,
      {List<String> breadcrumbs = const [],
      Map<String, Object?>? activity,
      String? sessionId}) {
    try {
      if (!_enabled || !_sink.isConfigured) return;
      if (_sessionCount >= maxPerSession) return;
      final fp = _builder.fingerprintForNative(report);
      final last = _lastSeen[fp];
      final t = _now();
      if (last != null && t.difference(last) < dedupeWindow) return;
      _lastSeen[fp] = t;
      _sessionCount++;
      _sink.enqueue(_builder.fromNative(report,
          breadcrumbs: breadcrumbs,
          activity: activity,
          sessionId: sessionId,
          now: t));
    } catch (_) {
      // Best-effort: forwarding a native crash must never break the app.
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/diagnostics_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/diagnostics/diagnostics_service.dart packages/screen_recorder/test/diagnostics/diagnostics_service_test.dart
git commit -m "feat: DiagnosticsService.captureNativeCrash"
```

---

## Task 5: `NativeCrashScanner` + watermark

**Files:**
- Create: `packages/screen_recorder/lib/diagnostics/native_crash_scanner.dart`
- Create: `packages/screen_recorder/test/diagnostics/native_crash_scanner_test.dart`

**Interfaces:**
- Consumes: `parseCrashReport` (Task 1), `DiagnosticsService.captureNativeCrash` (Task 4), `PersistedSession` (Task 3), `PiiScrubber`.
- Produces:
  - `class NativeCrashWatermarkStore` constructed with `{required String path}`; `Set<String> seenFiles()`; `DateTime? watermark()`; `void record(String fileName, DateTime? at)` (persists to JSON).
  - `class NativeCrashScanner` constructed with `{required Directory reportsDir, required NativeCrashWatermarkStore watermarkStore, required PiiScrubber scrubber, required void Function(NativeCrashReport report) onCrash, Set<String> ownProcesses = const {'ffmpeg','ffprobe','whisper-cli'}, String appBundleName = 'Slipreel'}`.
  - `void scan()` — synchronous, best-effort: list `*.ips`/`*.crash`, parse, filter to ours by `faultingBinary` ∈ ownProcesses OR file mentions the app bundle, skip files already in the watermark seen-set, call `onCrash` for each new one, record it in the watermark. Never throws.

- [ ] **Step 1: Write the failing tests**

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/native_crash_scanner.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory reports;
  late Directory state;
  final scrubber = PiiScrubber(homeDir: '/Users/alice');

  setUp(() {
    reports = Directory.systemTemp.createTempSync('reports');
    state = Directory.systemTemp.createTempSync('state');
  });
  tearDown(() {
    reports.deleteSync(recursive: true);
    state.deleteSync(recursive: true);
  });

  NativeCrashScanner make(List<NativeCrashReport> out) => NativeCrashScanner(
        reportsDir: reports,
        watermarkStore:
            NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
        scrubber: scrubber,
        onCrash: out.add,
      );

  void writeReport(String name, String procName) {
    File('${reports.path}/$name').writeAsStringSync(
      '{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000","os_version":"macOS 15.5"}\n'
      '{"procName":"$procName","exception":{"signal":"SIGSEGV"},'
      '"usedImages":[{"index":0,"name":"$procName"}],'
      '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":10}]}]}',
    );
  }

  test('forwards only our processes', () {
    writeReport('ours.ips', 'ffmpeg');
    writeReport('other.ips', 'Google Chrome');
    final out = <NativeCrashReport>[];
    make(out).scan();
    expect(out.map((r) => r.faultingBinary), ['ffmpeg']);
  });

  test('is idempotent: a second scan forwards nothing new', () {
    writeReport('ours.ips', 'whisper-cli');
    final out = <NativeCrashReport>[];
    final scanner = make(out);
    scanner.scan();
    scanner.scan();
    expect(out.length, 1);
  });

  test('a fresh scanner (new run) skips already-watermarked files', () {
    writeReport('ours.ips', 'ffmpeg');
    final out = <NativeCrashReport>[];
    make(out).scan(); // records watermark
    final out2 = <NativeCrashReport>[];
    make(out2).scan(); // new scanner, same watermark file
    expect(out2, isEmpty);
  });

  test('a garbage file is skipped without throwing', () {
    File('${reports.path}/bad.ips').writeAsStringSync('not a report');
    final out = <NativeCrashReport>[];
    expect(() => make(out).scan(), returnsNormally);
    expect(out, isEmpty);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/native_crash_scanner_test.dart`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement the watermark store + scanner**

```dart
import 'dart:convert';
import 'dart:io';

import 'native_crash_report.dart';
import 'pii_scrubber.dart';

/// Remembers which reports have already been forwarded, so a rescan (this
/// launch or any later one) never re-sends them.
class NativeCrashWatermarkStore {
  NativeCrashWatermarkStore({required this.path});
  final String path;

  Set<String> _seen = {};
  DateTime? _watermark;
  bool _loaded = false;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _seen = ((json['seen'] as List?)?.cast<String>() ?? const []).toSet();
      final w = json['watermark']?.toString();
      _watermark = w == null ? null : DateTime.tryParse(w);
    } catch (_) {}
  }

  Set<String> seenFiles() {
    _load();
    return _seen;
  }

  DateTime? watermark() {
    _load();
    return _watermark;
  }

  void record(String fileName, DateTime? at) {
    _load();
    _seen.add(fileName);
    if (at != null && (_watermark == null || at.isAfter(_watermark!))) {
      _watermark = at;
    }
    // Bound the seen-set so it can't grow without limit.
    if (_seen.length > 500) {
      _seen = _seen.toList().sublist(_seen.length - 500).toSet();
    }
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'seen': _seen.toList(),
        if (_watermark != null) 'watermark': _watermark!.toUtc().toIso8601String(),
      }), flush: true);
    } catch (_) {}
  }
}

/// Scans macOS crash reports at startup and forwards the ones caused by our app
/// or a bundled helper via [onCrash]. Best-effort and synchronous; any failure
/// is swallowed so it can never block or crash launch.
class NativeCrashScanner {
  NativeCrashScanner({
    required this.reportsDir,
    required this.watermarkStore,
    required this.scrubber,
    required this.onCrash,
    this.ownProcesses = const {'ffmpeg', 'ffprobe', 'whisper-cli'},
    this.appBundleName = 'Slipreel',
  });

  final Directory reportsDir;
  final NativeCrashWatermarkStore watermarkStore;
  final PiiScrubber scrubber;
  final void Function(NativeCrashReport report) onCrash;
  final Set<String> ownProcesses;
  final String appBundleName;

  void scan() {
    try {
      if (!reportsDir.existsSync()) return;
      final seen = watermarkStore.seenFiles();
      final files = reportsDir
          .listSync()
          .whereType<File>()
          .where((f) {
            final n = f.path.split(Platform.pathSeparator).last;
            return (n.endsWith('.ips') || n.endsWith('.crash')) &&
                !seen.contains(n);
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final f in files) {
        final name = f.path.split(Platform.pathSeparator).last;
        String contents;
        try {
          contents = f.readAsStringSync();
        } catch (_) {
          continue;
        }
        final report =
            parseCrashReport(contents, fileName: name, scrubber: scrubber);
        if (report == null) {
          // Unparseable: record it so we don't retry every launch.
          watermarkStore.record(name, null);
          continue;
        }
        if (!_isOurs(report, contents)) {
          watermarkStore.record(name, report.crashedAt);
          continue;
        }
        onCrash(report);
        watermarkStore.record(name, report.crashedAt);
      }
    } catch (_) {
      // Best-effort: a scan failure must never block launch.
    }
  }

  bool _isOurs(NativeCrashReport report, String contents) =>
      ownProcesses.contains(report.faultingBinary) ||
      report.faultingBinary == appBundleName ||
      contents.contains('$appBundleName.app');
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/native_crash_scanner_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/diagnostics/native_crash_scanner.dart packages/screen_recorder/test/diagnostics/native_crash_scanner_test.dart
git commit -m "feat: NativeCrashScanner forwards our reports past a watermark"
```

---

## Task 6: Wire into `main.dart` + session id + integration test

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`
- Create: `packages/screen_recorder/test/diagnostics/native_crash_integration_test.dart`

**Interfaces:**
- Consumes: everything above; existing `main.dart` locals `appSupportPath`, `distinctId`, `scrubber`, `diagnosticsMeta`, `diagnosticsService`, `initialGlobalPreferences.shareDiagnostics`, `Breadcrumbs.instance`.
- Produces: no new public API — wiring only, plus a per-launch `session_id` in `diagnosticsMeta`.

- [ ] **Step 1: Write the failing integration test**

This asserts the end-to-end wiring rule from spec §5 without launching the app: a *survived* `session.json` attaches crumbs to the emitted native event; a *cleared* one does not. It drives the scanner + store directly the way `main.dart` will.

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/native_crash_scanner.dart';
import 'package:screen_recorder/diagnostics/persistent_crumb_store.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory reports;
  late Directory state;
  final scrubber = PiiScrubber(homeDir: '/Users/alice');
  final builder = ExceptionEventBuilder(scrubber: scrubber, meta: const {'source': 'app'});

  setUp(() {
    reports = Directory.systemTemp.createTempSync('reports');
    state = Directory.systemTemp.createTempSync('state');
  });
  tearDown(() {
    reports.deleteSync(recursive: true);
    state.deleteSync(recursive: true);
  });

  void writeOurReport() => File('${reports.path}/ours.ips').writeAsStringSync(
        '{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000","os_version":"macOS 15.5"}\n'
        '{"procName":"ffmpeg","exception":{"signal":"SIGSEGV"},'
        '"usedImages":[{"index":0,"name":"ffmpeg"}],'
        '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":10}]}]}',
      );

  test('survived session.json attaches crumbs to the native event', () {
    File('${state.path}/session.json').writeAsStringSync(jsonEncode({
      'session_id': 'crashed',
      'breadcrumbs': ['event:export_started'],
      'activity': {'op': 'export'},
    }));
    writeOurReport();

    final store = PersistentCrumbStore(
        path: '${state.path}/session.json',
        sessionId: 'current',
        breadcrumbs: Breadcrumbs(),
        scrubber: scrubber,
        enabled: true);
    final prev = store.readPrevious(); // survived => not null

    final events = [];
    NativeCrashScanner(
      reportsDir: reports,
      watermarkStore: NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
      scrubber: scrubber,
      onCrash: (r) => events.add(builder.fromNative(r,
          breadcrumbs: prev?.breadcrumbs ?? const [],
          activity: prev?.activity,
          sessionId: prev?.sessionId)),
    ).scan();

    expect(events.single.properties['breadcrumbs'], ['event:export_started']);
    expect(events.single.properties['session_id'], 'crashed');
  });

  test('cleared session.json means the native event carries no crumbs', () {
    writeOurReport(); // no session.json => clean prior exit
    final store = PersistentCrumbStore(
        path: '${state.path}/session.json',
        sessionId: 'current',
        breadcrumbs: Breadcrumbs(),
        scrubber: scrubber,
        enabled: true);
    final prev = store.readPrevious(); // null

    final events = [];
    NativeCrashScanner(
      reportsDir: reports,
      watermarkStore: NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
      scrubber: scrubber,
      onCrash: (r) => events.add(builder.fromNative(r,
          breadcrumbs: prev?.breadcrumbs ?? const [],
          activity: prev?.activity,
          sessionId: prev?.sessionId)),
    ).scan();

    expect(events.single.properties['breadcrumbs'], isEmpty);
    expect(events.single.properties.containsKey('context'), false);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/native_crash_integration_test.dart`
Expected: FAIL to compile/pass until Tasks 1-5 are in (if run in isolation it passes once those exist; this task adds the real `main.dart` wiring).

- [ ] **Step 3: Add the per-launch session id to diagnostics meta**

In `main.dart`, where `diagnosticsMeta` is built (around line 270), add a per-launch session id used by both the meta and the crumb store. Generate it with the same 16-byte-hex `Random.secure()` mechanism `_resolveAnalyticsDistinctId` already uses (line ~462) — `Random` is already imported (`import 'dart:math' show Random;`), so no new dependency:

```dart
  final sessionRnd = Random.secure();
  final sessionId = List<int>.generate(16, (_) => sessionRnd.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final diagnosticsMeta = <String, Object?>{
    'source': 'app',
    'platform': Platform.operatingSystem,
    'app_version': appVersion,
    'session_id': sessionId,
  };
```

- [ ] **Step 4: Construct the crumb store + run the scanner post-first-frame**

After `installGlobalErrorHandlers(...)` (line 313) and before/around `runApp`, add — all guarded so failure never blocks launch, all gated on `initialGlobalPreferences.shareDiagnostics`:

```dart
  final crumbStore = PersistentCrumbStore(
    path: p.join(appSupportPath, 'diagnostics', 'session.json'),
    sessionId: sessionId,
    breadcrumbs: Breadcrumbs.instance,
    scrubber: scrubber,
    enabled: initialGlobalPreferences.shareDiagnostics,
  );
  // Read the previous (possibly crashed) session BEFORE this session writes.
  final previousSession = crumbStore.readPrevious();

  // After first frame: forward any native crash reports, then start mirroring
  // this session's crumbs. Best-effort; never blocks launch.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      if (initialGlobalPreferences.shareDiagnostics) {
        NativeCrashScanner(
          reportsDir: Directory(
              p.join(Platform.environment['HOME'] ?? '',
                  'Library', 'Logs', 'DiagnosticReports')),
          watermarkStore: NativeCrashWatermarkStore(
              path: p.join(appSupportPath, 'diagnostics',
                  'native_crash_watermark.json')),
          scrubber: scrubber,
          onCrash: (report) => diagnosticsService.captureNativeCrash(
            report,
            breadcrumbs: previousSession?.breadcrumbs ?? const [],
            activity: previousSession?.activity,
            sessionId: previousSession?.sessionId,
          ),
        ).scan();
      }
      // Start this session's trail (deletes the previous file via first write).
      crumbStore.start();
      crumbStore.writeIfDirty();
    } catch (_) {}
  });
```

- [ ] **Step 5: Expose the store via a provider, clear on clean exit + on opt-out**

`crumbStore` is created in `main()` but the runtime `shareDiagnostics` listener and lifecycle hooks reach services through providers. Mirror `diagnosticsServiceProvider` exactly.

First, add a throwing provider next to `diagnosticsServiceProvider` (in the same file it is declared, or in `persistent_crumb_store.dart`):

```dart
final crumbStoreProvider = Provider<PersistentCrumbStore>(
  (ref) => throw UnimplementedError('Override crumbStoreProvider in main()'),
);
```

Then override it in the `runApp` `ProviderScope` overrides list (right beside line 366's `diagnosticsServiceProvider.overrideWithValue(diagnosticsService)`):

```dart
      crumbStoreProvider.overrideWithValue(crumbStore),
```

In the `shareDiagnostics` listener (line 519, currently `(prev, next) => ref.read(diagnosticsServiceProvider).setEnabled(next)`), also clear the on-disk trail when the user opts out:

```dart
      (prev, next) {
        ref.read(diagnosticsServiceProvider).setEnabled(next);
        if (!next) ref.read(crumbStoreProvider).clearOnCleanExit();
      },
```

In the app-shutdown / detached lifecycle path (near line 685 where `ref.read(diagnosticsServiceProvider).flush()` runs on shutdown), add a clean-exit clear so a graceful quit deletes `session.json`:

```dart
      ref.read(crumbStoreProvider).clearOnCleanExit();
```

Note: `clearOnCleanExit` is what makes a surviving `session.json` mean "crashed" — so it must run on *every* clean shutdown path that also flushes diagnostics. Put it beside each existing `diagnosticsServiceProvider).flush()` shutdown call.

- [ ] **Step 6: Run the full diagnostics suite + integration test**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/`
Expected: PASS (all diagnostics tests including the integration test).

- [ ] **Step 7: Analyze the whole package + run the full app suite**

Run: `cd packages/screen_recorder && flutter analyze && flutter test`
Expected: analyze clean; all tests pass.

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder/lib/main.dart packages/screen_recorder/test/diagnostics/native_crash_integration_test.dart
git commit -m "feat: wire native crash scanner + persistent crumbs into launch"
```

---

## Task 7: Activity breadcrumbs at the risky boundaries

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart` (or wherever the crumb store is reachable) + the export/recording entry points that already drop analytics breadcrumbs.

**Interfaces:**
- Consumes: `crumbStore.setActivity(...)`, `crumbStore.flushNow()`.

This task makes the correlation actually rich: set the activity record and force a synchronous flush right before the highest-crash-risk handoffs (spawning a helper binary; starting ScreenCaptureKit capture), and clear it when the op ends.

- [ ] **Step 1: Find the handoff points**

Locate where the app spawns `ffmpeg`/`whisper-cli` (export/transcribe start) and where it starts capture. These already call `Breadcrumbs.instance.dropEvent(...)` / analytics `capture(...)` for `export_started` / `recording_started` — the same places.

Run: `cd packages/screen_recorder && grep -rn "export_started\|recording_started\|transcribe" lib/ | head`

- [ ] **Step 2: Set + flush activity before the handoff**

At each such point, right before the native handoff, add (via whatever reference to `crumbStore` the wiring exposes — mirror how `diagnosticsService` is reached from these call sites):

```dart
  crumbStore.setActivity({'op': 'export', 'preset': preset.id});
  crumbStore.flushNow(); // survive a crash in the very next native call
```

and on completion/failure of that op:

```dart
  crumbStore.setActivity(null);
```

Use only cheap, non-identifying values in the activity map (op name, preset id, counts, durations) — it is scrubbed, but keep it content-free by construction like the analytics props.

- [ ] **Step 3: Run tests**

Run: `cd packages/screen_recorder && flutter test`
Expected: PASS. (No new unit test is required here — the store's write/flush behavior is covered in Task 3; this task only calls existing, tested methods. If the handoff code has its own tests, update them to tolerate the new calls.)

- [ ] **Step 4: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/
git commit -m "feat: record activity context before native helper/capture handoffs"
```

---

## Task 8: Docs + memory

**Files:**
- Modify: `docs/superpowers/specs/2026-09-03-native-crash-scanner-v1b-design.md` (status → As-built, note any deviations)
- Modify: memory `error_tracking_feedback_subproject.md` + `MEMORY.md`

- [ ] **Step 1: Record as-built**

Update the spec Status line to `As-built` and add a short "As-built deviations" section noting anything that differed from this plan (e.g. the exact `main.dart` wiring point, the UUID mechanism reused).

- [ ] **Step 2: Update memory**

Update `error_tracking_feedback_subproject.md`: v1b built — `NativeCrashScanner` + `PersistentCrumbStore` + `fromNative`; per-launch `session_id`; clean-exit-clears crash discriminator; unsymbolicated frames; live validation still manual (force a helper SIGSEGV + an in-process crash, relaunch, confirm grouped native issues with `exception_platform: 'native'`). Update the MEMORY.md pointer line.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-09-03-native-crash-scanner-v1b-design.md
git commit -m "docs: mark native crash scanner v1b as-built"
```

(Memory files live outside the repo; write them separately with the memory tool.)

---

## Deferred to live validation (not a code task)

Per spec §10, after merge: force an `ffmpeg` SIGSEGV mid-export and an in-process crash, relaunch, and confirm in PostHog one grouped native issue each with `exception_platform: 'native'`, `lang: 'native'` frames, and — for the in-process case — an attached crumb trail. This is manual and belongs in the PR's test-plan notes, not an automated test.
