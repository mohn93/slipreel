// packages/screen_recorder/test/export/gif_export_pipeline_test.dart
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/gif_export_pipeline.dart';
import 'package:screen_recorder/models/compression_bitrate.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/state/editor_project_state.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ExportSettings _gifSettings({
  ExportResolution resolution = ExportResolution.r720p,
  CompressionTier compression = CompressionTier.web,
  int frameRate = 10,
}) => ExportSettings(
      format: ExportFormat.gif,
      resolution: resolution,
      compression: compression,
      frameRate: frameRate,
      destination: ExportDestination.file,
    );

EditorProjectState _bareState() => EditorProjectState.defaults().copyForTest(
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

RecordingMetadata _metadata() => RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.now(),
      widthPx: 320,
      heightPx: 240,
      fps: 30,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GifExportPipeline', () {
    test('end-to-end produces a non-empty valid GIF on the test fixture',
        () async {
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_e2e');
      final outPath = '${tmp.path}/out.gif';

      try {
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(),
        );

        final summary = await pipeline.run();

        // File exists and is non-empty
        final file = File(outPath);
        expect(file.existsSync(), isTrue);
        expect(summary.outputBytes, greaterThan(0));

        // First 6 bytes must be GIF87a or GIF89a
        final header = file.readAsBytesSync().sublist(0, 6);
        final headerStr = String.fromCharCodes(header);
        expect(
          headerStr == 'GIF87a' || headerStr == 'GIF89a',
          isTrue,
          reason: 'Expected GIF magic bytes, got: $headerStr',
        );

        // Sanity: < 5 MB for a 1-second 720p GIF
        expect(summary.outputBytes, lessThan(5 * 1024 * 1024));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('onProgress is monotonically non-decreasing, ends at 1.0, crosses 0.5',
        () async {
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_prog');
      final outPath = '${tmp.path}/out.gif';

      final progressValues = <double>[];

      try {
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(),
        );

        await pipeline.run(
          onProgress: (p) => progressValues.add(p),
        );

        expect(progressValues, isNotEmpty);

        // Monotonically non-decreasing
        for (var i = 1; i < progressValues.length; i++) {
          expect(
            progressValues[i],
            greaterThanOrEqualTo(progressValues[i - 1]),
            reason: 'Progress went backwards at index $i: '
                '${progressValues[i - 1]} → ${progressValues[i]}',
          );
        }

        // Ends at 1.0
        expect(progressValues.last, closeTo(1.0, 0.001));

        // Crosses 0.5 (both passes ran)
        expect(
          progressValues.any((p) => p >= 0.5),
          isTrue,
          reason: 'Progress never reached 0.5 — pass 2 may not have run',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('palette temp file is cleaned up after a successful run', () async {
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_cleanup');
      final outPath = '${tmp.path}/out.gif';

      try {
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(),
        );

        await pipeline.run();

        // The pipeline wrote the palette to a temp path inside tmp (or
        // the system tmp dir). Either way, no palette.png may survive
        // in the output dir.
        final leftover = Directory(tmp.path)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('palette.png'))
            .toList();
        expect(
          leftover,
          isEmpty,
          reason: 'Expected palette.png to be deleted; found: $leftover',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('gifPaletteSettings returns correct knobs for web tier', () {
      final s = gifPaletteSettings(CompressionTier.web);
      expect(s.maxColors, 128);
      expect(s.dither, 'bayer:bayer_scale=3');
    });
  });
}

// ---------------------------------------------------------------------------
// Test extension
// ---------------------------------------------------------------------------

extension on EditorProjectState {
  EditorProjectState copyForTest({WindowFrame? windowFrame}) {
    return EditorProjectState(
      zoomRegions: zoomRegions,
      screenAnimationConfig: screenAnimationConfig,
      cursorAnimationConfig: cursorAnimationConfig,
      cursorSize: cursorSize,
      cursorStyle: cursorStyle,
      cursorClickEffect: cursorClickEffect,
      hideCursorOverlay: hideCursorOverlay,
      motionBlur: motionBlur,
      windowFrame: windowFrame ?? this.windowFrame,
    );
  }
}
