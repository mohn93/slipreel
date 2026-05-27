// packages/screen_recorder/test/export/ffmpeg_decoder_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_decoder.dart';
import 'package:slipreel_engine/models/trim_selection.dart';

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

    test('cfrFps resamples a 30fps source to a different constant rate',
        () async {
      // Source is 30fps × 1s = 30 frames. Asking for 60fps must dup
      // frames so we end up with ~60 raw frames (allow ±2 for ffmpeg's
      // own rounding at fixture boundaries).
      final decoder = FfmpegDecoder(
        inputPath: 'test/fixtures/sample_recording.mp4',
        width: 320,
        height: 240,
        cfrFps: 60,
      );
      final frames = <Uint8List>[];
      await decoder.frames().forEach(frames.add);
      expect(frames.length, inInclusiveRange(58, 62));
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

  group('FfmpegDecoder trim args', () {
    test('no trim => -vf is just fps', () {
      final d = FfmpegDecoder(
          inputPath: 'in.mp4', width: 320, height: 240, cfrFps: 30);
      final vfIndex = d.argsForTesting().indexOf('-vf');
      expect(vfIndex, greaterThanOrEqualTo(0));
      expect(d.argsForTesting()[vfIndex + 1], 'fps=30');
    });

    test('trim => -vf has trim,setpts,fps in order', () {
      final d = FfmpegDecoder(
        inputPath: 'in.mp4',
        width: 320,
        height: 240,
        cfrFps: 30,
        trim: TrimSelection(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 3),
        ),
      );
      final args = d.argsForTesting();
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf,
          'trim=start=1.000000:duration=2.000000,setpts=PTS-STARTPTS,fps=30');
    });
  });
}
