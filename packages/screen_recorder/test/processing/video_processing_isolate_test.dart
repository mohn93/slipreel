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
  });
}
