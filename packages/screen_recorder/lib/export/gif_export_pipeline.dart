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
import 'ffmpeg_probe.dart';
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
  }) {
    if (settings.format != ExportFormat.gif) {
      throw ArgumentError.value(
        settings.format,
        'settings.format',
        'GifExportPipeline requires ExportFormat.gif',
      );
    }
  }

  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;
  final EditorProjectState projectState;
  final ExportSettings settings;

  // Holds the directory created for the palette temp file so we can
  // delete it recursively in the finally block (fixes the dir-leak that
  // left empty gif_palette* dirs under /var/folders/…/T/).
  Directory? _paletteDir;

  /// Runs both passes. [onProgress] receives a value in [0, 1]:
  /// pass 1 covers [0, 0.5], pass 2 covers [0.5, 1.0].
  Future<ExportPerfSummary> run({
    void Function(double progress)? onProgress,
  }) async {
    final wallSw = Stopwatch()..start();

    final probed = await ffmpegProbe(
      path: sourcePath,
      metadataFps: sourceMetadata.fps,
    );
    final srcWidth = probed.width;
    final srcHeight = probed.height;

    final fps = settings.frameRate;
    final outputDims = settings.resolution.dimensionsFor(
      Size(srcWidth.toDouble(), srcHeight.toDouble()),
    );
    final outWidth = outputDims.width.toInt();
    final outHeight = outputDims.height.toInt();

    final paletteSettings = gifPaletteSettings(settings.compression);

    final palettePath = _makePaletteTmpPath();

    final int? expectedFrames = _expectedFrames(probed, fps);

    try {
      final compositeSw1 = Stopwatch();
      var pass1Frames = 0;

      // Pass 1: decode + compose → ffmpeg palettegen → palette.png.
      // The compositor renders each frame at its full framed size; ffmpeg
      // then scales and generates the optimum palette from all frames.
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

      // Pass 2: decode + compose → ffmpeg paletteuse → output.gif.
      // A fresh compositor is required so animation controllers start from
      // t=0 and produce the exact same frames that pass 1 sent to palettegen.
      final compositeSw2 = Stopwatch();
      var pass2Frames = 0;

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
      } catch (e) {
        // Pass 2 failed: remove the partial output so callers cannot
        // mistake an incomplete file for a successful export.
        if (await File(outputPath).exists()) {
          try {
            await File(outputPath).delete();
          } catch (_) {}
        }
        rethrow;
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
      // Recursively delete the temp directory that holds palette.png.
      // Deleting the dir (not just the file) avoids leaving behind
      // empty gif_palette* directories under the system temp folder.
      try {
        final dir = _paletteDir;
        if (dir != null && dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      } catch (_) {
        // Best-effort cleanup; if the OS already reaped the temp dir we
        // have nothing to do.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _makePaletteTmpPath() {
    _paletteDir = Directory.systemTemp.createTempSync('gif_palette');
    return '${_paletteDir!.path}/palette.png';
  }

  int? _expectedFrames(FfmpegProbeResult probed, int fps) {
    final dur = probed.durationSec;
    if (dur != null && dur > 0) return (dur * fps).round();
    final nb = probed.nbFrames;
    if (nb != null && probed.fps > 0) {
      return (nb * fps / probed.fps).round();
    }
    return null;
  }

  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }
}
