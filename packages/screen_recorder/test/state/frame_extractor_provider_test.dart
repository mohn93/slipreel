import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/frame_extractor_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FrameKey has value equality and hashCode', () {
    const a = FrameKey('/v.mp4', 1000, 280, 600);
    const b = FrameKey('/v.mp4', 1000, 280, 600);
    const c = FrameKey('/v.mp4', 2000, 280, 600);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });

  test('decodeRgbaToImage builds a ui.Image of the requested size', () async {
    final bytes = Uint8List(2 * 2 * 4); // 2x2 transparent RGBA
    final ui.Image img = await decodeRgbaToImage(bytes, 2, 2);
    expect(img.width, 2);
    expect(img.height, 2);
  });
}
