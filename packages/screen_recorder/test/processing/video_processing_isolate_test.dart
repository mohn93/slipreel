import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/processing/video_processing_isolate.dart';

void main() {
  group('VideoProcessingIsolate', () {
    test('should send initialization message and receive response', () async {
      final isolate = VideoProcessingIsolate();
      await isolate.initialize();
      expect(isolate.isInitialized, true);
      await isolate.dispose();
    });

    test('should configure encoder with video settings', () async {
      final isolate = VideoProcessingIsolate();
      await isolate.initialize();

      await isolate.configureEncoder(
        outputPath: '/tmp/test.mp4',
        width: 1920,
        height: 1080,
        fps: 30,
      );

      expect(isolate.isConfigured, true);
      await isolate.dispose();
    });
  });
}
