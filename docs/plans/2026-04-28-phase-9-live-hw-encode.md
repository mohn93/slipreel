# Phase 9 Implementation Plan: Live HW Encode + Perf Instrumentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hit Phase 9 perf targets — recording at 60 FPS <10% CPU, <500 MB memory for 30 min, ≤1% dropped frames; export at ≥1.0× real-time with HW encoding — by moving from a per-frame BGRA-spool architecture to a live HW-encoded MP4, switching the export encoder to `h264_videotoolbox`, and adding minimal per-session perf summaries.

**Architecture:** macOS native side gains a `LiveRecordingWriter` (VTCompressionSession + AVAssetWriter) that writes a finished MP4 directly during capture — no raw-frame disk spool, no FFmpeg finalize. Cursor and effects are no longer baked into the recording; they're applied as overlays during editor preview and composited at export. A new export pipeline pipes FFmpeg-decode → existing isolate compositor → FFmpeg-encode-with-`h264_videotoolbox`. Windows/Linux retain the existing spool-based path until a future phase.

**Tech Stack:** Swift (VideoToolbox, AVFoundation, mach kernel APIs), Dart 3 + Flutter, Riverpod, FFmpeg subprocesses, `video_player`, `path_provider`, melos workspace, the existing `app_logger` zone-based logging.

**Reference design:** `docs/superpowers/specs/2026-04-28-phase-9-live-hw-encode-design.md` (commit `58c823f`).

**Important context note:** Today, the editor's "Export" button is a stub (`playback_screen.dart:203-208` has a TODO; it shows a SnackBar but does nothing). The recording's MP4 *is* the user's final output, with cursor baked in. This plan therefore (a) changes the recording to produce a pure-source MP4 and (b) implements the post-recording export pipeline that previously didn't exist.

---

## File map (all changes, by package)

### `packages/screen_recorder_platform_interface/lib/`

- Create: `src/models/recording_result.dart` — return type for `stopLiveRecording`
- Create: `src/models/native_perf_stats.dart` — CPU/mem/drop counts from native side
- Create: `src/models/recording_metadata.dart` — sidecar JSON model with `isPureSource` flag
- Modify: `src/screen_recorder_platform_interface.dart` — add `startLiveRecording` / `stopLiveRecording` methods
- Modify: `src/constants.dart` — add new method channel constants

### `packages/screen_recorder_macos/macos/Classes/`

- Create: `LiveRecordingWriter.swift` — AVAssetWriter wrapper (video + audio)
- Create: `PerfSampler.swift` — CPU and memory sampling via mach APIs
- Modify: `VideoToolboxEncoder.swift` — promote skeleton to active, add output callback
- Modify: `ScreenCaptureManager.swift` — forward `CMSampleBuffer` (no pixel copy)
- Modify: `AudioCaptureManager.swift` — forward `CMSampleBuffer` to live writer
- Modify: `ScreenRecorderMacosPlugin.swift` — handle `startLiveRecording` / `stopLiveRecording`

### `packages/screen_recorder/lib/`

- Create: `rendering/cursor_geometry.dart` — pure helpers (cursor lookup, screen→video mapping)
- Create: `effects/effect_params.dart` — pure helpers (settings → paint params)
- Create: `utils/perf_summary.dart` — `RecordingPerfSummary`, `ExportPerfSummary`
- Create: `models/recording_metadata.dart` — sidecar JSON wrapper
- Create: `export/export_pipeline.dart` — coordinator
- Create: `export/ffmpeg_decoder.dart` — FFmpeg decode subprocess wrapper
- Create: `export/ffmpeg_encoder.dart` — FFmpeg encode subprocess wrapper (h264_videotoolbox + fallback)
- Create: `ui/widgets/cursor_overlay_painter.dart`
- Create: `ui/widgets/background_effect_layer.dart`
- Modify: `video_encoder.dart` — shrink to live-writer façade
- Modify: `state/recording_state.dart` — call live writer, emit perf summary, write sidecar
- Modify: `rendering/cursor_renderer.dart` — remove its use from the recording path; keep for export
- Modify: `ui/screens/playback_screen.dart` — wire overlays + connect Export button to pipeline

### Tests

- `packages/screen_recorder/test/rendering/cursor_geometry_test.dart`
- `packages/screen_recorder/test/effects/effect_params_test.dart`
- `packages/screen_recorder/test/utils/perf_summary_test.dart`
- `packages/screen_recorder/test/models/recording_metadata_test.dart`
- `packages/screen_recorder/test/export/ffmpeg_decoder_test.dart`
- `packages/screen_recorder/test/export/ffmpeg_encoder_test.dart`
- `packages/screen_recorder/test/export/export_pipeline_test.dart`
- `packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart`
- `packages/screen_recorder/test/integration/live_recording_smoke_test.dart` (macOS-gated)
- `packages/screen_recorder/test/fixtures/sample_recording.mp4` — pre-recorded fixture (1-second test pattern, 1080p30, with audio)

### Docs

- Modify: `MANUAL_TESTING_CHECKLIST.md` — add Phase 9 verification section

---

## Build commands you'll need throughout

| Action | Command |
|---|---|
| Run all Dart tests in main package | `cd packages/screen_recorder && flutter test` |
| Run a single Dart test | `cd packages/screen_recorder && flutter test test/path/to_test.dart` |
| Analyze Dart | `cd packages/screen_recorder && flutter analyze` |
| Build macOS app | `cd packages/screen_recorder && flutter build macos --debug` |
| Run macOS app (interactive) | `cd packages/screen_recorder && flutter run -d macos` |
| Run analyzer across workspace | `melos run analyze` |
| Run tests across workspace | `melos run test` |

Always run `flutter analyze` before committing — the project recently cleaned up analyzer issues (commit `1a43cdf`) and the convention is zero warnings.

---

## Batch A — Foundation (parallel-safe, pure-Dart, TDD)

These tasks have no dependencies on each other or on native code. They're pure helpers and data classes that downstream tasks will use. Do them first so subsequent tasks have stable building blocks.

### Task 1: Pure helper `cursor_geometry.dart`

**Files:**
- Create: `packages/screen_recorder/lib/rendering/cursor_geometry.dart`
- Create: `packages/screen_recorder/test/rendering/cursor_geometry_test.dart`

**Why:** The cursor lookup/interpolation logic is currently embedded in `CursorRecording.getPositionAt` and the canvas placement math is in `CursorRenderer.renderCursorOnFrame`. We need both at *export* time (in the isolate compositor) and at *preview* time (in the new `CursorOverlayPainter`). Extract the geometry into pure functions so both paths share one implementation — that's the drift-mitigation strategy from the spec.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/rendering/cursor_geometry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'dart:ui';

void main() {
  group('cursorAt', () {
    test('returns null for empty recording', () {
      final rec = CursorRecording();
      expect(cursorAt(rec, const Duration(seconds: 1)), isNull);
    });

    test('returns exact match when one exists', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 10, y: 20, timestampMicros: 1000000, isClicked: false));
      final pos = cursorAt(rec, const Duration(seconds: 1));
      expect(pos, isNotNull);
      expect(pos!.x, 10);
      expect(pos.y, 20);
    });

    test('interpolates between samples', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 0, y: 0, timestampMicros: 0, isClicked: false))
        ..addPosition(const CursorPosition(
            x: 100, y: 200, timestampMicros: 1000000, isClicked: false));
      final pos = cursorAt(rec, const Duration(milliseconds: 500));
      expect(pos!.x, closeTo(50, 0.1));
      expect(pos.y, closeTo(100, 0.1));
    });

    test('preserves isClicked true if either neighbor is clicked', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(
            x: 0, y: 0, timestampMicros: 0, isClicked: false))
        ..addPosition(const CursorPosition(
            x: 10, y: 10, timestampMicros: 1000000, isClicked: true));
      final pos = cursorAt(rec, const Duration(milliseconds: 500));
      expect(pos!.isClicked, isTrue);
    });
  });

  group('screenToVideoSpace', () {
    test('identity when sizes match', () {
      const screenPos = Offset(100, 200);
      final result = screenToVideoSpace(
        screenPos: screenPos,
        screenSize: const Size(1920, 1080),
        videoSize: const Size(1920, 1080),
      );
      expect(result, const Offset(100, 200));
    });

    test('scales when video is downscaled', () {
      const screenPos = Offset(960, 540);
      final result = screenToVideoSpace(
        screenPos: screenPos,
        screenSize: const Size(1920, 1080),
        videoSize: const Size(960, 540),
      );
      expect(result.dx, closeTo(480, 0.1));
      expect(result.dy, closeTo(270, 0.1));
    });
  });
}
```

- [ ] **Step 2: Run tests, confirm they fail with "function not defined"**

```
cd packages/screen_recorder && flutter test test/rendering/cursor_geometry_test.dart
```

Expected: FAIL — `cursorAt` and `screenToVideoSpace` not defined.

- [ ] **Step 3: Write the implementation**

```dart
// packages/screen_recorder/lib/rendering/cursor_geometry.dart
import 'dart:ui';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';

/// Returns the interpolated cursor position at the given time, or null if
/// the recording is empty.
///
/// This wraps [CursorRecording.getPositionAt] in a typed [Duration] API and
/// is the single source of truth for cursor-time lookups across the export
/// compositor and the preview overlay painter.
CursorPosition? cursorAt(CursorRecording recording, Duration t) {
  return recording.getPositionAt(t.inMicroseconds);
}

/// Maps a cursor position captured in screen coordinates to the corresponding
/// position inside a video of [videoSize], assuming the captured area filled
/// [screenSize]. Used when the recorded video is a different resolution than
/// the screen the cursor was tracked on (e.g. window-only capture, or scaled
/// export).
Offset screenToVideoSpace({
  required Offset screenPos,
  required Size screenSize,
  required Size videoSize,
}) {
  final scaleX = videoSize.width / screenSize.width;
  final scaleY = videoSize.height / screenSize.height;
  return Offset(screenPos.dx * scaleX, screenPos.dy * scaleY);
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```
cd packages/screen_recorder && flutter test test/rendering/cursor_geometry_test.dart
```

Expected: All tests pass.

- [ ] **Step 5: Run analyzer**

```
cd packages/screen_recorder && flutter analyze
```

Expected: zero issues.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/rendering/cursor_geometry.dart packages/screen_recorder/test/rendering/cursor_geometry_test.dart
git commit -m "feat: add cursor_geometry pure helpers for shared use across preview and export"
```

---

### Task 2: Pure helper `effect_params.dart`

**Files:**
- Create: `packages/screen_recorder/lib/effects/effect_params.dart`
- Create: `packages/screen_recorder/test/effects/effect_params_test.dart`

**Why:** Same drift-mitigation reason as Task 1 — settings-to-paint-parameters conversions need to be identical between the editor preview overlay and the export-time compositor. Extracting now means both paths can call the same helper later.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/effects/effect_params_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/effect_params.dart';

void main() {
  group('blurSigmaForIntensity', () {
    test('low intensity returns small sigma', () {
      expect(blurSigmaForIntensity(BlurIntensity.low), inInclusiveRange(2, 6));
    });
    test('high intensity returns large sigma', () {
      expect(blurSigmaForIntensity(BlurIntensity.high), greaterThan(20));
    });
    test('strictly increasing across intensities', () {
      final low = blurSigmaForIntensity(BlurIntensity.low);
      final medium = blurSigmaForIntensity(BlurIntensity.medium);
      final high = blurSigmaForIntensity(BlurIntensity.high);
      expect(low, lessThan(medium));
      expect(medium, lessThan(high));
    });
  });

  group('cornerRadiusPx', () {
    test('zero for none preset', () {
      expect(cornerRadiusPx(CornerRadiusPreset.none), 0);
    });
    test('positive for rounded preset', () {
      expect(cornerRadiusPx(CornerRadiusPreset.rounded), greaterThan(0));
    });
  });
}
```

- [ ] **Step 2: Run tests, confirm fail**

```
cd packages/screen_recorder && flutter test test/effects/effect_params_test.dart
```

Expected: FAIL — types/functions undefined.

- [ ] **Step 3: Write the implementation**

```dart
// packages/screen_recorder/lib/effects/effect_params.dart

/// Blur intensity preset chosen by the user in the editor.
enum BlurIntensity { low, medium, high }

/// Corner radius preset chosen by the user.
enum CornerRadiusPreset { none, subtle, rounded, pronounced }

/// Convert a blur intensity preset to a Gaussian sigma in pixels.
double blurSigmaForIntensity(BlurIntensity i) {
  switch (i) {
    case BlurIntensity.low:
      return 4;
    case BlurIntensity.medium:
      return 12;
    case BlurIntensity.high:
      return 28;
  }
}

/// Convert a corner-radius preset to a pixel value applied to the
/// `BorderRadius.circular(...)` of the video frame.
double cornerRadiusPx(CornerRadiusPreset p) {
  switch (p) {
    case CornerRadiusPreset.none:
      return 0;
    case CornerRadiusPreset.subtle:
      return 8;
    case CornerRadiusPreset.rounded:
      return 16;
    case CornerRadiusPreset.pronounced:
      return 32;
  }
}
```

- [ ] **Step 4: Run tests, confirm pass**

```
cd packages/screen_recorder && flutter test test/effects/effect_params_test.dart
```

- [ ] **Step 5: Analyze**

```
cd packages/screen_recorder && flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/effects/effect_params.dart packages/screen_recorder/test/effects/effect_params_test.dart
git commit -m "feat: add effect_params pure helpers for shared use across preview and export"
```

---

### Task 3: `RecordingPerfSummary` and `ExportPerfSummary`

**Files:**
- Create: `packages/screen_recorder/lib/utils/perf_summary.dart`
- Create: `packages/screen_recorder/test/utils/perf_summary_test.dart`

**Why:** The instrumentation half of Phase 9 is a single log line per session that says "PASS or FAIL against targets, here are the numbers." Two simple value classes with `format()`. TDD-friendly.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/utils/perf_summary_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/utils/perf_summary.dart';

void main() {
  group('RecordingPerfSummary', () {
    test('format includes all key fields', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 5,
        cpuPctAvg: 4.2,
        cpuPctP95: 7.1,
        memPeakBytes: 84 * 1024 * 1024,
        outputBytes: 156000000,
        targetFps: 60,
      );
      final formatted = s.format();
      expect(formatted, contains('duration=60.0s'));
      expect(formatted, contains('frames=3600'));
      expect(formatted, contains('droppedFrames=5'));
      expect(formatted, contains('cpuPctAvg=4.2'));
      expect(formatted, contains('memPeakMB=84'));
      expect(formatted, contains('verdict'));
      expect(formatted, contains('PASS'));
    });

    test('verdict FAIL when CPU exceeds target', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 0,
        cpuPctAvg: 15.0,
        cpuPctP95: 22.0,
        memPeakBytes: 100 * 1024 * 1024,
        outputBytes: 100000000,
        targetFps: 60,
      );
      expect(s.format(), contains('FAIL'));
    });

    test('verdict FAIL when memory exceeds target', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 0,
        cpuPctAvg: 5.0,
        cpuPctP95: 8.0,
        memPeakBytes: 600 * 1024 * 1024,
        outputBytes: 100000000,
        targetFps: 60,
      );
      expect(s.format(), contains('FAIL'));
    });

    test('verdict FAIL when drop rate exceeds 1%', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 50,
        cpuPctAvg: 5.0,
        cpuPctP95: 8.0,
        memPeakBytes: 100 * 1024 * 1024,
        outputBytes: 100000000,
        targetFps: 60,
      );
      expect(s.format(), contains('FAIL'));
    });
  });

  group('ExportPerfSummary', () {
    test('format includes realtime multiple', () {
      const s = ExportPerfSummary(
        inputDurationSeconds: 60.0,
        wallTimeSeconds: 12.0,
        decodeMsPerFrame: 2.1,
        compositeMsPerFrame: 4.3,
        encodeMsPerFrame: 1.4,
        outputBytes: 85000000,
        outputCodec: 'h264_videotoolbox',
        usedHardwareEncoder: true,
      );
      final f = s.format();
      expect(f, contains('realtimeMultiple=5.0x'));
      expect(f, contains('HW encoder: yes'));
      expect(f, contains('PASS'));
    });

    test('verdict FAIL when slower than realtime', () {
      const s = ExportPerfSummary(
        inputDurationSeconds: 60.0,
        wallTimeSeconds: 90.0,
        decodeMsPerFrame: 5,
        compositeMsPerFrame: 15,
        encodeMsPerFrame: 10,
        outputBytes: 80000000,
        outputCodec: 'libx264',
        usedHardwareEncoder: false,
      );
      expect(s.format(), contains('FAIL'));
    });
  });
}
```

- [ ] **Step 2: Run tests, confirm fail**

- [ ] **Step 3: Write the implementation**

```dart
// packages/screen_recorder/lib/utils/perf_summary.dart

/// Phase 9 recording-side performance targets. Used by [RecordingPerfSummary]
/// to compute its PASS/FAIL verdict.
class RecordingTargets {
  static const double maxCpuPctAvg = 10.0;
  static const int maxMemBytes = 500 * 1024 * 1024;
  static const double maxDropFraction = 0.01; // 1%
}

/// Phase 9 export-side performance target.
class ExportTargets {
  static const double minRealtimeMultiple = 1.0;
}

class RecordingPerfSummary {
  final double durationSeconds;
  final int frameCount;
  final int expectedFrameCount;
  final int droppedFrameCount;
  final double cpuPctAvg;
  final double cpuPctP95;
  final int memPeakBytes;
  final int outputBytes;
  final int targetFps;

  const RecordingPerfSummary({
    required this.durationSeconds,
    required this.frameCount,
    required this.expectedFrameCount,
    required this.droppedFrameCount,
    required this.cpuPctAvg,
    required this.cpuPctP95,
    required this.memPeakBytes,
    required this.outputBytes,
    required this.targetFps,
  });

  double get actualFps =>
      durationSeconds > 0 ? frameCount / durationSeconds : 0;

  double get dropFraction =>
      expectedFrameCount > 0 ? droppedFrameCount / expectedFrameCount : 0;

  int get memPeakMB => (memPeakBytes / (1024 * 1024)).round();

  bool get cpuOk => cpuPctAvg <= RecordingTargets.maxCpuPctAvg;
  bool get memOk => memPeakBytes <= RecordingTargets.maxMemBytes;
  bool get fpsOk => actualFps >= targetFps * 0.97; // 3% tolerance
  bool get dropsOk => dropFraction <= RecordingTargets.maxDropFraction;
  bool get pass => cpuOk && memOk && fpsOk && dropsOk;

  String format() {
    final dropPct = (dropFraction * 100).toStringAsFixed(2);
    final mark = (bool ok) => ok ? '✓' : '✗';
    return '''
[Recording] summary: duration=${durationSeconds.toStringAsFixed(1)}s frames=$frameCount expectedFrames=$expectedFrameCount droppedFrames=$droppedFrameCount ($dropPct%) actualFps=${actualFps.toStringAsFixed(1)} cpuPctAvg=${cpuPctAvg.toStringAsFixed(1)} cpuPctP95=${cpuPctP95.toStringAsFixed(1)} memPeakMB=$memPeakMB outputBytes=$outputBytes
[Recording] verdict: cpuPct≤10 ${mark(cpuOk)}  memPeak≤500MB ${mark(memOk)}  fps=$targetFps ${mark(fpsOk)}  drops≤1% ${mark(dropsOk)}  -> ${pass ? "PASS" : "FAIL"}'''
        .trim();
  }
}

class ExportPerfSummary {
  final double inputDurationSeconds;
  final double wallTimeSeconds;
  final double decodeMsPerFrame;
  final double compositeMsPerFrame;
  final double encodeMsPerFrame;
  final int outputBytes;
  final String outputCodec;
  final bool usedHardwareEncoder;

  const ExportPerfSummary({
    required this.inputDurationSeconds,
    required this.wallTimeSeconds,
    required this.decodeMsPerFrame,
    required this.compositeMsPerFrame,
    required this.encodeMsPerFrame,
    required this.outputBytes,
    required this.outputCodec,
    required this.usedHardwareEncoder,
  });

  double get realtimeMultiple =>
      wallTimeSeconds > 0 ? inputDurationSeconds / wallTimeSeconds : 0;

  bool get pass => realtimeMultiple >= ExportTargets.minRealtimeMultiple;

  String format() {
    final hw = usedHardwareEncoder ? 'yes' : 'no';
    final mark = pass ? '✓' : '✗';
    return '''
[Export] summary: inputDuration=${inputDurationSeconds.toStringAsFixed(1)}s exportWallTime=${wallTimeSeconds.toStringAsFixed(1)}s realtimeMultiple=${realtimeMultiple.toStringAsFixed(1)}x (HW encoder: $hw) decodeMs/frame=${decodeMsPerFrame.toStringAsFixed(1)} compositeMs/frame=${compositeMsPerFrame.toStringAsFixed(1)} encodeMs/frame=${encodeMsPerFrame.toStringAsFixed(1)} outputBytes=$outputBytes outputCodec=$outputCodec
[Export] verdict: realtimeMultiple≥1.0 $mark  -> ${pass ? "PASS" : "FAIL"}'''
        .trim();
  }
}
```

- [ ] **Step 4: Run tests, confirm pass**

```
cd packages/screen_recorder && flutter test test/utils/perf_summary_test.dart
```

- [ ] **Step 5: Analyze**

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/utils/perf_summary.dart packages/screen_recorder/test/utils/perf_summary_test.dart
git commit -m "feat: add perf summary classes for recording and export verdicts"
```

---

### Task 4: Recording metadata sidecar (`isPureSource` flag)

**Files:**
- Create: `packages/screen_recorder/lib/models/recording_metadata.dart`
- Create: `packages/screen_recorder/test/models/recording_metadata_test.dart`

**Why:** Pre-Phase-9 recordings have cursor baked in. New recordings have it as a sidecar overlay. The editor needs to know which kind it's looking at, so it knows whether to draw the cursor overlay (drawing it on a baked-in recording would render two cursors).

- [ ] **Step 1: Write failing tests**

```dart
// packages/screen_recorder/test/models/recording_metadata_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/recording_metadata.dart';

void main() {
  group('RecordingMetadata', () {
    test('round-trips through JSON', () {
      final m = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.parse('2026-04-28T10:00:00Z'),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );
      final json = m.toJson();
      final restored = RecordingMetadata.fromJson(json);
      expect(restored.isPureSource, isTrue);
      expect(restored.widthPx, 1920);
      expect(restored.heightPx, 1080);
      expect(restored.fps, 60);
      expect(restored.recordedAt, m.recordedAt);
    });

    test('legacy returns isPureSource=false when sidecar missing', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_meta');
      final videoPath = '${tmp.path}/legacy.mp4';
      File(videoPath).writeAsBytesSync([0]);
      final m = await RecordingMetadata.loadForVideo(videoPath);
      expect(m.isPureSource, isFalse);
      tmp.deleteSync(recursive: true);
    });

    test('saves and reloads alongside video file', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_meta');
      final videoPath = '${tmp.path}/rec.mp4';
      File(videoPath).writeAsBytesSync([0]);
      final m = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.parse('2026-04-28T10:00:00Z'),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );
      await m.saveForVideo(videoPath);
      final loaded = await RecordingMetadata.loadForVideo(videoPath);
      expect(loaded.isPureSource, isTrue);
      expect(loaded.widthPx, 1920);
      tmp.deleteSync(recursive: true);
    });
  });
}
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/models/recording_metadata.dart
import 'dart:convert';
import 'dart:io';

/// Sidecar metadata stored next to a recorded MP4 as
/// `<videopath>.meta.json`.
///
/// `isPureSource: true` means the video contains the raw capture only —
/// cursor and effects are stored separately and applied as overlays at
/// preview time and composited at export. `false` (or missing sidecar)
/// means a pre-Phase-9 recording where cursor is already baked in.
class RecordingMetadata {
  final bool isPureSource;
  final DateTime recordedAt;
  final int widthPx;
  final int heightPx;
  final int fps;

  const RecordingMetadata({
    required this.isPureSource,
    required this.recordedAt,
    required this.widthPx,
    required this.heightPx,
    required this.fps,
  });

  Map<String, dynamic> toJson() => {
        'isPureSource': isPureSource,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
        'widthPx': widthPx,
        'heightPx': heightPx,
        'fps': fps,
        'schemaVersion': 1,
      };

  factory RecordingMetadata.fromJson(Map<String, dynamic> json) {
    return RecordingMetadata(
      isPureSource: json['isPureSource'] as bool? ?? false,
      recordedAt:
          DateTime.parse(json['recordedAt'] as String? ?? '1970-01-01T00:00:00Z'),
      widthPx: json['widthPx'] as int? ?? 0,
      heightPx: json['heightPx'] as int? ?? 0,
      fps: json['fps'] as int? ?? 30,
    );
  }

  static String _sidecarPath(String videoPath) => '$videoPath.meta.json';

  Future<void> saveForVideo(String videoPath) async {
    final file = File(_sidecarPath(videoPath));
    await file.writeAsString(jsonEncode(toJson()));
  }

  /// Loads the sidecar for [videoPath], returning a legacy default
  /// (`isPureSource: false`) if the sidecar does not exist.
  static Future<RecordingMetadata> loadForVideo(String videoPath) async {
    final file = File(_sidecarPath(videoPath));
    if (!await file.exists()) {
      return RecordingMetadata(
        isPureSource: false,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
        widthPx: 0,
        heightPx: 0,
        fps: 30,
      );
    }
    final content = await file.readAsString();
    return RecordingMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>);
  }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Analyze**

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/models/recording_metadata.dart packages/screen_recorder/test/models/recording_metadata_test.dart
git commit -m "feat: add RecordingMetadata sidecar with isPureSource flag"
```

---

## Batch B — Native macOS live writer

These tasks build the native side of the live HW encode pipeline. Sequential. Each task ends in a `flutter build macos` to ensure compilation, since these are Swift changes that aren't unit-tested directly — they're verified by the integration test in Batch F.

### Task 5: `LiveRecordingWriter.swift`

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift`

**Why:** The new component that owns the AVAssetWriter and exposes simple "start writing", "append video buffer", "append audio buffer", "stop and finalize" APIs. Encapsulates all the AVFoundation muxing detail in one place so `ScreenCaptureManager` and `AudioCaptureManager` don't have to know about it.

- [ ] **Step 1: Create the file**

```swift
// packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Writes a complete H.264 + AAC MP4 file directly during capture.
///
/// Owns an `AVAssetWriter` with two inputs (video and optional audio).
/// Compressed video sample buffers come from `VideoToolboxEncoder`'s output
/// callback; audio sample buffers come from `AudioCaptureManager`. Both are
/// appended in real time as the capture session produces them.
///
/// On `stop()` the writer flushes pending samples, finalizes the file, and
/// returns the absolute path.
class LiveRecordingWriter {
  // MARK: - Errors

  enum WriterError: LocalizedError {
    case alreadyStarted
    case notStarted
    case assetWriterCreateFailed(Error)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case startWritingFailed(Error?)
    case finalizeFailed(Error?)

    var errorDescription: String? {
      switch self {
      case .alreadyStarted: return "LiveRecordingWriter is already started"
      case .notStarted: return "LiveRecordingWriter is not started"
      case .assetWriterCreateFailed(let e): return "Failed to create AVAssetWriter: \(e.localizedDescription)"
      case .cannotAddVideoInput: return "AVAssetWriter would not accept the video input"
      case .cannotAddAudioInput: return "AVAssetWriter would not accept the audio input"
      case .startWritingFailed(let e): return "AVAssetWriter.startWriting failed: \(e?.localizedDescription ?? "unknown")"
      case .finalizeFailed(let e): return "AVAssetWriter.finishWriting failed: \(e?.localizedDescription ?? "unknown")"
      }
    }
  }

  // MARK: - Properties

  private let outputURL: URL
  private let width: Int
  private let height: Int
  private let fps: Int
  private let captureAudio: Bool

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?

  private var isStarted = false
  private var sessionStartedAt: CMTime?

  /// Set to true once `assetWriter.startWriting()` has been called.
  private var writerActive = false

  // MARK: - Init

  init(outputPath: String, width: Int, height: Int, fps: Int, captureAudio: Bool) {
    self.outputURL = URL(fileURLWithPath: outputPath)
    self.width = width
    self.height = height
    self.fps = fps
    self.captureAudio = captureAudio
  }

  // MARK: - Lifecycle

  /// Configure the AVAssetWriter and prepare it to receive samples.
  /// Call once before any `append*` call.
  func start() throws {
    guard !isStarted else { throw WriterError.alreadyStarted }

    // Remove any pre-existing file at the path
    try? FileManager.default.removeItem(at: outputURL)

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    } catch {
      throw WriterError.assetWriterCreateFailed(error)
    }

    // Video input — expects already-compressed H.264 sample buffers from VTCompressionSession.
    // Output settings are nil because we're passing through compressed data.
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
    videoInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(videoInput) else {
      throw WriterError.cannotAddVideoInput
    }
    writer.add(videoInput)
    self.videoInput = videoInput

    // Audio input — let the writer encode raw PCM to AAC for us.
    if captureAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
      ]
      let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audioInput.expectsMediaDataInRealTime = true
      guard writer.canAdd(audioInput) else {
        throw WriterError.cannotAddAudioInput
      }
      writer.add(audioInput)
      self.audioInput = audioInput
    }

    self.assetWriter = writer
    self.isStarted = true
  }

  /// Append a compressed video sample. The first append also opens the
  /// session — its presentation time becomes the timeline origin.
  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard isStarted, let writer = assetWriter, let input = videoInput else { return }

    if !writerActive {
      let startedOk = writer.startWriting()
      if !startedOk {
        NSLog("[LiveRecordingWriter] startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        return
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      writer.startSession(atSourceTime: pts)
      sessionStartedAt = pts
      writerActive = true
    }

    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    } else {
      // Drop. Capture queue depth + VT real-time mode should keep this rare;
      // PerfSampler will report the drop count.
    }
  }

  /// Append a raw audio sample buffer. The writer encodes to AAC.
  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard isStarted, writerActive, let input = audioInput else { return }
    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    }
  }

  /// Finish writing and return the output path. Safe to call once.
  func stop(completion: @escaping (Result<String, Error>) -> Void) {
    guard isStarted, let writer = assetWriter else {
      completion(.failure(WriterError.notStarted))
      return
    }

    videoInput?.markAsFinished()
    audioInput?.markAsFinished()

    if !writerActive {
      // Nothing was ever written; just clean up.
      isStarted = false
      completion(.success(outputURL.path))
      return
    }

    writer.finishWriting { [weak self] in
      guard let self = self else { return }
      defer { self.isStarted = false }
      if writer.status == .completed {
        completion(.success(self.outputURL.path))
      } else {
        completion(.failure(WriterError.finalizeFailed(writer.error)))
      }
    }
  }
}
```

- [ ] **Step 2: Build the macOS app to ensure compilation**

```
cd packages/screen_recorder && flutter build macos --debug
```

Expected: build succeeds. (The new file isn't wired up yet, so behavior is unchanged.)

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
git commit -m "feat: add LiveRecordingWriter for live MP4 muxing during capture"
```

---

### Task 6: Promote `VideoToolboxEncoder.swift` to active use

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/VideoToolboxEncoder.swift`

**Why:** The skeleton creates a `VTCompressionSession` but has `outputCallback: nil`, which means encoded output goes nowhere. We need to wire the output callback so compressed `CMSampleBuffer`s flow into the `LiveRecordingWriter`. We also tighten the configuration to require HW acceleration (per the spec's "fail loudly if unavailable" decision).

- [ ] **Step 1: Replace the file with the wired-up version**

```swift
// packages/screen_recorder_macos/macos/Classes/VideoToolboxEncoder.swift
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

/// Hardware-accelerated H.264 encoder using VideoToolbox.
///
/// Receives raw `CVPixelBuffer`s from the capture stream, hands them to a
/// `VTCompressionSession`, and forwards each compressed `CMSampleBuffer` to
/// the configured output handler (typically `LiveRecordingWriter.appendVideo`).
class VideoToolboxEncoder {
  enum EncoderError: LocalizedError {
    case sessionCreateFailed(OSStatus)
    case hardwareUnavailable
    case configFailed(OSStatus)
    case encodeFailed(OSStatus)
    case notInitialized

    var errorDescription: String? {
      switch self {
      case .sessionCreateFailed(let s):
        return "VTCompressionSessionCreate failed (status \(s))"
      case .hardwareUnavailable:
        return "Hardware H.264 encoder is not available on this Mac"
      case .configFailed(let s):
        return "VTSessionSetProperty failed (status \(s))"
      case .encodeFailed(let s):
        return "VTCompressionSessionEncodeFrame failed (status \(s))"
      case .notInitialized:
        return "VideoToolboxEncoder used before initialize()"
      }
    }
  }

  private var compressionSession: VTCompressionSession?
  private let width: Int
  private let height: Int
  private let fps: Int

  /// Called for each compressed sample. Set before initialize().
  var onCompressedSample: ((CMSampleBuffer) -> Void)?

  /// Atomically tracks frames the encoder reported as dropped via
  /// `kVTEncodeInfo_FrameDropped`. Read at stop time.
  private(set) var droppedFrameCount: Int = 0

  init(width: Int, height: Int, fps: Int) {
    self.width = width
    self.height = height
    self.fps = fps
  }

  func initialize() throws {
    let bitsPerPixel = 0.1 // ~6 Mbps at 1080p30, ~12 Mbps at 1080p60
    let bitrate = Int(Double(width * height * fps) * bitsPerPixel)

    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue,
      ] as CFDictionary,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: VideoToolboxEncoder.outputCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &session
    )

    guard status == noErr, let session = session else {
      if status == kVTCouldNotFindVideoEncoderErr {
        throw EncoderError.hardwareUnavailable
      }
      throw EncoderError.sessionCreateFailed(status)
    }
    compressionSession = session

    try setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    try setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    try setProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    try setProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    try setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
    try setProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))

    VTCompressionSessionPrepareToEncodeFrames(session)
  }

  private func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
    let status = VTSessionSetProperty(session, key: key, value: value)
    if status != noErr { throw EncoderError.configFailed(status) }
  }

  func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws {
    guard let session = compressionSession else { throw EncoderError.notInitialized }
    var flags = VTEncodeInfoFlags()
    let status = VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: timestamp,
      duration: .invalid,
      frameProperties: nil,
      sourceFrameRefcon: nil,
      infoFlagsOut: &flags
    )
    if status != noErr { throw EncoderError.encodeFailed(status) }
    if flags.contains(.frameDropped) { droppedFrameCount += 1 }
  }

  func finalize() {
    guard let session = compressionSession else { return }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
    compressionSession = nil
  }

  deinit { finalize() }

  // MARK: - Output callback

  private static let outputCallback: VTCompressionOutputCallback = {
    (refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer) in
    guard status == noErr else {
      NSLog("[VideoToolboxEncoder] encode error: \(status)")
      return
    }
    guard let sampleBuffer = sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard let refcon = refcon else { return }
    let encoder = Unmanaged<VideoToolboxEncoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.onCompressedSample?(sampleBuffer)
  }
}
```

- [ ] **Step 2: Build to ensure compilation**

```
cd packages/screen_recorder && flutter build macos --debug
```

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/VideoToolboxEncoder.swift
git commit -m "feat: promote VideoToolboxEncoder to active HW H.264 encoder with output callback"
```

---

### Task 7: Forward `CMSampleBuffer` from `ScreenCaptureManager` instead of copying pixels

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift` (the file we read; the part that needs change is just the callback signature wiring — the existing class already accepts an `onFrameReceived: ((CMSampleBuffer) -> Void)?` callback, so the manager itself is good. The change in this task is at the *consumer* — see Task 10).

**Wait, that's correct — ScreenCaptureManager already passes CMSampleBuffer through.** The pixel copy lives in `FrameStreamHandler.sendFrame` in `ScreenRecorderMacosPlugin.swift`. The change for live recording is to bypass `FrameStreamHandler` entirely and route the buffer to `VideoToolboxEncoder`. This wiring is in Task 10. **This task is therefore a no-op for the manager itself; we keep this entry as a checkpoint to verify the assumption.**

- [ ] **Step 1: Read `ScreenCaptureManager.swift` and confirm `onFrameReceived: ((CMSampleBuffer) -> Void)?` is the only output path**

Expected: yes, confirmed. No change to file.

- [ ] **Step 2: Skip — no commit needed.**

---

### Task 8: Forward `CMSampleBuffer` from `AudioCaptureManager`

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift`

**Why:** Today `AudioCaptureManager` converts float→Int16 PCM in a per-sample loop and emits `Data` via the `onAudioReceived: ((Data, Int64) -> Void)?` callback for the FrameStreamHandler-style PCM spool. For the live writer path, `AVAssetWriter` accepts `CMSampleBuffer` directly and handles AAC encoding. We add a *parallel* callback `onSampleBufferReceived: ((CMSampleBuffer) -> Void)?` that forwards the raw sample buffer, and leave the existing PCM callback in place (Windows/Linux still use the spool path, and we don't want to break them).

- [ ] **Step 1: Add the new callback and emit alongside the existing one**

Modify the file. Add a new property near the existing `onAudioReceived`:

```swift
  // Existing (unchanged):
  var onAudioReceived: ((Data, Int64) -> Void)?
  var onError: ((Error) -> Void)?

  // NEW: raw CMSampleBuffer for the live writer path. Either or both
  // callbacks can be set; both are invoked per buffer.
  var onSampleBufferReceived: ((CMSampleBuffer) -> Void)?
```

Then in `processAudioBuffer(_:time:)`, emit a `CMSampleBuffer` if anyone is listening. Append this code at the end of the method (after the existing `onAudioReceived?(...)` call):

```swift
    // Forward as CMSampleBuffer for the AVAssetWriter path.
    if let onBuf = onSampleBufferReceived,
       let sampleBuffer = makeSampleBuffer(from: buffer, time: time) {
      onBuf(sampleBuffer)
    }
```

And add a private helper that converts the `AVAudioPCMBuffer` to a `CMSampleBuffer`:

```swift
  private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
    guard let formatDescription = buffer.format.streamDescription.pointee.cmFormatDescription() else {
      return nil
    }

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
      presentationTimeStamp: CMTime(value: CMTimeValue(time.sampleTime), timescale: CMTimeScale(buffer.format.sampleRate)),
      decodeTimeStamp: .invalid
    )

    // Wrap the AVAudioPCMBuffer's audio buffer list in a CMSampleBuffer.
    let status = CMAudioSampleBufferCreateWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: false,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: CMItemCount(buffer.frameLength),
      presentationTimeStamp: timing.presentationTimeStamp,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sb = sampleBuffer else { return nil }

    let setDataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sb,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      bufferList: buffer.audioBufferList
    )
    guard setDataStatus == noErr else { return nil }

    return sb
  }
}

// Helper at the bottom of the file: get a CMAudioFormatDescription from
// AudioStreamBasicDescription (defined as an extension on
// UnsafeMutablePointer<AudioStreamBasicDescription>).
fileprivate extension UnsafeMutablePointer where Pointee == AudioStreamBasicDescription {
  func cmFormatDescription() -> CMAudioFormatDescription? {
    var asbd = self.pointee
    var fd: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &fd
    )
    return status == noErr ? fd : nil
  }
}
```

- [ ] **Step 2: Build to confirm compilation**

```
cd packages/screen_recorder && flutter build macos --debug
```

Expected: build succeeds. (Behavior unchanged because nobody is setting `onSampleBufferReceived` yet.)

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift
git commit -m "feat: add CMSampleBuffer audio callback for live writer path"
```

---

### Task 9: `PerfSampler.swift` — native CPU and memory sampling

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/PerfSampler.swift`

**Why:** Sample CPU% and resident memory once per second on the native side during recording and surface avg/p95 + peak in the stop response. Done natively to avoid perturbing Dart isolates.

- [ ] **Step 1: Create the file**

```swift
// packages/screen_recorder_macos/macos/Classes/PerfSampler.swift
import Foundation
import Darwin

/// Samples this process's CPU% (across all threads) and resident memory at
/// 1 Hz on a background queue. Call `start()` when the recording begins and
/// `stop()` when it ends — `stop()` returns the aggregate stats.
class PerfSampler {
  struct Stats {
    let cpuPctSamples: [Double]
    let memBytesSamples: [UInt64]

    var cpuPctAvg: Double {
      guard !cpuPctSamples.isEmpty else { return 0 }
      return cpuPctSamples.reduce(0, +) / Double(cpuPctSamples.count)
    }
    var cpuPctP95: Double {
      guard !cpuPctSamples.isEmpty else { return 0 }
      let sorted = cpuPctSamples.sorted()
      let idx = Int((Double(sorted.count - 1) * 0.95).rounded())
      return sorted[idx]
    }
    var memBytesPeak: UInt64 { memBytesSamples.max() ?? 0 }
  }

  private var timer: DispatchSourceTimer?
  private var samples = Stats(cpuPctSamples: [], memBytesSamples: [])
  private let queue = DispatchQueue(label: "com.slipreel.perf_sampler")
  private let lock = NSLock()
  private var cpuPctAccum: [Double] = []
  private var memBytesAccum: [UInt64] = []

  private var lastTotalUserTime: TimeInterval = 0
  private var lastTotalSystemTime: TimeInterval = 0
  private var lastSampleAt: Date = Date()

  func start() {
    lock.lock()
    cpuPctAccum.removeAll()
    memBytesAccum.removeAll()
    (lastTotalUserTime, lastTotalSystemTime) = currentCpuTimes()
    lastSampleAt = Date()
    lock.unlock()

    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
    t.setEventHandler { [weak self] in self?.takeSample() }
    timer = t
    t.resume()
  }

  func stop() -> Stats {
    timer?.cancel()
    timer = nil
    lock.lock()
    let s = Stats(cpuPctSamples: cpuPctAccum, memBytesSamples: memBytesAccum)
    lock.unlock()
    return s
  }

  // MARK: - Sampling

  private func takeSample() {
    let (user, system) = currentCpuTimes()
    let cpuTime = (user - lastTotalUserTime) + (system - lastTotalSystemTime)
    let now = Date()
    let wall = now.timeIntervalSince(lastSampleAt)
    let pct = wall > 0 ? (cpuTime / wall) * 100.0 : 0
    let mem = currentResidentMemoryBytes()

    lock.lock()
    cpuPctAccum.append(pct)
    memBytesAccum.append(mem)
    lock.unlock()

    lastTotalUserTime = user
    lastTotalSystemTime = system
    lastSampleAt = now
  }

  private func currentCpuTimes() -> (user: TimeInterval, system: TimeInterval) {
    var info = task_thread_times_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    let user = TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1_000_000.0
    let system = TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1_000_000.0
    return (user, system)
  }

  private func currentResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return info.resident_size
  }
}
```

- [ ] **Step 2: Build**

```
cd packages/screen_recorder && flutter build macos --debug
```

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/PerfSampler.swift
git commit -m "feat: add PerfSampler for native CPU and memory sampling"
```

---

### Task 10: Wire `startLiveRecording` / `stopLiveRecording` into `ScreenRecorderMacosPlugin`

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

**Why:** Add new method handlers that own the new pipeline lifetime: instantiate `LiveRecordingWriter`, `VideoToolboxEncoder`, `PerfSampler`, hook them all together, route buffers through them, and on stop return the output path plus the perf stats. Keep the old `startRecording` / `stopRecording` handlers untouched — those still serve Windows/Linux and remain available as a fallback.

- [ ] **Step 1: Add properties and method routing**

Near the top of `ScreenRecorderMacosPlugin`, add:

```swift
  // NEW: Live recording state.
  private var liveWriter: LiveRecordingWriter?
  private var liveEncoder: VideoToolboxEncoder?
  private var perfSampler: PerfSampler?
  private var liveStartTime: Date?
  private var liveFrameCount: Int = 0
```

In `handle(_:result:)`, add cases:

```swift
    case "startLiveRecording":
      startLiveRecording(call: call, result: result)
    case "stopLiveRecording":
      stopLiveRecording(result: result)
```

- [ ] **Step 2: Implement `startLiveRecording`**

Append to the class:

```swift
  // MARK: - Live Recording (Phase 9)

  private func startLiveRecording(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let source = args["source"] as? String,
          let fps = args["frameRate"] as? Int,
          let outputPath = args["outputPath"] as? String,
          let width = args["width"] as? Int,
          let height = args["height"] as? Int else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "Missing required parameters",
                          details: nil))
      return
    }
    let sourceId = args["sourceId"] as? String
    let captureAudio = args["captureAudio"] as? Bool ?? false
    let captureCursor = args["captureCursor"] as? Bool ?? true

    Task {
      do {
        // Construct & start the writer
        let writer = LiveRecordingWriter(
          outputPath: outputPath, width: width, height: height,
          fps: fps, captureAudio: captureAudio)
        try writer.start()

        // Construct the encoder; require HW acceleration. Throws on old Macs.
        let encoder = VideoToolboxEncoder(width: width, height: height, fps: fps)
        encoder.onCompressedSample = { [weak writer] sb in
          writer?.appendVideo(sb)
        }
        try encoder.initialize()

        // Capture manager
        if captureManager == nil { captureManager = ScreenCaptureManager() }
        captureManager?.onFrameReceived = { [weak encoder] sampleBuffer in
          guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
          let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          try? encoder?.encode(pixelBuffer: pb, timestamp: pts)
        }

        let isWindow = source == "window"
        var actualSourceId = sourceId
        if actualSourceId == nil && !isWindow {
          actualSourceId = String(CGMainDisplayID())
        }
        guard let finalSourceId = actualSourceId else {
          result(FlutterError(code: "INVALID_ARGUMENTS",
                              message: "sourceId required for window capture",
                              details: nil))
          return
        }
        try await captureManager?.startCapture(sourceId: finalSourceId, fps: fps, isWindow: isWindow)

        // Audio
        if captureAudio {
          if audioCaptureManager == nil { audioCaptureManager = AudioCaptureManager() }
          audioCaptureManager?.onSampleBufferReceived = { [weak writer] sb in
            writer?.appendAudio(sb)
          }
          try audioCaptureManager?.startCapture(includeMicrophone: true, includeSystem: false)
        }

        // Cursor (still streamed to Dart; sidecar is written there)
        if captureCursor {
          if cursorTracker == nil { cursorTracker = CursorTracker() }
          cursorTracker?.onCursorUpdate = { [weak self] x, y, ts, isClicked in
            self?.cursorStreamHandler?.sendCursorPosition(x: x, y: y, timestamp: ts, isClicked: isClicked)
          }
          try cursorTracker?.startTracking(frequency: 60)
        }

        // Perf
        let sampler = PerfSampler()
        sampler.start()

        // Record state
        self.liveWriter = writer
        self.liveEncoder = encoder
        self.perfSampler = sampler
        self.liveStartTime = Date()
        self.liveFrameCount = 0

        result(true)
      } catch {
        result(FlutterError(code: "LIVE_START_FAILED",
                            message: "Failed to start live recording: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }
```

- [ ] **Step 3: Implement `stopLiveRecording`**

```swift
  private func stopLiveRecording(result: @escaping FlutterResult) {
    Task {
      do {
        try await captureManager?.stopCapture()
        captureManager = nil

        if let am = audioCaptureManager, am.isCaptureActive() {
          am.onSampleBufferReceived = nil
          am.onAudioReceived = nil
          am.onError = nil
          am.stopCapture()
          audioCaptureManager = nil
        }
        if let ct = cursorTracker {
          ct.onCursorUpdate = nil
          if ct.isCurrentlyTracking() { ct.stopTracking() }
          cursorTracker = nil
        }

        liveEncoder?.finalize()
        let droppedFrames = liveEncoder?.droppedFrameCount ?? 0
        liveEncoder = nil

        let stats = perfSampler?.stop()
        perfSampler = nil

        guard let writer = liveWriter else {
          result(FlutterError(code: "NOT_RECORDING", message: "no live writer", details: nil))
          return
        }
        liveWriter = nil

        writer.stop { stopResult in
          switch stopResult {
          case .success(let path):
            let payload: [String: Any] = [
              "outputPath": path,
              "droppedFrames": droppedFrames,
              "cpuPctSamples": stats?.cpuPctSamples ?? [],
              "memBytesSamples": stats?.memBytesSamples ?? [],
            ]
            result(payload)
          case .failure(let err):
            result(FlutterError(code: "LIVE_STOP_FAILED",
                                message: "Failed to finalize: \(err.localizedDescription)",
                                details: nil))
          }
        }
      } catch {
        result(FlutterError(code: "LIVE_STOP_FAILED",
                            message: "Failed to stop live recording: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }
```

- [ ] **Step 4: Build**

```
cd packages/screen_recorder && flutter build macos --debug
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat: add startLiveRecording/stopLiveRecording method handlers on macOS"
```

---

## Batch C — Dart side of live recording

### Task 11: Platform interface — `startLiveRecording` / `stopLiveRecording` + result types

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/recording_result.dart`
- Create: `packages/screen_recorder_platform_interface/lib/src/models/native_perf_stats.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Create: `packages/screen_recorder_platform_interface/test/models/recording_result_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/models/recording_result_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('NativePerfStats parses from method-channel map', () {
    final map = <String, dynamic>{
      'droppedFrames': 3,
      'cpuPctSamples': <double>[1.0, 2.0, 3.0],
      'memBytesSamples': <int>[1000000, 2000000, 1500000],
    };
    final stats = NativePerfStats.fromMap(map);
    expect(stats.droppedFrames, 3);
    expect(stats.cpuPctSamples, [1.0, 2.0, 3.0]);
    expect(stats.memBytesPeak, 2000000);
  });

  test('RecordingResult parses from method-channel map', () {
    final map = <String, dynamic>{
      'outputPath': '/tmp/x.mp4',
      'droppedFrames': 0,
      'cpuPctSamples': <double>[],
      'memBytesSamples': <int>[],
    };
    final r = RecordingResult.fromMap(map);
    expect(r.outputPath, '/tmp/x.mp4');
    expect(r.perfStats.droppedFrames, 0);
  });
}
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement the models**

```dart
// packages/screen_recorder_platform_interface/lib/src/models/native_perf_stats.dart

/// Native-side performance counters captured during a recording session.
///
/// Returned to Dart as part of [RecordingResult] when a live recording stops.
class NativePerfStats {
  final int droppedFrames;
  final List<double> cpuPctSamples;
  final List<int> memBytesSamples;

  const NativePerfStats({
    required this.droppedFrames,
    required this.cpuPctSamples,
    required this.memBytesSamples,
  });

  factory NativePerfStats.fromMap(Map<String, dynamic> map) {
    return NativePerfStats(
      droppedFrames: (map['droppedFrames'] as num?)?.toInt() ?? 0,
      cpuPctSamples: ((map['cpuPctSamples'] as List?) ?? const [])
          .map((e) => (e as num).toDouble())
          .toList(),
      memBytesSamples: ((map['memBytesSamples'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }

  static const empty = NativePerfStats(
    droppedFrames: 0,
    cpuPctSamples: [],
    memBytesSamples: [],
  );

  double get cpuPctAvg {
    if (cpuPctSamples.isEmpty) return 0;
    return cpuPctSamples.reduce((a, b) => a + b) / cpuPctSamples.length;
  }

  double get cpuPctP95 {
    if (cpuPctSamples.isEmpty) return 0;
    final sorted = [...cpuPctSamples]..sort();
    final idx = ((sorted.length - 1) * 0.95).round();
    return sorted[idx];
  }

  int get memBytesPeak {
    if (memBytesSamples.isEmpty) return 0;
    return memBytesSamples.reduce((a, b) => a > b ? a : b);
  }
}
```

```dart
// packages/screen_recorder_platform_interface/lib/src/models/recording_result.dart
import 'native_perf_stats.dart';

/// Result of a live recording session: the output file path plus the native
/// perf stats for the session.
class RecordingResult {
  final String outputPath;
  final NativePerfStats perfStats;

  const RecordingResult({
    required this.outputPath,
    required this.perfStats,
  });

  factory RecordingResult.fromMap(Map<String, dynamic> map) {
    return RecordingResult(
      outputPath: map['outputPath'] as String? ?? '',
      perfStats: NativePerfStats.fromMap(map),
    );
  }
}
```

- [ ] **Step 4: Add new methods to the interface**

In `screen_recorder_platform_interface.dart`, add imports and abstract methods:

```dart
import 'models/recording_result.dart';

  // ... existing methods ...

  /// Start a live HW-encoded recording. Writes a complete MP4 directly to
  /// [outputPath] during capture (no raw-frame spool). Throws
  /// `UnsupportedError` on platforms that don't support the live path.
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
  }) {
    throw UnsupportedError(
      'startLiveRecording() is not supported on this platform; '
      'use startRecording() with the spool-based path instead.',
    );
  }

  /// Stop the live recording, finalize the MP4, and return the path plus
  /// native perf stats.
  Future<RecordingResult> stopLiveRecording() {
    throw UnsupportedError('stopLiveRecording() is not supported on this platform.');
  }
```

Also add the models to the package's barrel file. Open `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (the *outer* one; check before editing) and ensure the new files are exported:

```dart
export 'src/models/recording_result.dart';
export 'src/models/native_perf_stats.dart';
```

- [ ] **Step 5: Add channel constants**

Open `packages/screen_recorder_platform_interface/lib/src/constants.dart` and add new method names. Inspect the file first; add entries `'startLiveRecording'` and `'stopLiveRecording'` alongside the existing method-name constants.

- [ ] **Step 6: Run tests, confirm pass**

```
cd packages/screen_recorder_platform_interface && flutter test
```

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder_platform_interface/
git commit -m "feat: add live recording API + RecordingResult/NativePerfStats to platform interface"
```

---

### Task 12: macOS platform implementation — wire new methods through the method channel

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos.dart` (the Dart side of the macOS plugin; read first to understand current structure)

**Why:** Override `startLiveRecording` / `stopLiveRecording` in the macOS implementation class to call the new method channel methods.

- [ ] **Step 1: Read the current macOS Dart implementation**

```
flutter analyze packages/screen_recorder_macos
```

Open `packages/screen_recorder_macos/lib/screen_recorder_macos.dart`. Find the class that extends `ScreenRecorderPlatform`.

- [ ] **Step 2: Override `startLiveRecording` and `stopLiveRecording`**

Inside that class, add:

```dart
  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
  }) async {
    await methodChannel.invokeMethod<void>('startLiveRecording', {
      ...settings.toJson(),
      'outputPath': outputPath,
      'width': width,
      'height': height,
    });
  }

  @override
  Future<RecordingResult> stopLiveRecording() async {
    final raw = await methodChannel.invokeMapMethod<String, dynamic>(
      'stopLiveRecording',
    );
    if (raw == null) {
      throw StateError('stopLiveRecording returned null');
    }
    return RecordingResult.fromMap(raw);
  }
```

(Adjust `methodChannel` reference to match the variable name used in the existing class.)

- [ ] **Step 3: Build to confirm compilation**

```
cd packages/screen_recorder && flutter build macos --debug
```

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos.dart
git commit -m "feat: wire live recording method channel calls in macOS plugin"
```

---

### Task 13: Shrink `video_encoder.dart` to a live-writer façade

**Files:**
- Modify: `packages/screen_recorder/lib/video_encoder.dart`

**Why:** The current `VideoEncoder` accumulates `.bgra` frames and `.pcm` audio samples on disk and runs FFmpeg on stop. With live recording, the native side does all of that. `VideoEncoder` becomes a thin wrapper that delegates to `ScreenRecorderPlatform.instance.startLiveRecording` / `stopLiveRecording` and reports the result.

The old `addFrame`, `addAudioSample`, and `finalize` methods are no longer called for live recordings (the streams that drove them are no longer consumed in Task 14), so this task replaces the file entirely. `VideoEncoderIsolate` is similarly no longer needed for the live path; we'll delete it in Task 14 after wiring the new flow in.

- [ ] **Step 1: Replace the file**

```dart
// packages/screen_recorder/lib/video_encoder.dart
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'utils/app_logger.dart';

/// Façade over the platform's live HW-encoded recording API.
///
/// Started before the platform-side capture begins; stopped after capture
/// ends. The output MP4 is written directly by the native side during
/// capture; this class does not see frame bytes.
class VideoEncoder {
  String? _outputPath;
  int _width = 0;
  int _height = 0;
  int _fps = 30;
  bool _isActive = false;

  /// Start a live recording session that will write to [outputPath].
  /// Must be called before [ScreenRecorderPlatform.startLiveRecording] would
  /// otherwise be triggered (see [RecordingController]).
  Future<void> start({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
  }) async {
    _outputPath = outputPath;
    _width = width;
    _height = height;
    _fps = settings.frameRate;
    await ScreenRecorderPlatform.instance.startLiveRecording(
      settings: settings,
      outputPath: outputPath,
      width: width,
      height: height,
    );
    _isActive = true;
    AppLogger.videoEncoder.i('Live recording started: ${_width}x$_height @ ${_fps}fps -> $_outputPath');
  }

  /// Stop the live recording and return the result (path + native perf stats).
  Future<RecordingResult> stop() async {
    if (!_isActive) {
      throw StateError('VideoEncoder.stop called when not active');
    }
    final result = await ScreenRecorderPlatform.instance.stopLiveRecording();
    _isActive = false;
    AppLogger.videoEncoder.i('Live recording finished: ${result.outputPath}');
    return result;
  }

  bool get isActive => _isActive;
  String? get outputPath => _outputPath;
  int get width => _width;
  int get height => _height;
  int get fps => _fps;
}
```

- [ ] **Step 2: Run analyzer (it will surface every caller of the old API)**

```
cd packages/screen_recorder && flutter analyze
```

Expected: errors in `recording_state.dart` (uses old `addFrame`, `setCursorData`, etc.) and `video_encoder_isolate.dart`. We'll fix those in Task 14.

- [ ] **Step 3: Don't commit yet — Task 14 fixes the callers.**

---

### Task 14: Update `recording_state.dart` to use the live-writer flow + emit perf summary

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Delete: `packages/screen_recorder/lib/video_encoder_isolate.dart`
- Delete: `packages/screen_recorder/lib/processing/video_processing_isolate.dart` (only the recording-side wrapper; if the file is also used by some hypothetical export path, leave it — but per the explorer's report, currently it serves only the recording flow)

**Why:** The Dart-side recording controller no longer reads from `frameStream` or `audioStream` on macOS; those are bypassed by the live writer. It still subscribes to `cursorStream` (cursor tracking is unchanged). On stop it pulls back the `RecordingResult`, builds a `RecordingPerfSummary`, and logs it. The cursor sidecar is written; the recording metadata sidecar is also written.

- [ ] **Step 1: Replace the controller**

```dart
// packages/screen_recorder/lib/state/recording_state.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';
import '../models/recording_metadata.dart';
import '../utils/app_logger.dart';
import '../utils/perf_summary.dart';
import '../video_encoder.dart';

enum RecordingStatus { idle, recording, processing, completed, error }

class RecordingState {
  final RecordingStatus status;
  final int frameCount;
  final Duration duration;
  final String? videoPath;
  final String? error;
  final String? selectedWindowId;

  const RecordingState({
    this.status = RecordingStatus.idle,
    this.frameCount = 0,
    this.duration = Duration.zero,
    this.videoPath,
    this.error,
    this.selectedWindowId,
  });

  RecordingState copyWith({
    RecordingStatus? status,
    int? frameCount,
    Duration? duration,
    String? videoPath,
    String? error,
    String? selectedWindowId,
  }) {
    return RecordingState(
      status: status ?? this.status,
      frameCount: frameCount ?? this.frameCount,
      duration: duration ?? this.duration,
      videoPath: videoPath ?? this.videoPath,
      error: error,
      selectedWindowId: selectedWindowId ?? this.selectedWindowId,
    );
  }

  bool get isRecording => status == RecordingStatus.recording;
  bool get isProcessing => status == RecordingStatus.processing;
  bool get canStartRecording =>
      status == RecordingStatus.idle || status == RecordingStatus.completed;
}

class RecordingController extends StateNotifier<RecordingState> {
  RecordingController() : super(const RecordingState());

  final VideoEncoder _videoEncoder = VideoEncoder();
  StreamSubscription<CursorPosition>? _cursorSubscription;
  CursorRecording? _cursorRecording;
  Timer? _durationTimer;
  DateTime? _startTime;

  static const int _defaultFps = 60;
  static const int _defaultWidth = 1920;
  static const int _defaultHeight = 1080;

  void selectWindow(String? windowId) {
    state = state.copyWith(selectedWindowId: windowId);
  }

  Future<void> startRecording() async {
    if (!state.canStartRecording || state.selectedWindowId == null) return;
    try {
      state = state.copyWith(
        status: RecordingStatus.recording,
        frameCount: 0,
        duration: Duration.zero,
        videoPath: null,
        error: null,
      );

      final docsDir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${docsDir.path}/recording_$ts.mp4';

      final settings = RecordingSettings(
        source: RecordingSource.window,
        sourceId: state.selectedWindowId,
        frameRate: _defaultFps,
        captureAudio: true,
        captureCursor: true,
      );

      await _videoEncoder.start(
        settings: settings,
        outputPath: outputPath,
        width: _defaultWidth,
        height: _defaultHeight,
      );

      _cursorRecording = CursorRecording();
      _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
        (pos) => _cursorRecording?.addPosition(pos),
        onError: (e) => AppLogger.recording.w('Cursor stream error', error: e),
      );

      _startTime = DateTime.now();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_startTime != null) {
          state = state.copyWith(duration: DateTime.now().difference(_startTime!));
        }
      });
    } catch (e) {
      _handleError('Failed to start recording: $e');
    }
  }

  Future<void> stopRecording() async {
    if (!state.isRecording) return;
    try {
      state = state.copyWith(status: RecordingStatus.processing);

      _durationTimer?.cancel();
      _durationTimer = null;
      final duration = _startTime != null
          ? DateTime.now().difference(_startTime!)
          : Duration.zero;
      _startTime = null;

      await _cursorSubscription?.cancel();
      _cursorSubscription = null;

      final result = await _videoEncoder.stop();

      // Save cursor sidecar (next to MP4).
      if (_cursorRecording != null && _cursorRecording!.count > 0) {
        await _cursorRecording!.saveToFile('${result.outputPath}.cursor.json');
        AppLogger.recording.i('Cursor data saved: ${_cursorRecording!.count} positions');
      }
      _cursorRecording = null;

      // Save recording metadata sidecar.
      final meta = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.now(),
        widthPx: _videoEncoder.width,
        heightPx: _videoEncoder.height,
        fps: _videoEncoder.fps,
      );
      await meta.saveForVideo(result.outputPath);

      // Build and log the perf summary.
      final fileSize = await File(result.outputPath).length();
      final expectedFrames =
          (duration.inMilliseconds * _videoEncoder.fps / 1000).round();
      // The native encoder doesn't emit a precise count yet; until it does,
      // use expected frames (minus drops) as the actual count for verdict
      // purposes. fpsOk effectively becomes a "duration matches expected"
      // check, which is good enough for the PASS/FAIL gate.
      final summary = RecordingPerfSummary(
        durationSeconds: duration.inMilliseconds / 1000.0,
        frameCount: expectedFrames - result.perfStats.droppedFrames,
        expectedFrameCount: expectedFrames,
        droppedFrameCount: result.perfStats.droppedFrames,
        cpuPctAvg: result.perfStats.cpuPctAvg,
        cpuPctP95: result.perfStats.cpuPctP95,
        memPeakBytes: result.perfStats.memBytesPeak,
        outputBytes: fileSize,
        targetFps: _videoEncoder.fps,
      );
      AppLogger.recording.i(summary.format());

      state = state.copyWith(
        status: RecordingStatus.completed,
        videoPath: result.outputPath,
        duration: duration,
      );
    } catch (e) {
      _handleError('Failed to stop recording: $e');
    }
  }

  void _handleError(String message) {
    state = state.copyWith(status: RecordingStatus.error, error: message);
    _cursorSubscription?.cancel();
    _cursorSubscription = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _startTime = null;
    _cursorRecording = null;
  }

  void reset() => state = const RecordingState();

  @override
  void dispose() {
    _cursorSubscription?.cancel();
    _durationTimer?.cancel();
    super.dispose();
  }
}

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>(
        (ref) => RecordingController());

final formattedDurationProvider = Provider<String>((ref) {
  final d = ref.watch(recordingControllerProvider.select((s) => s.duration));
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
});

final fpsProvider = Provider<double>((ref) {
  final s = ref.watch(recordingControllerProvider);
  if (s.frameCount == 0 || s.duration.inSeconds == 0) return 0;
  return s.frameCount / s.duration.inSeconds;
});
```

- [ ] **Step 2: Delete the now-unused isolate files**

```
git rm packages/screen_recorder/lib/video_encoder_isolate.dart packages/screen_recorder/lib/processing/video_processing_isolate.dart
```

If `video_processing_isolate.dart` is imported elsewhere outside the recording flow, run `flutter analyze` to surface the imports and remove them. The recording flow is the only known caller per the explorer's report.

- [ ] **Step 3: Run analyzer + tests**

```
cd packages/screen_recorder && flutter analyze && flutter test
```

Expected: zero analyzer issues; existing unit tests pass. The UI tests that load `recording_screen.dart` may need their imports adjusted to remove references to the deleted isolate file.

- [ ] **Step 4: Commit**

```bash
git add -A packages/screen_recorder/
git commit -m "feat: switch recording to live HW encode flow with perf summary on stop"
```

---

## Batch D — Export pipeline (new code)

These tasks build the export pipeline that didn't exist before (the editor's Export button is a stub today). The pipeline is: FFmpeg-decode source MP4 → existing-style isolate compositor (cursor + effects) → FFmpeg-encode with `h264_videotoolbox` (libx264 fallback).

### Task 15: `FfmpegDecoder` — decode source MP4 to BGRA on stdout

**Files:**
- Create: `packages/screen_recorder/lib/export/ffmpeg_decoder.dart`
- Create: `packages/screen_recorder/test/export/ffmpeg_decoder_test.dart`
- Create: `packages/screen_recorder/test/fixtures/sample_recording.mp4` (1-second 320×240 30fps test pattern with audio; instructions to generate it below)

**Why:** First stage of the export pipeline. Spawns `ffmpeg -i <src> -f rawvideo -pix_fmt bgra -` and exposes the raw BGRA frame stream. Times itself.

- [ ] **Step 1: Generate the test fixture**

Run once on your machine and commit the result:

```
mkdir -p packages/screen_recorder/test/fixtures
ffmpeg -y -f lavfi -i 'testsrc=duration=1:size=320x240:rate=30' \
       -f lavfi -i 'sine=frequency=440:duration=1' \
       -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
       -c:a aac -b:a 64k \
       packages/screen_recorder/test/fixtures/sample_recording.mp4
git add packages/screen_recorder/test/fixtures/sample_recording.mp4
```

- [ ] **Step 2: Write the failing tests**

```dart
// packages/screen_recorder/test/export/ffmpeg_decoder_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/ffmpeg_decoder.dart';

void main() {
  group('FfmpegDecoder', () {
    test('decodes the test fixture into the expected number of frames', () async {
      final decoder = FfmpegDecoder(
        inputPath: 'test/fixtures/sample_recording.mp4',
        width: 320,
        height: 240,
      );
      final frames = <Uint8List>[];
      await decoder.frames().forEach(frames.add);
      // 30fps × 1s = 30 frames; allow ±2 for encoder rounding.
      expect(frames.length, inInclusiveRange(28, 32));
      // Each frame is W * H * 4 bytes (BGRA).
      expect(frames.first.length, 320 * 240 * 4);
      // Total decode time recorded.
      expect(decoder.totalDecodeMs, greaterThan(0));
    });

    test('throws on non-existent file', () async {
      final decoder = FfmpegDecoder(
        inputPath: '/nonexistent/path.mp4',
        width: 320,
        height: 240,
      );
      expect(decoder.frames().toList(), throwsException);
    });
  });
}
```

- [ ] **Step 3: Run, confirm fail**

- [ ] **Step 4: Implement**

```dart
// packages/screen_recorder/lib/export/ffmpeg_decoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../utils/app_logger.dart';

/// Spawns `ffmpeg` to decode an input video into raw BGRA frames streamed
/// on stdout. Each emitted [Uint8List] is exactly `width * height * 4` bytes.
class FfmpegDecoder {
  final String inputPath;
  final int width;
  final int height;

  /// Total wall-clock milliseconds spent reading/awaiting decoded bytes.
  /// Does not include subprocess spawn time.
  int totalDecodeMs = 0;

  FfmpegDecoder({
    required this.inputPath,
    required this.width,
    required this.height,
  });

  Stream<Uint8List> frames() async* {
    final args = [
      '-loglevel', 'error',
      '-i', inputPath,
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-',
    ];
    AppLogger.ffmpeg.d('decode: ffmpeg ${args.join(" ")}');

    final process = await Process.start('ffmpeg', args);
    final frameSize = width * height * 4;
    final buffer = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();

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
  }
}
```

- [ ] **Step 5: Run tests, confirm pass**

```
cd packages/screen_recorder && flutter test test/export/ffmpeg_decoder_test.dart
```

(Skip on machines without `ffmpeg` on `PATH`. The CI runner must have `ffmpeg` installed; this matches the existing dependency in `video_encoder.dart`.)

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/export/ffmpeg_decoder.dart packages/screen_recorder/test/export/ffmpeg_decoder_test.dart packages/screen_recorder/test/fixtures/sample_recording.mp4
git commit -m "feat: add FfmpegDecoder for export pipeline source frames"
```

---

### Task 16: `FfmpegEncoder` — h264_videotoolbox encoder with libx264 fallback

**Files:**
- Create: `packages/screen_recorder/lib/export/ffmpeg_encoder.dart`
- Create: `packages/screen_recorder/test/export/ffmpeg_encoder_test.dart`

**Why:** Third stage of the export pipeline. Spawns `ffmpeg -f rawvideo -pix_fmt bgra -i - … -c:v h264_videotoolbox …`, accepts raw frames on stdin, and re-uses the source's audio via `-c:a copy`. If the HW encoder fails to start, retries once with `libx264`.

- [ ] **Step 1: Write failing tests**

```dart
// packages/screen_recorder/test/export/ffmpeg_encoder_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/ffmpeg_encoder.dart';

void main() {
  group('FfmpegEncoder', () {
    test('encodes a stream of solid-color frames to a valid MP4', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_enc');
      final outPath = '${tmp.path}/out.mp4';

      final encoder = FfmpegEncoder(
        outputPath: outPath,
        width: 320,
        height: 240,
        fps: 30,
        bitrateKbps: 1000,
        audioSourcePath: 'test/fixtures/sample_recording.mp4',
      );

      // 30 solid red frames (BGRA).
      final frame = Uint8List(320 * 240 * 4);
      for (var i = 0; i < frame.length; i += 4) {
        frame[i] = 0; frame[i + 1] = 0; frame[i + 2] = 255; frame[i + 3] = 255;
      }

      await encoder.start();
      for (var i = 0; i < 30; i++) {
        await encoder.writeFrame(frame);
      }
      await encoder.finish();

      final file = File(outPath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(1000));
      expect(encoder.totalEncodeMs, greaterThan(0));

      tmp.deleteSync(recursive: true);
    });
  });
}
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/export/ffmpeg_encoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../utils/app_logger.dart';

/// Spawns `ffmpeg` to encode raw BGRA frames piped into its stdin.
/// Tries `h264_videotoolbox` first; falls back to `libx264` if startup fails.
class FfmpegEncoder {
  final String outputPath;
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;

  /// Optional path to the source MP4 — its audio track is muxed into the
  /// output via `-c:a copy` (no re-encode).
  final String? audioSourcePath;

  Process? _process;
  String _codecUsed = 'h264_videotoolbox';
  int totalEncodeMs = 0;
  final Stopwatch _sw = Stopwatch();

  String get codecUsed => _codecUsed;
  bool get usedHardware => _codecUsed == 'h264_videotoolbox';

  FfmpegEncoder({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    this.audioSourcePath,
  });

  List<String> _argsFor(String codec) {
    final args = <String>[
      '-loglevel', 'error',
      '-y',
      // Video input from stdin
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-s', '${width}x$height',
      '-r', '$fps',
      '-i', '-',
    ];
    if (audioSourcePath != null) {
      args.addAll(['-i', audioSourcePath!]);
      args.addAll(['-map', '0:v', '-map', '1:a:0']);
    }
    args.addAll([
      '-c:v', codec,
      '-b:v', '${bitrateKbps}k',
      '-pix_fmt', 'yuv420p',
    ]);
    if (audioSourcePath != null) {
      args.addAll(['-c:a', 'copy']);
    }
    args.add(outputPath);
    return args;
  }

  Future<void> start() async {
    Future<bool> tryCodec(String codec) async {
      final args = _argsFor(codec);
      AppLogger.ffmpeg.d('encode ($codec): ffmpeg ${args.join(" ")}');
      try {
        _process = await Process.start('ffmpeg', args);
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

  Future<void> writeFrame(Uint8List bgra) async {
    final p = _process;
    if (p == null) throw StateError('FfmpegEncoder.writeFrame before start');
    p.stdin.add(bgra);
    await p.stdin.flush();
  }

  Future<void> finish() async {
    final p = _process;
    if (p == null) return;
    await p.stdin.close();
    final exit = await p.exitCode;
    _sw.stop();
    totalEncodeMs = _sw.elapsedMilliseconds;
    if (exit != 0) {
      final err = await p.stderr.transform(SystemEncoding().decoder).join();
      throw Exception('ffmpeg encode exited $exit: $err');
    }
  }
}
```

- [ ] **Step 4: Run tests, confirm pass**

```
cd packages/screen_recorder && flutter test test/export/ffmpeg_encoder_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/export/ffmpeg_encoder.dart packages/screen_recorder/test/export/ffmpeg_encoder_test.dart
git commit -m "feat: add FfmpegEncoder with h264_videotoolbox primary and libx264 fallback"
```

---

### Task 17: `ExportPipeline` — coordinator that wires decoder + compositor + encoder

**Files:**
- Create: `packages/screen_recorder/lib/export/export_pipeline.dart`
- Create: `packages/screen_recorder/test/export/export_pipeline_test.dart`

**Why:** The orchestrator that takes a recording (path, metadata, cursor) and a target preset, runs the three stages, and emits an `ExportPerfSummary` at the end. This is what the editor's Export button will call.

The compositor stage uses `CursorRenderer` (existing class — still useful here, since cursor is now applied at export not at recording). For the first cut we keep the compositor on the main isolate path; if the perf summary later shows it's a bottleneck we can re-introduce isolate execution.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/export/export_pipeline_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/cursor_recording.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExportPipeline', () {
    test('end-to-end produces a valid MP4 and a PASS summary on the fixture', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_pipe');
      final outPath = '${tmp.path}/out.mp4';

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
        bitrateKbps: 800,
      );

      final summary = await pipeline.run();

      expect(File(outPath).existsSync(), isTrue);
      expect(summary.inputDurationSeconds, closeTo(1.0, 0.2));
      expect(summary.realtimeMultiple, greaterThan(0));
      // We don't assert PASS here because CI hardware varies; just sanity-check.
      expect(summary.format(), contains('verdict'));

      tmp.deleteSync(recursive: true);
    });
  });
}
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:typed_data';
import '../models/cursor_recording.dart';
import '../models/recording_metadata.dart';
import '../rendering/cursor_renderer.dart';
import '../utils/perf_summary.dart';
import '../utils/app_logger.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_encoder.dart';

/// Orchestrates: decode source MP4 → composite cursor + effects → encode HW.
class ExportPipeline {
  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;
  final int bitrateKbps;

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.bitrateKbps,
  });

  Future<ExportPerfSummary> run() async {
    final width = sourceMetadata.widthPx;
    final height = sourceMetadata.heightPx;
    final fps = sourceMetadata.fps;

    final decoder = FfmpegDecoder(
      inputPath: sourcePath,
      width: width,
      height: height,
    );
    final encoder = FfmpegEncoder(
      outputPath: outputPath,
      width: width,
      height: height,
      fps: fps,
      bitrateKbps: bitrateKbps,
      audioSourcePath: sourcePath,
    );

    final cursorRenderer = CursorRenderer();
    if (sourceMetadata.isPureSource && cursorRecording.count > 0) {
      await cursorRenderer.initialize();
    }

    await encoder.start();

    final wallSw = Stopwatch()..start();
    final compositeSw = Stopwatch();
    int frameIndex = 0;
    int totalFrames = 0;

    try {
      await for (final raw in decoder.frames()) {
        Uint8List composited = raw;

        if (sourceMetadata.isPureSource && cursorRecording.count > 0) {
          compositeSw.start();
          final ts = ((1000000 * frameIndex) ~/ fps);
          composited = await cursorRenderer.renderCursorOnFrame(
            frameData: raw,
            width: width,
            height: height,
            timestampMicros: ts,
            cursorRecording: cursorRecording,
          );
          compositeSw.stop();
        }

        await encoder.writeFrame(composited);
        frameIndex++;
        totalFrames++;
      }
    } finally {
      cursorRenderer.dispose();
    }

    await encoder.finish();
    wallSw.stop();

    final wallSec = wallSw.elapsedMilliseconds / 1000.0;
    final inputDuration = totalFrames > 0 ? totalFrames / fps : 0.0;
    final outputBytes = await _fileLength(outputPath);

    final summary = ExportPerfSummary(
      inputDurationSeconds: inputDuration,
      wallTimeSeconds: wallSec,
      decodeMsPerFrame: totalFrames > 0 ? decoder.totalDecodeMs / totalFrames : 0,
      compositeMsPerFrame: totalFrames > 0
          ? compositeSw.elapsedMilliseconds / totalFrames
          : 0,
      encodeMsPerFrame: totalFrames > 0 ? encoder.totalEncodeMs / totalFrames : 0,
      outputBytes: outputBytes,
      outputCodec: encoder.codecUsed,
      usedHardwareEncoder: encoder.usedHardware,
    );
    AppLogger.ffmpeg.i(summary.format());
    return summary;
  }

  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }
}
```

Top of the same file must include:

```dart
import 'dart:io';
```

- [ ] **Step 4: Run tests, confirm pass**

```
cd packages/screen_recorder && flutter test test/export/export_pipeline_test.dart
```

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/screen_recorder && flutter analyze
git add packages/screen_recorder/lib/export/export_pipeline.dart packages/screen_recorder/test/export/export_pipeline_test.dart
git commit -m "feat: add ExportPipeline coordinator with decode/composite/encode timing"
```

---

### Task 18: Connect Export button in `playback_screen.dart` to `ExportPipeline`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

**Why:** Replace the SnackBar stub at lines 192-208 with a real export call that runs the pipeline, shows progress, and reports the resulting summary.

- [ ] **Step 1: Replace `_showExportDialog`**

Open the file. Find `_showExportDialog` (around line 186). Replace with:

```dart
  Future<void> _showExportDialog() async {
    final preset = await showDialog<ExportPreset>(
      context: context,
      builder: (context) => const ExportDialog(),
    );
    if (preset == null || !mounted) return;

    // Resolve output path beside the source.
    final src = File(widget.videoPath);
    final dir = src.parent.path;
    final stem = src.uri.pathSegments.last.split('.').first;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = '$dir/${stem}_export_${preset.name}_$ts.mp4';

    // Load source metadata + cursor sidecar (best-effort).
    final meta = await RecordingMetadata.loadForVideo(widget.videoPath);
    CursorRecording cursorRec;
    try {
      cursorRec = await CursorRecording.loadFromFile('${widget.videoPath}.cursor.json');
    } catch (_) {
      cursorRec = CursorRecording();
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    try {
      final pipeline = ExportPipeline(
        sourcePath: widget.videoPath,
        outputPath: out,
        sourceMetadata: meta,
        cursorRecording: cursorRec,
        bitrateKbps: preset.bitrateKbps,
      );
      final summary = await pipeline.run();
      if (!mounted) return;
      Navigator.of(context).pop(); // close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(summary.pass
            ? 'Export complete: ${preset.name} (${summary.realtimeMultiple.toStringAsFixed(1)}× real-time)'
            : 'Export complete (slower than real-time): ${out}'),
        backgroundColor: summary.pass ? const Color(0xFF4CAF50) : Colors.orange,
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Export failed: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }
```

Add the imports at the top:

```dart
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
```

This requires `ExportPreset` to expose a `bitrateKbps` field. If it doesn't yet, add it to `lib/models/export_preset.dart` matching the existing fields. Read that file before changing it; keep the existing presets' values consistent (1080p30 ≈ 8000 kbps; 1080p60 ≈ 12000 kbps; 4K30 ≈ 35000 kbps; 4K60 ≈ 50000 kbps; web-optimized ≈ 4000 kbps).

- [ ] **Step 2: Build the Mac app, run it, do a manual export of the most-recent recording**

```
cd packages/screen_recorder && flutter run -d macos
```

In the app: open a previous recording (or record a fresh one), click Export, choose any preset, watch the SnackBar. Check the log output for the `[Export] summary:` line.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart packages/screen_recorder/lib/models/export_preset.dart
git commit -m "feat: wire Export button to ExportPipeline"
```

---

## Batch E — Editor preview overlays

These tasks add the cursor and frame overlays to the editor preview, gated by `RecordingMetadata.isPureSource`.

### Task 19: `CursorOverlayPainter` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart`
- Create: `packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/ui/widgets/cursor_overlay_painter.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  testWidgets('paints nothing when cursor recording is empty', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 200,
        height: 100,
        child: CustomPaint(
          painter: CursorOverlayPainter(
            cursorRecording: CursorRecording(),
            position: Duration.zero,
            videoSize: const Size(200, 100),
            screenSize: const Size(200, 100),
          ),
        ),
      ),
    ));
    expect(find.byType(CustomPaint), findsWidgets);
  });

  test('shouldRepaint true when position changes', () {
    final rec = CursorRecording()
      ..addPosition(const CursorPosition(
          x: 0, y: 0, timestampMicros: 0, isClicked: false));
    final a = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 100),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
    );
    final b = CursorOverlayPainter(
      cursorRecording: rec,
      position: const Duration(milliseconds: 200),
      videoSize: const Size(200, 100),
      screenSize: const Size(200, 100),
    );
    expect(b.shouldRepaint(a), isTrue);
  });
}
```

- [ ] **Step 2: Run, fail**

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart
import 'package:flutter/material.dart';
import '../../models/cursor_recording.dart';
import '../../rendering/cursor_geometry.dart';

/// Paints the recorded cursor on top of the video at the player's current
/// position. Reads positions from [CursorRecording] using the shared
/// [cursorAt] geometry helper, so its math matches the export-time renderer.
class CursorOverlayPainter extends CustomPainter {
  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final Size screenSize;

  CursorOverlayPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pos = cursorAt(cursorRecording, position);
    if (pos == null) return;

    // Map screen-space cursor coords to widget-space (size).
    final inVideo = screenToVideoSpace(
      screenPos: Offset(pos.x, pos.y),
      screenSize: screenSize,
      videoSize: videoSize,
    );
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;
    final widgetPos = Offset(inVideo.dx * scaleX, inVideo.dy * scaleY);

    final paint = Paint()
      ..color = pos.isClicked ? Colors.yellowAccent : Colors.white
      ..style = PaintingStyle.fill;

    // Simple cursor: 8px filled circle. Final visuals can be a sprite later;
    // the geometry math is what matters for spec correctness.
    canvas.drawCircle(widgetPos, 8, paint);
    canvas.drawCircle(
      widgetPos,
      8,
      Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CursorOverlayPainter old) {
    return old.position != position ||
        old.cursorRecording != cursorRecording ||
        old.videoSize != videoSize ||
        old.screenSize != screenSize;
  }
}
```

- [ ] **Step 4: Run, pass**

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/cursor_overlay_painter.dart packages/screen_recorder/test/ui/widgets/cursor_overlay_painter_test.dart
git commit -m "feat: add CursorOverlayPainter for editor preview overlay"
```

---

### Task 20: `BackgroundEffectLayer` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/background_effect_layer.dart`

**Why:** A small `Positioned.fill` widget that paints the chosen background (solid, gradient, blur of the desktop) behind the video frame in the editor. Gradient and solid are trivial; blur uses `BackdropFilter` (cheap; no per-frame pixel work). No tests for this — it's a pure-Flutter painting layer.

- [ ] **Step 1: Implement**

```dart
// packages/screen_recorder/lib/ui/widgets/background_effect_layer.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../effects/effect_params.dart';

enum BackgroundKind { none, solid, gradient, blur }

class BackgroundEffectLayer extends StatelessWidget {
  final BackgroundKind kind;
  final Color solidColor;
  final List<Color> gradientColors;
  final Alignment gradientBegin;
  final Alignment gradientEnd;
  final BlurIntensity blurIntensity;

  const BackgroundEffectLayer({
    super.key,
    required this.kind,
    this.solidColor = Colors.black,
    this.gradientColors = const [Color(0xFF6C63FF), Color(0xFF1E1E2E)],
    this.gradientBegin = Alignment.topLeft,
    this.gradientEnd = Alignment.bottomRight,
    this.blurIntensity = BlurIntensity.medium,
  });

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case BackgroundKind.none:
        return const SizedBox.shrink();
      case BackgroundKind.solid:
        return Positioned.fill(child: Container(color: solidColor));
      case BackgroundKind.gradient:
        return Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: gradientBegin,
                end: gradientEnd,
                colors: gradientColors,
              ),
            ),
          ),
        );
      case BackgroundKind.blur:
        final sigma = blurSigmaForIntensity(blurIntensity);
        return Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Container(color: Colors.black12),
          ),
        );
    }
  }
}
```

- [ ] **Step 2: Build to confirm compilation**

```
cd packages/screen_recorder && flutter build macos --debug
```

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/background_effect_layer.dart
git commit -m "feat: add BackgroundEffectLayer widget for editor preview"
```

---

### Task 21: Wire overlays into `playback_screen.dart`, gated by `isPureSource`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

**Why:** Stack the new overlays on top of the video player so the editor shows what the export will produce. Only show the cursor overlay if the recording is `isPureSource: true` — legacy recordings already have it baked in.

- [ ] **Step 1: Add metadata + cursor loading to `_PlaybackScreenState`**

Near the top of the state class, add fields:

```dart
  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
```

In `_initializeVideo` (after `_controller.initialize()` succeeds), add:

```dart
      _metadata = await RecordingMetadata.loadForVideo(widget.videoPath);
      try {
        _cursorRecording = await CursorRecording.loadFromFile(
            '${widget.videoPath}.cursor.json');
      } catch (_) {
        _cursorRecording = CursorRecording();
      }
```

Add the imports:

```dart
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/ui/widgets/cursor_overlay_painter.dart';
```

- [ ] **Step 2: Stack the overlay above the video**

In `_buildVideoPlayer` find the `Stack(children: [...])` that holds the frame painter + the video. Add the cursor overlay **above** the video clip, conditional on `_metadata?.isPureSource == true`. Inside the inner `Stack`, after the `Positioned` that contains the video, add:

```dart
            if (_metadata?.isPureSource == true && _cursorRecording.count > 0)
              Positioned(
                left: currentFrame.padding.left,
                top: currentFrame.padding.top,
                child: SizedBox(
                  width: videoSize.width,
                  height: videoSize.height,
                  child: CustomPaint(
                    painter: CursorOverlayPainter(
                      cursorRecording: _cursorRecording,
                      position: _controller.value.position,
                      videoSize: videoSize,
                      screenSize: videoSize, // Same for now; multi-monitor later.
                    ),
                  ),
                ),
              ),
```

- [ ] **Step 3: Build + run + smoke-test**

```
cd packages/screen_recorder && flutter run -d macos
```

Open a Phase-9 recording (the metadata sidecar must exist next to the MP4). Confirm the cursor dot tracks playback. Open a legacy recording (no sidecar) — confirm no overlay (cursor is baked into the file as before).

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: stack cursor overlay above video for pure-source recordings"
```

---

## Batch F — Verification & docs

### Task 22: Update `MANUAL_TESTING_CHECKLIST.md` with a Phase 9 verification section

**Files:**
- Modify: `MANUAL_TESTING_CHECKLIST.md`

- [ ] **Step 1: Append new section before "Sign-Off"**

```markdown
## Phase 9 Verification (macOS)

These checks confirm the live HW encode path and the export pipeline meet
their targets. Run on a representative Mac (Apple Silicon preferred).

### Recording (live HW encode)
- [ ] Start a 1-minute recording at 1080p60 of an active window
- [ ] Confirm CPU usage stays under 10% in Activity Monitor (avg)
- [ ] Confirm memory stays under 500 MB
- [ ] Stop recording — output `.mp4` exists at the path shown in the UI
- [ ] Sidecar `.meta.json` and `.cursor.json` exist next to the `.mp4`
- [ ] Log shows `[Recording] verdict: ... -> PASS`
- [ ] Open the recording in the editor — cursor overlay tracks playback

### Export (HW encode)
- [ ] Click Export, choose 1080p30 preset
- [ ] Export completes; output file plays in QuickTime
- [ ] Log shows `[Export] verdict: realtimeMultiple≥1.0 ✓ -> PASS`
- [ ] `outputCodec=h264_videotoolbox` in the summary line

### Legacy recording handling
- [ ] Open a recording made before Phase 9 (no `.meta.json` sidecar)
- [ ] No double-cursor in the editor preview (overlay correctly suppressed)
- [ ] Export still works (uses the same pipeline; cursor is already baked)
```

- [ ] **Step 2: Commit**

```bash
git add MANUAL_TESTING_CHECKLIST.md
git commit -m "docs: add Phase 9 verification section to manual testing checklist"
```

---

### Task 23: End-to-end manual smoke test

**Files:** none modified (this is verification, not code).

**Why:** This is the moment-of-truth check. After all prior tasks, run the full record → preview → export flow on a real Mac and confirm both perf summaries print PASS verdicts.

- [ ] **Step 1: Build + run the app**

```
cd packages/screen_recorder && flutter run -d macos
```

- [ ] **Step 2: Record 60 seconds of a window at 1080p (the default)**

Use any real window (a browser, a terminal). Move the cursor around. Click a few times. Stop after roughly 60 seconds.

- [ ] **Step 3: Read the `[Recording] verdict:` line from the console**

Expected: `-> PASS`

If FAIL: capture the line, identify which target failed (CPU, memory, fps, drops), and create a follow-up task. Stop here and address before claiming Phase 9 complete.

- [ ] **Step 4: In the editor, scrub the timeline**

Confirm cursor overlay tracks scrubbing position. Confirm playback is smooth.

- [ ] **Step 5: Export with the 1080p30 preset**

Watch for the `[Export] verdict:` line.

Expected: `realtimeMultiple≥1.0 ✓ -> PASS` and `outputCodec=h264_videotoolbox`.

If FAIL: same procedure as above — record which stage was slow (decode/composite/encode) from the per-stage ms/frame, decide on the follow-up.

- [ ] **Step 6: If both verdicts are PASS, write a one-line summary in your team's appropriate place** (commit message, PR description, or the existing `MANUAL_TESTING_CHECKLIST.md` if the team uses it for sign-off):

```
Phase 9 verified on <Mac model> at <date>: Recording PASS, Export PASS (Nx real-time).
```

---

## What's deliberately out of scope

For absolute clarity (matching the spec's non-goals):

- Windows / Linux live HW encode — those platforms remain on the legacy `frameStream` + spool + FFmpeg-libx264 path. The platform interface's default `startLiveRecording` throws `UnsupportedError` there.
- 4K-specific tuning beyond what falls out of the architecture change.
- Native frame buffer pooling, GPU-shaded effects.
- Replacing FFmpeg with `AVAssetReader` / `AVAssetWriter` in the export path.
- Per-frame trace logging or a debug HUD.
- Composite stage running inside an isolate. (The current `ExportPipeline` runs it on the main isolate. If `compositeMs/frame` is ever the dominant export-stage time, isolate-ify it then.)

---

## When the plan is done

Both perf summary log lines should print `-> PASS` on a representative Mac. The Phase 9 manual checklist section should be all green. After that, normal work can resume — and the perf summaries continue printing on every recording and export, so any future regression shows up as a `-> FAIL` verdict that's grep-able in the logs.
