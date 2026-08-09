// packages/slipreel_engine/test/export/export_pipeline_output_res_test.dart
//
// Downscaled exports (source canvas larger than the export resolution)
// now render each frame at OUTPUT size inside FrameCompositor instead of
// canvas size + per-frame swscale (see FrameCompositor.renderSize). These
// end-to-end tests guard the pipeline wiring: the encoder's rawvideo
// dimensions, the blank gap buffers, and the filter graph's scale/pad
// stage must all agree with the compositor's render size, or the export
// breaks outright (frame-size mismatch) — and the output must still land
// at the requested resolution with real content.
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

EditorProjectState _noneFrameState({List<ClipSlice> clips = const []}) {
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
  widthPx: 1600,
  heightPx: 900,
  fps: 30,
);

Future<(int, int)> _probeDims(String path) async {
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
  return (int.parse(dims[0]), int.parse(dims[1]));
}

Future<double> _firstFrameMean(String path) async {
  final result = await Process.run('ffmpeg', [
    '-v',
    'error',
    '-i',
    path,
    '-frames:v',
    '1',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgb24',
    '-',
  ], stdoutEncoding: null);
  final bytes = result.stdout as List<int>;
  expect(bytes, isNotEmpty);
  var sum = 0;
  for (final b in bytes) {
    sum += b;
  }
  return sum / bytes.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String srcPath;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('output_res');
    srcPath = '${tmp.path}/src.mp4';
    // 1600×900 source — bigger than the 1280×720 export target, so the
    // compositor takes the downscale-render path.
    final gen = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1600x900:rate=30:duration=1',
      '-pix_fmt',
      'yuv420p',
      srcPath,
    ]);
    expect(gen.exitCode, 0, reason: 'fixture generation: ${gen.stderr}');
  });

  tearDownAll(() {
    tmp.deleteSync(recursive: true);
  });

  test('MP4 downscale export lands at 1280x720 with real content', () async {
    final outPath = '${tmp.path}/out.mp4';
    await ExportPipeline(
      sourcePath: srcPath,
      outputPath: outPath,
      sourceMetadata: _meta(),
      cursorRecording: CursorRecording(),
      projectState: _noneFrameState(),
      settings: const ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 30,
        destination: ExportDestination.file,
      ),
    ).run();

    expect(await _probeDims(outPath), (1280, 720));
    expect(
      await _firstFrameMean(outPath),
      greaterThan(10),
      reason: 'downscale-rendered frame must carry the source content',
    );
  });

  test(
    'MP4 downscale export with a trimmed slice (blank gap buffers at '
    'render size) still finalizes correctly',
    () async {
      final outPath = '${tmp.path}/out_trim.mp4';
      final summary = await ExportPipeline(
        sourcePath: srcPath,
        outputPath: outPath,
        sourceMetadata: _meta(),
        cursorRecording: CursorRecording(),
        projectState: _noneFrameState(
          clips: [
            ClipSlice(
              cutStart: Duration.zero,
              cutEnd: const Duration(seconds: 1),
              trimStart: const Duration(milliseconds: 500),
              trimEnd: const Duration(seconds: 1),
            ),
          ],
        ),
        settings: const ExportSettings(
          format: ExportFormat.mp4,
          resolution: ExportResolution.r720p,
          compression: CompressionTier.web,
          frameRate: 30,
          destination: ExportDestination.file,
        ),
      ).run();

      expect(summary.skippedCompositeFrames, greaterThanOrEqualTo(5));
      expect(await _probeDims(outPath), (1280, 720));
      expect(await _firstFrameMean(outPath), greaterThan(10));
    },
  );

  test('GIF downscale export lands at 1280x720 with real content', () async {
    final outPath = '${tmp.path}/out.gif';
    await GifExportPipeline(
      sourcePath: srcPath,
      outputPath: outPath,
      sourceMetadata: _meta(),
      cursorRecording: CursorRecording(),
      projectState: _noneFrameState(),
      settings: const ExportSettings(
        format: ExportFormat.gif,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 10,
        destination: ExportDestination.file,
      ),
    ).run();

    expect(await _probeDims(outPath), (1280, 720));
    expect(await _firstFrameMean(outPath), greaterThan(10));
  });
}
