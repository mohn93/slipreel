// packages/screen_recorder/lib/export/ffmpeg_decoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../utils/app_logger.dart';
import 'ffmpeg_resolver.dart';

/// Spawns `ffmpeg` to decode an input video into raw BGRA frames streamed
/// on stdout. Each emitted [Uint8List] is exactly `width * height * 4` bytes.
///
/// The decoder always reads the whole source. Slice-level trimming lives in
/// the encoder's `-filter_complex` (per-slice `trim=trimStart:trimEnd` nodes
/// built by `buildExportFilterGraph`); the decoder doesn't need to know
/// about cuts or trims any more.
class FfmpegDecoder {
  final String inputPath;
  final int width;
  final int height;

  /// When set, forces ffmpeg to resample the input to a constant frame
  /// rate via `-vf fps=N` before emitting raw bytes. Without this, the
  /// `rawvideo` muxer passes the source's native PTS through unchanged
  /// — which means VFR captures (SCStream skips frames when nothing on
  /// screen changes) arrive unevenly and any consumer that timestamps
  /// frames as `idx / fps` will desynchronize cursor motion / animation
  /// from screen content. With the filter applied ffmpeg drops or
  /// duplicates frames so the stream is exactly N frames per second.
  final int? cfrFps;

  /// Total wall-clock milliseconds spent reading/awaiting decoded bytes.
  /// Does not include subprocess spawn time.
  int totalDecodeMs = 0;

  Process? _process;

  /// Set when [kill] is called. A killed decoder exits with a signal code
  /// (e.g. -9), which is an EXPECTED cooperative teardown — the encoder
  /// satisfied its trim and the pipeline stopped the decoder — not a decode
  /// failure. Used to suppress the non-zero-exit throw in [frames] for that
  /// case while still surfacing genuine decode errors (non-zero exit we did
  /// NOT cause).
  bool _killed = false;

  FfmpegDecoder({
    required this.inputPath,
    required this.width,
    required this.height,
    this.cfrFps,
  });

  @visibleForTesting
  List<String> argsForTesting() => _buildArgs();

  List<String> _buildArgs() {
    final vf = <String>[
      if (cfrFps != null) 'fps=$cfrFps',
    ];
    return <String>[
      '-loglevel', 'error',
      '-i', inputPath,
      if (vf.isNotEmpty) ...['-vf', vf.join(',')],
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-',
    ];
  }

  Stream<Uint8List> frames() async* {
    final args = _buildArgs();
    final binary = Ffmpeg.resolve();
    AppLogger.ffmpeg.d('decode: $binary ${args.join(" ")}');

    final process = _process = await Process.start(binary, args);
    final frameSize = width * height * 4;
    final stopwatch = Stopwatch()..start();

    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(stderrBuffer.write)
        .catchError((_) {}); // stderr is diagnostic only; never let it go unhandled

    try {
      // Copy incoming chunks straight into a per-frame accumulator:
      // exactly one memcpy per byte. Each completed frame is yielded
      // and a fresh buffer allocated — consumers queue frames, so a
      // yielded buffer must never be reused. (The previous
      // BytesBuilder + sublist + fromList slicing copied every frame
      // 2-3x, ~an extra 33MB of memcpy per 4K frame on the hottest
      // producer in the pipeline.)
      var frame = Uint8List(frameSize);
      var filled = 0;
      await for (final chunk in process.stdout) {
        var offset = 0;
        while (offset < chunk.length) {
          final available = chunk.length - offset;
          final needed = frameSize - filled;
          final take = available < needed ? available : needed;
          frame.setRange(filled, filled + take, chunk, offset);
          filled += take;
          offset += take;
          if (filled == frameSize) {
            yield frame;
            frame = Uint8List(frameSize);
            filled = 0;
          }
        }
      }
      final exit = await process.exitCode;
      await stderrDone;
      // A non-zero exit is only a failure if WE didn't kill the process. The
      // cooperative early-exit path (encoder satisfied its trim → pipeline
      // calls decoder.kill()) terminates ffmpeg with a signal; that is a clean
      // teardown, not a decode error. Without this guard the SIGKILL (-9)
      // races the stream-cancel and intermittently fails the export.
      if (exit != 0 && !_killed) {
        throw Exception('ffmpeg decode exited $exit: $stderrBuffer');
      }
    } finally {
      stopwatch.stop();
      totalDecodeMs = stopwatch.elapsedMilliseconds;
    }
  }

  /// Terminates the ffmpeg subprocess if running. Safe before start / after
  /// exit. Used by the pipeline to avoid orphaning ffmpeg on error/cancel.
  void kill() {
    _killed = true;
    _process?.kill(ProcessSignal.sigkill);
  }
}
