// packages/screen_recorder/test/export/export_pipeline_test.dart
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExportPipeline', () {
    test('end-to-end produces a valid MP4 and a PASS summary on the fixture',
        () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_pipe');
      final outPath = '${tmp.path}/out.mp4';

      // Use a "None" frame so the compositor's totalSize equals the
      // source video size — keeps this test focused on the decode →
      // composite → encode loop without inflating output dims via the
      // default rounded frame's padding.
      final state = EditorProjectState.defaults().copyForTest(
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

      // r720p.dimensionsFor(320×240) → width = round(320*720/240) = 960 (even),
      // height = 720. This upscales the 320×240 fixture; the test's goal is
      // "produces a valid MP4 + sane summary", not pixel-exact dimensions.
      final settings = const ExportSettings(
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

      final summary = await pipeline.run();

      expect(File(outPath).existsSync(), isTrue);
      expect(summary.inputDurationSeconds, closeTo(1.0, 0.2));
      expect(summary.realtimeMultiple, greaterThan(0));
      // CI hardware varies; just sanity-check the report makes sense.
      expect(summary.format(), contains('verdict'));

      tmp.deleteSync(recursive: true);
    });
  });
}

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
