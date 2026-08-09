import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/rendering/caption_renderer.dart';

void main() {
  const segs = [
    CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000, text: 'one'),
    CaptionSegment(id: 'b', startMicros: 1000, endMicros: 2000, text: 'two'),
  ];

  group('activeCaptionAt', () {
    test('returns the segment whose half-open range contains t', () {
      expect(activeCaptionAt(segs, 500)?.text, 'one');
      expect(activeCaptionAt(segs, 1000)?.text, 'two');
      expect(activeCaptionAt(segs, 1999)?.text, 'two');
    });
    test('returns null in gaps / out of range', () {
      expect(activeCaptionAt(segs, 2000), isNull);
      expect(activeCaptionAt(const [], 0), isNull);
    });
  });

  group('captionFontSize', () {
    test('scales with canvas height and fontScale', () {
      final base = captionFontSize(1000, 1.0);
      expect(captionFontSize(2000, 1.0), closeTo(base * 2, 0.001));
      expect(captionFontSize(1000, 2.0), closeTo(base * 2, 0.001));
    });
  });

  group('layout memoization', () {
    // paint() ran TextPainter.layout on EVERY frame the caption was
    // visible — text shaping is one of the more expensive per-frame
    // costs, and the inputs only change when the segment or style does.
    const style = CaptionStyle(enabled: true);
    const size = ui.Size(640, 360);
    final segments = [
      const CaptionSegment(
        id: 'a',
        startMicros: 0,
        endMicros: 5000000,
        text: 'hello world',
      ),
      const CaptionSegment(
        id: 'b',
        startMicros: 5000000,
        endMicros: 9000000,
        text: 'second line',
      ),
    ];

    void paintAt(int ms) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        const ui.Rect.fromLTWH(0, 0, 640, 360),
      );
      CaptionRenderer.paint(
        canvas,
        size,
        Duration(milliseconds: ms),
        segments,
        style,
      );
      recorder.endRecording().dispose();
    }

    test('repeated frames of the same caption lay out once', () {
      CaptionRenderer.debugResetLayoutCache();
      paintAt(100);
      paintAt(200);
      paintAt(300);
      expect(CaptionRenderer.debugLayoutCount, 1,
          reason: 'same text/style/canvas must reuse the laid-out painter');
    });

    test('a different segment lays out again', () {
      CaptionRenderer.debugResetLayoutCache();
      paintAt(100); // segment a
      paintAt(6000); // segment b
      paintAt(6100); // segment b again — cached
      expect(CaptionRenderer.debugLayoutCount, 2);
    });

    test('cached paints are pixel-identical to fresh paints', () async {
      Future<Uint8List> bytesAt(int ms) async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(
          recorder,
          const ui.Rect.fromLTWH(0, 0, 640, 360),
        );
        CaptionRenderer.paint(
          canvas,
          size,
          Duration(milliseconds: ms),
          segments,
          style,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(640, 360);
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        picture.dispose();
        image.dispose();
        return data!.buffer.asUint8List();
      }

      CaptionRenderer.debugResetLayoutCache();
      final fresh = await bytesAt(100);
      final cached = await bytesAt(100);
      expect(cached, equals(fresh));
    });
  });
}
