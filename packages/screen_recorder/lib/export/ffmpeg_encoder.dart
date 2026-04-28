// packages/screen_recorder/lib/export/ffmpeg_encoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../utils/app_logger.dart';

/// Spawns `ffmpeg` to encode raw BGRA frames piped into its stdin.
/// Tries `h264_videotoolbox` first; falls back to `libx264` if startup fails.
class FfmpegEncoder {
  final String outputPath;
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;

  /// Optional path to the source MP4 — its audio track is muxed into the
  /// output via `-c:a copy` (no re-encode).
  final String? audioSourcePath;

  Process? _process;
  String _codecUsed = 'h264_videotoolbox';
  int totalEncodeMs = 0;
  final Stopwatch _sw = Stopwatch();

  String get codecUsed => _codecUsed;
  bool get usedHardware => _codecUsed == 'h264_videotoolbox';

  FfmpegEncoder({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    this.audioSourcePath,
  });

  List<String> _argsFor(String codec) {
    final args = <String>[
      '-loglevel', 'error',
      '-y',
      // Video input from stdin
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-s', '${width}x$height',
      '-r', '$fps',
      '-i', '-',
    ];
    if (audioSourcePath != null) {
      args.addAll(['-i', audioSourcePath!]);
      args.addAll(['-map', '0:v', '-map', '1:a:0']);
    }
    args.addAll([
      '-c:v', codec,
      '-b:v', '${bitrateKbps}k',
      '-pix_fmt', 'yuv420p',
    ]);
    if (audioSourcePath != null) {
      args.addAll(['-c:a', 'copy']);
    }
    args.add(outputPath);
    return args;
  }

  Future<void> start() async {
    Future<bool> tryCodec(String codec) async {
      final args = _argsFor(codec);
      AppLogger.ffmpeg.d('encode ($codec): ffmpeg ${args.join(" ")}');
      try {
        _process = await Process.start('ffmpeg', args);
        return true;
      } catch (e) {
        AppLogger.ffmpeg.w('ffmpeg start with $codec failed: $e');
        return false;
      }
    }

    if (await tryCodec('h264_videotoolbox')) {
      _codecUsed = 'h264_videotoolbox';
    } else if (await tryCodec('libx264')) {
      _codecUsed = 'libx264';
    } else {
      throw Exception('Could not start ffmpeg with any encoder');
    }
    _sw.start();
  }

  Future<void> writeFrame(Uint8List bgra) async {
    final p = _process;
    if (p == null) throw StateError('FfmpegEncoder.writeFrame before start');
    p.stdin.add(bgra);
    await p.stdin.flush();
  }

  Future<void> finish() async {
    final p = _process;
    if (p == null) return;
    await p.stdin.close();
    final exit = await p.exitCode;
    _sw.stop();
    totalEncodeMs = _sw.elapsedMilliseconds;
    if (exit != 0) {
      final err = await p.stderr.transform(SystemEncoding().decoder).join();
      throw Exception('ffmpeg encode exited $exit: $err');
    }
  }
}
