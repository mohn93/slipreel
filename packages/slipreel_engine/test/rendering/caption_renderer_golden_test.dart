@TestOn('mac-os')
library;

import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/rendering/caption_renderer.dart';

Future<ui.Image> _render(CaptionStyle style) async {
  final recorder = ui.PictureRecorder();
  const size = Size(640, 360);
  final canvas = ui.Canvas(recorder, Offset.zero & size);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF335577));
  CaptionRenderer.paint(
    canvas,
    size,
    const Duration(milliseconds: 500),
    const [
      CaptionSegment(
          id: 'a', startMicros: 0, endMicros: 1000000, text: 'Hello, captions!'),
    ],
    style,
  );
  return recorder.endRecording().toImage(640, 360);
}

void main() {
  testWidgets('caption box golden', (tester) async {
    final img = await _render(const CaptionStyle(enabled: true));
    await expectLater(img, matchesGoldenFile('goldens/caption_box.png'));
  });

  testWidgets('caption outline golden', (tester) async {
    final img = await _render(const CaptionStyle(
        enabled: true, background: CaptionBackground.outline));
    await expectLater(img, matchesGoldenFile('goldens/caption_outline.png'));
  });
}
