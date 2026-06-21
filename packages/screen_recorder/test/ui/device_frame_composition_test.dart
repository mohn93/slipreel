// packages/screen_recorder/test/ui/device_frame_composition_test.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:screen_recorder/ui/widgets/zoom/device_frame_composition.dart';

Future<ui.Image> _img() async {
  final r = ui.PictureRecorder();
  ui.Canvas(r).drawRect(const Rect.fromLTWH(0, 0, 2, 2),
      Paint()..color = const Color(0xFFFF0000));
  return r.endRecording().toImage(2, 2);
}

void main() {
  testWidgets('positions video and bezel per layout', (tester) async {
    const layout = DeviceFrameLayout(
      canvasSize: Size(120, 240),
      bezelRect: Rect.fromLTWH(0, 0, 120, 240),
      screenRect: Rect.fromLTWH(10, 10, 100, 220),
      videoRect: Rect.fromLTWH(10, 10, 100, 220),
    );
    final image = await _img();
    await tester.pumpWidget(MaterialApp(
      home: DeviceFrameComposition(
        layout: layout,
        video: const ColoredBox(color: Color(0xFF00FF00), key: Key('video')),
        bezel: _TestImageProvider(image),
      ),
    ));
    final videoRect = tester.getRect(find.byKey(const Key('video')));
    expect(videoRect.width, closeTo(100, 0.5));
    expect(videoRect.height, closeTo(220, 0.5));
    expect(find.byType(Image), findsOneWidget);
  });
}

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  _TestImageProvider(this.image);
  final ui.Image image;
  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration c) async => this;
  @override
  ImageStreamCompleter loadImage(_TestImageProvider key, ImageDecoderCallback d) =>
      OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image)),
      );
}
