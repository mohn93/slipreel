# Slice Audio Waveform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a subtle, bottom-anchored audio waveform inside each main clip slice in the bottom timeline, drawn only when the recording has audio.

**Architecture:** A pure `WaveformPeaks` model + `reducePcmToPeaks` reducer live in `slipreel_engine`. A `WaveformExtractor` runs one ffmpeg pass (mixing audio streams to mono 8 kHz PCM) and reduces it to a normalized peak array, cached to a `<recording>.waveform.json` sidecar. A `FutureProvider.family` keyed by `videoPath` exposes the peaks to the UI. `SliceBar` gains a `WaveformPainter` layer behind its label that samples its own source time-range out of the shared peak array; it fades in when ready and dims when the slice's audio is muted/speed-silenced.

**Tech Stack:** Dart, Flutter, flutter_riverpod, ffmpeg/ffprobe (via the existing `Ffmpeg` resolver), `package:flutter_test`.

---

## File Structure

**Create:**
- `packages/slipreel_engine/lib/audio/waveform_peaks.dart` — immutable model + `slice()` + JSON.
- `packages/slipreel_engine/lib/audio/waveform_extractor.dart` — ffmpeg PCM decode + `reducePcmToPeaks` + arg builder.
- `packages/slipreel_engine/test/audio/waveform_peaks_test.dart`
- `packages/slipreel_engine/test/audio/waveform_extractor_test.dart`
- `packages/screen_recorder/lib/state/waveform_provider.dart` — sidecar cache + `waveformProvider`.
- `packages/screen_recorder/lib/ui/widgets/timeline/waveform_painter.dart` — `WaveformPainter` + pure path helpers.
- `packages/screen_recorder/test/state/waveform_sidecar_test.dart`
- `packages/screen_recorder/test/ui/widgets/timeline/waveform_painter_test.dart`
- `packages/screen_recorder/test/ui/widgets/timeline/slice_bar_waveform_test.dart`

**Modify:**
- `packages/screen_recorder/lib/ui/widgets/timeline/slice_bar.dart` — waveform layer + dim logic.
- `packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart` — thread `waveform`/`hasMic`/`hasSystem`.
- `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart` — same three params.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — read providers at the `EditorTimeline` call site.

**Run all tests for a package with:** `cd packages/<pkg> && flutter test <path>`

---

## Task 1: `WaveformPeaks` model

**Files:**
- Create: `packages/slipreel_engine/lib/audio/waveform_peaks.dart`
- Test: `packages/slipreel_engine/test/audio/waveform_peaks_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/audio/waveform_peaks_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';

void main() {
  group('WaveformPeaks.slice', () {
    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: List<double>.generate(1000, (i) => (i % 100) / 100.0), // 10s
      sourceDuration: const Duration(seconds: 10),
    );

    test('returns the bucket sub-range for a source window', () {
      // 2.00s .. 3.00s at 100 buckets/s => indices 200..300
      final sub = peaks.slice(
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      );
      expect(sub.length, 100);
      expect(sub.first, closeTo(0.0, 1e-9)); // bucket 200 => (200%100)/100 = 0
    });

    test('clamps to array bounds', () {
      final sub = peaks.slice(
        const Duration(seconds: 9),
        const Duration(seconds: 20),
      );
      expect(sub.length, 100); // 900..1000 clamped
    });

    test('returns empty for a degenerate window', () {
      final sub = peaks.slice(
        const Duration(seconds: 5),
        const Duration(seconds: 5),
      );
      expect(sub, isEmpty);
    });
  });

  group('WaveformPeaks json + equality', () {
    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: const [0.0, 0.5, 1.0, 0.25],
      sourceDuration: const Duration(milliseconds: 40),
    );

    test('round-trips through json (8-bit quantized)', () {
      final restored = WaveformPeaks.fromJson(peaks.toJson());
      expect(restored.bucketsPerSecond, 100);
      expect(restored.sourceDuration, const Duration(milliseconds: 40));
      expect(restored.peaks.length, 4);
      // 8-bit quantization tolerance.
      for (var i = 0; i < 4; i++) {
        expect(restored.peaks[i], closeTo(peaks.peaks[i], 1 / 255));
      }
    });

    test('fromJson rejects a mismatched version', () {
      final json = peaks.toJson()..['version'] = 999;
      expect(() => WaveformPeaks.fromJson(json), throwsFormatException);
    });

    test('== and hashCode are value-based', () {
      final a = WaveformPeaks(
        bucketsPerSecond: 100,
        peaks: const [0.1, 0.2],
        sourceDuration: const Duration(seconds: 1),
      );
      final b = WaveformPeaks(
        bucketsPerSecond: 100,
        peaks: const [0.1, 0.2],
        sourceDuration: const Duration(seconds: 1),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/audio/waveform_peaks_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:slipreel_engine/audio/waveform_peaks.dart'`.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/slipreel_engine/lib/audio/waveform_peaks.dart

/// Bumped when the on-disk sidecar format changes; stale sidecars with a
/// different version are ignored and re-extracted.
const int kWaveformSidecarVersion = 1;

/// Normalized per-bucket audio loudness across a whole recording's source
/// timeline. `peaks[i]` is in 0.0..1.0 (normalized to the recording's global
/// loudest bucket). Buckets are evenly spaced at [bucketsPerSecond].
class WaveformPeaks {
  WaveformPeaks({
    required this.bucketsPerSecond,
    required List<double> peaks,
    required this.sourceDuration,
  }) : peaks = List<double>.unmodifiable(peaks);

  final int bucketsPerSecond;
  final List<double> peaks;
  final Duration sourceDuration;

  /// Buckets covering the SOURCE-time window [start, end). Clamped to the
  /// array bounds; returns an empty list for a degenerate/empty window.
  List<double> slice(Duration start, Duration end) {
    if (peaks.isEmpty) return const [];
    final perMicro = bucketsPerSecond / 1e6;
    final startIdx =
        (start.inMicroseconds * perMicro).floor().clamp(0, peaks.length);
    final endIdx =
        (end.inMicroseconds * perMicro).ceil().clamp(0, peaks.length);
    if (endIdx <= startIdx) return const [];
    return peaks.sublist(startIdx, endIdx);
  }

  Map<String, dynamic> toJson() => {
        'version': kWaveformSidecarVersion,
        'bucketsPerSecond': bucketsPerSecond,
        'sourceDurationMicros': sourceDuration.inMicroseconds,
        // 8-bit quantized to keep the sidecar small; a waveform doesn't need
        // more than 256 amplitude levels.
        'peaks': peaks
            .map((p) => (p.clamp(0.0, 1.0) * 255).round())
            .toList(growable: false),
      };

  factory WaveformPeaks.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != kWaveformSidecarVersion) {
      throw FormatException('WaveformPeaks: unsupported version $version');
    }
    final bps = json['bucketsPerSecond'];
    final durMicros = json['sourceDurationMicros'];
    final rawPeaks = json['peaks'];
    if (bps is! num || durMicros is! num || rawPeaks is! List) {
      throw const FormatException('WaveformPeaks: malformed json');
    }
    return WaveformPeaks(
      bucketsPerSecond: bps.toInt(),
      sourceDuration: Duration(microseconds: durMicros.toInt()),
      peaks: rawPeaks
          .map((v) => (v is num ? v.toInt() : 0) / 255.0)
          .toList(growable: false),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaveformPeaks &&
          other.bucketsPerSecond == bucketsPerSecond &&
          other.sourceDuration == sourceDuration &&
          _listEquals(other.peaks, peaks);

  @override
  int get hashCode => Object.hash(
        bucketsPerSecond,
        sourceDuration,
        // Length + a coarse sample so hashCode stays O(1)-ish for big arrays.
        peaks.length,
        peaks.isEmpty ? 0 : peaks[peaks.length ~/ 2],
      );

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 1e-9) return false;
    }
    return true;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/audio/waveform_peaks_test.dart`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/audio/waveform_peaks.dart packages/slipreel_engine/test/audio/waveform_peaks_test.dart
git commit -m "feat(waveform): WaveformPeaks model with source-range slicing + json"
```

---

## Task 2: PCM reducer + ffmpeg arg builder (pure)

**Files:**
- Create: `packages/slipreel_engine/lib/audio/waveform_extractor.dart`
- Test: `packages/slipreel_engine/test/audio/waveform_extractor_test.dart` (pure part only here; the ffmpeg integration test is added in Task 3)

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/audio/waveform_extractor_test.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_extractor.dart';

void main() {
  group('reducePcmToPeaks', () {
    test('empty input -> empty peaks', () {
      expect(reducePcmToPeaks(Int16List(0), samplesPerBucket: 80), isEmpty);
    });

    test('buckets by samplesPerBucket and normalizes to global max', () {
      // 160 samples => 2 buckets at samplesPerBucket=80.
      // Bucket 0 peak = 4000, bucket 1 peak = 8000 => normalized 0.5, 1.0.
      final s = Int16List(160);
      for (var i = 0; i < 80; i++) {
        s[i] = (i.isEven ? 4000 : -4000);
      }
      for (var i = 80; i < 160; i++) {
        s[i] = (i.isEven ? 8000 : -8000);
      }
      final peaks = reducePcmToPeaks(s, samplesPerBucket: 80);
      expect(peaks.length, 2);
      expect(peaks[0], closeTo(0.5, 1e-6));
      expect(peaks[1], closeTo(1.0, 1e-6));
    });

    test('all-silence stays all-zero (no divide-by-zero)', () {
      final peaks = reducePcmToPeaks(Int16List(240), samplesPerBucket: 80);
      expect(peaks.length, 3);
      expect(peaks.every((p) => p == 0.0), isTrue);
    });
  });

  group('buildWaveformPcmArgs', () {
    test('single stream maps the first audio stream directly', () {
      final args = buildWaveformPcmArgs('/x/rec.mp4', 1);
      expect(args, containsAllInOrder(['-map', '0:a:0']));
      expect(args, containsAllInOrder(['-ar', '8000']));
      expect(args, containsAllInOrder(['-f', 's16le', '-']));
      expect(args.contains('-filter_complex'), isFalse);
    });

    test('two streams amix down to one labelled output', () {
      final args = buildWaveformPcmArgs('/x/rec.mp4', 2);
      expect(args, containsAllInOrder(['-filter_complex',
          '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]']));
      expect(args, containsAllInOrder(['-map', '[aout]']));
      expect(args, containsAllInOrder(['-ac', '1', '-ar', '8000']));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/audio/waveform_extractor_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/slipreel_engine/lib/audio/waveform_extractor.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

/// Sample rate we decode audio to for waveform purposes — low enough to keep
/// the PCM small, high enough that 100 buckets/sec stay meaningful.
const int kWaveformSampleRate = 8000;
const int kWaveformBucketsPerSecond = 100;
const int kWaveformSamplesPerBucket =
    kWaveformSampleRate ~/ kWaveformBucketsPerSecond; // 80 (10ms buckets)

/// Reduces mono PCM (signed 16-bit samples) to a normalized peak-per-bucket
/// array. Peak = max abs sample in the bucket / 32768, then the whole array
/// is normalized to its global max so quiet recordings still read.
List<double> reducePcmToPeaks(
  Int16List samples, {
  required int samplesPerBucket,
}) {
  if (samples.isEmpty || samplesPerBucket <= 0) return const [];
  final bucketCount = (samples.length / samplesPerBucket).ceil();
  final peaks = List<double>.filled(bucketCount, 0.0);
  var globalMax = 0.0;
  for (var b = 0; b < bucketCount; b++) {
    final start = b * samplesPerBucket;
    final end = (start + samplesPerBucket) < samples.length
        ? (start + samplesPerBucket)
        : samples.length;
    var peak = 0;
    for (var i = start; i < end; i++) {
      final a = samples[i] < 0 ? -samples[i] : samples[i];
      if (a > peak) peak = a;
    }
    final v = peak / 32768.0;
    peaks[b] = v;
    if (v > globalMax) globalMax = v;
  }
  if (globalMax > 0) {
    for (var b = 0; b < bucketCount; b++) {
      peaks[b] = peaks[b] / globalMax;
    }
  }
  return peaks;
}

/// ffmpeg args that emit mono [kWaveformSampleRate] Hz signed-16 little-endian
/// PCM on stdout. Two streams are mixed (`amix`); one stream is mapped
/// directly.
List<String> buildWaveformPcmArgs(String videoPath, int streamCount) {
  final args = <String>['-v', 'error', '-i', videoPath];
  if (streamCount >= 2) {
    args.addAll([
      '-filter_complex',
      '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]',
      '-map',
      '[aout]',
    ]);
  } else {
    args.addAll(['-map', '0:a:0']);
  }
  args.addAll(['-ac', '1', '-ar', '$kWaveformSampleRate', '-f', 's16le', '-']);
  return args;
}

/// Extracts a [WaveformPeaks] for a recording, or null when the recording has
/// no audio or extraction fails. Runs one ffprobe (stream count) + one ffmpeg
/// (PCM decode) pass. Pure helpers above are unit-tested separately.
class WaveformExtractor {
  const WaveformExtractor();

  Future<WaveformPeaks?> extract(String videoPath) async {
    final probe = await ffmpegProbe(path: videoPath);
    final streamCount = probe.audioStreams.length;
    if (streamCount == 0) return null;

    final result = await Process.run(
      Ffmpeg.resolve(),
      buildWaveformPcmArgs(videoPath, streamCount),
      stdoutEncoding: null, // keep stdout as raw bytes (List<int>)
    );
    if (result.exitCode != 0) return null;
    final bytes = result.stdout as List<int>;
    if (bytes.length < 2) return null;

    final samples = _bytesToInt16(bytes);
    final peaks =
        reducePcmToPeaks(samples, samplesPerBucket: kWaveformSamplesPerBucket);
    if (peaks.isEmpty) return null;

    final micros = (samples.length / kWaveformSampleRate * 1e6).round();
    return WaveformPeaks(
      bucketsPerSecond: kWaveformBucketsPerSecond,
      peaks: peaks,
      sourceDuration: Duration(microseconds: micros),
    );
  }

  static Int16List _bytesToInt16(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final n = bd.lengthInBytes ~/ 2;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little);
    }
    return out;
  }
}
```

> If `ffmpegProbe` returns a result whose audio-streams getter is named differently than `audioStreams`, match the existing name (see `packages/slipreel_engine/lib/export/ffmpeg_probe.dart`). The probe call in `playback_screen.dart` uses `probedForAudio.audioStreams`, so `audioStreams` is correct.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/audio/waveform_extractor_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/audio/waveform_extractor.dart packages/slipreel_engine/test/audio/waveform_extractor_test.dart
git commit -m "feat(waveform): pure PCM->peaks reducer + ffmpeg arg builder"
```

---

## Task 3: `WaveformExtractor` ffmpeg integration test

**Files:**
- Modify: `packages/slipreel_engine/test/audio/waveform_extractor_test.dart`

This validates the real ffmpeg pass against the existing fixture used by `ffmpeg_probe_test.dart`. It is robust to whether the fixture has audio.

- [ ] **Step 1: Add the integration test**

Append this `group` inside `main()` in `test/audio/waveform_extractor_test.dart` (add the imports `dart:io` and `package:slipreel_engine/export/ffmpeg_probe.dart` at the top):

```dart
  group('WaveformExtractor.extract (ffmpeg integration)', () {
    final fixture = File('test/fixtures/sample_recording.mp4');

    test('matches the fixture audio presence', () async {
      if (!fixture.existsSync()) {
        markTestSkipped('fixture missing');
        return;
      }
      final probe = await ffmpegProbe(path: fixture.path);
      final peaks = await const WaveformExtractor().extract(fixture.path);

      if (probe.audioStreams.isEmpty) {
        expect(peaks, isNull);
      } else {
        expect(peaks, isNotNull);
        expect(peaks!.peaks, isNotEmpty);
        expect(peaks.bucketsPerSecond, kWaveformBucketsPerSecond);
        expect(peaks.sourceDuration, greaterThan(Duration.zero));
        expect(peaks.peaks.every((p) => p >= 0.0 && p <= 1.0), isTrue);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('returns null for a path with no audio streams', () async {
      // A bogus path makes ffprobe report zero streams -> null, no throw.
      final peaks =
          await const WaveformExtractor().extract('/nonexistent/none.mp4');
      expect(peaks, isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
```

- [ ] **Step 2: Run the test**

Run: `cd packages/slipreel_engine && flutter test test/audio/waveform_extractor_test.dart`
Expected: PASS (the integration group passes or skips if the fixture is absent; ffmpeg must be resolvable on the machine).

- [ ] **Step 3: Commit**

```bash
git add packages/slipreel_engine/test/audio/waveform_extractor_test.dart
git commit -m "test(waveform): ffmpeg extraction integration against fixture"
```

---

## Task 4: Sidecar cache + `waveformProvider`

**Files:**
- Create: `packages/screen_recorder/lib/state/waveform_provider.dart`
- Test: `packages/screen_recorder/test/state/waveform_sidecar_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/waveform_sidecar_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:screen_recorder/state/waveform_provider.dart';

void main() {
  test('sidecar save -> load round-trips', () async {
    final dir = await Directory.systemTemp.createTemp('wf_sidecar');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/rec.mp4';

    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: const [0.0, 0.5, 1.0],
      sourceDuration: const Duration(milliseconds: 30),
    );

    await saveWaveformSidecar(videoPath, peaks);
    expect(File('$videoPath.waveform.json').existsSync(), isTrue);

    final loaded = await loadWaveformSidecar(videoPath);
    expect(loaded, isNotNull);
    expect(loaded!.peaks.length, 3);
    expect(loaded.bucketsPerSecond, 100);
  });

  test('load returns null when no sidecar exists', () async {
    final loaded = await loadWaveformSidecar('/no/such/rec.mp4');
    expect(loaded, isNull);
  });

  test('load returns null on a version mismatch', () async {
    final dir = await Directory.systemTemp.createTemp('wf_sidecar_ver');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/rec.mp4';
    await File('$videoPath.waveform.json')
        .writeAsString('{"version":999,"bucketsPerSecond":100,'
            '"sourceDurationMicros":1000,"peaks":[1,2,3]}');

    final loaded = await loadWaveformSidecar(videoPath);
    expect(loaded, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/waveform_sidecar_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/state/waveform_provider.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:slipreel_engine/audio/waveform_extractor.dart';

String _sidecarPath(String videoPath) => '$videoPath.waveform.json';

/// Reads a cached [WaveformPeaks] sidecar next to the recording. Returns null
/// if it's missing, unreadable, or a stale/unsupported version.
Future<WaveformPeaks?> loadWaveformSidecar(String videoPath) async {
  try {
    final file = File(_sidecarPath(videoPath));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) return null;
    return WaveformPeaks.fromJson(json);
  } catch (_) {
    return null; // missing/corrupt/version-mismatch -> re-extract
  }
}

/// Writes the sidecar next to the recording. Best-effort; swallows IO errors.
Future<void> saveWaveformSidecar(String videoPath, WaveformPeaks peaks) async {
  try {
    await File(_sidecarPath(videoPath))
        .writeAsString(jsonEncode(peaks.toJson()));
  } catch (_) {/* non-fatal: waveform just won't be cached */}
}

/// Per-recording waveform peaks. Sidecar hit returns instantly; a miss runs
/// one ffmpeg extraction, caches it, and returns it. Errors resolve to null so
/// the UI simply draws no waveform.
final waveformProvider =
    FutureProvider.family<WaveformPeaks?, String>((ref, videoPath) async {
  final cached = await loadWaveformSidecar(videoPath);
  if (cached != null) return cached;
  try {
    final peaks = await const WaveformExtractor().extract(videoPath);
    if (peaks != null) await saveWaveformSidecar(videoPath, peaks);
    return peaks;
  } catch (_) {
    return null;
  }
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/waveform_sidecar_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/waveform_provider.dart packages/screen_recorder/test/state/waveform_sidecar_test.dart
git commit -m "feat(waveform): sidecar cache + waveformProvider (FutureProvider.family)"
```

---

## Task 5: `WaveformPainter`

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/timeline/waveform_painter.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/waveform_painter_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/timeline/waveform_painter_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/waveform_painter.dart';

void main() {
  group('waveformPoints', () {
    test('maps samples across width, taller sample sits higher', () {
      const size = Size(100, 40);
      final pts = waveformPoints(const [0.0, 1.0], size, 0.6);
      expect(pts.length, 2);
      expect(pts.first.dx, 0.0);
      expect(pts.last.dx, 100.0);
      // y grows downward: the louder (1.0) sample has the smaller y.
      expect(pts.last.dy, lessThan(pts.first.dy));
      // 1.0 sample reaches 60% of height up from the bottom (40 * 0.6 = 24).
      expect(pts.last.dy, closeTo(40 - 24, 1e-6));
    });

    test('empty / single sample -> empty points', () {
      expect(waveformPoints(const [], const Size(10, 10), 0.6), isEmpty);
      expect(waveformPoints(const [0.5], const Size(10, 10), 0.6), isEmpty);
    });
  });

  group('buildSmoothPath', () {
    test('path spans the full width', () {
      final pts = waveformPoints(
        List<double>.generate(20, (i) => (i % 5) / 5),
        const Size(200, 40),
        0.6,
      );
      final path = buildSmoothPath(pts);
      final b = path.getBounds();
      expect(b.left, closeTo(0, 1.0));
      expect(b.right, closeTo(200, 2.0));
    });
  });

  testWidgets('painter renders without throwing', (tester) async {
    await tester.pumpWidget(
      Center(
        child: CustomPaint(
          size: const Size(120, 46),
          painter: WaveformPainter(
            samples: List<double>.generate(40, (i) => (i % 7) / 7),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/waveform_painter_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/ui/widgets/timeline/waveform_painter.dart
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Light bright-edge area waveform colour (matches the locked design).
const Color _kWaveColor = Color(0xFFEAF1FF);
const double _kFillAlpha = 0.30; // bottom-edge fill alpha
const double _kStrokeAlpha = 0.45; // top stroke alpha
const double _kMaxHeightFactor = 0.6; // peaks reach 60% of slice height
const double _kStrokeWidth = 1.25;

/// Maps normalized samples (0..1) to canvas points. y grows downward, so a
/// louder sample yields a SMALLER y (drawn higher). Returns empty for <2
/// samples (a spline needs at least two points).
List<Offset> waveformPoints(
  List<double> samples,
  Size size,
  double maxHeightFactor,
) {
  if (samples.length < 2 || size.width <= 0 || size.height <= 0) {
    return const [];
  }
  final maxH = size.height * maxHeightFactor;
  final last = samples.length - 1;
  final pts = <Offset>[];
  for (var i = 0; i < samples.length; i++) {
    final x = i / last * size.width;
    final h = samples[i].clamp(0.0, 1.0) * maxH;
    pts.add(Offset(x, size.height - h));
  }
  return pts;
}

/// Smooth Catmull-Rom spline through [pts] (open curve). Empty path for <2.
Path buildSmoothPath(List<Offset> pts) {
  final path = Path();
  if (pts.length < 2) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = i == 0 ? pts[i] : pts[i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
    final c1 = Offset(
      p1.dx + (p2.dx - p0.dx) / 6.0,
      p1.dy + (p2.dy - p0.dy) / 6.0,
    );
    final c2 = Offset(
      p2.dx - (p3.dx - p1.dx) / 6.0,
      p2.dy - (p3.dy - p1.dy) / 6.0,
    );
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path;
}

/// Draws a subtle bottom-anchored area waveform with a soft gradient fill and
/// a thin bright top stroke. Dimming/fade is handled by the caller's
/// AnimatedOpacity, so this painter always paints at its configured alpha.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({required this.samples});

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = waveformPoints(samples, size, _kMaxHeightFactor);
    if (pts.isEmpty) return;

    final line = buildSmoothPath(pts);
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fill = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, size.height), // bottom: solid-ish
        Offset(0, 0), // top: transparent
        [
          _kWaveColor.withValues(alpha: _kFillAlpha),
          _kWaveColor.withValues(alpha: 0.0),
        ],
        const [0.0, 0.8],
      );
    canvas.drawPath(area, fill);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kStrokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = _kWaveColor.withValues(alpha: _kStrokeAlpha);
    canvas.drawPath(line, stroke);
  }

  @override
  bool shouldRepaint(WaveformPainter old) {
    // SliceBar rebuilds every frame during the selection glow and hands a
    // freshly-allocated sub-range list each time, so identity always differs.
    // Compare by content (cheap for a per-slice array) so we only repaint the
    // spline when the samples actually change.
    if (identical(old.samples, samples)) return false;
    if (old.samples.length != samples.length) return true;
    for (var i = 0; i < samples.length; i++) {
      if (old.samples[i] != samples[i]) return true;
    }
    return false;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/waveform_painter_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/waveform_painter.dart packages/screen_recorder/test/ui/widgets/timeline/waveform_painter_test.dart
git commit -m "feat(waveform): WaveformPainter (smooth bottom-anchored area)"
```

---

## Task 6: `SliceBar` waveform layer

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/slice_bar.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/slice_bar_waveform_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/timeline/slice_bar_waveform_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart';
import 'package:screen_recorder/ui/widgets/timeline/waveform_painter.dart';

WaveformPeaks _peaks() => WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: List<double>.generate(1000, (i) => (i % 50) / 50.0), // 10s
      sourceDuration: const Duration(seconds: 10),
    );

Widget _host(SliceBar bar) => MaterialApp(
      home: Scaffold(
        body: Stack(children: [bar]),
      ),
    );

WaveformPainter _painterOf(WidgetTester tester) {
  final cp = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).firstWhere(
        (w) => w.painter is WaveformPainter,
        orElse: () => throw StateError('no WaveformPainter found'),
      );
  return cp.painter as WaveformPainter;
}

void main() {
  final slice = ClipSlice(
    cutStart: Duration.zero,
    cutEnd: const Duration(seconds: 6),
  );

  SliceBar build({
    WaveformPeaks? waveform,
    bool hasMic = true,
    bool hasSystem = false,
    bool micMuted = false,
  }) =>
      SliceBar(
        slice: slice.copyWith(micMuted: micMuted),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50, // 6s * 50 = 300px wide
        editedStart: Duration.zero,
        waveform: waveform,
        hasMic: hasMic,
        hasSystem: hasSystem,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      );

  testWidgets('no waveform painter when peaks are absent', (tester) async {
    await tester.pumpWidget(_host(build(waveform: null)));
    final hasWavePainter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .any((w) => w.painter is WaveformPainter);
    // The layer may exist with empty samples, but it must paint nothing.
    if (hasWavePainter) {
      expect(_painterOf(tester).samples, isEmpty);
    }
  });

  testWidgets('renders a non-empty WaveformPainter when peaks exist',
      (tester) async {
    await tester.pumpWidget(_host(build(waveform: _peaks())));
    await tester.pump(const Duration(milliseconds: 250)); // fade-in
    expect(_painterOf(tester).samples, isNotEmpty);
  });

  testWidgets('muted slice dims the waveform layer to a low opacity',
      (tester) async {
    await tester
        .pumpWidget(_host(build(waveform: _peaks(), micMuted: true)));
    await tester.pump(const Duration(milliseconds: 250));
    final opacity = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .map((w) => w.opacity)
        .where((o) => o < 0.5)
        .toList();
    expect(opacity, isNotEmpty); // the waveform layer is dimmed
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/slice_bar_waveform_test.dart`
Expected: FAIL — `SliceBar` has no `waveform`/`hasMic`/`hasSystem` params (compile error).

- [ ] **Step 3a: Add imports to `slice_bar.dart`**

At the top of `packages/screen_recorder/lib/ui/widgets/timeline/slice_bar.dart`, after the existing `clip_slice.dart` import (line 6), add:

```dart
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:screen_recorder/ui/widgets/timeline/waveform_painter.dart';
```

- [ ] **Step 3b: Add constructor params**

In the `SliceBar` constructor (around lines 28-40), add after `this.animateLayout = true,`:

```dart
    this.waveform,
    this.hasMic = false,
    this.hasSystem = false,
```

And add the fields after `final bool animateLayout;` (line 58):

```dart
  /// Shared waveform for the whole recording; this slice samples its own
  /// source range out of it. Null when the recording has no audio (or the
  /// extraction hasn't finished yet) — then no waveform is drawn.
  final WaveformPeaks? waveform;

  /// Whether the recording has a mic / system audio stream. Drives the dim
  /// rule together with this slice's mute flags and speed.
  final bool hasMic;
  final bool hasSystem;
```

- [ ] **Step 3c: Add derived getters + constant**

In `_SliceBarState`, add near the other style constants (e.g. after `_kCaptionMinBodyPx`, line 205):

```dart
  // Waveform suppresses below this body width — sub-16px bars just shimmer.
  static const double _kWaveformMinBodyPx = 16.0;

  /// This slice's slice of the shared recording waveform, mapped to its
  /// SOURCE trim range. Empty when there's no waveform.
  List<double> get _waveformSamples =>
      widget.waveform?.slice(widget.slice.trimStart, widget.slice.trimEnd) ??
      const [];

  /// True when this slice's mixed audio is effectively silent — every present
  /// stream is muted, or it's speed-silenced. Drives the dim treatment.
  bool get _audioSilent {
    if (widget.slice.audioSilencedBySpeed) return true;
    final micSilent = !widget.hasMic || widget.slice.micMuted;
    final sysSilent = !widget.hasSystem || widget.slice.systemMuted;
    return micSilent && sysSilent;
  }
```

- [ ] **Step 3d: Add the waveform builder**

Add this method to `_SliceBarState` (e.g. right after `_buildBody`, around line 614):

```dart
  /// Bottom-anchored waveform painted inside the body, behind the label.
  /// Always present (so the AnimatedOpacity can fade it in when extraction
  /// finishes); the painter no-ops on empty samples. Dims to a low opacity
  /// when the slice's audio is silent.
  Widget _buildWaveform() {
    final samples = _waveformSamples;
    final bodyWidth = math.max(0.0, _widthPx - _kInterSliceGap);
    final show = samples.length >= 2 && bodyWidth >= _kWaveformMinBodyPx;
    final opacity = !show ? 0.0 : (_audioSilent ? 0.12 : 1.0);
    return Positioned(
      key: const ValueKey('slice-bar-waveform'),
      left: 0,
      top: 0,
      width: bodyWidth,
      height: laneHeight,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          opacity: opacity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CustomPaint(
              size: Size(bodyWidth, laneHeight.toDouble()),
              painter: WaveformPainter(samples: samples),
            ),
          ),
        ),
      ),
    );
  }
```

- [ ] **Step 3e: Insert the layer into the Stack**

In `build()`, immediately after `_buildBody(isSel: isSel),` (line 534), add:

```dart
                    _buildWaveform(),
```

This places the waveform above the body fill and below the ticks/label.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/slice_bar_waveform_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the existing SliceBar/ClipLane tests for regressions**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/`
Expected: PASS (the new param is optional with defaults; existing tests construct `SliceBar`/`ClipLane` unchanged).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/slice_bar.dart packages/screen_recorder/test/ui/widgets/timeline/slice_bar_waveform_test.dart
git commit -m "feat(waveform): render waveform layer inside SliceBar with dim rule"
```

---

## Task 7: Thread `waveform`/`hasMic`/`hasSystem` through ClipLane → EditorTimeline → PlaybackScreen

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/ui/widgets/timeline/clip_lane_multi_slice_test.dart` (add one assertion)

- [ ] **Step 1: ClipLane — add params and pass to SliceBar**

In `clip_lane.dart`, add the import after the `slice_bar.dart` import (line 3):

```dart
import 'package:slipreel_engine/audio/waveform_peaks.dart';
```

Add constructor params (after `this.animateLayout = true,`, line 24):

```dart
    this.waveform,
    this.hasMic = false,
    this.hasSystem = false,
```

Add fields (after `final bool animateLayout;`, line 45):

```dart
  final WaveformPeaks? waveform;
  final bool hasMic;
  final bool hasSystem;
```

In `_buildSlice`, pass them to `SliceBar(...)` (after `animateLayout: widget.animateLayout,`, line 154):

```dart
          waveform: widget.waveform,
          hasMic: widget.hasMic,
          hasSystem: widget.hasSystem,
```

- [ ] **Step 2: EditorTimeline — add params and pass to ClipLane**

In `editor_timeline.dart`, add the import alongside the other slipreel_engine imports near the top:

```dart
import 'package:slipreel_engine/audio/waveform_peaks.dart';
```

Add constructor params (after `this.showCameraLane = false,`, line 160):

```dart
    this.waveform,
    this.hasMic = false,
    this.hasSystem = false,
```

Add fields next to the other `final` declarations (e.g. after the `clips` field doc near line 187):

```dart
  /// Shared recording waveform handed down to each [SliceBar]. Null = no
  /// audio / not yet extracted.
  final WaveformPeaks? waveform;
  final bool hasMic;
  final bool hasSystem;
```

In the `ClipLane(...)` call (around line 1691), add after `animateLayout: animateTimelineLayout,`:

```dart
                                          waveform: widget.waveform,
                                          hasMic: widget.hasMic,
                                          hasSystem: widget.hasSystem,
```

- [ ] **Step 3: PlaybackScreen — read providers at the EditorTimeline call site**

In `playback_screen.dart`, ensure these imports exist near the top (add any that are missing):

```dart
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:screen_recorder/state/waveform_provider.dart';
```

At the `EditorTimeline(` call (line 2649), add these three arguments to the constructor (e.g. right after `duration: editedDuration,`):

```dart
                waveform:
                    ref.watch(waveformProvider(widget.videoPath)).valueOrNull,
                hasMic: inferAudioRoles(
                  ref.watch(recordingAudioStreamsProvider),
                ).containsKey(AudioRole.microphone),
                hasSystem: inferAudioRoles(
                  ref.watch(recordingAudioStreamsProvider),
                ).containsKey(AudioRole.system),
```

> `ref` is available here — this build closure already calls `ref.watch(editorProjectControllerProvider)` (line 2654). `widget.videoPath` is the recording path. The waveform extraction kicks off lazily on first `watch` and the slice fades in when it resolves.

- [ ] **Step 4: Add a wiring assertion to the existing ClipLane test**

Open `packages/screen_recorder/test/ui/widgets/timeline/clip_lane_multi_slice_test.dart` and add this test inside `main()` (import `package:slipreel_engine/audio/waveform_peaks.dart` and `package:screen_recorder/ui/widgets/timeline/waveform_painter.dart` at the top):

```dart
  testWidgets('forwards waveform to slices', (tester) async {
    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: List<double>.generate(600, (i) => (i % 30) / 30.0),
      sourceDuration: const Duration(seconds: 6),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ClipLane(
                clips: [
                  ClipSlice(
                    cutStart: Duration.zero,
                    cutEnd: const Duration(seconds: 6),
                  ),
                ],
                selectedSliceIndex: null,
                pixelsPerSecond: 50,
                waveform: peaks,
                hasMic: true,
                onSliceSelected: (_) {},
                onSliceTrimStartChanged: (_, __) {},
                onSliceTrimEndChanged: (_, __) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    final hasWave = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .any((w) => w.painter is WaveformPainter &&
            (w.painter as WaveformPainter).samples.isNotEmpty);
    expect(hasWave, isTrue);
  });
```

> If `ClipLane`'s existing test file already imports `ClipSlice`, reuse that import. Match the existing test file's import style.

- [ ] **Step 5: Run the timeline tests**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/`
Expected: PASS (new wiring test + all existing timeline tests).

- [ ] **Step 6: Analyze the whole package for type/threading errors**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/playback_screen.dart lib/ui/widgets/timeline/editor_timeline.dart lib/ui/widgets/timeline/clip_lane.dart`
Expected: No errors (warnings/infos pre-existing in the file are acceptable).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/clip_lane.dart packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart packages/screen_recorder/lib/ui/screens/playback_screen.dart packages/screen_recorder/test/ui/widgets/timeline/clip_lane_multi_slice_test.dart
git commit -m "feat(waveform): thread recording waveform into the clip lane"
```

---

## Task 8: Full-suite check + manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run both package test suites**

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS.

Run: `cd packages/screen_recorder && flutter test`
Expected: PASS.

- [ ] **Step 2: Manual verification (record evidence in the PR/notes)**

Launch the app (use the project's run skill / normal launch flow), then:

1. Open a recording that has **mic + system audio**. Confirm a subtle bright-edge area waveform fades in under each slice's label within ~1s, and that louder moments show taller peaks.
2. **Trim** a slice inward — the visible waveform should match the remaining (trimmed) audio, not slide.
3. **Speed up** a slice to 2× — the waveform compresses into the narrower slice. At **>4×** it dims (speed-silenced).
4. **Mute** the slice's audio (all present streams) in the slice editor — the waveform dims to near-invisible; unmuting restores it.
5. Open a recording with **no audio** — no waveform appears, slices render exactly as before.
6. Confirm a `<recording>.waveform.json` sidecar is written next to the recording, and reopening the project shows the waveform instantly (no re-extraction delay).

- [ ] **Step 3: Commit any verification notes / fixes** (if changes were needed)

```bash
git add -A
git commit -m "chore(waveform): manual verification fixes"
```

---

## Notes for the implementer

- **DRY:** `reducePcmToPeaks`, `buildWaveformPcmArgs`, `waveformPoints`, and `buildSmoothPath` are deliberately pure top-level functions so they're tested without ffmpeg or a widget tree.
- **YAGNI:** No gain-reactive height, no per-stream curves, no record-stop pre-generation — all explicitly out of scope (see the spec's "Future work").
- **Performance:** `WaveformPainter.shouldRepaint` compares `samples` by content, so even though `SliceBar` reallocates the sub-range list on every glow-frame rebuild, the spline only repaints when the samples actually change.
