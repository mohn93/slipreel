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

      await isolate.processFrame(frameData, 0);

      expect(progressUpdates, isNotEmpty);
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

      final outputPath = await isolate.finalize();
      expect(outputPath, equals('/tmp/test_final.mp4'));

      await isolate.dispose();
    });
  });
}
