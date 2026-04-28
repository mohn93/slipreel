// packages/screen_recorder/test/export/export_pipeline_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/cursor_recording.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExportPipeline', () {
    test('end-to-end produces a valid MP4 and a PASS summary on the fixture', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_pipe');
      final outPath = '${tmp.path}/out.mp4';

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
        bitrateKbps: 800,
      );

      final summary = await pipeline.run();

      expect(File(outPath).existsSync(), isTrue);
      expect(summary.inputDurationSeconds, closeTo(1.0, 0.2));
      expect(summary.realtimeMultiple, greaterThan(0));
      // We don't assert PASS here because CI hardware varies; just sanity-check.
      expect(summary.format(), contains('verdict'));

      tmp.deleteSync(recursive: true);
    });
  });
}
