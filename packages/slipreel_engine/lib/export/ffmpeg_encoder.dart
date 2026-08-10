// packages/screen_recorder/lib/export/ffmpeg_encoder.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../utils/app_logger.dart';
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
/// Two modes:
///
///   1. **Filter-graph mode** (used by [ExportPipeline] for N-slice export).
///      Caller passes [filterComplex] (a full `-filter_complex` payload built
///      by `buildExportFilterGraph`) plus output labels. The encoder routes
///      the composed-frame stdin as input `[0]` and (when [audioSourcePath]
///      is set) the audio source MP4 as input `[1]`, then maps
///      [videoOutLabel] for video and (when set) [audioOutLabel] for audio.
///      The filter graph owns scale/pad/trim/setpts/fade/atempo/concat/amix —
///      the encoder just routes inputs and outputs.
///
///   2. **Plain-scale mode** (back-compat for tests and any future video-only
///      caller that doesn't need slice-aware filters). [filterComplex] is
///      null, the encoder builds a `-vf scale=...,pad=...,setsar=1` chain
///      automatically when output dimensions differ from source, and no
///      audio is muxed.
///
/// Single-slice and N-slice MP4 exports both run through filter-graph mode
/// today (N=1 just produces `concat=n=1`).
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

  /// Optional path to the source MP4 carrying the recording's audio. Mapped
  /// to input `[1]` of the filter graph; ignored when [audioOutLabel] is
  /// null (no audio) or [filterComplex] is null (plain-scale mode).
  final String? audioSourcePath;

  /// Full `-filter_complex` payload. When set, the encoder runs in
  /// filter-graph mode and bypasses the built-in `-vf scale/pad` shim. The
  /// graph must produce [videoOutLabel] and (optionally) [audioOutLabel].
  ///
  /// `null` ⇒ plain-scale mode (back-compat); the encoder builds its own
  /// `-vf` chain from output/source dimensions, with no audio.
  final String? filterComplex;

  /// `-map` target for video. Required when [filterComplex] is set; ignored
  /// in plain-scale mode.
  final String? videoOutLabel;

  /// `-map` target for audio. When non-null, the encoder also maps audio
  /// and emits `-c:a aac -b:a {audioBitrateKbps}k`. Null ⇒ video-only.
  /// Ignored in plain-scale mode (audio is never muxed there).
  final String? audioOutLabel;

  /// AAC bitrate for the muxed audio track. Defaults to 192 kbps (matches
  /// the historical `kMixedAudioBitrateKbps` from `audio_mix_args.dart`).
  final int audioBitrateKbps;

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
    this.filterComplex,
    this.videoOutLabel,
    this.audioOutLabel,
    this.audioBitrateKbps = 192,
    int? sourceWidth,
    int? sourceHeight,
    int? sourceFps,
    this.pixelFormat = FfmpegPixelFormat.bgra,
  }) : sourceWidth = sourceWidth ?? width,
       sourceHeight = sourceHeight ?? height,
       sourceFps = sourceFps ?? fps;

  List<String> _argsFor(String codec) {
    final useGraph = filterComplex != null && filterComplex!.isNotEmpty;
    final hasAudio =
        useGraph && audioOutLabel != null && audioSourcePath != null;

    final args = <String>[
      '-loglevel',
      'error',
      '-y',
      '-f',
      'rawvideo',
      '-pix_fmt',
      pixelFormat.ffmpegName,
      '-s',
      '${sourceWidth}x$sourceHeight',
      '-r',
      '$sourceFps',
      '-i',
      '-',
    ];

    // libx264 only runs when the HW encoder is unavailable — exactly when
    // speed matters most. x264's default `medium` preset is several times
    // slower than `veryfast` for negligible quality difference at our
    // bitrates. (VideoToolbox has no -preset; passing one errors.)
    final codecTuning = <String>[
      if (codec == 'libx264') ...['-preset', 'veryfast'],
    ];

    if (useGraph) {
      if (hasAudio) {
        args.addAll(['-i', audioSourcePath!]);
      }
      args.addAll(['-filter_complex', filterComplex!]);
      args.addAll(['-map', videoOutLabel!]);
      if (hasAudio) {
        args.addAll(['-map', audioOutLabel!]);
      }
      args.addAll([
        '-c:v',
        codec,
        '-b:v',
        '${bitrateKbps}k',
        '-pix_fmt',
        'yuv420p',
      ]);
      args.addAll(codecTuning);
      args.addAll(['-r', '$fps']);
      if (hasAudio) {
        args.addAll(['-c:a', 'aac', '-b:a', '${audioBitrateKbps}k']);
      }
    } else {
      // Plain-scale back-compat path: simple -vf scale/pad when needed, no
      // audio. Used by FfmpegEncoder unit tests and any video-only caller
      // that doesn't need the N-slice filter graph.
      final needsScale = width != sourceWidth || height != sourceHeight;
      final videoFilters = <String>[
        if (needsScale) ...[
          'scale=$width:$height:force_original_aspect_ratio=decrease',
          'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black',
          'setsar=1',
        ],
      ];
      args.addAll([
        '-c:v',
        codec,
        '-b:v',
        '${bitrateKbps}k',
        '-pix_fmt',
        'yuv420p',
      ]);
      args.addAll(codecTuning);
      if (videoFilters.isNotEmpty) {
        args.addAll(['-vf', videoFilters.join(',')]);
      }
      args.addAll(['-r', '$fps']);
    }
    // faststart relocates the moov atom to the file head at finalize so
    // the MP4 starts playing before a full download (shareable links).
    args.addAll(['-movflags', '+faststart']);
    args.add(outputPath);
    return args;
  }

  /// Test seam: the resolved ffmpeg arg list for [codec].
  List<String> argsForTesting(String codec) => _argsFor(codec);

  /// Test seam: force the VideoToolbox capability probe to a fixed result
  /// instead of spawning ffmpeg. `null` (the default) restores real probing.
  static set videotoolboxProbeOverride(bool? value) =>
      _videotoolboxProbeOverride = value;
  static bool? _videotoolboxProbeOverride;

  /// Cached result of the one-time VideoToolbox probe — hardware availability
  /// is constant for the life of the process.
  static bool? _videotoolboxUsable;

  /// Whether `h264_videotoolbox` can actually *encode* on this host — not just
  /// whether ffmpeg lists it. The Apple HW encoder is present on every Mac yet
  /// fails to create a compression session in headless/VM environments (e.g.
  /// CI runners), and is absent entirely off-Mac. ffmpeg surfaces both as a
  /// non-zero exit *after* the process starts, so a throwaway 1-frame encode is
  /// the only reliable probe. Runs once (cached). This lets [start] commit to a
  /// codec that works *before* streaming — the streaming encoder can't retry
  /// once source frames have been consumed.
  static Future<bool> _videotoolboxCanEncode(String binary) async {
    final override = _videotoolboxProbeOverride;
    if (override != null) return override;
    final cached = _videotoolboxUsable;
    if (cached != null) return cached;
    var ok = false;
    try {
      final result = await Process.run(binary, const [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=16x16:r=1:d=1',
        '-frames:v', '1', '-c:v', 'h264_videotoolbox', //
        '-f', 'null', '-',
      ]);
      ok = result.exitCode == 0;
    } catch (_) {
      // ffmpeg vanished between resolve() and probe, or the OS refused to
      // spawn it — treat as "no HW encoder" and let the caller use libx264.
      ok = false;
    }
    _videotoolboxUsable = ok;
    return ok;
  }

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

    // Probe first: Process.start succeeds even when h264_videotoolbox can't
    // create a session, so committing on start() alone strands the streaming
    // encode on a dead codec. Only attempt VT when it can actually encode;
    // otherwise fall straight through to the portable libx264 software path.
    final canUseHardware = await _videotoolboxCanEncode(binary);
    if (canUseHardware && await tryCodec('h264_videotoolbox')) {
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
        .catchError(
          (_) {},
        ); // stderr is diagnostic only; never let it go unhandled
    _sw.start();
  }

  /// Returns true while ffmpeg is still consuming stdin; false once it has
  /// closed the pipe (e.g., the filter graph trimmed the output and ffmpeg
  /// already has enough frames). The caller should stop writing further
  /// frames when this returns false — pushing more produces "Broken pipe"
  /// errors on macOS.
  ///
  /// Only broken-pipe errors are caught and translated to a `false`
  /// return. Real encoder failures (OOM, type errors, malformed state)
  /// must propagate so the pipeline's `eagerError: true` tear-down sees
  /// the actual cause instead of a silent truncated output.
  Future<bool> writeFrame(Uint8List bgra) async {
    final p = _process;
    if (p == null) throw StateError('FfmpegEncoder.writeFrame before start');
    if (_stdinClosed) return false;
    try {
      p.stdin.add(bgra);
      await p.stdin.flush();
      return true;
    } on SocketException catch (e) {
      // ffmpeg closed stdin (filter trim satisfied, process exiting).
      // Mark and let the caller drain instead of crashing the pipeline.
      _stdinClosed = true;
      AppLogger.ffmpeg.d(
        'FfmpegEncoder: stdin closed mid-write (likely trim-satisfied): $e',
      );
      return false;
    } on FileSystemException catch (e) {
      // Some Dart versions on macOS surface broken pipes as
      // FileSystemException("Write failed", OSError(errno: 32)). Treat
      // those identically to SocketException; anything else (a real
      // disk-level error) still propagates because writeFrame doesn't
      // touch the filesystem.
      _stdinClosed = true;
      AppLogger.ffmpeg.d(
        'FfmpegEncoder: stdin closed mid-write (likely trim-satisfied): $e',
      );
      return false;
    }
  }

  bool _stdinClosed = false;

  Future<void> finish() async {
    final p = _process;
    if (p == null) return;
    if (!_stdinClosed) {
      try {
        await p.stdin.close();
      } catch (_) {
        // ffmpeg already exited and closed its end of the pipe.
      }
      _stdinClosed = true;
    }
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
