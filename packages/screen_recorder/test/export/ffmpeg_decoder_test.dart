// packages/screen_recorder/test/export/ffmpeg_decoder_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/ffmpeg_decoder.dart';

void main() {
  group('FfmpegDecoder', () {
    test('decodes the test fixture into the expected number of frames', () async {
      final decoder = FfmpegDecoder(
        inputPath: 'test/fixtures/sample_recording.mp4',
        width: 320,
        height: 240,
      );
      final frames = <Uint8List>[];
      await decoder.frames().forEach(frames.add);
      // 30fps × 1s = 30 frames; allow ±2 for encoder rounding.
      expect(frames.length, inInclusiveRange(28, 32));
      // Each frame is W * H * 4 bytes (BGRA).
      expect(frames.first.length, 320 * 240 * 4);
      // Total decode time recorded.
      expect(decoder.totalDecodeMs, greaterThan(0));
    });

    test('throws on non-existent file', () async {
      final decoder = FfmpegDecoder(
        inputPath: '/nonexistent/path.mp4',
        width: 320,
        height: 240,
      );
      expect(decoder.frames().toList(), throwsException);
    });
  });
}
