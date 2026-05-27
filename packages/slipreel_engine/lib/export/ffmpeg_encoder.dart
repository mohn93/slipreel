// packages/screen_recorder/lib/export/ffmpeg_encoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../models/trim_selection.dart';
import '../utils/app_logger.dart';
import 'audio_mix_args.dart';
import 'ffmpeg_filters.dart';
import 'ffmpeg_resolver.dart';

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

  /// When set, the audio input is input-seek-trimmed (`-ss`/`-t`) to the same
  /// range as the (already-trimmed) video so the muxed output stays A/V-synced
  /// and the container length matches the trim. Null ⇒ full-length audio.
  final TrimSelection? trim;

  /// Playback-speed factor applied at encode (2.0 ⇒ 2× faster). 1.0 ⇒ no-op.
  /// Drives `setpts` on the video chain and `atempo` on the audio mix.
  final double playbackSpeed;

  /// Fade-in / fade-out durations applied at encode. Zero ⇒ no fade.
  /// Drive `fade`/`afade` on the video/audio chains.
  final Duration fadeIn;
  final Duration fadeOut;

  /// Duration of the encoded output (after trim + speed). Required to position
  /// the fade-out (`st = outputDuration - fadeOut`); when null, fade-out is
  /// skipped.
  final Duration? outputDuration;

  Process? _process;
  StringBuffer? _stderrBuffer;
  Future<void>? _stderrDone;
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
    this.trim,
    this.playbackSpeed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.outputDuration,
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

    // Video filter chain: scale/pad (when output res differs), then speed
    // (setpts) and fades, then setsar (only needed when we scaled/padded).
    final videoFilters = <String>[
      if (needsScale) ...[
        'scale=$width:$height:force_original_aspect_ratio=decrease',
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black',
      ],
      if (playbackSpeed != 1.0) setptsForSpeed(playbackSpeed),
      if (fadeIn > Duration.zero) 'fade=t=in:st=0:d=${ffSeconds(fadeIn)}',
      if (fadeOut > Duration.zero && outputDuration != null)
        'fade=t=out:st=${ffSeconds(outputDuration! - fadeOut)}:d=${ffSeconds(fadeOut)}',
      if (needsScale) 'setsar=1',
    ];
    final videoChain = videoFilters.join(',');

    if (hasAudio) {
      // Audio present: route video + audio through one -filter_complex so we
      // never mix -vf with -filter_complex (which can conflict).
      // Input-seek the audio to the trim range so it matches the
      // already-trimmed video; `[1:a:0]` in the mix plan then refers to the
      // trimmed audio.
      if (trim != null) {
        args.addAll(['-ss', ffSeconds(trim!.start), '-t', ffSeconds(trim!.duration)]);
      }
      args.addAll(['-i', audioSourcePath!]);
      final vlabel =
          videoChain.isEmpty ? '[0:v]null[vout]' : '[0:v]$videoChain[vout]';
      // Audio post-processing (speed/fade) appended after the mix's [aout].
      // The mix plan already trimmed the audio at the input (`-ss`/`-t`); these
      // operate on the mix output, so they compose with the input trim.
      final audioPost = <String>[
        if (playbackSpeed != 1.0) speedAtempo(playbackSpeed),
        if (fadeIn > Duration.zero) 'afade=t=in:st=0:d=${ffSeconds(fadeIn)}',
        if (fadeOut > Duration.zero && outputDuration != null)
          'afade=t=out:st=${ffSeconds(outputDuration! - fadeOut)}:d=${ffSeconds(fadeOut)}',
      ];
      final String audioMapLabel;
      final String audioGraph;
      if (audioPost.isEmpty) {
        audioGraph = plan!.filterComplex!;
        audioMapLabel = plan.mapLabel!;
      } else {
        audioGraph =
            '${plan!.filterComplex!};${plan.mapLabel!}${audioPost.join(',')}[aoutx]';
        audioMapLabel = '[aoutx]';
      }
      args.addAll(['-filter_complex', '$vlabel;$audioGraph']);
      args.addAll(['-map', '[vout]', '-map', audioMapLabel]);
      args.addAll(
          ['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      args.addAll(['-r', '$fps']);
      args.addAll(['-c:a', 'aac', '-b:a', '${plan.bitrateKbps}k']);
    } else {
      // Video only (today's path): -vf for the scale/speed/fade chain, no audio.
      args.addAll(
          ['-c:v', codec, '-b:v', '${bitrateKbps}k', '-pix_fmt', 'yuv420p']);
      if (videoChain.isNotEmpty) {
        args.addAll(['-vf', videoChain]);
      }
      args.addAll(['-r', '$fps']);
    }
    // Safety net: when trimming with audio, let the container length follow
    // the shorter stream so audio overhang can't extend the file past the
    // trimmed video. Only when trimming, to keep the no-trim arg shape that
    // existing tests pin unchanged.
    if (trim != null && hasAudio) args.add('-shortest');
    args.add(outputPath);
    return args;
  }

  /// Test seam: the resolved ffmpeg arg list for [codec].
  List<String> argsForTesting(String codec) => _argsFor(codec);

  Future<void> start() async {
    final binary = Ffmpeg.resolve();

    Future<bool> tryCodec(String codec) async {
      final args = _argsFor(codec);
      AppLogger.ffmpeg.d('encode ($codec): $binary ${args.join(" ")}');
      try {
        _process = await Process.start(binary, args);
        return true;
      } catch (e) {
        AppLogger.ffmpeg.w('$binary start with $codec failed: $e');
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
    final p = _process!;
    final buffer = StringBuffer();
    _stderrBuffer = buffer;
    _stderrDone = p.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(buffer.write)
        .catchError((_) {}); // stderr is diagnostic only; never let it go unhandled
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

    await _stderrDone;
    final stderr = _stderrBuffer?.toString() ?? '';

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

  /// Terminates the ffmpeg subprocess if running. Safe before start / after
  /// finish. Used to avoid orphaning ffmpeg on error/cancel.
  void kill() {
    _process?.kill(ProcessSignal.sigkill);
  }
}
