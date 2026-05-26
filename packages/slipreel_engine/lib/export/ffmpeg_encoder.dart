// packages/screen_recorder/lib/export/ffmpeg_encoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../utils/app_logger.dart';
import 'audio_mix_args.dart';

/// Pixel format of the raw frames arriving on the encoder's stdin.
///
/// `bgra` matches what the legacy decode→cursor-blit pipeline emits;
/// `rgba` matches what `ui.Image.toByteData(format: rawRgba)` emits, so
/// the FrameCompositor (which uses Flutter's Canvas) can pipe its output
/// directly without a per-frame channel swap in Dart.
enum FfmpegPixelFormat {
  bgra('bgra'),
  rgba('rgba');

  const FfmpegPixelFormat(this.ffmpegName);
  final String ffmpegName;
}

/// Spawns `ffmpeg` to encode raw BGRA/RGBA frames piped into its stdin.
/// Tries `h264_videotoolbox` first; falls back to `libx264` if startup fails.
///
/// [sourceWidth]/[sourceHeight] describe the raw frames arriving on stdin
/// (decoder output). [width]/[height] are the output dimensions. When they
/// differ a `-vf scale` filter is inserted automatically.
class FfmpegEncoder {
  final String outputPath;

  /// Output dimensions written to the MP4.
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;

  /// Dimensions of the raw frames piped into stdin (decoder/source res).
  final int sourceWidth;
  final int sourceHeight;

  /// Frame rate of the stream arriving on stdin (decoder/source rate).
  /// Tells ffmpeg how to interpret stdin timing — must match the rate the
  /// decoder is actually producing frames at, not the preset's [fps], or
  /// the encoded video plays at the wrong speed.
  final int sourceFps;

  /// Pixel format of frames arriving on stdin.
  final FfmpegPixelFormat pixelFormat;

  /// Optional path to the source MP4 carrying the recording's audio. When an
  /// [audioMixPlan] with audio is supplied, its audio streams are mixed and
  /// re-encoded to AAC into the output; otherwise the output has no audio.
  final String? audioSourcePath;

  /// When non-null and [AudioMixPlan.hasAudio], the export muxes audio from
  /// [audioSourcePath] through this ffmpeg filtergraph (per-track volume +
  /// amix downmix) instead of copying. Null/`!hasAudio` ⇒ video-only output.
  final AudioMixPlan? audioMixPlan;

  Process? _process;
  String _codecUsed = 'h264_videotoolbox';
  bool _hwEncoderConfirmed = false;
  int totalEncodeMs = 0;
  final Stopwatch _sw = Stopwatch();

  String get codecUsed => _codecUsed;
  bool get usedHardware => _hwEncoderConfirmed;

  FfmpegEncoder({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateKbps,
    this.audioSourcePath,
    this.audioMixPlan,
    int? sourceWidth,
    int? sourceHeight,
    int? sourceFps,
    this.pixelFormat = FfmpegPixelFormat.bgra,
  })  : sourceWidth = sourceWidth ?? width,
        sourceHeight = sourceHeight ?? height,
        sourceFps = sourceFps ?? fps;

  List<String> _argsFor(String codec) {
    final plan = audioMixPlan;
    final hasAudio = audioSourcePath != null && (plan?.hasAudio ?? false);
    final needsScale = width != sourceWidth || height != sourceHeight;

    final args = <String>[
      '-loglevel', 'error',
      '-y',
      '-f', 'rawvideo',
      '-pix_fmt', pixelFormat.ffmpegName,
      '-s', '${sourceWidth}x$sourceHeight',
      '-r', '$sourceFps',
      '-i', '-',
    ];

    final scaleChain =
        'scale=$width:$height:force_original_aspect_ratio=decrease,'
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1';

    if (hasAudio) {
      // Audio present: route video + audio through one -filter_complex so we
      // never mix -vf with -filter_complex (which can conflict).
      args.addAll(['-i', audioSourcePath!]);
      final videoChain =
          needsScale ? '[0:v]$scaleChain[vout]' : '[0:v]null[vout]';
      args.addAll(['-filter_complex', '$videoChain;${plan!.filterComplex!}']);
      args.addAll(['-map', '[vout]', '-map', plan.mapLabel!]);
      args.addAll(
          ['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      args.addAll(['-r', '$fps']);
      args.addAll(['-c:a', 'aac', '-b:a', '${plan.bitrateKbps}k']);
    } else {
      // Video only (today's path): -vf for scaling, no audio.
      args.addAll(
          ['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      if (needsScale) {
        args.addAll(['-vf', scaleChain]);
      }
      args.addAll(['-r', '$fps']);
    }
    args.add(outputPath);
    return args;
  }

  /// Test seam: the resolved ffmpeg arg list for [codec].
  List<String> argsForTesting(String codec) => _argsFor(codec);

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

    final stderr = await p.stderr.transform(SystemEncoding().decoder).join();

    if (exit != 0) {
      // Correct _codecUsed if VideoToolbox failed silently after start().
      if (_codecUsed == 'h264_videotoolbox' &&
          (stderr.contains('videotoolbox') ||
              stderr.contains('Error initializing'))) {
        _codecUsed = 'libx264';
      }
      throw Exception('ffmpeg encode exited $exit: $stderr');
    }

    // Confirm HW encoder actually engaged: exit 0 and no VT init errors.
    if (_codecUsed == 'h264_videotoolbox' &&
        !stderr.contains('videotoolbox') &&
        !stderr.contains('Error initializing')) {
      _hwEncoderConfirmed = true;
    }
  }
}
