// Golden pixels are host-specific (font hinting / AA differ across platforms),
// and these references were generated on macOS — the app's only target. Run
// them on the macOS job; the Linux (portable) CI job skips this file.
@TestOn('mac-os')
library;

import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/camera_shape.dart';
import 'package:slipreel_engine/rendering/camera_frame_painter.dart';

Future<ui.Image> solidImage(int w, int h, Color c) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = c);
  return rec.endRecording().toImage(w, h);
}

Future<ui.Image> render(CameraSettings settings, {double reveal = 1.0}) async {
  final cam = await solidImage(160, 120, const Color(0xFF3366FF));
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 300, 200),
      Paint()..color = const Color(0xFF101010)); // bg
  CameraFramePainter.paint(
    canvas,
    image: cam,
    pixelBox: const Rect.fromLTWH(90, 50, 120, 100),
    settings: settings,
    opacity: settings.opacity,
    reveal: reveal,
  );
  return rec.endRecording().toImage(300, 200);
}

class _LayerCountingCanvas implements ui.Canvas {
  int saveLayerCount = 0;

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    saveLayerCount++;
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('circle bubble matches golden', (tester) async {
    final img = await render(
      const CameraSettings(
          shape: CameraShape.circle,
          mirror: false,
          shadow: true,
          borderWidth: 4,
          borderColor: 0xFFFFFFFF),
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_circle.png'));
  });

  testWidgets('rounded-rect bubble matches golden', (tester) async {
    final img = await render(
      const CameraSettings(
          shape: CameraShape.horizontal,
          roundness: 0.5,
          mirror: true,
          shadow: false,
          borderWidth: 0),
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_rrect.png'));
  });

  testWidgets('steady state (opacity 1, reveal 1) skips the group '
      'saveLayer', (tester) async {
    // At full opacity with no reveal blur the layer is a pure no-op
    // group (alpha 1, no filter) — group compositing equals direct
    // drawing, so paying a full offscreen layer per exported frame for
    // it is pure waste. The goldens above pin pixel-identity of the
    // skip; this pins that the skip actually happens.
    final cam = await solidImage(160, 120, const Color(0xFF3366FF));
    final spy = _LayerCountingCanvas();
    CameraFramePainter.paint(
      spy,
      image: cam,
      pixelBox: const Rect.fromLTWH(90, 50, 120, 100),
      settings: const CameraSettings(
          shape: CameraShape.circle,
          mirror: false,
          shadow: true,
          borderWidth: 4,
          borderColor: 0xFFFFFFFF),
      opacity: 1.0,
      reveal: 1.0,
    );
    expect(spy.saveLayerCount, 0,
        reason: 'full-opacity steady state must not allocate a group layer');

    final fadedSpy = _LayerCountingCanvas();
    CameraFramePainter.paint(
      fadedSpy,
      image: cam,
      pixelBox: const Rect.fromLTWH(90, 50, 120, 100),
      settings: const CameraSettings(shape: CameraShape.circle),
      opacity: 0.5,
      reveal: 1.0,
    );
    expect(fadedSpy.saveLayerCount, 1,
        reason: 'partial opacity still needs the group layer so the '
            'shadow/image/border fade as one unit');
  });

  testWidgets('mid-reveal: faded, blurred, slid down (vanish/appear)',
      (tester) async {
    final img = await render(
      const CameraSettings(
          shape: CameraShape.circle,
          mirror: false,
          shadow: true,
          borderWidth: 4,
          borderColor: 0xFFFFFFFF),
      reveal: 0.5,
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_reveal_half.png'));
  });
}
