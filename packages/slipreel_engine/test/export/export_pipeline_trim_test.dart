// packages/slipreel_engine/test/export/export_pipeline_trim_test.dart
//
// End-to-end MP4 export test for the N-slice cut-tool model. The B-era
// top-level [TrimSelection] field on [ExportPipeline] is gone (subsumed by
// per-slice trimStart/trimEnd on state.timeline.clips). This test pins:
//
//   1. A single slice trimmed inward (trimStart > cutStart, trimEnd < cutEnd)
//      produces an output shorter than the source.
//   2. Two adjacent slices stitch into one output via the encoder's
//      filter_complex (per-slice trim, concat=n=2).
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _noneFrameState({required List<ClipSlice> clips}) {
  final base = EditorProjectState.defaults().copyWith(
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
  return base.copyWith(timeline: base.timeline.copyWith(clips: clips));
}

const _settings = ExportSettings(
  format: ExportFormat.mp4,
  resolution: ExportResolution.r720p,
  compression: CompressionTier.web,
  frameRate: 30,
  destination: ExportDestination.file,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('single inward-trimmed slice exports ~trimEnd-trimStart of video',
      () async {
    final tmp = Directory.systemTemp.createTempSync('slice_trim');
    final outPath = '${tmp.path}/out.mp4';

    // Fixture is ~1s. Cut at [0, 1s], trim inward to [0, 0.5s].
    final state = _noneFrameState(clips: [
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 1),
        trimStart: Duration.zero,
        trimEnd: const Duration(milliseconds: 500),
      ),
    ]);

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
      settings: _settings,
    ).run();

    final probed = await ffmpegProbe(path: outPath, metadataFps: 30);
    expect(probed.durationSec, isNotNull);
    expect(probed.durationSec!, lessThan(0.8),
        reason: 'trimmed export must be ~0.5s, not the full ~1s fixture');

    // Container including audio reflects the trim.
    final probe = await Process.run('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nokey=1:noprint_wrappers=1',
      outPath,
    ]);
    final containerDur = double.tryParse((probe.stdout as String).trim());
    expect(containerDur, isNotNull);
    expect(containerDur!, lessThan(0.8));
    tmp.deleteSync(recursive: true);
  });

  test('two adjacent slices concat into a stitched output', () async {
    final tmp = Directory.systemTemp.createTempSync('two_slice');
    final outPath = '${tmp.path}/out.mp4';

    // Two halves of the ~1s fixture. Total output should be ~1s.
    final state = _noneFrameState(clips: [
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(milliseconds: 400),
      ),
      ClipSlice(
        cutStart: const Duration(milliseconds: 400),
        cutEnd: const Duration(milliseconds: 800),
      ),
    ]);

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
      settings: _settings,
    ).run();

    final probed = await ffmpegProbe(path: outPath, metadataFps: 30);
    expect(probed.durationSec, isNotNull);
    // Two 0.4s slices ⇒ ~0.8s output. Wide tolerance for encoder rounding.
    expect(probed.durationSec!, inInclusiveRange(0.5, 1.1),
        reason: 'two-slice concat should be ~0.8s');
    tmp.deleteSync(recursive: true);
  });

  // Regression guard: the cooperative early-exit path relies on the encoder's
  // SocketException-as-stdin-closed translation + the pipeline's
  // decoder.kill()/queue.close() teardown. When the filter window is much
  // smaller than the decoded source, this path is exercised aggressively —
  // ffmpeg closes stdin almost immediately after the first ~100ms of frames
  // satisfy the trim, while the decoder still has ~900ms of frames queued
  // up. The output MP4 must still finalize cleanly at ~100ms.
  //
  // If this test fails, suspect: (a) the decoder's exit-code check now
  // treats SIGKILL-after-explicit-kill() as a hard failure instead of a
  // clean cooperative teardown, or (b) the encoder catches more than the
  // narrowed SocketException/FileSystemException pair (regressing Fix 1).
  test('aggressively trimmed slice (~100ms window inside a much longer cut) '
      'finalizes a valid MP4 via cooperative early-exit', () async {
    final tmp = Directory.systemTemp.createTempSync('aggressive_trim');
    final outPath = '${tmp.path}/out.mp4';

    // Fixture is ~1s. Cut declares [0, 1s] (the immutable source range),
    // trim cuts hard to [0, 100ms]. Decoder reads all 30 source frames;
    // the filter graph only wants ~3 frames; ffmpeg closes stdin early.
    final state = _noneFrameState(clips: [
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 1),
        trimStart: Duration.zero,
        trimEnd: const Duration(milliseconds: 100),
      ),
    ]);

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
      settings: _settings,
    ).run();

    final outFile = File(outPath);
    expect(outFile.existsSync(), isTrue,
        reason: 'cooperative early-exit must still produce an output file');
    expect(outFile.lengthSync(), greaterThan(1000),
        reason: 'output must be a real MP4, not a truncated fragment');

    final probed = await ffmpegProbe(path: outPath, metadataFps: 30);
    expect(probed.durationSec, isNotNull);
    expect(probed.durationSec!, inInclusiveRange(0.05, 0.15),
        reason: 'aggressive trim window of 100ms ± 50ms slop');
    tmp.deleteSync(recursive: true);
  });
}
