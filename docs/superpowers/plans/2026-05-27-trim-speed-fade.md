# Trim / Speed / Fade Export Implementation Plan (Workstream A4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make MP4 and GIF exports honor the editor's trim selection, playback speed, and fade in/out — closing the Critical data-loss bug where a trimmed/slowed/faded clip exports full-length, full-speed, no-fade.

**Architecture:** Trim is applied at decode (ffmpeg `trim` filter + PTS reset) and the compositor's per-frame `position` is offset by `trim.start` so cursor/zoom stay aligned. Speed (`setpts`/`atempo`) and fades (`fade`/`afade`) are applied at encode, read from `EditorProjectState` (which already carries them). `playback_screen` passes its `_trimSelection` into the pipelines (the missing wiring).

**Tech Stack:** Dart, ffmpeg filtergraphs, Flutter test.

**Spec:** `docs/superpowers/specs/2026-05-26-critical-major-remediation-design.md` (Workstream A4; Critical #3)

**Branch:** `remediation/critical-major`

## Ground truth (from recon — do not re-derive)
- `EditorProjectState` already has `double playbackSpeed` (default 1.0), `Duration fadeIn`/`fadeOut` (default zero), persisted. Both export pipelines already receive `projectState` but ignore these three fields.
- `TrimSelection` (`packages/slipreel_engine/lib/models/trim_selection.dart`): `Duration start`, `Duration end`, `Duration get duration => end - start`, `contains()`, `copyWith()`. NOT on `EditorProjectState`; lives on `_PlaybackScreenState._trimSelection` and is NEVER passed to the pipeline today.
- `FfmpegDecoder.frames()` builds args `['-loglevel','error','-i',inputPath, if(cfrFps)...['-vf','fps=$cfrFps'], '-f','rawvideo','-pix_fmt','bgra','-']`. No seek.
- `ExportPipeline` compose loop: `tsMicros = (1000000 * index) ~/ pipelineFps; compositor.compose(bgra: raw, position: Duration(microseconds: tsMicros))`. `position` flows to `ScenePassBuilder` which samples cursor/zoom at that timestamp — so offsetting `position` by `trim.start` aligns cursor/zoom to the trimmed slice.
- `FfmpegEncoder._argsFor(codec)` builds the video chain `scaleChain = 'scale=W:H:force_original_aspect_ratio=decrease,pad=...,setsar=1'`. Two branches: **audio present** → everything via `-filter_complex` (`'[0:v]$scaleChain[vout]' or '[0:v]null[vout]'` ; `;${plan.filterComplex}` ; `-map [vout] -map ${plan.mapLabel}`); **video-only** → `-vf scaleChain` only when `needsScale`. `argsForTesting(codec)` exposes the arg list for unit tests.
- `AudioMixPlan` (`audio_mix_args.dart`): `filterComplex` produces audio at `mapLabel` (`[aout]`), `bitrateKbps`. `hasAudio` when both non-null.
- GIF pipeline: two passes, each `Process.start` with `-vf`(pass1 palettegen)/`-lavfi`(pass2 paletteuse) chains; a fresh `FfmpegDecoder(cfrFps: fps)` per pass; per-frame compose at `position = index/fps`. No audio.

## Shared helpers (created in Task 1, reused later)
A new `packages/slipreel_engine/lib/export/ffmpeg_filters.dart` with pure, unit-tested helpers:
- `String ffSeconds(Duration d)` → seconds with 6 decimals.
- `String setptsForSpeed(double speed)` → `'setpts=PTS/${_n(speed)}'`.
- `List<String> atempoChain(double speed)` → atempo factors each in [0.5, 2.0].
- `String speedAtempo(double speed)` → `atempoChain` joined by `,`.

---

## Task 1: ffmpeg filter helpers

**Files:**
- Create: `packages/slipreel_engine/lib/export/ffmpeg_filters.dart`
- Test: `packages/slipreel_engine/test/export/ffmpeg_filters_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/export/ffmpeg_filters_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_filters.dart';

void main() {
  group('ffSeconds', () {
    test('formats microseconds to 6-decimal seconds', () {
      expect(ffSeconds(const Duration(milliseconds: 1500)), '1.500000');
      expect(ffSeconds(Duration.zero), '0.000000');
    });
  });

  group('setptsForSpeed', () {
    test('emits PTS division by the speed', () {
      expect(setptsForSpeed(2.0), 'setpts=PTS/2.0');
      expect(setptsForSpeed(0.5), 'setpts=PTS/0.5');
    });
  });

  group('atempoChain', () {
    test('single factor when within [0.5, 2.0]', () {
      expect(atempoChain(1.5), [closeTo(1.5, 1e-9)]);
      expect(atempoChain(2.0), [closeTo(2.0, 1e-9)]);
      expect(atempoChain(0.5), [closeTo(0.5, 1e-9)]);
    });
    test('decomposes >2.0 into chained factors', () {
      final c = atempoChain(4.0);
      expect(c.length, 2);
      expect(c.reduce((a, b) => a * b), closeTo(4.0, 1e-9));
      expect(c.every((f) => f >= 0.5 && f <= 2.0), isTrue);
    });
    test('decomposes <0.5 into chained factors', () {
      final c = atempoChain(0.25);
      expect(c.reduce((a, b) => a * b), closeTo(0.25, 1e-9));
      expect(c.every((f) => f >= 0.5 && f <= 2.0), isTrue);
    });
  });

  group('speedAtempo', () {
    test('joins atempo filters with comma', () {
      expect(speedAtempo(1.5), 'atempo=1.5');
      expect(speedAtempo(4.0), 'atempo=2.0,atempo=2.0');
    });
  });
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_filters_test.dart`
Expected: FAIL (URI doesn't exist).

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/export/ffmpeg_filters.dart

/// Seconds with microsecond precision, for ffmpeg `st=`/`d=`/`start=` args.
String ffSeconds(Duration d) => (d.inMicroseconds / 1000000).toStringAsFixed(6);

/// Video PTS rescale for a playback-speed factor (2.0 ⇒ plays 2× faster).
String setptsForSpeed(double speed) => 'setpts=PTS/$speed';

/// ffmpeg's `atempo` only accepts a factor in [0.5, 2.0]; larger/smaller
/// speed changes must be chained. Returns the ordered per-filter factors
/// whose product equals [speed], each within [0.5, 2.0].
List<double> atempoChain(double speed) {
  final factors = <double>[];
  var s = speed;
  while (s > 2.0) {
    factors.add(2.0);
    s /= 2.0;
  }
  while (s < 0.5) {
    factors.add(0.5);
    s /= 0.5;
  }
  factors.add(s);
  return factors;
}

/// `atempo=...,atempo=...` chain implementing [speed] for audio.
String speedAtempo(double speed) =>
    atempoChain(speed).map((f) => 'atempo=$f').join(',');
```

- [ ] **Step 4: Run, verify pass**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_filters_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/ffmpeg_filters.dart packages/slipreel_engine/test/export/ffmpeg_filters_test.dart
git commit -m "feat(engine): ffmpeg filter helpers (ffSeconds, setpts, atempo chain)"
```

---

## Task 2: Trim in the decoder + MP4 pipeline

**Files:**
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_decoder.dart`
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Test: `packages/slipreel_engine/test/export/ffmpeg_decoder_test.dart` (add)
- Test: `packages/slipreel_engine/test/export/export_pipeline_trim_test.dart` (create)

- [ ] **Step 1: Write a failing decoder unit test for the trim filter**

`FfmpegDecoder` needs a test seam for its args. Add a `@visibleForTesting List<String> argsForTesting()` to the decoder (it builds the same arg list as `frames()`). First add this test to `test/export/ffmpeg_decoder_test.dart`:

```dart
  group('FfmpegDecoder trim args', () {
    test('no trim => -vf is just fps', () {
      final d = FfmpegDecoder(
          inputPath: 'in.mp4', width: 320, height: 240, cfrFps: 30);
      final vfIndex = d.argsForTesting().indexOf('-vf');
      expect(vfIndex, greaterThanOrEqualTo(0));
      expect(d.argsForTesting()[vfIndex + 1], 'fps=30');
    });

    test('trim => -vf has trim,setpts,fps in order', () {
      final d = FfmpegDecoder(
        inputPath: 'in.mp4',
        width: 320,
        height: 240,
        cfrFps: 30,
        trim: TrimSelection(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 3),
        ),
      );
      final args = d.argsForTesting();
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf,
          'trim=start=1.000000:duration=2.000000,setpts=PTS-STARTPTS,fps=30');
    });
  });
```
Add imports to the test file if missing: `import 'package:slipreel_engine/models/trim_selection.dart';`.

- [ ] **Step 2: Run, verify fail**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_decoder_test.dart`
Expected: FAIL — `trim` param and `argsForTesting` don't exist.

- [ ] **Step 3: Implement decoder trim**

In `ffmpeg_decoder.dart`:
- Add imports: `import 'package:flutter/foundation.dart' show visibleForTesting;`, `import '../models/trim_selection.dart';`, `import 'ffmpeg_filters.dart';`.
- Add field + ctor param: `final TrimSelection? trim;` and `this.trim,` in the constructor.
- Extract arg-building into a method and reuse it in `frames()`:
```dart
  @visibleForTesting
  List<String> argsForTesting() => _buildArgs();

  List<String> _buildArgs() {
    final vf = <String>[
      if (trim != null)
        'trim=start=${ffSeconds(trim!.start)}:duration=${ffSeconds(trim!.duration)},'
            'setpts=PTS-STARTPTS',
      if (cfrFps != null) 'fps=$cfrFps',
    ];
    return <String>[
      '-loglevel', 'error',
      '-i', inputPath,
      if (vf.isNotEmpty) ...['-vf', vf.join(',')],
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-',
    ];
  }
```
In `frames()`, replace the inline `final args = <String>[ ... ];` with `final args = _buildArgs();` (keep everything else — resolver, stderr drain, kill — intact).

- [ ] **Step 4: Run decoder test, verify pass**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_decoder_test.dart`
Expected: PASS (incl. the existing fixture decode tests, which have no trim).

- [ ] **Step 5: Write a failing MP4 trim integration test**

```dart
// packages/slipreel_engine/test/export/export_pipeline_trim_test.dart
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/trim_selection.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('trimmed MP4 export produces ~trim.duration of video', () async {
    final tmp = Directory.systemTemp.createTempSync('trim_test');
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

    // The fixture is ~1s. Trim to its first 0.5s.
    final trim = TrimSelection(
      start: Duration.zero,
      end: const Duration(milliseconds: 500),
    );

    await ExportPipeline(
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
      trim: trim,
    ).run();

    final probed = await ffmpegProbe(path: outPath, metadataFps: 30);
    expect(probed.durationSec, isNotNull);
    // ~0.5s ± 0.2s tolerance (encoder GOP / rounding).
    expect(probed.durationSec!, lessThan(0.8),
        reason: 'trimmed export must be ~0.5s, not the full ~1s fixture');
    tmp.deleteSync(recursive: true);
  });
}
```

- [ ] **Step 6: Implement trim in ExportPipeline**

In `export_pipeline.dart`:
- Add `import '../models/trim_selection.dart';`.
- Add field + ctor param: `final TrimSelection? trim;` and `this.trim,` (named, optional).
- Pass to decoder: in the `FfmpegDecoder(...)` construction add `trim: trim,`.
- Offset the compose position. In the compose loop, replace:
```dart
          final tsMicros = (1000000 * index) ~/ pipelineFps;
          ...
          final composited = await compositor.compose(
            bgra: raw,
            position: Duration(microseconds: tsMicros),
          );
```
with:
```dart
          final tsMicros = (1000000 * index) ~/ pipelineFps;
          // Decoded frames start at trim.start (the decoder reset PTS to 0),
          // but cursor/zoom timestamps are relative to the full recording —
          // so sample the scene at trim.start + elapsed.
          final scenePosition =
              (trim?.start ?? Duration.zero) + Duration(microseconds: tsMicros);
          ...
          final composited = await compositor.compose(
            bgra: raw,
            position: scenePosition,
          );
```
- Recompute `expectedFrames` for the trimmed range. Replace the `expectedFrames` IIFE so that when `trim != null` it uses the trim duration:
```dart
    final int? expectedFrames = () {
      if (trim != null) {
        return (trim!.duration.inMicroseconds / 1000000 * pipelineFps).round();
      }
      final dur = probed.durationSec;
      if (dur != null && dur > 0) {
        return (dur * pipelineFps).round();
      }
      final nb = probed.nbFrames;
      if (nb != null && probed.fps > 0) {
        return (nb * pipelineFps / probed.fps).round();
      }
      return null;
    }();
```

- [ ] **Step 7: Run trim tests + full export suite**

Run: `cd packages/slipreel_engine && flutter test test/export/`
Expected: PASS — the trim integration test confirms a ~0.5s output; existing tests still green.

- [ ] **Step 8: Commit**

```bash
git add packages/slipreel_engine/lib/export/ffmpeg_decoder.dart packages/slipreel_engine/lib/export/export_pipeline.dart packages/slipreel_engine/test/export/ffmpeg_decoder_test.dart packages/slipreel_engine/test/export/export_pipeline_trim_test.dart
git commit -m "feat(engine): apply trim selection in MP4 export (decoder seek + scene offset)"
```

---

## Task 3: Trim in the GIF pipeline

**Files:**
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart`
- Test: `packages/slipreel_engine/test/export/gif_export_pipeline_test.dart` (add a trim case, or a new file)

- [ ] **Step 1: Implement trim in GifExportPipeline**

In `gif_export_pipeline.dart`:
- Add `import '../models/trim_selection.dart';`.
- Add field + ctor param `final TrimSelection? trim;` / `this.trim,`.
- In BOTH pass-1 and pass-2 `FfmpegDecoder(...)` constructions, add `trim: trim,`.
- In BOTH pass loops, offset the compose position: replace `final tsMicros = (1000000 * index) ~/ fps;` usage so `compose(position: ...)` receives `(trim?.start ?? Duration.zero) + Duration(microseconds: tsMicros)`.
- In `_expectedFrames(probed, fps)`, when `trim != null` return `(trim!.duration.inMicroseconds / 1000000 * fps).round();` before the existing logic.

- [ ] **Step 2: Write/extend a GIF trim test**

Add to `test/export/gif_export_pipeline_test.dart` a test that runs a GIF export with `trim: TrimSelection(start: Duration.zero, end: const Duration(milliseconds: 500))` on the fixture and asserts the output GIF exists and is non-empty (GIF duration probing is unreliable; assert the file is produced and `_expectedFrames` halves — assert via output existence + that it differs in size from the untrimmed export, or simply that it is a valid non-empty GIF). Keep it minimal: assert `File(out).existsSync()` and `length > 0`.

- [ ] **Step 3: Run + commit**

Run: `cd packages/slipreel_engine && flutter test test/export/gif_export_pipeline_test.dart test/export/`
Expected: PASS.
```bash
git add packages/slipreel_engine/lib/export/gif_export_pipeline.dart packages/slipreel_engine/test/export/gif_export_pipeline_test.dart
git commit -m "feat(engine): apply trim selection in GIF export"
```

---

## Task 4: Speed + fade in the encoder + MP4 pipeline wiring

**Files:**
- Modify: `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart`
- Modify: `packages/slipreel_engine/lib/export/export_pipeline.dart`
- Test: `packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart` (add cases)

- [ ] **Step 1: Write failing encoder arg tests for speed + fade**

Add to `test/export/ffmpeg_encoder_args_test.dart` (add `import 'package:slipreel_engine/export/ffmpeg_filters.dart';` if needed):

```dart
  group('speed + fade filters', () {
    test('video-only: speed inserts setpts, fades insert fade in/out', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000,
        playbackSpeed: 2.0,
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 500),
        outputDuration: const Duration(seconds: 5),
      );
      final args = enc.argsForTesting('libx264');
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, contains('setpts=PTS/2.0'));
      expect(vf, contains('fade=t=in:st=0:d=0.500000'));
      expect(vf, contains('fade=t=out:st=4.500000:d=0.500000'));
    });

    test('no speed / no fade => no setpts/fade in video chain', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 200, height: 200, fps: 30,
        bitrateKbps: 2000, sourceWidth: 100, sourceHeight: 100);
      final args = enc.argsForTesting('libx264');
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, isNot(contains('setpts')));
      expect(vf, isNot(contains('fade=')));
    });

    test('audio present: speed adds atempo, fade adds afade after the mix', () {
      final enc = FfmpegEncoder(
        outputPath: '/tmp/o.mp4', width: 100, height: 100, fps: 30,
        bitrateKbps: 2000,
        audioSourcePath: '/tmp/in.mp4',
        audioMixPlan: const AudioMixPlan(
          filterComplex:
              '[1:a:0]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[aout]',
          mapLabel: '[aout]',
          bitrateKbps: 192,
        ),
        playbackSpeed: 2.0,
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 500),
        outputDuration: const Duration(seconds: 5),
      );
      final joined = enc.argsForTesting('libx264').join(' ');
      expect(joined, contains('atempo=2.0'));
      expect(joined, contains('afade=t=in:st=0:d=0.500000'));
      expect(joined, contains('afade=t=out:st=4.500000:d=0.500000'));
      // audio is remapped to the post-processed label, not the raw [aout]
      expect(joined, contains('-map [aoutx]'));
    });
  });
```

- [ ] **Step 2: Run, verify fail**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_encoder_args_test.dart`
Expected: FAIL — new ctor params + filter logic don't exist.

- [ ] **Step 3: Implement speed + fade in the encoder**

In `ffmpeg_encoder.dart`:
- Add `import 'ffmpeg_filters.dart';`.
- Add ctor params (named, defaulted): `this.playbackSpeed = 1.0`, `this.fadeIn = Duration.zero`, `this.fadeOut = Duration.zero`, `this.outputDuration` (nullable `Duration?`), with matching `final` fields: `final double playbackSpeed; final Duration fadeIn; final Duration fadeOut; final Duration? outputDuration;`.
- Replace `_argsFor`'s video-chain construction. Build a video filter list rather than the fixed `scaleChain`:
```dart
    final videoFilters = <String>[
      if (needsScale) ...[
        'scale=$width:$height:force_original_aspect_ratio=decrease',
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black',
      ],
      if (playbackSpeed != 1.0) setptsForSpeed(playbackSpeed),
      if (fadeIn > Duration.zero) 'fade=t=in:st=0:d=${ffSeconds(fadeIn)}',
      if (fadeOut > Duration.zero && outputDuration != null)
        'fade=t=out:st=${ffSeconds(outputDuration! - fadeOut)}:d=${ffSeconds(fadeOut)}',
      if (needsScale) 'setsar=1',
    ];
    final videoChain = videoFilters.join(',');
```
- In the `hasAudio` branch: replace the fixed `videoChain` label logic with:
```dart
      args.addAll(['-i', audioSourcePath!]);
      final vlabel = videoChain.isEmpty ? '[0:v]null[vout]' : '[0:v]$videoChain[vout]';
      // Audio post-processing (speed/fade) appended after the mix's [aout].
      final audioPost = <String>[
        if (playbackSpeed != 1.0) speedAtempo(playbackSpeed),
        if (fadeIn > Duration.zero) 'afade=t=in:st=0:d=${ffSeconds(fadeIn)}',
        if (fadeOut > Duration.zero && outputDuration != null)
          'afade=t=out:st=${ffSeconds(outputDuration! - fadeOut)}:d=${ffSeconds(fadeOut)}',
      ];
      final String audioMapLabel;
      final String audioGraph;
      if (audioPost.isEmpty) {
        audioGraph = plan!.filterComplex!;
        audioMapLabel = plan.mapLabel!;
      } else {
        audioGraph =
            '${plan!.filterComplex!};${plan.mapLabel!}${audioPost.join(',')}[aoutx]';
        audioMapLabel = '[aoutx]';
      }
      args.addAll(['-filter_complex', '$vlabel;$audioGraph']);
      args.addAll(['-map', '[vout]', '-map', audioMapLabel]);
      args.addAll(['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      args.addAll(['-r', '$fps']);
      args.addAll(['-c:a', 'aac', '-b:a', '${plan.bitrateKbps}k']);
```
- In the video-only branch: replace the `if (needsScale) args.addAll(['-vf', scaleChain]);` with:
```dart
      args.addAll(['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      if (videoChain.isNotEmpty) {
        args.addAll(['-vf', videoChain]);
      }
      args.addAll(['-r', '$fps']);
```
(Delete the now-unused `scaleChain` local.)

- [ ] **Step 4: Run encoder arg tests, verify pass**

Run: `cd packages/slipreel_engine && flutter test test/export/ffmpeg_encoder_args_test.dart`
Expected: PASS (incl. the existing 3 tests — no-audio, audio, video-only-scale — which have speed=1/fade=0 so emit no setpts/fade and behave as before).

- [ ] **Step 5: Wire speed/fade + outputDuration from the pipeline**

In `export_pipeline.dart`, where the `FfmpegEncoder(...)` is constructed, compute the trimmed/sped output duration and pass the three fields:
```dart
    final inputDurationSec = trim != null
        ? trim!.duration.inMicroseconds / 1000000
        : (probed.durationSec ?? 0);
    final outputDurationSec = inputDurationSec / projectState.playbackSpeed;
    final encoder = FfmpegEncoder(
      // ...existing args...
      playbackSpeed: projectState.playbackSpeed,
      fadeIn: projectState.fadeIn,
      fadeOut: projectState.fadeOut,
      outputDuration: outputDurationSec > 0
          ? Duration(microseconds: (outputDurationSec * 1000000).round())
          : null,
    );
```

- [ ] **Step 6: Run full suite + commit**

Run: `cd packages/slipreel_engine && flutter test test/export/`
Expected: PASS.
```bash
git add packages/slipreel_engine/lib/export/ffmpeg_encoder.dart packages/slipreel_engine/lib/export/export_pipeline.dart packages/slipreel_engine/test/export/ffmpeg_encoder_args_test.dart
git commit -m "feat(engine): apply playback speed + fades in MP4 export (setpts/atempo/fade/afade)"
```

---

## Task 5: Speed + fade in the GIF pipeline (video-only)

**Files:**
- Modify: `packages/slipreel_engine/lib/export/gif_export_pipeline.dart`
- Test: `packages/slipreel_engine/test/export/gif_export_pipeline_test.dart`

- [ ] **Step 1: Implement**

GIF has no audio, so only video `setpts`/`fade`. The pass-1 (`-vf ...palettegen`) and pass-2 (`-lavfi [0:v]...paletteuse`) chains build a scale/pad chain. Insert speed/fade into BOTH chains, computing `outputDurationSec = (trim?.duration ?? probed.durationSec) / projectState.playbackSpeed`:
- In pass 1's `-vf` string, after the `scale=...,pad=...` and before `palettegen`, insert (comma-joined, only when non-default): `setptsForSpeed(speed)`, `fade=t=in:st=0:d=${ffSeconds(fadeIn)}`, `fade=t=out:st=${ffSeconds(outDur - fadeOut)}:d=${ffSeconds(fadeOut)}`.
- In pass 2's `-lavfi`, the `[0:v]scale=...,pad=... [scaled]` segment gets the same inserts before `[scaled]`.
- Add `import 'ffmpeg_filters.dart';`.
Note: keep the existing palettegen/paletteuse filters intact; only insert the new video filters into the scale/pad portion.

- [ ] **Step 2: Test**

Add a GIF test that exports the fixture with `playbackSpeed: 2.0` (via `projectState.copyWith(playbackSpeed: 2.0)`) and fades, asserting the output GIF exists and is non-empty (exact duration of a GIF is hard to probe; assert validity + non-empty). Keep minimal.

- [ ] **Step 3: Run + commit**

Run: `cd packages/slipreel_engine && flutter test test/export/`
Expected: PASS.
```bash
git add packages/slipreel_engine/lib/export/gif_export_pipeline.dart packages/slipreel_engine/test/export/gif_export_pipeline_test.dart
git commit -m "feat(engine): apply playback speed + fades in GIF export"
```

---

## Task 6: Wire trim from playback_screen (end-to-end fix)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (the `_exportBody` pipeline construction, ~lines 534-550)

- [ ] **Step 1: Pass `_trimSelection` into both pipelines**

In `playback_screen.dart`, in `_exportBody`, both the `GifExportPipeline(...)` and `ExportPipeline(...)` constructions currently pass `projectState: _project, settings: settings` but no trim. Add `trim: _trimSelection,` to BOTH constructor calls. (Speed/fade already flow because both read `projectState.playbackSpeed/fadeIn/fadeOut`.) Guard: if `_trimSelection` covers the full clip (start == zero && end == duration) it's harmless to pass — the decoder trim filter just re-emits the whole clip; no special-casing needed.

- [ ] **Step 2: Verify the app analyzes + its export test still passes**

Run: `cd packages/screen_recorder && flutter analyze --no-fatal-infos lib/ui/screens/playback_screen.dart`
Expected: no new errors/warnings.
Run: `cd packages/screen_recorder && flutter test test/ui/screens/playback_screen_export_test.dart`
Expected: PASS (this test exercises the ExportDialog, unaffected by the trim wiring).

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "fix(app): pass trim selection into export pipelines (closes trim-dropped-on-export)"
```

---

## Self-Review

**Spec coverage (A4):**
- Trim → Tasks 2 (MP4 decoder + position offset + expectedFrames) + 3 (GIF) + 6 (UI wiring, end-to-end). ✓
- Playback speed → Tasks 4 (MP4 setpts + atempo) + 5 (GIF setpts). Read from projectState (already flows). ✓
- Fades → Tasks 4 (MP4 fade/afade) + 5 (GIF fade). ✓
- Helpers (Task 1) underpin all. ✓
- Cursor/zoom alignment after trim → Task 2 Step 6 (scene position offset by trim.start) + integration test asserts duration; the position-offset is the alignment mechanism the spec's risk note calls out.

**Placeholder scan:** No placeholders. Tasks 3 & 5 describe the GIF filter inserts in prose with exact filter fragments rather than a full file rewrite, because the GIF chains are long string literals already in the file — the implementer inserts the named fragments (`setptsForSpeed(speed)`, `fade=t=in:...`, `fade=t=out:...`) at the named positions (after `scale,pad`, before `palettegen`/`[scaled]`).

**Type consistency:** `ffSeconds`/`setptsForSpeed`/`speedAtempo` (Task 1) used in Tasks 2/4/5. `TrimSelection.start`/`.duration` used consistently. Encoder new params (`playbackSpeed`, `fadeIn`, `fadeOut`, `outputDuration`) defined in Task 4 Step 3 and supplied by the pipeline in Step 5. `[aoutx]` post-mix label consistent between Step 3 and the Step 1 test.

**Risks / confirm during execution:**
- `EditorProjectState` exposes `playbackSpeed`/`fadeIn`/`fadeOut` as assumed (recon-confirmed). If `ExportResolution`/probe field names differ, match existing usage in `export_pipeline_test.dart`.
- GIF duration assertions are weak (file-exists/non-empty) by necessity; the strong duration assertion is on the MP4 path (Task 2).
- The trim integration test tolerance (`<0.8s` for a 0.5s trim of a ~1s fixture) accounts for encoder GOP rounding; adjust if the fixture differs.
- `outputDuration` for fade-out uses trim/speed-derived duration; if both trim and probed duration are unavailable, fade-out is skipped (guarded by `outputDuration != null`).
