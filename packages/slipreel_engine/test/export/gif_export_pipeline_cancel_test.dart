import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GifExportPipeline cancellation', () {
    test(
      'a pre-cancelled token throws ExportCancelledException and leaves no '
      'GIF output',
      () async {
        final tmp = Directory.systemTemp.createTempSync('gif_cancel_pipe');
        final outPath = '${tmp.path}/out.gif';

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
          format: ExportFormat.gif,
          resolution: ExportResolution.r720p,
          compression: CompressionTier.web,
          frameRate: 10,
          destination: ExportDestination.file,
        );

        final pipeline = GifExportPipeline(
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
        );

        final token = CancelToken()..cancel();

        await expectLater(
          pipeline.run(cancelToken: token),
          throwsA(isA<ExportCancelledException>()),
        );

        // The translating catch deletes any partial output, so no GIF should
        // remain on disk.
        expect(File(outPath).existsSync(), isFalse);

        tmp.deleteSync(recursive: true);
      },
    );

    test(
      'cancellation mid-pass kills the decoder ffmpeg process (no orphan '
      'blocked on a full stdout pipe)',
      () async {
        // Contract pin. The pass loops only call decoder.kill() in the
        // stdin-closed cooperative-exit branches, so on an exception
        // thrown from inside the loop (here: the loop-top cancellation
        // check, firing on the first decoded frame because the token
        // was cancelled before the whenCancelled handler had a live
        // decoder to kill) the decoder is never explicitly killed. It
        // still must not survive: cancelling the frames() stream
        // closes the stdout pipe's read end and ffmpeg exits on EPIPE.
        // This test pins that no-orphan behavior — a decoder refactor
        // that detaches stdout from the consumer (background drain,
        // buffering isolate) would break the implicit cleanup and must
        // add an explicit kill on the exception path.
        final tmp = Directory.systemTemp.createTempSync('gif_leak');
        // Unique source name so the pgrep below can't match a decoder
        // owned by another concurrently-running test suite.
        final uniqueName =
            'leakprobe_${DateTime.now().microsecondsSinceEpoch}.mp4';
        final srcPath = '${tmp.path}/$uniqueName';
        File('test/fixtures/sample_recording.mp4').copySync(srcPath);
        final outPath = '${tmp.path}/out.gif';

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
          format: ExportFormat.gif,
          resolution: ExportResolution.r720p,
          compression: CompressionTier.web,
          frameRate: 10,
          destination: ExportDestination.file,
        );

        final pipeline = GifExportPipeline(
          sourcePath: srcPath,
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
        );

        final token = CancelToken()..cancel();
        await expectLater(
          pipeline.run(cancelToken: token),
          throwsA(isA<ExportCancelledException>()),
        );

        // A killed process disappears promptly; poll briefly to absorb
        // OS teardown latency, then require zero survivors.
        var alive = true;
        for (var i = 0; i < 30 && alive; i++) {
          final pgrep = await Process.run('pgrep', ['-f', uniqueName]);
          alive = pgrep.exitCode == 0;
          if (alive) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(alive, isFalse,
            reason: 'an ffmpeg process reading $uniqueName survived the '
                'cancelled export — the pass finally-block must kill the '
                'decoder');

        tmp.deleteSync(recursive: true);
      },
    );
  });
}
