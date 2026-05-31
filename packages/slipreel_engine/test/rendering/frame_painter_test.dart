import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
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

    test('calculateTotalSize uses uniform padding for OutputAspect.auto', () {
      final frame = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(30),
        cornerRadius: 0,
        shadowBlur: 0,
        shadowOffset: Offset.zero,
        shadowColor: const Color(0x00000000),
        borderWidth: 0,
      );
      final totalSize = FramePainter.calculateTotalSize(
        frame: frame,
        videoSize: const Size(320, 240),
      );
      // Uniform: 320 + 30 + 30 = 380; 240 + 30 + 30 = 300.
      expect(totalSize, const Size(380, 300));
    });

    test('calculateTotalSize honors explicit aspect (vertical9x16 grows height)', () {
      final frame = WindowFrame(
        name: 'Test',
        padding: EdgeInsets.zero,
        cornerRadius: 0,
        shadowBlur: 0,
        shadowOffset: Offset.zero,
        shadowColor: const Color(0x00000000),
        borderWidth: 0,
      );
      final totalSize = FramePainter.calculateTotalSize(
        frame: frame,
        videoSize: const Size(1920, 1080),
        aspect: OutputAspect.vertical9x16,
      );
      expect(totalSize.width, 1920);
      expect(totalSize.height, closeTo(1920 / (9 / 16), 1e-6));
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
