// packages/screen_recorder/lib/export/ffmpeg_decoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../models/trim_selection.dart';
import '../utils/app_logger.dart';
import 'ffmpeg_filters.dart';
import 'ffmpeg_resolver.dart';

/// Spawns `ffmpeg` to decode an input video into raw BGRA frames streamed
/// on stdout. Each emitted [Uint8List] is exactly `width * height * 4` bytes.
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

  /// When set, only decodes the slice [trim.start, trim.start + trim.duration]
  /// via the ffmpeg `trim` filter with PTS reset (`setpts=PTS-STARTPTS`).
  final TrimSelection? trim;

  /// Total wall-clock milliseconds spent reading/awaiting decoded bytes.
  /// Does not include subprocess spawn time.
  int totalDecodeMs = 0;

  Process? _process;

  FfmpegDecoder({
    required this.inputPath,
    required this.width,
    required this.height,
    this.cfrFps,
    this.trim,
  });

  @visibleForTesting
  List<String> argsForTesting() => _buildArgs();

  List<String> _buildArgs() {
    final vf = <String>[
      // Filter-based (`trim=`) seeking is frame-accurate but decodes from
      // frame 0 (accuracy over speed — slower for trims that start late in a
      // long source).
      if (trim != null)
        'trim=start=${ffSeconds(trim!.start)}:duration=${ffSeconds(trim!.duration)},'
            'setpts=PTS-STARTPTS',
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
    final buffer = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();

    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(stderrBuffer.write)
        .catchError((_) {}); // stderr is diagnostic only; never let it go unhandled

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
      await stderrDone;
      if (exit != 0) {
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
    _process?.kill(ProcessSignal.sigkill);
  }
}
