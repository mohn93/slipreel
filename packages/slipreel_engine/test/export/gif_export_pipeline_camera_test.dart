import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// GIF camera parity: the MP4 pipeline composites the `.camera.mov`
/// sidecar (Plan 3) but the GIF pipeline shipped without any camera
/// wiring — a camera-enabled project previewed with a PiP bubble and
/// exported a GIF without one.
///
/// Strategy: run the same camera-enabled project twice, once with the
/// camera sidecars on disk and once without. The pipeline is
/// deterministic, so if the outputs are byte-identical the camera never
/// reached the compositor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GIF export composites the camera sidecar like the MP4 pipeline',
      () async {
    final tmp = Directory.systemTemp.createTempSync('gif_camera');
    try {
      final withCamPath = '${tmp.path}/with_cam.mp4';
      final noCamPath = '${tmp.path}/no_cam.mp4';
      File('test/fixtures/sample_recording.mp4')
        ..copySync(withCamPath)
        ..copySync(noCamPath);

      // Camera movie: reuse the fixture itself (decoded by content, the
      // .mov suffix is just the sidecar naming contract). Meta matches
      // the fixture's real 320x240 geometry.
      File('test/fixtures/sample_recording.mp4')
          .copySync(CameraSidecarMeta.moviePathForVideo(withCamPath));
      await const CameraSidecarMeta(
        deviceLabel: 'TestCam',
        width: 320,
        height: 240,
        frameCount: 30,
        offsetMicros: 0,
        selfViewX: 0.5,
        selfViewY: 0.5,
      ).saveForVideo(withCamPath);

      final base = EditorProjectState.defaults().copyWith(
        windowFrame: const WindowFrame(
          name: 'None',
          padding: EdgeInsets.zero,
          cornerRadius: 0,
          shadowBlur: 0,
          shadowOffset: Offset.zero,
          shadowColor: Color(0x00000000),
          borderWidth: 0,
        ),
        cameraSettings: const CameraSettings(enabled: true),
        cameraRegions: [
          CameraRegion(
            startTime: Duration.zero,
            duration: const Duration(seconds: 1),
            centerX: 0.5,
            centerY: 0.5,
            size: 0.4,
          ),
        ],
      );

      const settings = ExportSettings(
        format: ExportFormat.gif,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.web,
        frameRate: 10,
        destination: ExportDestination.file,
      );

      final meta = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.now(),
        widthPx: 320,
        heightPx: 240,
        fps: 30,
      );

      Future<List<int>> export(String srcPath, String outName) async {
        final outPath = '${tmp.path}/$outName';
        await GifExportPipeline(
          sourcePath: srcPath,
          outputPath: outPath,
          sourceMetadata: meta,
          cursorRecording: CursorRecording(),
          projectState: base,
          settings: settings,
        ).run();
        return File(outPath).readAsBytes();
      }

      final withCam = await export(withCamPath, 'with_cam.gif');
      final withoutCam = await export(noCamPath, 'no_cam.gif');

      expect(withCam, isNotEmpty);
      expect(withoutCam, isNotEmpty);

      final identical = withCam.length == withoutCam.length &&
          () {
            for (var i = 0; i < withCam.length; i++) {
              if (withCam[i] != withoutCam[i]) return false;
            }
            return true;
          }();
      expect(identical, isFalse,
          reason: 'A camera-enabled project with a .camera.mov sidecar '
              'must produce different GIF pixels than the same project '
              'without one — identical output means the camera overlay '
              'never reached the GIF compositor.');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
