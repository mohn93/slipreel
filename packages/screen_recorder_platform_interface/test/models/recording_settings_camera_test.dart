import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/recording_settings.dart';
import 'package:screen_recorder_platform_interface/src/models/camera_config.dart';

void main() {
  group('RecordingSettings.camera', () {
    test('defaults to null and serializes as null', () {
      const s = RecordingSettings(source: RecordingSource.screen);
      expect(s.camera, isNull);
      expect(s.toJson()['camera'], isNull);
    });

    test('round-trips a camera config through json', () {
      const s = RecordingSettings(
        source: RecordingSource.screen,
        camera: CameraConfig(deviceUid: 'cam', deviceLabel: 'FaceTime HD'),
      );
      final back = RecordingSettings.fromJson(s.toJson());
      expect(back.camera, const CameraConfig(deviceUid: 'cam', deviceLabel: 'FaceTime HD'));
    });

    test('copyWith can set and clear camera via the sentinel', () {
      const base = RecordingSettings(
        source: RecordingSource.screen,
        camera: CameraConfig(deviceUid: 'cam', deviceLabel: 'L'),
      );
      // Omitting camera preserves it.
      expect(base.copyWith(frameRate: 60).camera, isNotNull);
      // Passing null clears it.
      expect(base.copyWith(camera: null).camera, isNull);
    });
  });
}
