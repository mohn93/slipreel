// packages/screen_recorder/test/export/ffmpeg_encoder_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/ffmpeg_encoder.dart';

void main() {
  group('FfmpegEncoder', () {
    test('encodes a stream of solid-color frames to a valid MP4', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_enc');
      final outPath = '${tmp.path}/out.mp4';

      final encoder = FfmpegEncoder(
        outputPath: outPath,
        width: 320,
        height: 240,
        fps: 30,
        bitrateKbps: 1000,
        audioSourcePath: 'test/fixtures/sample_recording.mp4',
      );

      // 30 solid red frames (BGRA).
      final frame = Uint8List(320 * 240 * 4);
      for (var i = 0; i < frame.length; i += 4) {
        frame[i] = 0; frame[i + 1] = 0; frame[i + 2] = 255; frame[i + 3] = 255;
      }

      await encoder.start();
      for (var i = 0; i < 30; i++) {
        await encoder.writeFrame(frame);
      }
      await encoder.finish();

      final file = File(outPath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(1000));
      expect(encoder.totalEncodeMs, greaterThan(0));

      tmp.deleteSync(recursive: true);
    });
  });
}
