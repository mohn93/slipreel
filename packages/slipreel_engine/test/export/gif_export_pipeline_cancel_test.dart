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
  });
}
