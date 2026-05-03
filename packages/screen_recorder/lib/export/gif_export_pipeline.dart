// packages/screen_recorder/lib/export/gif_export_pipeline.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import '../models/compression_bitrate.dart';
import '../models/cursor_recording.dart';
import '../models/export_settings.dart';
import '../models/recording_metadata.dart';
import '../state/editor_project_state.dart';
import '../utils/app_logger.dart';
import '../utils/perf_summary.dart';
import 'export_compositor.dart';
import 'ffmpeg_decoder.dart';
import 'frame_compositor.dart';

/// Two-pass GIF export pipeline using ffmpeg's palettegen + paletteuse.
///
/// Design choice: two full decode+compose passes rather than buffering all
/// composed frames to a temp intermediate. At GIF frame rates (≤30fps) and
/// short durations, two passes through the source are ~2× the decode cost
/// but keep peak memory at one frame — versus buffering every RGBA frame,
/// which at 720p/10fps/1s is ~800MB for a 60s clip. Two-pass decode is
/// the right call for GIF: clips are typically short and memory matters more.
///
/// Each pass creates a fresh [FrameCompositor] because the cursor-motion
/// and zoom-focal controllers carry state across [compose] calls — reusing
/// a compositor from pass 1 in pass 2 would start mid-animation and produce
/// different frames than pass 1 showed ffmpeg for palette sampling.
class GifExportPipeline {
  GifExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.projectState,
    required this.settings,
  }) : assert(settings.format == ExportFormat.gif,
            'GifExportPipeline requires settings.format == ExportFormat.gif');

  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;
  final EditorProjectState projectState;
  final ExportSettings settings;

  List<int>? _probedDims; // [width, height, fps]
  int? _probedNbFrames;
  double? _probedDurationSec;

  /// Runs both passes. [onProgress] receives a value in [0, 1]:
  /// pass 1 covers [0, 0.5], pass 2 covers [0.5, 1.0].
  Future<ExportPerfSummary> run({
    void Function(double progress)? onProgress,
  }) async {
    final wallSw = Stopwatch()..start();

    final probed = await _probeSource();
    final srcWidth = probed[0];
    final srcHeight = probed[1];

    final fps = settings.frameRate;
    final outputDims = settings.resolution.dimensionsFor(
      Size(srcWidth.toDouble(), srcHeight.toDouble()),
    );
    final outWidth = outputDims.width.toInt();
    final outHeight = outputDims.height.toInt();

    final paletteSettings = gifPaletteSettings(settings.compression);

    final palettePath = await _makePaletteTmpPath();

    final int? expectedFrames = _expectedFrames(fps);

    try {
      final compositeSw1 = Stopwatch();
      var pass1Frames = 0;

      // ----------------------------------------------------------------
      // Pass 1: decode + compose → ffmpeg palettegen → palette.png
      // ----------------------------------------------------------------
      final compositor1 = InProcessExportCompositor(FrameCompositor(
        projectState: projectState,
        cursorRecording: cursorRecording,
        metadata: sourceMetadata,
        videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
        fps: fps,
      ));

      final pass1Args = [
        '-loglevel', 'error',
        '-y',
        '-f', 'rawvideo',
        '-pix_fmt', 'rgba',
        '-s', '${compositor1.totalSize.width.toInt()}x${compositor1.totalSize.height.toInt()}',
        '-r', '$fps',
        '-i', '-',
        '-vf',
        'scale=${outWidth}x$outHeight:force_original_aspect_ratio=decrease,'
            'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black,'
            'palettegen=max_colors=${paletteSettings.maxColors}:stats_mode=full',
        palettePath,
      ];
      AppLogger.ffmpeg.d('gif pass1: ffmpeg ${pass1Args.join(" ")}');

      final proc1 = await Process.start('ffmpeg', pass1Args);

      final decoder1 = FfmpegDecoder(
        inputPath: sourcePath,
        width: srcWidth,
        height: srcHeight,
        cfrFps: fps,
      );

      try {
        var index = 0;
        await for (final raw in decoder1.frames()) {
          final tsMicros = (1000000 * index) ~/ fps;
          compositeSw1.start();
          final composed = await compositor1.compose(
            bgra: raw,
            position: Duration(microseconds: tsMicros),
          );
          compositeSw1.stop();
          proc1.stdin.add(composed);
          await proc1.stdin.flush();
          pass1Frames++;
          if (onProgress != null && expectedFrames != null && expectedFrames > 0) {
            onProgress((pass1Frames / expectedFrames * 0.5).clamp(0.0, 0.5));
          }
          index++;
        }
      } finally {
        await compositor1.dispose();
        await proc1.stdin.close();
      }

      final exit1 = await proc1.exitCode;
      if (exit1 != 0) {
        final stderr1 = await proc1.stderr
            .transform(SystemEncoding().decoder)
            .join();
        throw Exception('GIF pass 1 (palettegen) exited $exit1: $stderr1');
      }

      // ----------------------------------------------------------------
      // Pass 2: decode + compose → ffmpeg paletteuse → output.gif
      // ----------------------------------------------------------------
      final compositeSw2 = Stopwatch();
      var pass2Frames = 0;

      // Fresh compositor: controllers start from t=0 to produce the same
      // frames pass 1 sent to palettegen.
      final compositor2 = InProcessExportCompositor(FrameCompositor(
        projectState: projectState,
        cursorRecording: cursorRecording,
        metadata: sourceMetadata,
        videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
        fps: fps,
      ));

      final pass2Args = [
        '-loglevel', 'error',
        '-y',
        '-f', 'rawvideo',
        '-pix_fmt', 'rgba',
        '-s', '${compositor2.totalSize.width.toInt()}x${compositor2.totalSize.height.toInt()}',
        '-r', '$fps',
        '-i', '-',
        '-i', palettePath,
        '-lavfi',
        '[0:v]scale=${outWidth}x$outHeight:force_original_aspect_ratio=decrease,'
            'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black [scaled];'
            '[scaled][1:v]paletteuse=dither=${paletteSettings.dither}',
        '-loop', '0',
        outputPath,
      ];
      AppLogger.ffmpeg.d('gif pass2: ffmpeg ${pass2Args.join(" ")}');

      final proc2 = await Process.start('ffmpeg', pass2Args);

      final decoder2 = FfmpegDecoder(
        inputPath: sourcePath,
        width: srcWidth,
        height: srcHeight,
        cfrFps: fps,
      );

      try {
        var index = 0;
        await for (final raw in decoder2.frames()) {
          final tsMicros = (1000000 * index) ~/ fps;
          compositeSw2.start();
          final composed = await compositor2.compose(
            bgra: raw,
            position: Duration(microseconds: tsMicros),
          );
          compositeSw2.stop();
          proc2.stdin.add(composed);
          await proc2.stdin.flush();
          pass2Frames++;
          if (onProgress != null && expectedFrames != null && expectedFrames > 0) {
            onProgress(
                (0.5 + pass2Frames / expectedFrames * 0.5).clamp(0.5, 1.0));
          }
          index++;
        }
      } finally {
        await compositor2.dispose();
        await proc2.stdin.close();
      }

      final exit2 = await proc2.exitCode;
      if (exit2 != 0) {
        final stderr2 = await proc2.stderr
            .transform(SystemEncoding().decoder)
            .join();
        throw Exception('GIF pass 2 (paletteuse) exited $exit2: $stderr2');
      }

      if (onProgress != null) onProgress(1.0);

      wallSw.stop();
      final wallSec = wallSw.elapsedMilliseconds / 1000.0;
      final totalFrames = pass2Frames;
      final inputDuration = totalFrames > 0 ? totalFrames / fps : 0.0;
      final outputBytes = await _fileLength(outputPath);

      final compositeMsPerFrame = totalFrames > 0
          ? (compositeSw1.elapsedMilliseconds +
                  compositeSw2.elapsedMilliseconds) /
              (totalFrames * 2)
          : 0.0;

      final summary = ExportPerfSummary(
        inputDurationSeconds: inputDuration,
        wallTimeSeconds: wallSec,
        decodeMsPerFrame: 0,
        compositeMsPerFrame: compositeMsPerFrame,
        encodeMsPerFrame: 0,
        outputBytes: outputBytes,
        outputCodec: 'gif',
        usedHardwareEncoder: false,
      );
      AppLogger.ffmpeg.i(summary.format());
      return summary;
    } finally {
      // Delete the intermediate palette on both success and error.
      try {
        final f = File(palettePath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Future<String> _makePaletteTmpPath() async {
    final dir = await Directory.systemTemp.createTemp('gif_palette');
    return '${dir.path}/palette.png';
  }

  int? _expectedFrames(int fps) {
    final dur = _probedDurationSec;
    if (dur != null && dur > 0) return (dur * fps).round();
    final nb = _probedNbFrames;
    if (nb != null) {
      final probed = _probedDims;
      if (probed != null && probed[2] > 0) {
        return (nb * fps / probed[2]).round();
      }
    }
    return null;
  }

  Future<List<int>> _probeSource() async {
    if (_probedDims != null) return _probedDims!;

    final result = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries',
      'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration',
      '-of', 'default=nw=1:nk=0',
      sourcePath,
    ]);
    final output = (result.stdout as String).trim();
    final fields = <String, String>{};
    for (final line in output.split('\n')) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      fields[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    final w = int.tryParse(fields['width'] ?? '');
    final h = int.tryParse(fields['height'] ?? '');
    if (w == null || h == null) {
      throw Exception('ffprobe missing width/height: $output');
    }

    int? parseRate(String? s) {
      if (s == null || s.isEmpty || s == 'N/A' || s == '0/0') return null;
      if (s.contains('/')) {
        final nd = s.split('/');
        if (nd.length != 2) return null;
        final num = double.tryParse(nd[0]);
        final den = double.tryParse(nd[1]);
        if (num == null || den == null || den <= 0) return null;
        final v = num / den;
        return v <= 0 ? null : v.round();
      }
      final v = double.tryParse(s);
      return (v == null || v <= 0) ? null : v.round();
    }

    final avgRate = parseRate(fields['avg_frame_rate']);
    final rRate = parseRate(fields['r_frame_rate']);
    final nbFrames = int.tryParse(fields['nb_frames'] ?? '');
    final dur = double.tryParse(fields['duration'] ?? '');

    int? derivedRate;
    if (nbFrames != null && nbFrames > 0 && dur != null && dur > 0) {
      derivedRate = (nbFrames / dur).round();
    }

    final fps = avgRate ??
        derivedRate ??
        rRate ??
        (sourceMetadata.fps > 0 ? sourceMetadata.fps : 30);

    AppLogger.ffmpeg.d(
      'gif probe: avg=$avgRate derived=$derivedRate r=$rRate '
      'nb_frames=$nbFrames duration=$dur → using $fps fps',
    );

    _probedDims = [w, h, fps];
    _probedNbFrames = nbFrames;
    _probedDurationSec = dur;
    return _probedDims!;
  }

  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }
}
