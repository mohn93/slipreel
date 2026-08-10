// packages/screen_recorder/test/export/gif_export_pipeline_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/models/compression_bitrate.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

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

EditorProjectState _bareState() => EditorProjectState.defaults().copyWith(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GifExportPipeline', () {
    test(
      'end-to-end produces a non-empty valid GIF on the test fixture',
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
      },
    );

    test('onProgress is monotonically non-decreasing, ends at 1.0, '
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

        await pipeline.run(onProgress: (p) => progressValues.add(p));

        expect(progressValues, isNotEmpty);

        // Monotonically non-decreasing.
        for (var i = 1; i < progressValues.length; i++) {
          expect(
            progressValues[i],
            greaterThanOrEqualTo(progressValues[i - 1]),
            reason:
                'Progress went backwards at index $i: '
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

    test('progress reports the fraction of the EDITED output, matching '
        'the MP4 pipeline semantics', () async {
      // GIF progress previously measured "fraction of source frames
      // fed" (probed source duration as denominator, slices ignored).
      // MP4 reports "fraction of edited output completed" — the
      // forward-correct semantics once trimmed-away frames stop being
      // composed at all. Unify: lead-in frames (source time before
      // trimStart) contribute zero, and a failed probe no longer
      // silences the bar (the slice list is the denominator).
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_prog_trim');
      final outPath = '${tmp.path}/out.gif';

      final base = _bareState();
      final trimmed = base.copyWith(
        timeline: base.timeline.copyWith(
          clips: [
            ClipSlice(
              cutStart: Duration.zero,
              cutEnd: const Duration(seconds: 1),
              trimStart: const Duration(milliseconds: 500),
              trimEnd: const Duration(seconds: 1),
            ),
          ],
        ),
      );

      final reported = <double>[];
      try {
        await GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: trimmed,
          settings: _gifSettings(),
        ).run(onProgress: reported.add);

        expect(reported, isNotEmpty);
        for (var i = 1; i < reported.length; i++) {
          expect(
            reported[i],
            greaterThanOrEqualTo(reported[i - 1]),
            reason: 'progress must be monotonically non-decreasing',
          );
        }
        expect(reported.last, closeTo(1.0, 0.001));
        expect(
          reported.first,
          0.0,
          reason:
              'the first fed frame is at source t=0, before the '
              'trimStart — none of the edited output exists yet, so '
              'progress must read 0, not "1 source frame consumed"',
        );
        expect(
          reported.where((p) => p == 0.0).length,
          greaterThanOrEqualTo(3),
          reason:
              'every lead-in frame before trimStart must report 0.0 '
              'under edited-output semantics',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('palette tmp directory is removed after a successful run', () async {
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
        final paletteDir = pipeline.debugPaletteDirectoryPath;
        expect(paletteDir, isNotNull);
        expect(
          Directory(paletteDir!).existsSync(),
          isFalse,
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
      final paletteDir = pipeline.debugPaletteDirectoryPath;
      expect(paletteDir, isNotNull);
      expect(
        Directory(paletteDir!).existsSync(),
        isFalse,
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

    test(
      'lossless cache is capped and stale crash artifacts are reaped',
      () async {
        final tmp = Directory.systemTemp.createTempSync('gif_cache_cap_test');
        final stale = Directory(
          '${Directory.systemTemp.path}/slipreel_gif_cache_stale_'
          '${DateTime.now().microsecondsSinceEpoch}',
        )..createSync();
        final marker = File('${stale.path}/.created')
          ..writeAsStringSync(
            jsonEncode({
              'kind': 'slipreel-gif-cache',
              'version': 1,
              'ownerPid': 99999999,
              'createdAt': DateTime.now()
                  .subtract(const Duration(days: 2))
                  .toUtc()
                  .toIso8601String(),
            }),
          );
        await marker.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)),
        );
        final active = Directory(
          '${Directory.systemTemp.path}/slipreel_gif_cache_active_'
          '${DateTime.now().microsecondsSinceEpoch}',
        )..createSync();
        final activeMarker = File('${active.path}/.created')
          ..writeAsStringSync(
            jsonEncode({
              'kind': 'slipreel-gif-cache',
              'version': 1,
              'ownerPid': pid,
              'createdAt': DateTime.now()
                  .subtract(const Duration(days: 2))
                  .toUtc()
                  .toIso8601String(),
            }),
          );
        await activeMarker.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)),
        );
        final unowned = Directory(
          '${Directory.systemTemp.path}/slipreel_gif_cache_unowned_'
          '${DateTime.now().microsecondsSinceEpoch}',
        )..createSync();
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
          if (stale.existsSync()) stale.deleteSync(recursive: true);
          if (active.existsSync()) active.deleteSync(recursive: true);
          if (unowned.existsSync()) unowned.deleteSync(recursive: true);
        });
        final outPath = '${tmp.path}/out.gif';
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(),
          maxCacheBytes: 1024,
        );

        await expectLater(
          pipeline.run(),
          throwsA(isA<GifCacheLimitExceededException>()),
        );

        expect(stale.existsSync(), isFalse);
        expect(
          active.existsSync(),
          isTrue,
          reason: 'an old cache whose owner PID is alive must be preserved',
        );
        expect(
          unowned.existsSync(),
          isTrue,
          reason: 'a prefix match without an ownership marker is not ours',
        );
        expect(File(outPath).existsSync(), isFalse);
        expect(
          Directory(pipeline.debugPaletteDirectoryPath!).existsSync(),
          isFalse,
        );
      },
    );

    test('cache cap is enforced after the first submitted frame', () async {
      final tmp = Directory.systemTemp.createTempSync('gif_cache_first_frame');
      final outPath = '${tmp.path}/out.gif';
      var cacheLengthChecks = 0;
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final pipeline = GifExportPipeline(
        sourcePath: 'test/fixtures/sample_recording.mp4',
        outputPath: outPath,
        sourceMetadata: _metadata(),
        cursorRecording: CursorRecording(),
        projectState: _bareState(),
        settings: _gifSettings(),
        maxCacheBytes: 16 * 1024 * 1024,
        cacheLengthForTesting: (_) async {
          cacheLengthChecks++;
          // First call is the pre-write headroom check. The very next call is
          // the post-first-frame limit check and must abort immediately.
          return cacheLengthChecks == 1 ? 0 : 20 * 1024 * 1024;
        },
      );

      await expectLater(
        pipeline.run(),
        throwsA(isA<GifCacheLimitExceededException>()),
      );
      expect(File(outPath).existsSync(), isFalse);
      expect(
        Directory(pipeline.debugPaletteDirectoryPath!).existsSync(),
        isFalse,
      );
    });

    test(
      'low free space is rejected before pass 1 can write a 1080p frame',
      () async {
        final tmp = Directory.systemTemp.createTempSync('gif_cache_low_space');
        final outPath = '${tmp.path}/out.gif';
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(resolution: ExportResolution.r1080p),
          availableBytesForTesting: (_) async => 17 * 1024 * 1024,
        );
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        await expectLater(
          pipeline.run(),
          throwsA(isA<GifCacheLimitExceededException>()),
        );
        expect(File(outPath).existsSync(), isFalse);
        expect(
          Directory(pipeline.debugPaletteDirectoryPath!).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'marker write failure removes the newly-created cache directory',
      () async {
        final tmp = Directory.systemTemp.createTempSync('gif_marker_failure');
        addTearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: '${tmp.path}/unused.gif',
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState(),
          settings: _gifSettings(),
          writeCacheMarkerForTesting: (_) => throw StateError('marker failed'),
        );

        await expectLater(pipeline.run(), throwsA(isA<StateError>()));
        expect(pipeline.debugPaletteDirectoryPath, isNotNull);
        expect(
          Directory(pipeline.debugPaletteDirectoryPath!).existsSync(),
          isFalse,
        );
      },
    );

    test('Windows free-space output parser accepts byte counts', () {
      expect(parseWindowsFreeSpaceOutput('  123456789\r\n'), 123456789);
      expect(parseWindowsFreeSpaceOutput('not-a-number'), isNull);
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

        await expectLater(pipeline.run(), throwsA(isA<Exception>()));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('per-slice trim GIF export produces a non-empty valid GIF', () async {
      // B-era TrimSelection field is gone; per-slice trimStart/trimEnd
      // replaces it. This pins the same behavioural outcome (a trimmed
      // GIF still produces valid output) for the N-slice path.
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_trim');
      final outPath = '${tmp.path}/out.gif';

      try {
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState().copyWith(
            timeline: Timeline(
              clips: [
                ClipSlice(
                  cutStart: Duration.zero,
                  cutEnd: const Duration(seconds: 1),
                  trimStart: Duration.zero,
                  trimEnd: const Duration(milliseconds: 500),
                ),
              ],
            ),
          ),
          settings: _gifSettings(),
        );

        final summary = await pipeline.run();

        final file = File(outPath);
        expect(file.existsSync(), isTrue);
        expect(summary.outputBytes, greaterThan(0));

        final header = file.readAsBytesSync().sublist(0, 6);
        final headerStr = String.fromCharCodes(header);
        expect(
          headerStr == 'GIF87a' || headerStr == 'GIF89a',
          isTrue,
          reason: 'Expected GIF magic bytes, got: $headerStr',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('speed + fade GIF export produces a non-empty valid GIF', () async {
      final tmp = Directory.systemTemp.createTempSync('gif_pipe_speed_fade');
      final outPath = '${tmp.path}/out.gif';

      try {
        final pipeline = GifExportPipeline(
          sourcePath: 'test/fixtures/sample_recording.mp4',
          outputPath: outPath,
          sourceMetadata: _metadata(),
          cursorRecording: CursorRecording(),
          projectState: _bareState().copyWith(
            timeline: Timeline(
              clips: [
                ClipSlice(
                  cutStart: Duration.zero,
                  cutEnd: const Duration(seconds: 60),
                  playbackSpeed: 2.0,
                  fadeIn: const Duration(milliseconds: 200),
                  fadeOut: const Duration(milliseconds: 200),
                ),
              ],
            ),
          ),
          settings: _gifSettings(),
        );

        final summary = await pipeline.run();

        final file = File(outPath);
        expect(file.existsSync(), isTrue);
        expect(summary.outputBytes, greaterThan(0));

        final header = file.readAsBytesSync().sublist(0, 6);
        final headerStr = String.fromCharCodes(header);
        expect(
          headerStr == 'GIF87a' || headerStr == 'GIF89a',
          isTrue,
          reason: 'Expected GIF magic bytes, got: $headerStr',
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
