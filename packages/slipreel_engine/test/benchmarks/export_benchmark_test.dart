@TestOn('mac-os')
library;

// Repeatable export benchmark for before/after comparison of pipeline
// changes. Skipped by default (it renders ~3-6s of real export work);
// run explicitly with:
//
//   flutter test --run-skipped test/benchmarks/export_benchmark_test.dart
//
// Scenario: synthetic 1080p 30fps clip, padded window frame, one
// follow-cursor zoom region, cursor motion blur active, a mid-source
// slice trim — the representative shape of a real edited export, so it
// exercises decode, per-frame composition (chrome, zoom transform,
// accumulation cursor blur, focal track), GPU readback, and encode.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

// 720p/4s rather than a full-scale clip: flutter_tester rasterizes with
// the SOFTWARE Skia backend, so composition here is CPU-bound and much
// slower than the real app's GPU path. Absolute numbers are therefore
// pessimistic; the benchmark is for RELATIVE before/after comparison of
// pipeline changes, where the software path exaggerates (helpfully) the
// cost of extra raster passes and memcpys.
const _srcWidth = 1280;
const _srcHeight = 720;
const _srcFps = 30;
const _srcSeconds = 4;

Future<String> _synthesizeSource(Directory tmp) async {
  final path = '${tmp.path}/bench_source.mp4';
  final result = await Process.run(Ffmpeg.resolve(), [
    '-v', 'error', '-y',
    '-f', 'lavfi',
    '-i', 'testsrc2=size=${_srcWidth}x$_srcHeight:rate=$_srcFps',
    '-t', '$_srcSeconds',
    '-c:v', 'h264_videotoolbox',
    '-b:v', '8000k',
    '-pix_fmt', 'yuv420p',
    path,
  ]);
  if (result.exitCode != 0) {
    throw Exception('benchmark source synthesis failed: ${result.stderr}');
  }
  return path;
}

CursorRecording _sweepingCursor() {
  final r = CursorRecording();
  final rand = math.Random(42);
  var x = 200.0, y = 200.0;
  for (var t = 0; t < _srcSeconds * 1000; t += 16) {
    x = (x + 6 + rand.nextDouble() * 4).clamp(0.0, _srcWidth - 1.0);
    y = (y + math.sin(t / 400.0) * 8).clamp(0.0, _srcHeight - 1.0);
    final clicked = t % 2000 < 120;
    r.addPosition(CursorPosition(
      x: x,
      y: y,
      timestampMicros: t * 1000,
      isClicked: clicked,
    ));
  }
  return r;
}

EditorProjectState _benchState() {
  final base = EditorProjectState.defaults().copyWith(
    windowFrame: const WindowFrame(
      name: 'Bench',
      padding: EdgeInsets.all(64),
      cornerRadius: 12,
      shadowBlur: 24,
      shadowOffset: Offset(0, 8),
      shadowColor: Color(0x66000000),
      borderWidth: 0,
    ),
    motionBlur: 0.8,
    cursorMovementBlur: 0.8,
    zoomRegions: [
      ZoomRegion(
        rect: const Rect.fromLTWH(300, 200, 640, 360),
        startTime: const Duration(seconds: 1, milliseconds: 500),
        duration: const Duration(seconds: 1, milliseconds: 500),
        zoomLevel: 2.0,
        videoBounds: const Size(1280, 720),
      ),
    ],
  );
  return base.copyWith(
    timeline: base.timeline.copyWith(clips: [
      ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: _srcSeconds),
        trimStart: const Duration(seconds: 1),
        trimEnd: const Duration(seconds: 3),
      ),
    ]),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'export-benchmark',
    () async {
      final tmp = Directory.systemTemp.createTempSync('export_bench');
      try {
        final srcPath = await _synthesizeSource(tmp);
        final outPath = '${tmp.path}/bench_out.mp4';

        final summary = await ExportPipeline(
          sourcePath: srcPath,
          outputPath: outPath,
          sourceMetadata: RecordingMetadata(
            isPureSource: true,
            recordedAt: DateTime.now(),
            widthPx: _srcWidth,
            heightPx: _srcHeight,
            fps: _srcFps,
          ),
          cursorRecording: _sweepingCursor(),
          projectState: _benchState(),
          settings: const ExportSettings(
            format: ExportFormat.mp4,
            resolution: ExportResolution.r1080p,
            compression: CompressionTier.web,
            frameRate: 30,
            destination: ExportDestination.file,
          ),
        ).run();

        // The perf summary line is the benchmark output.
        // ignore: avoid_print
        print('BENCH ${summary.format()}');
        expect(File(outPath).existsSync(), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
    skip: 'Benchmark — run explicitly with --run-skipped',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
