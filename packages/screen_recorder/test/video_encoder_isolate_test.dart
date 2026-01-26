import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/video_encoder_isolate.dart';

void main() {
  group('VideoEncoderIsolate', () {
    test('should encode video using background isolate', () async {
      final encoder = VideoEncoderIsolate();

      await encoder.initialize(
        outputPath: '/tmp/test_isolate.mp4',
        width: 1920,
        height: 1080,
        fps: 30,
      );

      expect(encoder.isInitialized, true);

      final progressUpdates = <double>[];
      encoder.onProgress = (progress) {
        progressUpdates.add(progress);
      };

      // Add a few frames
      for (int i = 0; i < 3; i++) {
        final frameData = Uint8List(1920 * 1080 * 4);
        await encoder.addFrame(frameData, i * 33333);
      }

      final outputPath = await encoder.finalize();

      expect(outputPath, isNotEmpty);
      expect(progressUpdates, isNotEmpty);
      expect(encoder.frameCount, 3);
    });
  });
}
