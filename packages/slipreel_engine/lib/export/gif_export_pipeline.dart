// packages/screen_recorder/lib/export/gif_export_pipeline.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import '../models/compression_bitrate.dart';
import '../models/cursor_recording.dart';
import '../models/export_settings.dart';
import '../models/recording_metadata.dart';
import '../models/trim_selection.dart';
import '../rendering/output_canvas_resolver.dart';
import '../state/clip_slice.dart';
import '../state/editor_project_state.dart';
import '../utils/app_logger.dart';
import '../utils/perf_summary.dart';
import 'export_cancellation.dart';
import 'export_compositor.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_filters.dart';
import 'ffmpeg_probe.dart';
import 'ffmpeg_resolver.dart';
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
    this.trim,
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
  final TrimSelection? trim;

  // Holds the directory created for the palette temp file so we can
  // delete it recursively in the finally block (fixes the dir-leak that
  // left empty gif_palette* dirs under /var/folders/…/T/).
  Directory? _paletteDir;

  Process? _activeProc;
  FfmpegDecoder? _activeDecoder;

  /// Runs both passes. [onProgress] receives a value in [0, 1]:
  /// pass 1 covers [0, 0.5], pass 2 covers [0.5, 1.0].
  ///
  /// Single-use: each pipeline instance and each [cancelToken] is meant for
  /// one [run] call. The `whenCancelled` handler and the `_activeProc` /
  /// `_activeDecoder` fields are wired/mutated per run, so don't reuse a
  /// [CancelToken] across runs (kill() is idempotent, so reuse is currently
  /// harmless, but the assumption may tighten later).
  Future<ExportPerfSummary> run({
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final wallSw = Stopwatch()..start();
    final ffmpegBin = Ffmpeg.resolve();
    cancelToken?.whenCancelled.then((_) {
      _activeProc?.kill(ProcessSignal.sigkill);
      _activeDecoder?.kill();
    });

    final probed = await ffmpegProbe(
      path: sourcePath,
      metadataFps: sourceMetadata.fps,
    );
    final srcWidth = probed.width;
    final srcHeight = probed.height;

    final fps = settings.frameRate;
    // Output dimensions follow the COMPOSITED canvas (aspect + padding),
    // not the raw source. Without this, a vertical-9:16 export at 1080p
    // would still produce a 16:9 GIF because `dimensionsFor` would
    // width-scale from the raw 1920×1080 source aspect instead of the
    // 9:16 canvas the user picked.
    final composedCanvas = OutputCanvasResolver.resolve(
      videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
      padding: projectState.windowFrame.padding,
      aspect: projectState.outputAspect,
    ).canvasSize;
    final outputDims = settings.resolution.dimensionsFor(composedCanvas);
    final outWidth = outputDims.width.toInt();
    final outHeight = outputDims.height.toInt();

    final paletteSettings = gifPaletteSettings(settings.compression);

    // Speed + fade are video-only for GIF (no audio track). Computed once and
    // spliced into both pass-1 (palettegen) and pass-2 (paletteuse) chains.
    // Slice-editor model: these live on the timeline's first clip slice;
    // pipelines stay single-slice for now.
    final clip0 = _firstClipOrEmpty(projectState);
    final speed = clip0.playbackSpeed;
    final fadeIn = clip0.fadeIn;
    final fadeOut = clip0.fadeOut;
    final inputDurSec = trim != null
        ? trim!.duration.inMicroseconds / 1000000
        : (probed.durationSec ?? 0);
    final outputDurSec = speed != 0 ? inputDurSec / speed : inputDurSec;
    final outputDuration =
        Duration(microseconds: (outputDurSec * 1000000).round());
    final fadeOutStart =
        (outputDuration > fadeOut) ? outputDuration - fadeOut : Duration.zero;
    final extraVideoFilters = <String>[
      if (speed != 1.0) setptsForSpeed(speed),
      if (fadeIn > Duration.zero) 'fade=t=in:st=0:d=${ffSeconds(fadeIn)}',
      if (fadeOut > Duration.zero && outputDuration > Duration.zero)
        'fade=t=out:st=${ffSeconds(fadeOutStart)}:d=${ffSeconds(fadeOut)}',
    ];
    final extraVideo =
        extraVideoFilters.isEmpty ? '' : '${extraVideoFilters.join(',')},';

    final palettePath = _makePaletteTmpPath();

    final int? expectedFrames = _expectedFrames(probed, fps);

    try {
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
            '$extraVideo'
            'palettegen=max_colors=${paletteSettings.maxColors}:stats_mode=full',
        palettePath,
      ];
      AppLogger.ffmpeg.d('gif pass1: $ffmpegBin ${pass1Args.join(" ")}');

      final proc1 = await Process.start(ffmpegBin, pass1Args);
      _activeProc = proc1;
      final stderr1Buffer = StringBuffer();
      final stderr1Done = proc1.stderr
          .transform(const SystemEncoding().decoder)
          .forEach(stderr1Buffer.write)
          .catchError((_) {}); // stderr is diagnostic only; never let it go unhandled

      final decoder1 = FfmpegDecoder(
        inputPath: sourcePath,
        width: srcWidth,
        height: srcHeight,
        cfrFps: fps,
      );
      _activeDecoder = decoder1;

      try {
        var index = 0;
        await for (final raw in decoder1.frames()) {
          if (cancelToken?.isCancelled ?? false) {
            throw const ExportCancelledException();
          }
          final tsMicros = (1000000 * index) ~/ fps;
          index++;
          // The decoder no longer trims (FfmpegDecoder dropped its `trim`
          // field as part of the N-slice MP4 refactor). When a top-level
          // trim is set, skip source frames outside the window in dart
          // before they hit the compositor / palettegen.
          if (trim != null) {
            final sourcePos = Duration(microseconds: tsMicros);
            if (sourcePos < trim!.start) continue;
            if (sourcePos >= trim!.end) break;
          }
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
        }
      } finally {
        await compositor1.dispose();
        await proc1.stdin.close();
      }

      final exit1 = await proc1.exitCode;
      await stderr1Done;
      if (exit1 != 0) {
        throw Exception('GIF pass 1 (palettegen) exited $exit1: $stderr1Buffer');
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
            'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black,'
            '${extraVideo}null [scaled];'
            '[scaled][1:v]paletteuse=dither=${paletteSettings.dither}',
        '-loop', '0',
        outputPath,
      ];
      AppLogger.ffmpeg.d('gif pass2: $ffmpegBin ${pass2Args.join(" ")}');

      final proc2 = await Process.start(ffmpegBin, pass2Args);
      _activeProc = proc2;
      final stderr2Buffer = StringBuffer();
      final stderr2Done = proc2.stderr
          .transform(const SystemEncoding().decoder)
          .forEach(stderr2Buffer.write)
          .catchError((_) {}); // stderr is diagnostic only; never let it go unhandled

      final decoder2 = FfmpegDecoder(
        inputPath: sourcePath,
        width: srcWidth,
        height: srcHeight,
        cfrFps: fps,
      );
      _activeDecoder = decoder2;

      try {
        try {
          var index = 0;
          await for (final raw in decoder2.frames()) {
            if (cancelToken?.isCancelled ?? false) {
              throw const ExportCancelledException();
            }
            final tsMicros = (1000000 * index) ~/ fps;
            index++;
            // Trim-window dart-side skip (see pass 1 for context).
            if (trim != null) {
              final sourcePos = Duration(microseconds: tsMicros);
              if (sourcePos < trim!.start) continue;
              if (sourcePos >= trim!.end) break;
            }
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
          }
        } finally {
          await compositor2.dispose();
          await proc2.stdin.close();
        }

        final exit2 = await proc2.exitCode;
        await stderr2Done;
        if (exit2 != 0) {
          throw Exception('GIF pass 2 (paletteuse) exited $exit2: $stderr2Buffer');
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
      } catch (_) {
        // Best-effort: remove any partial output so a cancelled/failed GIF
        // isn't mistaken for a real export.
        try {
          final out = File(outputPath);
          if (await out.exists()) await out.delete();
        } catch (_) {}
        if (cancelToken?.isCancelled ?? false) {
          throw const ExportCancelledException();
        }
        rethrow;
      }
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
    if (trim != null) {
      return (trim!.duration.inMicroseconds / 1000000 * fps).round();
    }
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

/// Returns the first slice in [state.timeline.clips], or a zero-length default
/// when the timeline is empty. Centralises the "single-slice bridge" the
/// export pipelines use to read playback/fade fields off the timeline.
ClipSlice _firstClipOrEmpty(EditorProjectState state) {
  final clips = state.timeline.clips;
  if (clips.isEmpty) {
    return ClipSlice(cutStart: Duration.zero, cutEnd: Duration.zero);
  }
  return clips.first;
}
