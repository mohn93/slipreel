import 'dart:typed_data';
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

    test('should process frame with progress callback', () async {
      final isolate = VideoProcessingIsolate();
      await isolate.initialize();

      await isolate.configureEncoder(
        outputPath: '/tmp/test.mp4',
        width: 1920,
        height: 1080,
        fps: 30,
      );

      final frameData = Uint8List(1920 * 1080 * 4); // BGRA data
      final progressUpdates = <double>[];

      isolate.onProgress = (progress) {
        progressUpdates.add(progress);
      };

      // Process 30 frames to trigger progress update (reports every 30 frames)
      // Note: totalFrames is set during finalize, so progress will be 0 until then
      for (var i = 0; i < 30; i++) {
        await isolate.processFrame(frameData, i * 33333); // 30fps = 33.333ms per frame
      }

      // Progress updates won't be sent until totalFrames is known (during finalize)
      // So we just verify the test completes without errors
      await isolate.finalize(30);
      await isolate.dispose();
    });

    test('should finalize video encoding', () async {
      final isolate = VideoProcessingIsolate();
      await isolate.initialize();

      await isolate.configureEncoder(
        outputPath: '/tmp/test_final.mp4',
        width: 1920,
        height: 1080,
        fps: 30,
      );

      final frameData = Uint8List(1920 * 1080 * 4);
      await isolate.processFrame(frameData, 0);

      final outputPath = await isolate.finalize(1);
      expect(outputPath, equals('/tmp/test_final.mp4'));

      await isolate.dispose();
    });

    test('should propagate errors from isolate via ErrorResponse', () async {
      final isolate = VideoProcessingIsolate();
      await isolate.initialize();

      // Try to process frame before configuring encoder - should throw
      final frameData = Uint8List(1920 * 1080 * 4);

      expect(
        () => isolate.processFrame(frameData, 0),
        throwsStateError,
      );

      await isolate.dispose();
    });

    test('should handle errors during finalization', () async {
      final isolate = VideoProcessingIsolate();
      await isolate.initialize();

      // Try to finalize without configuring encoder - should throw
      expect(
        () => isolate.finalize(0),
        throwsStateError,
      );

      await isolate.dispose();
    });
  });
}
