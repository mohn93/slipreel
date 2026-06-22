import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/rendering/caption_renderer.dart';

void main() {
  test('paint is a no-op when style disabled (no exception, empty picture)',
      () {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec, const Rect.fromLTWH(0, 0, 100, 100));
    CaptionRenderer.paint(
      canvas,
      const Size(100, 100),
      Duration.zero,
      const [CaptionSegment(id: 'a', startMicros: 0, endMicros: 1, text: 'x')],
      const CaptionStyle(),
    );
    expect(rec.endRecording(), isNotNull);
  });

  test('paint with enabled style + active segment does not throw', () {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec, const Rect.fromLTWH(0, 0, 640, 360));
    CaptionRenderer.paint(
      canvas,
      const Size(640, 360),
      const Duration(milliseconds: 5),
      const [
        CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000000, text: 'hi'),
      ],
      const CaptionStyle(enabled: true),
    );
    expect(rec.endRecording(), isNotNull);
  });
}
