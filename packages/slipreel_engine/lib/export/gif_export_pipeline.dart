// packages/screen_recorder/lib/export/gif_export_pipeline.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../models/camera_sidecar_meta.dart';
import '../models/compression_bitrate.dart';
import '../models/cursor_recording.dart';
import '../models/device_frame.dart';
import '../models/export_settings.dart';
import '../models/recording_metadata.dart';
import '../rendering/output_canvas_resolver.dart';
import '../rendering/motion_tuning.dart';
import '../state/clip_slice.dart';
import '../state/editor_project_state.dart';
import '../timeline/edited_time.dart';
import '../utils/app_logger.dart';
import '../utils/perf_summary.dart';
import 'bounded_async_queue.dart';
import 'camera_frame_source.dart';
import 'export_cancellation.dart';
import 'export_compositor.dart';
import 'export_pipeline.dart'
    show
        recommendedCameraDecodeSize,
        recommendedVideoDecodeSize,
        shouldCompositeCamera;
import 'ffmpeg_decoder.dart';
import 'ffmpeg_probe.dart';
import 'ffmpeg_resolver.dart';
import 'frame_compositor.dart';
import 'n_slice_filter_graph.dart';

/// Two-pass GIF export pipeline using ffmpeg's palettegen + paletteuse.
///
/// Source decode and Flutter composition happen once. Pass 1 splits the
/// edited/scaled stream between palette generation and a bounded-on-disk,
/// lossless FFV1 cache; pass 2 combines that cache with the generated palette.
/// This avoids a second stateful composition pass without retaining raw frames
/// in memory.
///
/// N-slice model: per-slice `trim=trimStart:trimEnd` + `setpts` + fades + concat
/// are built by [buildExportFilterGraph] with `audioStreams: []` (GIFs strip
/// audio). The result's `[outv]` feeds the palette-generation / palettized-
/// encode stages. Single-slice and empty-timeline projects both go through
/// this path (N=1 produces `concat=n=1`; empty timelines synthesize a
/// full-source slice).
class GifExportPipeline {
  static const int defaultMaxCacheBytes = 2 * 1024 * 1024 * 1024;
  static const String _cacheDirectoryPrefix = 'slipreel_gif_cache_';
  static const String _cacheMarkerName = '.created';
  static const String _cacheMarkerKind = 'slipreel-gif-cache';
  static const Duration _staleCacheAge = Duration(hours: 24);
  static const Duration _cacheHeartbeatInterval = Duration(minutes: 1);
  static const int _cacheFrameOverheadBytes = 1024 * 1024;

  GifExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.projectState,
    required this.settings,
    this.deviceFrameCatalog,
    this.motionTuning = MotionTuning.defaults,
    this.maxCacheBytes = defaultMaxCacheBytes,
    this.beforePass2ForTesting,
    this.afterPass1FrameForTesting,
    this.availableBytesForTesting,
    this.cacheLengthForTesting,
    this.writeCacheMarkerForTesting,
  }) {
    if (settings.format != ExportFormat.gif) {
      throw ArgumentError.value(
        settings.format,
        'settings.format',
        'GifExportPipeline requires ExportFormat.gif',
      );
    }
    if (maxCacheBytes <= 0) {
      throw ArgumentError.value(
        maxCacheBytes,
        'maxCacheBytes',
        'must be positive',
      );
    }
  }

  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;
  final EditorProjectState projectState;
  final ExportSettings settings;

  /// Optional device-frame catalog forwarded to the pass-1 compositor.
  /// Ensures the GIF output matches the editor preview when a device frame is
  /// active.
  final DeviceFrameCatalog? deviceFrameCatalog;
  final MotionTuning motionTuning;

  /// Hard upper bound for the lossless pass-1 frame cache. GIF composition is
  /// intentionally cached to avoid rendering the project twice, but FFV1 is
  /// lossless and its size cannot be predicted safely from duration alone.
  /// The pipeline aborts and removes partial artifacts before crossing this
  /// budget instead of filling the system volume.
  final int maxCacheBytes;

  @visibleForTesting
  final Future<void> Function()? beforePass2ForTesting;

  /// Called after pass 1 has submitted and flushed its first frame. Tests use
  /// this seam to cancel a genuinely live pass instead of pre-cancelling.
  @visibleForTesting
  final Future<void> Function()? afterPass1FrameForTesting;

  @visibleForTesting
  final Future<int?> Function(String path)? availableBytesForTesting;

  @visibleForTesting
  final Future<int> Function(String path)? cacheLengthForTesting;

  @visibleForTesting
  final void Function(File marker)? writeCacheMarkerForTesting;

  // Holds the directory created for the palette temp file so we can
  // delete it recursively in the finally block (fixes the dir-leak that
  // left empty gif_palette* dirs under /var/folders/…/T/).
  Directory? _paletteDir;
  Timer? _cacheHeartbeat;

  @visibleForTesting
  String? get debugPaletteDirectoryPath => _paletteDir?.path;

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
    if (cancelToken?.isCancelled ?? false) {
      throw const ExportCancelledException();
    }
    await _cleanupStaleCacheDirectories();
    if (cancelToken?.isCancelled ?? false) {
      throw const ExportCancelledException();
    }
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
    if (cancelToken?.isCancelled ?? false) {
      throw const ExportCancelledException();
    }
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
    final decodedVideoSize = recommendedVideoDecodeSize(
      sourceSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
      composedCanvas: composedCanvas,
      outputSize: Size(outWidth.toDouble(), outHeight.toDouble()),
      maxZoom: projectState.zoomRegions.fold<double>(
        1.0,
        (value, region) => region.zoomLevel > value ? region.zoomLevel : value,
      ),
      allowDownscale: projectState.windowFrame.deviceFrameId == null,
    );

    final paletteSettings = gifPaletteSettings(settings.compression);

    // Resolve the slice list for the filter graph. An empty timeline (no
    // saved editor project, B-era recordings) gets a synthetic full-source
    // slice so the N-slice filter graph degenerates to a clean
    // concat=n=1 + scale/pad + palette chain. Mirrors ExportPipeline's
    // _ensureSlices helper.
    final sourceDuration = probed.durationSec != null
        ? Duration(microseconds: (probed.durationSec! * 1000000).round())
        : Duration.zero;
    final slicedState = _ensureSlices(projectState, sourceDuration);
    final progressClips = slicedState.timeline.clips;
    final skipMargin = Duration(microseconds: (1000000 + fps - 1) ~/ fps);
    final firstNeeded = progressClips
        .map((clip) => clip.trimStart)
        .reduce((a, b) => a < b ? a : b);
    final lastNeeded = progressClips
        .map((clip) => clip.trimEnd)
        .reduce((a, b) => a > b ? a : b);
    final decodeStartFrame =
        (((firstNeeded - skipMargin).inMicroseconds).clamp(0, 1 << 62) * fps) ~/
        1000000;
    final decodeStart = Duration(
      microseconds: (1000000 * decodeStartFrame) ~/ fps,
    );
    final decodeEnd =
        sourceDuration > Duration.zero &&
            lastNeeded + skipMargin > sourceDuration
        ? sourceDuration
        : lastNeeded + skipMargin;

    // Per-slice video graph; GIFs strip audio so the helper sees no streams.
    final graph = buildExportFilterGraph(
      state: slicedState,
      audioStreams: const [],
      videoTimeOffset: decodeStart,
    );

    // Camera PiP parity with ExportPipeline: composite the webcam sidecar when
    // present + enabled. Decode failures degrade gracefully (warning, no
    // abort), matching the MP4 pipeline.
    const cameraDecodeWarning =
        'Camera could not be decoded; exported without the camera overlay.';
    final warnings = <String>[];
    final cameraMeta = await CameraSidecarMeta.loadForVideo(sourcePath);
    final cameraMoviePath = CameraSidecarMeta.moviePathForVideo(sourcePath);
    final compositeCamera = shouldCompositeCamera(
      hasSidecar: cameraMeta != null,
      enabled: projectState.cameraSettings.enabled,
      hasRegions: projectState.cameraRegions.isNotEmpty,
      movieExists: File(cameraMoviePath).existsSync(),
    );
    final cameraOriginalWidth = compositeCamera ? cameraMeta!.width : 0;
    final cameraOriginalHeight = compositeCamera ? cameraMeta!.height : 0;
    final cameraOriginalAspect = compositeCamera && cameraOriginalHeight != 0
        ? cameraOriginalWidth / cameraOriginalHeight
        : 1.0;
    final decodedCameraSize = compositeCamera
        ? recommendedCameraDecodeSize(
            sourceSize: Size(
              cameraOriginalWidth.toDouble(),
              cameraOriginalHeight.toDouble(),
            ),
            outputSize: Size(outWidth.toDouble(), outHeight.toDouble()),
            maxSizeFraction: projectState.cameraRegions.fold<double>(
              0,
              (value, region) => region.size > value ? region.size : value,
            ),
            shapeAspect: projectState.cameraSettings.shape.pixelAspect(
              cameraOriginalAspect,
            ),
          )
        : Size.zero;
    final cameraSrcWidth = decodedCameraSize.width.toInt();
    final cameraSrcHeight = decodedCameraSize.height.toInt();
    void warnCameraOnce() {
      if (!warnings.contains(cameraDecodeWarning)) {
        warnings.add(cameraDecodeWarning);
      }
    }

    CameraFrameSource? makeCameraSource() {
      if (!compositeCamera) return null;
      try {
        final cameraOffsetFrames = (cameraMeta!.offsetMicros * fps / 1e6)
            .round();
        final cameraFirstFrame = decodeStartFrame - cameraOffsetFrames > 0
            ? decodeStartFrame - cameraOffsetFrames
            : 0;
        final camDecoder = FfmpegDecoder(
          inputPath: cameraMoviePath,
          width: cameraOriginalWidth,
          height: cameraOriginalHeight,
          cfrFps: fps,
          outputWidth: cameraSrcWidth,
          outputHeight: cameraSrcHeight,
          startTime: Duration(
            microseconds: (1000000 * cameraFirstFrame) ~/ fps,
          ),
        );
        return CameraFrameSource(
          frames: camDecoder.frames(),
          fps: fps,
          offsetMicros: cameraMeta.offsetMicros,
          firstFrameIndex: cameraFirstFrame,
          // Reap the camera ffmpeg subprocess on teardown — cancelling
          // the stream iterator alone leaves it blocked on a full
          // stdout pipe.
          onDispose: camDecoder.kill,
        );
      } catch (e, st) {
        AppLogger.ffmpeg.w(
          'Camera GIF decode setup failed: $e',
          error: e,
          stackTrace: st,
        );
        warnCameraOnce();
        return null;
      }
    }

    try {
      final palettePath = _makePaletteTmpPath();
      final frameCachePath = '${_paletteDir!.path}/composed.mkv';
      final availableTempBytes = await _availableBytes(_paletteDir!.path);
      final cacheByteLimit = availableTempBytes == null
          ? maxCacheBytes
          : maxCacheBytes < availableTempBytes ~/ 2
          ? maxCacheBytes
          : availableTempBytes ~/ 2;
      final cacheFrameReserveBytes = _cacheFrameReserveBytes(
        width: outWidth,
        height: outHeight,
      );
      if (availableTempBytes != null && availableTempBytes < 16 * 1024 * 1024) {
        throw FileSystemException(
          'Not enough free temporary disk space for GIF export',
          _paletteDir!.path,
        );
      }
      // FFV1 is intra-frame and may expand incompressible input. Do not start
      // when the effective cache allowance cannot absorb one conservatively
      // sized frame; checking only after a write could fill a nearly-full
      // temp volume with the very first 4K frame.
      if (cacheByteLimit < cacheFrameReserveBytes) {
        throw GifCacheLimitExceededException(
          bytes: cacheFrameReserveBytes,
          limit: cacheByteLimit,
        );
      }

      // Progress mirrors ExportPipeline: each fed frame's source timestamp
      // maps through editedProgressAtSource so lead-in/gap frames report
      // zero and each pass sweeps its half of the bar exactly once. The
      // slice list (never empty after _ensureSlices) is the denominator,
      // so a failed duration probe can't silence the bar.
      final Duration? sourceFallbackTotal = sourceDuration > Duration.zero
          ? sourceDuration
          : null;
      double? passProgress(int tsMicros) => editedProgressAtSource(
        progressClips,
        Duration(microseconds: tsMicros),
        sourceFallbackTotal: sourceFallbackTotal,
      );

      // Slice-aware skip, mirroring ExportPipeline: gap frames are dropped
      // by the filter graph's per-slice trim, so the compositor skips them —
      // scene state still advances so kept frames
      // match a full compose. One reused blank buffer (never mutated;
      // stdin.flush() is awaited per write, so reuse is safe).
      Uint8List? blankFrame;
      var skippedFrames = 0;
      var composedFrames = 0;
      bool skipFrame(int tsMicros) => !sourceFrameContributes(
        progressClips,
        Duration(microseconds: tsMicros),
        margin: skipMargin,
      );

      try {
        final compositeSw1 = Stopwatch();

        // Pass 1: decode + compose → ffmpeg palettegen → palette.png.
        // The compositor renders each frame at its full framed size; ffmpeg
        // then scales and generates the optimum palette from all frames.
        final cameraSource1 = makeCameraSource();
        final compositor1 = InProcessExportCompositor(
          FrameCompositor(
            projectState: projectState,
            cursorRecording: cursorRecording,
            metadata: sourceMetadata,
            videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
            decodedVideoSize: decodedVideoSize,
            fps: fps,
            cameraFrameSource: cameraSource1,
            cameraOriginalAspect: cameraOriginalAspect,
            cameraSrcWidth: cameraSrcWidth,
            cameraSrcHeight: cameraSrcHeight,
            deviceFrameCatalog: deviceFrameCatalog,
            motionTuning: motionTuning,
            // Downscale-only hint, mirroring ExportPipeline: render at
            // export size when it is smaller than the composed canvas.
            outputSize: Size(outWidth.toDouble(), outHeight.toDouble()),
          ),
        );

        final pass1FilterComplex = buildGifCachedPass1FilterComplex(
          videoGraph: graph,
          outWidth: outWidth,
          outHeight: outHeight,
          paletteSettings: paletteSettings,
        );
        final pass1Args = [
          '-loglevel',
          'error',
          '-y',
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgba',
          '-s',
          '${compositor1.renderSize.width.toInt()}x${compositor1.renderSize.height.toInt()}',
          '-r',
          '$fps',
          '-i',
          '-',
          '-filter_complex',
          pass1FilterComplex,
          '-map',
          '[gifcache]',
          '-c:v',
          'ffv1',
          '-level',
          '3',
          '-pix_fmt',
          'bgra',
          frameCachePath,
          '-map',
          '[outpal]',
          '-frames:v',
          '1',
          palettePath,
        ];
        AppLogger.ffmpeg.d('gif pass1: $ffmpegBin ${pass1Args.join(" ")}');

        if (cancelToken?.isCancelled ?? false) {
          throw const ExportCancelledException();
        }
        final proc1 = await Process.start(ffmpegBin, pass1Args);
        _activeProc = proc1;
        final stderr1Buffer = StringBuffer();
        final stderr1Done = proc1.stderr
            .transform(const SystemEncoding().decoder)
            .forEach(stderr1Buffer.write)
            .catchError(
              (_) {},
            ); // stderr is diagnostic only; never let it go unhandled
        // Cancellation may have landed while Process.start was pending, when
        // the callback still had no handle to kill. Recheck immediately with
        // the new process registered and reap it before leaving.
        if (cancelToken?.isCancelled ?? false) {
          proc1.kill(ProcessSignal.sigkill);
          await proc1.exitCode;
          await stderr1Done;
          _activeProc = null;
          throw const ExportCancelledException();
        }

        final decoder1 = FfmpegDecoder(
          inputPath: sourcePath,
          width: srcWidth,
          height: srcHeight,
          cfrFps: fps,
          outputWidth: decodedVideoSize.width.toInt(),
          outputHeight: decodedVideoSize.height.toInt(),
          startTime: decodeStart,
          endTime: decodeEnd,
        );
        _activeDecoder = decoder1;

        var pass1StdinClosed = false;
        var sourceFramesFed = 0;
        final decodedQueue =
            BoundedAsyncQueue<({int sourceIndex, Uint8List bytes})>(2);
        final composedQueue =
            BoundedAsyncQueue<({int sourceIndex, Uint8List bytes})>(2);
        cancelToken?.whenCancelled.then((_) {
          decodedQueue.close();
          composedQueue.close();
        });
        try {
          if (decodeStartFrame > 0) {
            if (cancelToken?.isCancelled ?? false) {
              throw const ExportCancelledException();
            }
            final sourceMicros = (1000000 * (decodeStartFrame - 1)) ~/ fps;
            await advanceExportCompositor(
              compositor1,
              Duration(microseconds: sourceMicros),
            );
            skippedFrames += decodeStartFrame;
            final progress = passProgress(sourceMicros);
            if (progress != null) {
              onProgress?.call((progress * 0.5).clamp(0.0, 0.5));
            }
          }
          final decodeFuture = () async {
            try {
              var sourceIndex = decodeStartFrame;
              await for (final raw in decoder1.frames()) {
                if (decodedQueue.isClosed) break;
                try {
                  await decodedQueue.add((
                    sourceIndex: sourceIndex++,
                    bytes: raw,
                  ));
                } on StateError {
                  if (decodedQueue.isClosed) return;
                  rethrow;
                }
              }
            } finally {
              decodedQueue.close();
            }
          }();

          final composeFuture = () async {
            try {
              while (true) {
                final decoded = await decodedQueue.take();
                if (decoded == null || composedQueue.isClosed) break;
                final tsMicros = (1000000 * decoded.sourceIndex) ~/ fps;
                final Uint8List composed;
                if (skipFrame(tsMicros)) {
                  await advanceExportCompositor(
                    compositor1,
                    Duration(microseconds: tsMicros),
                  );
                  skippedFrames++;
                  composed = blankFrame ??= Uint8List(
                    compositor1.renderSize.width.toInt() *
                        compositor1.renderSize.height.toInt() *
                        4,
                  );
                } else {
                  compositeSw1.start();
                  try {
                    composed = await compositor1.compose(
                      bgra: decoded.bytes,
                      position: Duration(microseconds: tsMicros),
                    );
                    composedFrames++;
                  } finally {
                    compositeSw1.stop();
                  }
                }
                try {
                  await composedQueue.add((
                    sourceIndex: decoded.sourceIndex,
                    bytes: composed,
                  ));
                } on StateError {
                  if (composedQueue.isClosed) return;
                  rethrow;
                }
              }
            } finally {
              composedQueue.close();
            }
          }();

          final writeFuture = () async {
            while (true) {
              final composed = await composedQueue.take();
              if (composed == null) break;
              try {
                await _enforceCacheHeadroom(
                  frameCachePath,
                  cacheByteLimit,
                  cacheFrameReserveBytes,
                );
                proc1.stdin.add(composed.bytes);
                await proc1.stdin.flush();
                sourceFramesFed++;
                if (sourceFramesFed == 1) {
                  await afterPass1FrameForTesting?.call();
                }
                if (cancelToken?.isCancelled ?? false) {
                  throw const ExportCancelledException();
                }
                // Sample every submitted frame. The prior four-frame cadence
                // allowed several large lossless frames to cross the cap
                // before cancellation and cleanup could react.
                await _enforceCacheLimit(frameCachePath, cacheByteLimit);
              } on SocketException {
                pass1StdinClosed = true;
                decoder1.kill();
                decodedQueue.close();
                composedQueue.close();
                break;
              } on FileSystemException {
                pass1StdinClosed = true;
                decoder1.kill();
                decodedQueue.close();
                composedQueue.close();
                break;
              }
              if (onProgress != null) {
                final tsMicros = (1000000 * composed.sourceIndex) ~/ fps;
                final p = passProgress(tsMicros);
                if (p != null) onProgress((p * 0.5).clamp(0.0, 0.5));
              }
            }
          }();

          final stages = [decodeFuture, composeFuture, writeFuture];
          try {
            await Future.wait(stages, eagerError: true);
          } catch (_) {
            decoder1.kill();
            proc1.kill(ProcessSignal.sigkill);
            decodedQueue.close();
            composedQueue.close();
            await Future.wait(
              stages.map((stage) => stage.then<void>((_) {}, onError: (_) {})),
            );
            rethrow;
          }
        } finally {
          // Idempotent after EOF; essential when composition/write throws so
          // ffmpeg cannot remain blocked on an unread stdout pipe.
          decoder1.kill();
          await compositor1.dispose();
          await cameraSource1?.dispose();
          if (!pass1StdinClosed) {
            try {
              await proc1.stdin.close();
            } catch (_) {
              // ffmpeg already closed its end; nothing to do.
            }
          }
        }
        if (cameraSource1?.failed == true) warnCameraOnce();

        final exit1 = await proc1.exitCode;
        await stderr1Done;
        _activeProc = null;
        _activeDecoder = null;
        if (exit1 != 0) {
          throw Exception(
            'GIF pass 1 (palettegen) exited $exit1: $stderr1Buffer',
          );
        }
        await _enforceCacheLimit(frameCachePath, cacheByteLimit);

        if (cancelToken?.isCancelled ?? false) {
          throw const ExportCancelledException();
        }

        await beforePass2ForTesting?.call();
        if (cancelToken?.isCancelled ?? false) {
          throw const ExportCancelledException();
        }

        // Pass 2 reads the lossless, already-edited frame cache produced by
        // pass 1. This removes the former second source decode + full Flutter
        // composition pass while keeping memory bounded to the ffmpeg pipes.
        final pass2FilterComplex =
            '[0:v][1:v]paletteuse=dither=${paletteSettings.dither}[gifout]';
        final pass2Args = [
          '-loglevel',
          'error',
          '-y',
          '-i',
          frameCachePath,
          '-i',
          palettePath,
          '-filter_complex',
          pass2FilterComplex,
          '-map',
          '[gifout]',
          '-loop',
          '0',
          '-progress',
          'pipe:1',
          '-nostats',
          outputPath,
        ];
        AppLogger.ffmpeg.d('gif pass2: $ffmpegBin ${pass2Args.join(" ")}');

        final proc2 = await Process.start(ffmpegBin, pass2Args);
        _activeProc = proc2;
        // Cancellation can land after the pass-transition check but before
        // Process.start completes. Recheck with the new process handle wired
        // so the second pass can never escape cancellation.
        if (cancelToken?.isCancelled ?? false) {
          proc2.kill(ProcessSignal.sigkill);
          await proc2.exitCode;
          _activeProc = null;
          throw const ExportCancelledException();
        }
        final editedMicros = totalEditedDuration(progressClips).inMicroseconds;
        if (onProgress != null && editedMicros > 0) {
          // ffmpeg can finish a short GIF before its periodic `-progress`
          // writer emits an intermediate timestamp. Report the first cached
          // frame as soon as pass 2 starts so progress never appears stuck at
          // 50% and then jumps straight to completion.
          final estimatedFrames = (editedMicros * fps / 1000000).round();
          final denominator = estimatedFrames < 2 ? 2 : estimatedFrames;
          onProgress(0.5 + 0.5 / denominator);
        }
        final stderr2Buffer = StringBuffer();
        final stderr2Done = proc2.stderr
            .transform(const SystemEncoding().decoder)
            .forEach(stderr2Buffer.write)
            .catchError(
              (_) {},
            ); // stderr is diagnostic only; never let it go unhandled
        final progress2Done = proc2.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
              if (onProgress == null || editedMicros <= 0) return;
              if (!line.startsWith('out_time_us=')) return;
              final micros = int.tryParse(
                line.substring('out_time_us='.length),
              );
              if (micros == null) return;
              final p = (micros / editedMicros).clamp(0.0, 1.0);
              onProgress((0.5 + p * 0.5).clamp(0.5, 1.0));
            });
        try {
          final exit2 = await proc2.exitCode;
          await progress2Done;
          await stderr2Done;
          _activeProc = null;
          if (exit2 != 0) {
            throw Exception(
              'GIF pass 2 (paletteuse) exited $exit2: $stderr2Buffer',
            );
          }
          if (cancelToken?.isCancelled ?? false) {
            throw const ExportCancelledException();
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
        final totalFrames = editedMicros > 0
            ? (editedMicros * fps / 1000000).round()
            : sourceFramesFed;
        final inputDuration = editedMicros > 0
            ? editedMicros / 1000000.0
            : (totalFrames > 0 ? totalFrames / fps : 0.0);
        final outputBytes = await _fileLength(outputPath);

        // Blank-skipped frames were fed to ffmpeg but never composed —
        // divide composite time by the compose calls actually made.
        final compositeMsPerFrame = composedFrames > 0
            ? compositeSw1.elapsedMilliseconds / composedFrames
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
          warnings: warnings,
          skippedCompositeFrames: skippedFrames,
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
      // Reap subprocesses before removing their files. This matters on
      // platforms that keep an open output locked, and prevents a failed
      // pass from racing the recursive temp-directory deletion.
      _activeDecoder?.kill();
      final active = _activeProc;
      if (active != null) {
        active.kill(ProcessSignal.sigkill);
        try {
          await active.exitCode.timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
      _activeDecoder = null;
      _activeProc = null;
      _cacheHeartbeat?.cancel();
      _cacheHeartbeat = null;

      // Recursively delete the temp directory that holds the palette and
      // lossless frame cache.
      try {
        final dir = _paletteDir;
        if (dir != null && await dir.exists()) {
          await dir.delete(recursive: true);
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
    final directory = Directory.systemTemp.createTempSync(
      _cacheDirectoryPrefix,
    );
    _paletteDir = directory;
    final marker = File(
      '${directory.path}${Platform.pathSeparator}$_cacheMarkerName',
    );
    try {
      final writer = writeCacheMarkerForTesting;
      if (writer != null) {
        writer(marker);
      } else {
        marker.writeAsStringSync(
          jsonEncode({
            'kind': _cacheMarkerKind,
            'version': 1,
            'ownerPid': pid,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
      }
      _cacheHeartbeat?.cancel();
      _cacheHeartbeat = Timer.periodic(_cacheHeartbeatInterval, (_) {
        try {
          marker.setLastModifiedSync(DateTime.now().toUtc());
        } catch (_) {
          // Cleanup remains guarded by the live owner PID if a heartbeat
          // update loses a race with external temp maintenance.
        }
      });
      return '${directory.path}/palette.png';
    } catch (_) {
      _cacheHeartbeat?.cancel();
      _cacheHeartbeat = null;
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<int?> _availableBytes(String directoryPath) {
    final override = availableBytesForTesting;
    return override == null
        ? _availableBytesAt(directoryPath)
        : override(directoryPath);
  }

  static int _cacheFrameReserveBytes({
    required int width,
    required int height,
  }) {
    final rawBytes = width * height * 4;
    return rawBytes * 2 + _cacheFrameOverheadBytes;
  }

  Future<void> _enforceCacheHeadroom(
    String path,
    int byteLimit,
    int frameReserveBytes,
  ) async {
    final bytes = await _cacheLength(path);
    final projected = bytes + frameReserveBytes;
    if (projected > byteLimit) {
      throw GifCacheLimitExceededException(bytes: projected, limit: byteLimit);
    }
  }

  Future<void> _enforceCacheLimit(String path, int byteLimit) async {
    final bytes = await _cacheLength(path);
    if (bytes > byteLimit) {
      throw GifCacheLimitExceededException(bytes: bytes, limit: byteLimit);
    }
  }

  Future<int> _cacheLength(String path) async {
    final override = cacheLengthForTesting;
    if (override != null) return override(path);
    final file = File(path);
    return await file.exists() ? await file.length() : 0;
  }

  static Future<int?> _availableBytesAt(String directoryPath) async {
    try {
      if (Platform.isWindows) {
        // PowerShell is present on every supported Windows release. Passing
        // the path through an environment variable avoids interpolating an
        // arbitrary temp path into executable script text.
        final result = await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'[Console]::Out.Write((Get-Item -LiteralPath '
                r'$env:SLIPREEL_TEMP_PATH).PSDrive.Free)',
          ],
          environment: {'SLIPREEL_TEMP_PATH': directoryPath},
        );
        if (result.exitCode != 0) return null;
        return parseWindowsFreeSpaceOutput(result.stdout as String);
      }
      final result = await Process.run('df', ['-Pk', directoryPath]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String)
          .trim()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      if (lines.length < 2) return null;
      final columns = lines.last.trim().split(RegExp(r'\s+'));
      if (columns.length < 4) return null;
      final availableKb = int.tryParse(columns[3]);
      return availableKb == null ? null : availableKb * 1024;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cleanupStaleCacheDirectories() async {
    final now = DateTime.now().toUtc();
    try {
      await for (final entity in Directory.systemTemp.list()) {
        if (entity is! Directory ||
            !p.basename(entity.path).startsWith(_cacheDirectoryPrefix)) {
          continue;
        }
        try {
          final marker = File(
            '${entity.path}${Platform.pathSeparator}$_cacheMarkerName',
          );
          // A matching prefix alone is never enough authority for recursive
          // deletion. Require either our structured owner marker or the
          // timestamp-only marker written by older Slipreel versions.
          if (!await marker.exists()) continue;
          final owner = await _readCacheOwner(marker);
          if (owner == null) continue;
          final modified = (await marker.stat()).modified.toUtc();
          if (now.difference(modified) < _staleCacheAge) continue;
          final ownerPid = owner.ownerPid;
          if (ownerPid != null && await _isProcessAlive(ownerPid)) continue;
          await entity.delete(recursive: true);
        } catch (_) {
          // Another export/process may own it, or it may have disappeared.
        }
      }
    } catch (_) {
      // Temp enumeration is best-effort and must not block export startup.
    }
  }

  static Future<({int? ownerPid})?> _readCacheOwner(File marker) async {
    try {
      final raw = (await marker.readAsString()).trim();
      final legacyTimestamp = DateTime.tryParse(raw);
      if (legacyTimestamp != null) return (ownerPid: null);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['kind'] != _cacheMarkerKind ||
          decoded['version'] != 1 ||
          decoded['ownerPid'] is! num ||
          decoded['createdAt'] is! String ||
          DateTime.tryParse(decoded['createdAt'] as String) == null) {
        return null;
      }
      final ownerPid = (decoded['ownerPid'] as num).toInt();
      return ownerPid > 0 ? (ownerPid: ownerPid) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _isProcessAlive(int ownerPid) async {
    if (ownerPid == pid) return true;
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist.exe', [
          '/FI',
          'PID eq $ownerPid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        return result.exitCode == 0 &&
            (result.stdout as String).contains('"$ownerPid"');
      }
      final result = await Process.run('kill', ['-0', '$ownerPid']);
      return result.exitCode == 0;
    } catch (_) {
      // If liveness cannot be established, preserve the directory. A stale
      // cache leak is safer than deleting an active export's working set.
      return true;
    }
  }

  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }
}

@visibleForTesting
int? parseWindowsFreeSpaceOutput(String output) => int.tryParse(output.trim());

class GifCacheLimitExceededException implements Exception {
  const GifCacheLimitExceededException({
    required this.bytes,
    required this.limit,
  });

  final int bytes;
  final int limit;

  @override
  String toString() =>
      'GIF lossless cache exceeded its ${limit ~/ (1024 * 1024)} MiB '
      'safety limit (currently ${bytes ~/ (1024 * 1024)} MiB). Shorten the '
      'GIF, lower its resolution/frame rate, or export MP4 instead.';
}

/// Ensures [state.timeline.clips] is non-empty for filter-graph construction.
/// B-era recordings (no saved editor project) have an empty slice list —
/// synthesize a full-source slice so the N-slice video graph degenerates
/// cleanly to N=1. Mirrors the same helper in `export_pipeline.dart`.
EditorProjectState _ensureSlices(
  EditorProjectState state,
  Duration sourceDuration,
) {
  if (state.timeline.clips.isNotEmpty) return state;
  final span = sourceDuration > Duration.zero
      ? sourceDuration
      : const Duration(milliseconds: 1);
  return state.copyWith(
    timeline: state.timeline.copyWith(
      clips: [ClipSlice(cutStart: Duration.zero, cutEnd: span)],
    ),
  );
}

/// Pass-1 `-filter_complex` payload: per-slice video chains + concat from
/// the N-slice helper → `[outv]`, then a scale/pad stage to the export
/// resolution, then `palettegen` → `[outpal]`. The encoder maps `[outpal]`
/// to write `palette.png`.
@visibleForTesting
String buildGifPass1FilterComplex({
  required NSliceFilterGraph videoGraph,
  required int outWidth,
  required int outHeight,
  required GifPaletteSettings paletteSettings,
}) {
  final videoLabel = videoGraph.videoMapLabel ?? '[outv]';
  return '${videoGraph.filterComplex};'
      '${videoLabel}scale=$outWidth:$outHeight:'
      'force_original_aspect_ratio=decrease,'
      'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black,'
      'palettegen=max_colors=${paletteSettings.maxColors}:stats_mode=full'
      '[outpal]';
}

/// Production pass-1 graph: the edited/scaled stream is split so palettegen
/// and a lossless FFV1 cache receive the exact same composed frames. Pass 2
/// can then palette-use the cache without decoding and compositing the source
/// a second time.
@visibleForTesting
String buildGifCachedPass1FilterComplex({
  required NSliceFilterGraph videoGraph,
  required int outWidth,
  required int outHeight,
  required GifPaletteSettings paletteSettings,
}) {
  final videoLabel = videoGraph.videoMapLabel ?? '[outv]';
  return '${videoGraph.filterComplex};'
      '${videoLabel}scale=$outWidth:$outHeight:'
      'force_original_aspect_ratio=decrease,'
      'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black'
      '[scaled];'
      '[scaled]split=2[gifcache][palin];'
      '[palin]palettegen=max_colors=${paletteSettings.maxColors}:'
      'stats_mode=full[outpal]';
}

/// Pass-2 `-filter_complex` payload: per-slice video chains + concat from
/// the N-slice helper → `[outv]`, then a scale/pad stage → `[scaled]`,
/// then `paletteuse` against the palette PNG fed as `[1:v]` → `[gifout]`.
@visibleForTesting
String buildGifPass2FilterComplex({
  required NSliceFilterGraph videoGraph,
  required int outWidth,
  required int outHeight,
  required GifPaletteSettings paletteSettings,
}) {
  final videoLabel = videoGraph.videoMapLabel ?? '[outv]';
  return '${videoGraph.filterComplex};'
      '${videoLabel}scale=$outWidth:$outHeight:'
      'force_original_aspect_ratio=decrease,'
      'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black'
      '[scaled];'
      '[scaled][1:v]paletteuse=dither=${paletteSettings.dither}'
      '[gifout]';
}
