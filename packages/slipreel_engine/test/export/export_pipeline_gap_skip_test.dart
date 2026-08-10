// packages/slipreel_engine/test/export/export_pipeline_gap_skip_test.dart
//
// Slice-aware composition skip: source frames that fall in trimmed-away
// gaps are dropped by ffmpeg's per-slice trim, so the pipelines feed a
// blank placeholder instead of paying full composition for them. These
// tests pin (a) that skipping actually happens (summary counter) and
// (b) that no blank frame ever leaks into the visible output — a margin
// bug at a trim boundary would flash a pure-black frame.
import 'dart:io';
import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

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

RecordingMetadata _meta() => RecordingMetadata(
  isPureSource: true,
  recordedAt: DateTime.now(),
  widthPx: 320,
  heightPx: 240,
  fps: 30,
);

/// Decodes every frame of [path] to rgb24 and returns each frame's mean
/// channel value. A blanked RGBA placeholder that leaked into the output
/// would decode as pure black (mean ≈ 0); the fixture's real content
/// averages ~127. Frame dimensions come from ffprobe so a resolution
/// change can't silently misalign the per-frame windows.
Future<List<double>> _frameMeans(String path) async {
  final probe = await Process.run('ffprobe', [
    '-v',
    'error',
    '-select_streams',
    'v:0',
    '-show_entries',
    'stream=width,height',
    '-of',
    'csv=p=0',
    path,
  ]);
  final dims = (probe.stdout as String).trim().split(',');
  expect(dims, hasLength(2), reason: 'ffprobe dims of $path');
  final w = int.parse(dims[0]);
  final h = int.parse(dims[1]);
  final result = await Process.run('ffmpeg', [
    '-v',
    'error',
    '-i',
    path,
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgb24',
    '-',
  ], stdoutEncoding: null);
  expect(result.exitCode, 0, reason: 'decode of $path failed');
  final bytes = result.stdout as List<int>;
  final frameSize = w * h * 3;
  final means = <double>[];
  for (var off = 0; off + frameSize <= bytes.length; off += frameSize) {
    var sum = 0;
    for (var i = off; i < off + frameSize; i++) {
      sum += bytes[i];
    }
    means.add(sum / frameSize);
  }
  return means;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MP4: back-half trim skips composition for the leading gap and no '
      'blank frame leaks into the output', () async {
    final tmp = Directory.systemTemp.createTempSync('gap_skip_mp4');
    final outPath = '${tmp.path}/out.mp4';

    // Fixture is ~1s @30fps. Trim to the back half [0.5s, 1s]: the first
    // ~15 source frames are pure gap — they must be blank-skipped, not
    // composed.
    final state = _noneFrameState(
      clips: [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 1),
          trimStart: const Duration(milliseconds: 500),
          trimEnd: const Duration(seconds: 1),
        ),
      ],
    );

    final summary = await ExportPipeline(
      sourcePath: 'test/fixtures/sample_recording.mp4',
      outputPath: outPath,
      sourceMetadata: _meta(),
      cursorRecording: CursorRecording(),
      projectState: state,
      settings: const ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 30,
        destination: ExportDestination.file,
      ),
    ).run();

    // ~15 gap frames minus the one-frame boundary margin — anything
    // clearly positive proves the skip path ran.
    expect(
      summary.skippedCompositeFrames,
      greaterThanOrEqualTo(5),
      reason:
          'a 0.5s leading gap at 30fps must skip composition for '
          'most of its frames',
    );

    final means = await _frameMeans(outPath);
    expect(
      means.length,
      inInclusiveRange(12, 18),
      reason: 'the retained 0.5s window should contain ~15 frames',
    );
    for (var i = 0; i < means.length; i++) {
      expect(
        means[i],
        greaterThan(10),
        reason:
            'output frame $i is near-black — a blanked gap frame '
            'leaked through the trim boundary',
      );
    }
    tmp.deleteSync(recursive: true);
  });

  test('MP4: untrimmed timeline skips nothing', () async {
    final tmp = Directory.systemTemp.createTempSync('gap_skip_none');
    final outPath = '${tmp.path}/out.mp4';

    final summary = await ExportPipeline(
      sourcePath: 'test/fixtures/sample_recording.mp4',
      outputPath: outPath,
      sourceMetadata: _meta(),
      cursorRecording: CursorRecording(),
      projectState: _noneFrameState(clips: const []),
      settings: const ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 30,
        destination: ExportDestination.file,
      ),
    ).run();

    expect(summary.skippedCompositeFrames, 0);
    tmp.deleteSync(recursive: true);
  });

  test(
    'MP4: a finalization failure removes the completed/partial output',
    () async {
      final tmp = Directory.systemTemp.createTempSync('mp4_finish_failure');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final outPath = '${tmp.path}/out.mp4';

      final pipeline = ExportPipeline(
        sourcePath: 'test/fixtures/sample_recording.mp4',
        outputPath: outPath,
        sourceMetadata: _meta(),
        cursorRecording: CursorRecording(),
        projectState: _noneFrameState(clips: const []),
        settings: const ExportSettings(
          format: ExportFormat.mp4,
          resolution: ExportResolution.r720p,
          compression: CompressionTier.web,
          frameRate: 30,
          destination: ExportDestination.file,
        ),
        finishForTesting: (encoder) async {
          await encoder.finish();
          throw Exception('simulated late mux/finalization failure');
        },
      );

      await expectLater(pipeline.run(), throwsException);
      expect(File(outPath).existsSync(), isFalse);
    },
  );

  test('MP4: cancellation during finalization stays a cancellation', () async {
    final tmp = Directory.systemTemp.createTempSync('mp4_finish_cancel');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final outPath = '${tmp.path}/out.mp4';
    final enteredFinish = Completer<void>();
    final releaseFinish = Completer<void>();
    final token = CancelToken();

    final pipeline = ExportPipeline(
      sourcePath: 'test/fixtures/sample_recording.mp4',
      outputPath: outPath,
      sourceMetadata: _meta(),
      cursorRecording: CursorRecording(),
      projectState: _noneFrameState(clips: const []),
      settings: const ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 30,
        destination: ExportDestination.file,
      ),
      finishForTesting: (encoder) async {
        enteredFinish.complete();
        await releaseFinish.future;
        await encoder.finish();
      },
    );

    final run = pipeline.run(cancelToken: token);
    await enteredFinish.future.timeout(const Duration(seconds: 20));
    token.cancel();
    releaseFinish.complete();

    await expectLater(run, throwsA(isA<ExportCancelledException>()));
    expect(File(outPath).existsSync(), isFalse);
  });

  test('GIF: back-half trim skips source composition and no blank '
      'frame leaks into the output', () async {
    final tmp = Directory.systemTemp.createTempSync('gap_skip_gif');
    final outPath = '${tmp.path}/out.gif';

    final state = _noneFrameState(
      clips: [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 1),
          trimStart: const Duration(milliseconds: 500),
          trimEnd: const Duration(seconds: 1),
        ),
      ],
    );

    final summary = await GifExportPipeline(
      sourcePath: 'test/fixtures/sample_recording.mp4',
      outputPath: outPath,
      sourceMetadata: _meta(),
      cursorRecording: CursorRecording(),
      projectState: state,
      settings: const ExportSettings(
        format: ExportFormat.gif,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 10,
        destination: ExportDestination.file,
      ),
    ).run();

    // ~5 leading source frames at 10fps are state-only; pass 2 now reads
    // the lossless pass-1 cache and performs no Flutter composition.
    expect(
      summary.skippedCompositeFrames,
      greaterThanOrEqualTo(4),
      reason: 'the GIF source pass must skip the leading gap',
    );

    final means = await _frameMeans(outPath);
    expect(
      means.length,
      inInclusiveRange(4, 6),
      reason: 'the retained 0.5s window should contain ~5 GIF frames',
    );
    for (var i = 0; i < means.length; i++) {
      expect(
        means[i],
        greaterThan(10),
        reason:
            'GIF frame $i is near-black — a blanked gap frame '
            'leaked through the trim boundary',
      );
    }
    tmp.deleteSync(recursive: true);
  });
}
