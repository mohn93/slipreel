import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/rendering/frame_painter.dart';

void main() {
  group('FramePainter', () {
    test('should create with frame and video size', () {
      final frame = WindowFrame.none();
      final videoSize = const Size(1920, 1080);

      final painter = FramePainter(
        frame: frame,
        videoSize: videoSize,
      );

      expect(painter.frame, equals(frame));
      expect(painter.videoSize, equals(videoSize));
    });

    test('should repaint when frame changes', () {
      final frame1 = WindowFrame.none();
      final frame2 = WindowFrame.rounded();
      final videoSize = const Size(1920, 1080);

      final painter1 = FramePainter(
        frame: frame1,
        videoSize: videoSize,
      );
      final painter2 = FramePainter(
        frame: frame2,
        videoSize: videoSize,
      );

      expect(painter1.shouldRepaint(painter2), isTrue);
    });

    test('should not repaint when frame is same', () {
      final frame = WindowFrame.none();
      final videoSize = const Size(1920, 1080);

      final painter1 = FramePainter(
        frame: frame,
        videoSize: videoSize,
      );
      final painter2 = FramePainter(
        frame: frame,
        videoSize: videoSize,
      );

      expect(painter1.shouldRepaint(painter2), isFalse);
    });

    test('should repaint when video size changes', () {
      final frame = WindowFrame.none();
      final videoSize1 = const Size(1920, 1080);
      final videoSize2 = const Size(1280, 720);

      final painter1 = FramePainter(
        frame: frame,
        videoSize: videoSize1,
      );
      final painter2 = FramePainter(
        frame: frame,
        videoSize: videoSize2,
      );

      expect(painter1.shouldRepaint(painter2), isTrue);
    });

    test('should calculate total size including padding', () {
      final frame = WindowFrame.rounded();
      final videoSize = const Size(1920, 1080);

      final totalSize = FramePainter.calculateTotalSize(
        frame: frame,
        videoSize: videoSize,
      );

      // Rounded frame has 72px padding on all sides.
      expect(totalSize.width, equals(1920 + 144));
      expect(totalSize.height, equals(1080 + 144));
    });

    test('should return video size when frame is none', () {
      final frame = WindowFrame.none();
      final videoSize = const Size(1920, 1080);

      final totalSize = FramePainter.calculateTotalSize(
        frame: frame,
        videoSize: videoSize,
      );

      // No padding when frame is 'None'
      expect(totalSize.width, equals(1920));
      expect(totalSize.height, equals(1080));
    });
  });
}
