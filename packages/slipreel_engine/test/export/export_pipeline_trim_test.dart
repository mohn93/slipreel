// packages/slipreel_engine/test/export/export_pipeline_trim_test.dart
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/trim_selection.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('trimmed MP4 export produces ~trim.duration of video', () async {
    final tmp = Directory.systemTemp.createTempSync('trim_test');
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

    // The fixture is ~1s. Trim to its first 0.5s.
    final trim = TrimSelection(
      start: Duration.zero,
      end: const Duration(milliseconds: 500),
    );

    await ExportPipeline(
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
      trim: trim,
    ).run();

    final probed = await ffmpegProbe(path: outPath, metadataFps: 30);
    expect(probed.durationSec, isNotNull);
    // ~0.5s ± 0.2s tolerance (encoder GOP / rounding).
    expect(probed.durationSec!, lessThan(0.8),
        reason: 'trimmed export must be ~0.5s, not the full ~1s fixture');

    // Guard against the audio not being trimmed: the container duration
    // (driven by the longest stream) must reflect the trim, not the full clip.
    final probe = await Process.run('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nokey=1:noprint_wrappers=1',
      outPath,
    ]);
    final containerDur = double.tryParse((probe.stdout as String).trim());
    expect(containerDur, isNotNull);
    expect(containerDur!, lessThan(0.8),
        reason: 'container (incl. audio) must reflect the 0.5s trim, not the full ~1s clip');
    tmp.deleteSync(recursive: true);
  });
}
