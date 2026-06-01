import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

void main() {
  group('OutputCanvasResolver.resolve', () {
    test('auto + square video + zero padding → canvas equals video', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1000, 1000),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.auto,
      );
      expect(r.canvasSize, const Size(1000, 1000));
      expect(r.videoRect, const Rect.fromLTWH(0, 0, 1000, 1000));
    });

    test('auto + 1920x1080 + uniform 50px padding → 2020x1180 canvas, video at (50,50)', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: const EdgeInsets.all(50),
        aspect: OutputAspect.auto,
      );
      expect(r.canvasSize, const Size(2020, 1180));
      expect(r.videoRect, const Rect.fromLTWH(50, 50, 1920, 1080));
    });

    test('wide16x9 on square 1000x1000 video → canvas grows horizontally', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1000, 1000),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.wide16x9,
      );
      expect(r.canvasSize.height, 1000);
      expect(r.canvasSize.width, closeTo(1000 * 16 / 9, 1e-6));
      final expectedDx = (r.canvasSize.width - 1000) / 2;
      expect(r.videoRect.left, closeTo(expectedDx, 1e-6));
      expect(r.videoRect.top, 0);
      expect(r.videoRect.width, closeTo(1000, 1e-6));
      expect(r.videoRect.height, closeTo(1000, 1e-6));
    });

    test('vertical9x16 on 1920x1080 video → canvas grows vertically', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.vertical9x16,
      );
      expect(r.canvasSize.width, 1920);
      expect(r.canvasSize.height, closeTo(1920 / (9 / 16), 1e-6));
      final expectedDy = (r.canvasSize.height - 1080) / 2;
      expect(r.videoRect.left, 0);
      expect(r.videoRect.top, closeTo(expectedDy, 1e-6));
      expect(r.videoRect.width, closeTo(1920, 1e-6));
      expect(r.videoRect.height, closeTo(1080, 1e-6));
    });

    test('square1x1 on 1920x1080 video → canvas grows vertically to 1920x1920', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: EdgeInsets.zero,
        aspect: OutputAspect.square1x1,
      );
      expect(r.canvasSize, const Size(1920, 1920));
      expect(r.videoRect, const Rect.fromLTWH(0, 420, 1920, 1080));
    });

    test('vertical9x16 on 1920x1080 + 50px padding → padded 2020x1180; canvas grows to 9:16', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: const Size(1920, 1080),
        padding: const EdgeInsets.all(50),
        aspect: OutputAspect.vertical9x16,
      );
      expect(r.canvasSize.width, 2020);
      expect(r.canvasSize.height, closeTo(2020 / (9 / 16), 1e-6));
      final innerDy = (r.canvasSize.height - 1180) / 2;
      expect(r.videoRect.left, closeTo(50, 1e-6));
      expect(r.videoRect.top, closeTo(innerDy + 50, 1e-6));
      expect(r.videoRect.width, 1920);
      expect(r.videoRect.height, 1080);
    });

    test('zero-size video returns zero canvas (defensive)', () {
      final r = OutputCanvasResolver.resolve(
        videoSize: Size.zero,
        padding: EdgeInsets.zero,
        aspect: OutputAspect.wide16x9,
      );
      expect(r.canvasSize, Size.zero);
      expect(r.videoRect, Rect.zero);
    });
  });
}
