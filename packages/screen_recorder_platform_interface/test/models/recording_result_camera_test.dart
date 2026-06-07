// packages/screen_recorder_platform_interface/test/models/recording_result_camera_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/src/models/recording_result.dart';

void main() {
  test('parses camera fields when present', () {
    final r = RecordingResult.fromMap({
      'outputPath': '/tmp/r.mp4', 'width': 1920, 'height': 1080,
      'cameraFrameCount': 300, 'cameraWidth': 1280, 'cameraHeight': 720,
      'cameraOffsetMicros': 12000, 'cameraSelfViewX': 0.8, 'cameraSelfViewY': 0.75,
    });
    expect(r.cameraFrameCount, 300);
    expect(r.cameraWidth, 1280);
    expect(r.cameraHeight, 720);
    expect(r.cameraOffsetMicros, 12000);
    expect(r.cameraSelfViewX, 0.8);
    expect(r.cameraSelfViewY, 0.75);
    expect(r.hasCamera, isTrue);
  });

  test('absent camera fields => hasCamera false', () {
    final r = RecordingResult.fromMap({'outputPath': '/tmp/r.mp4', 'width': 1, 'height': 1});
    expect(r.cameraFrameCount, 0);
    expect(r.hasCamera, isFalse);
  });
}
