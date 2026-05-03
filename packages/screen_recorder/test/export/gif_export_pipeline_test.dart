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

        // File exists and is non-empty.
        final file = File(outPath);
        expect(file.existsSync(), isTrue);
        expect(summary.outputBytes, greaterThan(0));

        // First 6 bytes must be GIF87a or GIF89a.
        final header = file.readAsBytesSync().sublist(0, 6);
        final headerStr = String.fromCharCodes(header);
        expect(
          headerStr == 'GIF87a' || headerStr == 'GIF89a',
          isTrue,
          reason: 'Expected GIF magic bytes, got: $headerStr',
        );

        // Sanity: < 5 MB for a 1-second 720p GIF.
        expect(summary.outputBytes, lessThan(5 * 1024 * 1024));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test(
        'onProgress is monotonically non-decreasing, ends at 1.0, '
        'reports values in both pass-1 and pass-2 ranges', () async {
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

        // Monotonically non-decreasing.
        for (var i = 1; i < progressValues.length; i++) {
          expect(
            progressValues[i],
            greaterThanOrEqualTo(progressValues[i - 1]),
            reason: 'Progress went backwards at index $i: '
                '${progressValues[i - 1]} → ${progressValues[i]}',
          );
        }

        // Ends at 1.0.
        expect(progressValues.last, closeTo(1.0, 0.001));

        // Pass 1 must have reported at least one value in (0, 0.5).
        expect(
          progressValues.any((p) => p > 0 && p < 0.5),
          isTrue,
          reason: 'pass 1 must report progress in (0, 0.5)',
        );

        // Pass 2 must have reported at least one value in (0.5, 1.0).
        expect(
          progressValues.any((p) => p > 0.5 && p < 1.0),
          isTrue,
          reason: 'pass 2 must report progress in (0.5, 1.0)',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('palette tmp directory is removed after a successful run', () async {
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_cleanup');
      final outPath = '${tmp.path}/out.gif';

      // Snapshot which gif_palette* directories already exist before we run.
      final paletteDirsBefore = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith('gif_palette'))
          .map((d) => d.path)
          .toSet();

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

        final paletteDirsAfter = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.split('/').last.startsWith('gif_palette'))
            .map((d) => d.path)
            .toSet();

        expect(
          paletteDirsAfter.difference(paletteDirsBefore),
          isEmpty,
          reason: 'pipeline must clean up its palette dir',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('palette tmp directory is removed even when pass 2 fails', () async {
      // Force a pass-2 failure by directing output to a path inside a
      // non-existent directory — ffmpeg cannot open the output file.
      final bogusOutput =
          '/tmp/nonexistent_dir_${DateTime.now().microsecondsSinceEpoch}/out.gif';

      final paletteDirsBefore = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith('gif_palette'))
          .map((d) => d.path)
          .toSet();

      final pipeline = GifExportPipeline(
        sourcePath: 'test/fixtures/sample_recording.mp4',
        outputPath: bogusOutput,
        sourceMetadata: _metadata(),
        cursorRecording: CursorRecording(),
        projectState: _bareState(),
        settings: _gifSettings(),
      );

      // The pipeline must throw because pass 2 cannot write its output.
      await expectLater(pipeline.run(), throwsA(isA<Exception>()));

      // Even though it threw, the palette directory must be cleaned up.
      final paletteDirsAfter = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith('gif_palette'))
          .map((d) => d.path)
          .toSet();

      expect(
        paletteDirsAfter.difference(paletteDirsBefore),
        isEmpty,
        reason: 'palette dir must be cleaned up even when pass 2 fails',
      );
    });

    test('partial output.gif is removed when pass 2 fails', () async {
      // Same failure scenario: output path in a non-existent parent dir.
      final bogusOutput =
          '/tmp/nonexistent_dir_${DateTime.now().microsecondsSinceEpoch}/out.gif';

      final pipeline = GifExportPipeline(
        sourcePath: 'test/fixtures/sample_recording.mp4',
        outputPath: bogusOutput,
        sourceMetadata: _metadata(),
        cursorRecording: CursorRecording(),
        projectState: _bareState(),
        settings: _gifSettings(),
      );

      await expectLater(pipeline.run(), throwsA(isA<Exception>()));

      // The (non-existent or partial) output file must not be left behind.
      expect(
        File(bogusOutput).existsSync(),
        isFalse,
        reason: 'partial output.gif must be deleted on pass 2 failure',
      );
    });

    test('throws with a message when pass 1 fails (bad source)', () async {
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_fail_p1');
      final outPath = '${tmp.path}/out.gif';

      try {
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/does_not_exist.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(),
        );

        await expectLater(
          pipeline.run(),
          throwsA(isA<Exception>()),
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

    test('constructor throws ArgumentError when format is not gif', () {
      expect(
        () => GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: '/tmp/out.mp4',
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: ExportSettings(
            format: ExportFormat.mp4,
            resolution: ExportResolution.r720p,
            compression: CompressionTier.web,
            frameRate: 30,
            destination: ExportDestination.file,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
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
