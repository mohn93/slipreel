@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Premise pin for FrameCompositor's per-frame return path.
///
/// The compositor used to make a "defensive copy" of every composed
/// frame on the theory that `Image.toByteData`'s buffer is owned by the
/// image and freed on `dispose()`. That premise is wrong for Flutter's
/// engine: the readback allocates a fresh buffer with its own lifetime
/// (engine `image_encoding.cc` copies the pixels into a new SkData
/// handed to Dart) — so the copy was a pure 10-60 MB-per-frame memcpy
/// tax. This test pins the engine contract the no-copy return relies
/// on; if a future engine ever aliases the buffer, the corruption
/// assertions here fail before any export does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('toByteData(rawRgba) buffer is independent of the source image',
      () async {
    const size = 64;
    const sizeD = 64.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, sizeD, sizeD),
    );
    canvas.drawColor(const Color(0xFF12AB56), BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    picture.dispose();

    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(byteData, isNotNull);
    final bytes = byteData!.buffer.asUint8List();
    final snapshot = Uint8List.fromList(bytes);

    image.dispose();
    // Allocate fresh images over the freed slot to maximize the chance
    // an aliased buffer would visibly change.
    for (var i = 0; i < 4; i++) {
      final r2 = ui.PictureRecorder();
      ui.Canvas(
        r2,
        const Rect.fromLTWH(0, 0, sizeD, sizeD),
      ).drawColor(const Color(0xFFFFFFFF), BlendMode.src);
      final p2 = r2.endRecording();
      (await p2.toImage(size, size)).dispose();
      p2.dispose();
    }

    expect(bytes, snapshot,
        reason: 'the readback buffer must remain valid and unchanged '
            'after the source image is disposed — FrameCompositor '
            'returns it without a defensive copy');
    expect(bytes[0], 0x12, reason: 'RGBA channel order, R first');
    expect(bytes[1], 0xAB);
    expect(bytes[2], 0x56);
    expect(bytes[3], 0xFF);
  });
}
