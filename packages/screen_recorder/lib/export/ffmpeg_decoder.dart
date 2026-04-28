// packages/screen_recorder/lib/export/ffmpeg_decoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../utils/app_logger.dart';

/// Spawns `ffmpeg` to decode an input video into raw BGRA frames streamed
/// on stdout. Each emitted [Uint8List] is exactly `width * height * 4` bytes.
class FfmpegDecoder {
  final String inputPath;
  final int width;
  final int height;

  /// Total wall-clock milliseconds spent reading/awaiting decoded bytes.
  /// Does not include subprocess spawn time.
  int totalDecodeMs = 0;

  FfmpegDecoder({
    required this.inputPath,
    required this.width,
    required this.height,
  });

  Stream<Uint8List> frames() async* {
    final args = [
      '-loglevel', 'error',
      '-i', inputPath,
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-',
    ];
    AppLogger.ffmpeg.d('decode: ffmpeg ${args.join(" ")}');

    final process = await Process.start('ffmpeg', args);
    final frameSize = width * height * 4;
    final buffer = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();

    try {
      await for (final chunk in process.stdout) {
        buffer.add(chunk);
        while (buffer.length >= frameSize) {
          final all = buffer.takeBytes();
          var offset = 0;
          while (all.length - offset >= frameSize) {
            yield Uint8List.fromList(all.sublist(offset, offset + frameSize));
            offset += frameSize;
          }
          if (offset < all.length) {
            buffer.add(all.sublist(offset));
          }
        }
      }
      final exit = await process.exitCode;
      if (exit != 0) {
        final stderr = await process.stderr
            .transform(SystemEncoding().decoder)
            .join();
        throw Exception('ffmpeg decode exited $exit: $stderr');
      }
    } finally {
      stopwatch.stop();
      totalDecodeMs = stopwatch.elapsedMilliseconds;
    }
  }
}
