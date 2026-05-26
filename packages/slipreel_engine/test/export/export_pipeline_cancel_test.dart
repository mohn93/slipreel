import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExportPipeline cancellation', () {
    test(
      'a pre-cancelled token throws ExportCancelledException and produces no '
      'full MP4',
      () async {
        final tmp = Directory.systemTemp.createTempSync('cancel_pipe');
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

        final pipeline = ExportPipeline(
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

        // No complete MP4 should have been written. The file may not exist at
        // all, or be a tiny truncated fragment.
        final outFile = File(outPath);
        if (outFile.existsSync()) {
          expect(outFile.lengthSync(), lessThan(100000));
        }

        tmp.deleteSync(recursive: true);
      },
    );
  });
}
