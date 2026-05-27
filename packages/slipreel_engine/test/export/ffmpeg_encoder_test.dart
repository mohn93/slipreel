// packages/screen_recorder/test/export/ffmpeg_encoder_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_encoder.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

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
        sourceWidth: 320,
        sourceHeight: 240,
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
      // usedHardware must only be true after a clean finish() — not merely
      // because h264_videotoolbox was attempted.
      if (encoder.codecUsed == 'h264_videotoolbox') {
        expect(encoder.usedHardware, isTrue,
            reason: 'usedHardware must be true when VT encode succeeded cleanly');
      } else {
        expect(encoder.usedHardware, isFalse,
            reason: 'usedHardware must be false when libx264 fallback was used');
      }

      tmp.deleteSync(recursive: true);
    });
  });

  group('FfmpegEncoder ffmpeg resolution', () {
    tearDown(Ffmpeg.resetForTesting);

    test('start() throws FfmpegNotFoundException when ffmpeg is absent '
        '(not "Could not start with any encoder")', () async {
      Ffmpeg.resolver = FfmpegResolver(fileExists: (_) => false, pathEnv: '');
      final encoder = FfmpegEncoder(
        outputPath: '${Directory.systemTemp.path}/none.mp4',
        width: 320,
        height: 240,
        fps: 30,
        bitrateKbps: 2000,
      );
      await expectLater(encoder.start(), throwsA(isA<FfmpegNotFoundException>()));
    });
  });
}
