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

Future<ui.Image> render(CameraSettings settings, double originalAspect,
    {double reveal = 1.0}) async {
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
    originalAspect: originalAspect,
    opacity: settings.opacity,
    reveal: reveal,
  );
  return rec.endRecording().toImage(300, 200);
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
      160 / 120,
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
      160 / 120,
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_rrect.png'));
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
      160 / 120,
      reveal: 0.5,
    );
    await expectLater(img, matchesGoldenFile('goldens/camera_reveal_half.png'));
  });
}
