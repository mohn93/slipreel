import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';

void main() {
  group('recommendedVideoDecodeSize', () {
    test('downscales to the strongest zoom detail needed by output', () {
      expect(
        recommendedVideoDecodeSize(
          sourceSize: const Size(3840, 2160),
          composedCanvas: const Size(4000, 2400),
          outputSize: const Size(2000, 1200),
          maxZoom: 1,
        ),
        const Size(1920, 1080),
      );
      expect(
        recommendedVideoDecodeSize(
          sourceSize: const Size(3840, 2160),
          composedCanvas: const Size(4000, 2400),
          outputSize: const Size(2000, 1200),
          maxZoom: 2,
        ),
        const Size(3840, 2160),
      );
    });

    test('never upscales and can be disabled for device-frame geometry', () {
      expect(
        recommendedVideoDecodeSize(
          sourceSize: const Size(1280, 720),
          composedCanvas: const Size(1280, 720),
          outputSize: const Size(3840, 2160),
          maxZoom: 3,
        ),
        const Size(1280, 720),
      );
      expect(
        recommendedVideoDecodeSize(
          sourceSize: const Size(3840, 2160),
          composedCanvas: const Size(4000, 2400),
          outputSize: const Size(1000, 600),
          maxZoom: 1,
          allowDownscale: false,
        ),
        const Size(3840, 2160),
      );
    });
  });

  group('recommendedCameraDecodeSize', () {
    test('sizes the sidecar for its largest output PiP plus headroom', () {
      expect(
        recommendedCameraDecodeSize(
          sourceSize: const Size(1920, 1080),
          outputSize: const Size(1920, 1080),
          maxSizeFraction: 0.25,
          shapeAspect: 16 / 9,
        ),
        const Size(600, 338),
      );
    });

    test('clamps to native dimensions', () {
      expect(
        recommendedCameraDecodeSize(
          sourceSize: const Size(640, 480),
          outputSize: const Size(3840, 2160),
          maxSizeFraction: 1,
          shapeAspect: 4 / 3,
        ),
        const Size(640, 480),
      );
    });
  });
}
