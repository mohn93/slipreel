// packages/screen_recorder/test/export/ffmpeg_decoder_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_decoder.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

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

    test('yielded frames are independently owned (queued frames must not '
        'alias a reused buffer)', () async {
      // The MP4 pipeline holds several frames in flight at once
      // (BoundedAsyncQueue capacity 2 per stage). If the decoder ever
      // reused one accumulator buffer across yields, every queued frame
      // would alias the latest bytes.
      final decoder = FfmpegDecoder(
        inputPath: 'test/fixtures/sample_recording.mp4',
        width: 320,
        height: 240,
      );
      final frames = <Uint8List>[];
      await decoder.frames().forEach(frames.add);
      expect(frames.length, greaterThan(2));
      expect(identical(frames[0], frames[1]), isFalse);
      expect(identical(frames[0].buffer, frames[1].buffer), isFalse,
          reason: 'distinct frames must not share an underlying buffer');
      final probe = frames[1][0];
      frames[0][0] = probe == 0 ? 255 : 0;
      expect(frames[1][0], probe,
          reason: 'mutating one frame must not affect another');
    });

    test('decoded pixels carry correct BGRA content (solid red source)',
        () async {
      // Pins channel order and frame-slicing offsets: a byte of drift
      // at a frame boundary or a channel swap shows up immediately on
      // a solid-color source. Near-equality because H.264 YUV
      // round-trips are not byte-exact.
      final tmp = Directory.systemTemp.createTempSync('decoder_content');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final srcPath = '${tmp.path}/red.mp4';
      final gen = await Process.run(Ffmpeg.resolve(), [
        '-v', 'error', '-y',
        '-f', 'lavfi',
        '-i', 'color=c=red:size=64x48:rate=10',
        '-t', '1',
        '-c:v', 'h264_videotoolbox',
        '-b:v', '500k',
        '-pix_fmt', 'yuv420p',
        srcPath,
      ]);
      expect(gen.exitCode, 0, reason: 'source synthesis: ${gen.stderr}');

      final decoder = FfmpegDecoder(
        inputPath: srcPath,
        width: 64,
        height: 48,
      );
      final frames = <Uint8List>[];
      await decoder.frames().forEach(frames.add);
      expect(frames, isNotEmpty);
      for (final frame in frames) {
        // Sample a few pixels across the frame: BGRA ⇒ [B, G, R, A].
        for (final px in [0, (frame.length ~/ 8) & ~3, frame.length - 4]) {
          expect(frame[px], lessThan(80), reason: 'blue channel at $px');
          expect(frame[px + 1], lessThan(80), reason: 'green channel at $px');
          expect(frame[px + 2], greaterThan(180),
              reason: 'red channel at $px');
          expect(frame[px + 3], 255, reason: 'alpha at $px');
        }
      }
    });

    test('kill() ends the frame stream cleanly — no decode-error throw', () async {
      // Cooperative early-exit: the pipeline kills the decoder mid-stream once
      // the encoder satisfies its trim. The resulting signal exit (-9) is an
      // intentional teardown and must NOT surface as a decode failure (the
      // throw racing the stream-cancel is what intermittently failed exports).
      final decoder = FfmpegDecoder(
        inputPath: 'test/fixtures/sample_recording.mp4',
        width: 320,
        height: 240,
      );
      final it = StreamIterator(decoder.frames());
      expect(await it.moveNext(), isTrue,
          reason: 'a frame in hand ⇒ ffmpeg is running when we kill it');
      decoder.kill();
      // Draining the rest must COMPLETE (return false), never throw, despite
      // the SIGKILL. Without the kill-aware guard this throws "exited -9".
      await expectLater(() async {
        while (await it.moveNext()) {}
      }(), completes);
    });
  });

  group('FfmpegDecoder args', () {
    test('no cfrFps => no -vf', () {
      final d = FfmpegDecoder(
        inputPath: 'in.mp4',
        width: 320,
        height: 240,
      );
      final args = d.argsForTesting();
      expect(args.contains('-vf'), isFalse);
    });

    test('cfrFps => -vf is just fps', () {
      final d = FfmpegDecoder(
          inputPath: 'in.mp4', width: 320, height: 240, cfrFps: 30);
      final args = d.argsForTesting();
      final vfIndex = args.indexOf('-vf');
      expect(vfIndex, greaterThanOrEqualTo(0));
      expect(args[vfIndex + 1], 'fps=30');
    });
  });
}
