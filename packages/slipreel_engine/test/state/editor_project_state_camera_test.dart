import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  const dur = Duration(seconds: 10);
  CameraRegion region() => CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 5),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      );

  group('EditorProjectState camera', () {
    test('defaults: enabled circle look, empty camera regions', () {
      final s = EditorProjectState.defaults();
      expect(s.cameraSettings, const CameraSettings());
      expect(s.cameraRegions, isEmpty);
    });

    test('schemaVersion is 10', () {
      expect(EditorProjectState.currentSchemaVersion, 10);
      expect(EditorProjectState.defaults().toJson()['schemaVersion'], 10);
    });

    test('json round-trips cameraSettings + cameraRegions', () {
      final s = EditorProjectState.defaults().copyWith(
        cameraSettings: const CameraSettings(shape: CameraShape.horizontal),
        cameraRegions: [region()],
      );
      final back = EditorProjectState.fromJson(s.toJson(), videoDuration: dur);
      expect(back.cameraSettings.shape, CameraShape.horizontal);
      expect(back.cameraRegions, [region()]);
    });

    test('copyWith(cameraRegions:) writes through to the first camera track '
        'without disturbing zoom regions or clips', () {
      final base = EditorProjectState.defaults().copyWith(
        timeline: Timeline(
          zoomTracks: const [ZoomTrack()],
          clips: EditorProjectState.defaults().timeline.clips,
          cameraTracks: const [],
        ),
      );
      final next = base.copyWith(cameraRegions: [region()]);
      expect(next.cameraRegions, [region()]);
      expect(next.timeline.clips, base.timeline.clips);
    });

    test('a v8 sidecar (no camera keys) migrates to v9 with defaults', () {
      final v8 = EditorProjectState.defaults().toJson()
        ..['schemaVersion'] = 8
        ..remove('cameraSettings');
      (v8['timeline'] as Map<String, dynamic>).remove('cameraTracks');
      final s = EditorProjectState.fromJson(v8, videoDuration: dur);
      expect(s.cameraSettings, const CameraSettings());
      expect(s.cameraRegions, isEmpty);
    });

    test('equality includes cameraSettings', () {
      final a = EditorProjectState.defaults();
      final b = a.copyWith(
          cameraSettings: const CameraSettings(opacity: 0.5));
      expect(a == b, isFalse);
    });
  });
}
