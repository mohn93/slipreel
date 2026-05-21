import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/frame_painter.dart';

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

    test('should calculate total size with aspect-scaled padding', () {
      final frame = WindowFrame.rounded();
      final videoSize = const Size(1920, 1080);

      final totalSize = FramePainter.calculateTotalSize(
        frame: frame,
        videoSize: videoSize,
      );

      // Rounded frame stores 72px padding. We aspect-scale X by the
      // video's aspect ratio (16/9) so the canvas keeps the video
      // aspect — otherwise the outer FittedBox would resize the whole
      // composition every time padding moves. Vertical padding stays
      // at the stored value.
      const aspect = 1920 / 1080;
      expect(totalSize.width, closeTo(1920 + 2 * 72 * aspect, 1e-9));
      expect(totalSize.height, equals(1080 + 144));
      expect(totalSize.width / totalSize.height,
          closeTo(aspect, 1e-9));
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
