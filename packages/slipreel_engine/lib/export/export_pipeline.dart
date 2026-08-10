// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;
import 'package:flutter/foundation.dart' show visibleForTesting;
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
import '../utils/perf_summary.dart';
import '../utils/app_logger.dart';
import 'bounded_async_queue.dart';
import 'camera_frame_source.dart';
import 'export_cancellation.dart';
import 'export_compositor.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_encoder.dart';
import 'ffmpeg_probe.dart';
import 'frame_compositor.dart';
import 'n_slice_filter_graph.dart';

/// Whether the export should run the camera-PiP pass: all four conditions must
/// hold (a `.camera.json` sidecar exists, the project has the camera enabled,
/// at least one camera region, and the `.camera.mov` file is present).
bool shouldCompositeCamera({
  required bool hasSidecar,
  required bool enabled,
  required bool hasRegions,
  required bool movieExists,
}) => hasSidecar && enabled && hasRegions && movieExists;

/// User-facing warning when the camera couldn't be decoded and the export
/// finished screen-only. Single source of truth (set at decode-setup failure
/// and again if the source disables itself mid-encode).
const String _kCameraDecodeWarning =
    'Camera could not be decoded; exported without the camera overlay.';

/// Orchestrates: decode source MP4 → composite (wallpaper + frame +
/// video + cursor + zoom) via [FrameCompositor] → encode HW.
///
/// The compositor renders at the framed `totalSize` (videoSize +
/// effective padding) so the export matches the editor preview pixel
/// for pixel; ffmpeg's filter_complex then handles per-slice trim,
/// speed, fades, audio mix, and scale/pad-to-output-resolution.
///
/// N-slice model: per-slice `trim=trimStart:trimEnd`, `setpts`, fades, and
/// audio chains are emitted by [buildExportFilterGraph] and fed to the
/// encoder's `-filter_complex`. Single-slice and empty-timeline projects
/// both go through this path (N=1 produces `concat=n=1`, empty timelines
/// synthesize a full-source slice).
class ExportPipeline {
  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;

  /// The full editor project — wallpaper, frame chrome, zoom regions,
  /// animation configs, cursor visuals, and the timeline's slice list
  /// (per-slice trim/speed/fade/audio). Loaded from the
  /// `<videoPath>.editor.json` sidecar by the caller.
  final EditorProjectState projectState;

  /// Export settings: resolution, compression, frame rate, and destination.
  /// Must have [ExportSettings.format] == [ExportFormat.mp4].
  final ExportSettings settings;

  /// Optional device-frame catalog forwarded to [FrameCompositor]. When
  /// non-null and the project's [WindowFrame.deviceFrameId] resolves an
  /// entry, the compositor renders the device-frame shell instead of the
  /// chrome path — matching the editor preview pixel-for-pixel.
  final DeviceFrameCatalog? deviceFrameCatalog;

  /// Immutable session motion tuning captured when export starts.
  final MotionTuning motionTuning;

  @visibleForTesting
  final Future<void> Function(FfmpegEncoder encoder)? finishForTesting;

  // Cache for a single ffprobe result per pipeline instance.
  FfmpegProbeResult? _probeCache;

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.projectState,
    required this.settings,
    this.deviceFrameCatalog,
    this.motionTuning = MotionTuning.defaults,
    this.finishForTesting,
  }) {
    if (settings.format != ExportFormat.mp4) {
      throw ArgumentError.value(
        settings.format,
        'settings.format',
        'ExportPipeline handles MP4 only — pass GIF settings to GifExportPipeline.',
      );
    }
  }

  /// [onProgress] is called after every encoded frame with a value in
  /// `[0, 1]`. The denominator is `ffprobe`'s `nb_frames`; if that's
  /// unavailable the callback is suppressed (a determinate UI would
  /// rather show nothing than a wildly-wrong percentage).
  ///
  /// Single-use: each pipeline instance and each [cancelToken] is meant for
  /// one [run] call. The `whenCancelled` handler is wired per run, so don't
  /// reuse a [CancelToken] across runs (kill()/close() are idempotent, so
  /// reuse is currently harmless, but the assumption may tighten later).
  Future<ExportPerfSummary> run({
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const ExportCancelledException();
    }
    // ffprobe is authoritative for dimensions. Recording metadata
    // stores the *capture* width/height returned by the native plugin,
    // which can differ from what the encoder actually wrote to the
    // MP4 (e.g., padded to even values for codec compatibility). If
    // we trust metadata and the real decoded frames are even one row
    // taller, ffmpeg streams those extra bytes after each frame and
    // our frameSize-based slicer drifts a few bytes per frame —
    // showing up as a slow bottom-to-top scrolling effect on export.
    final probed = _probeCache ??= await ffmpegProbe(
      path: sourcePath,
      metadataFps: sourceMetadata.fps,
    );
    if (cancelToken?.isCancelled ?? false) {
      throw const ExportCancelledException();
    }
    final srcWidth = probed.width;
    final srcHeight = probed.height;

    // Output dimensions follow the COMPOSITED canvas (aspect + padding),
    // not the raw source. Without this, a vertical-9:16 export at 1080p
    // would still produce a 16:9 MP4 because `dimensionsFor` would
    // width-scale from the raw 1920×1080 source aspect instead of the
    // 9:16 canvas the user picked.
    final composedCanvas = OutputCanvasResolver.resolve(
      videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
      padding: projectState.windowFrame.padding,
      aspect: projectState.outputAspect,
    ).canvasSize;
    final outDims = settings.resolution.dimensionsFor(composedCanvas);
    final outWidth = outDims.width.toInt();
    final outHeight = outDims.height.toInt();
    final outFps = settings.frameRate;
    final bitrateKbps = effectiveBitrateKbps(
      settings.resolution,
      settings.compression,
      settings.frameRate,
    );

    // Drive the entire pipeline at the chosen output rate. The decoder
    // resamples the source (which may be VFR, e.g. SCStream skips
    // unchanged frames) to constant-rate outFps via `-vf fps=`; the
    // compositor samples cursor / zoom animations at outFps; the
    // encoder pipes through 1:1 with no internal up/downsample. Going
    // through a single rate eliminates the jitter caused by mislabeling
    // VFR frames as evenly spaced or by ffmpeg duplicating/dropping
    // frames internally to bridge two different rates.
    final pipelineFps = outFps;

    final decodedVideoSize = recommendedVideoDecodeSize(
      sourceSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
      composedCanvas: composedCanvas,
      outputSize: Size(outWidth.toDouble(), outHeight.toDouble()),
      maxZoom: projectState.zoomRegions.fold<double>(
        1.0,
        (value, region) => region.zoomLevel > value ? region.zoomLevel : value,
      ),
      // Device bezel/screen geometry does not share the standard composed
      // canvas ratio, so keep native pixels until it has its own resolver.
      allowDownscale: projectState.windowFrame.deviceFrameId == null,
    );

    final sourceDuration = probed.durationSec != null
        ? Duration(microseconds: (probed.durationSec! * 1000000).round())
        : Duration.zero;
    final slicedState = _ensureSlices(projectState, sourceDuration);
    final progressClips = slicedState.timeline.clips;
    final skipMargin = Duration(
      microseconds: (1000000 + pipelineFps - 1) ~/ pipelineFps,
    );
    final firstNeeded = progressClips
        .map((clip) => clip.trimStart)
        .reduce((a, b) => a < b ? a : b);
    final lastNeeded = progressClips
        .map((clip) => clip.trimEnd)
        .reduce((a, b) => a > b ? a : b);
    final decodeStartFrame =
        (((firstNeeded - skipMargin).inMicroseconds).clamp(0, 1 << 62) *
            pipelineFps) ~/
        1000000;
    final decodeStart = Duration(
      microseconds: (1000000 * decodeStartFrame) ~/ pipelineFps,
    );
    final decodeEnd =
        sourceDuration > Duration.zero &&
            lastNeeded + skipMargin > sourceDuration
        ? sourceDuration
        : lastNeeded + skipMargin;

    // Camera PiP (Plan 3): composite the webcam sidecar into export frames when
    // present + enabled. Decode failures degrade gracefully (warning, no abort).
    final warnings = <String>[];
    final cameraMeta = await CameraSidecarMeta.loadForVideo(sourcePath);
    if (cancelToken?.isCancelled ?? false) {
      throw const ExportCancelledException();
    }
    final cameraMoviePath = CameraSidecarMeta.moviePathForVideo(sourcePath);
    final compositeCamera = shouldCompositeCamera(
      hasSidecar: cameraMeta != null,
      enabled: projectState.cameraSettings.enabled,
      hasRegions: projectState.cameraRegions.isNotEmpty,
      movieExists: File(cameraMoviePath).existsSync(),
    );
    CameraFrameSource? cameraSource;
    double cameraOriginalAspect = 1.0;
    int cameraSrcWidth = 0;
    int cameraSrcHeight = 0;
    if (compositeCamera) {
      try {
        cameraSrcWidth = cameraMeta!.width;
        cameraSrcHeight = cameraMeta.height;
        cameraOriginalAspect = cameraSrcHeight == 0
            ? 1.0
            : cameraSrcWidth / cameraSrcHeight;
        final decodedCameraSize = recommendedCameraDecodeSize(
          sourceSize: Size(
            cameraSrcWidth.toDouble(),
            cameraSrcHeight.toDouble(),
          ),
          outputSize: Size(outWidth.toDouble(), outHeight.toDouble()),
          maxSizeFraction: projectState.cameraRegions.fold<double>(
            0,
            (value, region) => region.size > value ? region.size : value,
          ),
          shapeAspect: projectState.cameraSettings.shape.pixelAspect(
            cameraOriginalAspect,
          ),
        );
        final cameraOffsetFrames = (cameraMeta.offsetMicros * pipelineFps / 1e6)
            .round();
        final cameraFirstFrame = decodeStartFrame - cameraOffsetFrames > 0
            ? decodeStartFrame - cameraOffsetFrames
            : 0;
        final cameraStart = Duration(
          microseconds: (1000000 * cameraFirstFrame) ~/ pipelineFps,
        );
        final camDecoder = FfmpegDecoder(
          inputPath: cameraMoviePath,
          width: cameraSrcWidth,
          height: cameraSrcHeight,
          cfrFps: pipelineFps,
          outputWidth: decodedCameraSize.width.toInt(),
          outputHeight: decodedCameraSize.height.toInt(),
          startTime: cameraStart,
        );
        cameraSrcWidth = decodedCameraSize.width.toInt();
        cameraSrcHeight = decodedCameraSize.height.toInt();
        cameraSource = CameraFrameSource(
          frames: camDecoder.frames(),
          fps: pipelineFps,
          offsetMicros: cameraMeta.offsetMicros,
          firstFrameIndex: cameraFirstFrame,
          // Reap the camera ffmpeg subprocess on teardown — cancelling the
          // stream iterator alone leaves it blocked on a full stdout pipe.
          onDispose: camDecoder.kill,
        );
      } catch (e, st) {
        AppLogger.ffmpeg.w(
          'Camera export decode setup failed: $e',
          error: e,
          stackTrace: st,
        );
        cameraSource = null;
        warnings.add(_kCameraDecodeWarning);
      }
    }

    final ExportCompositor compositor = InProcessExportCompositor(
      FrameCompositor(
        projectState: projectState,
        cursorRecording: cursorRecording,
        metadata: sourceMetadata,
        videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
        decodedVideoSize: decodedVideoSize,
        fps: pipelineFps,
        cameraFrameSource: cameraSource,
        cameraOriginalAspect: cameraOriginalAspect,
        cameraSrcWidth: cameraSrcWidth,
        cameraSrcHeight: cameraSrcHeight,
        deviceFrameCatalog: deviceFrameCatalog,
        motionTuning: motionTuning,
        // Downscale-only hint: when the export resolution is smaller than
        // the composed canvas the compositor renders directly at output
        // size (see FrameCompositor.renderSize); otherwise ignored.
        outputSize: Size(outWidth.toDouble(), outHeight.toDouble()),
      ),
    );

    final decoder = FfmpegDecoder(
      inputPath: sourcePath,
      width: srcWidth,
      height: srcHeight,
      cfrFps: pipelineFps,
      outputWidth: decodedVideoSize.width.toInt(),
      outputHeight: decodedVideoSize.height.toInt(),
      startTime: decodeStart,
      endTime: decodeEnd,
    );

    // Build the per-slice ffmpeg filter graph. Per-slice trim/setpts/fade/
    // atempo/concat/amix all live in this string; the encoder just routes
    // the composed-frames stdin + audio-source-file pair through it.
    final base = buildExportFilterGraph(
      state: slicedState,
      audioStreams: probed.audioStreams,
      videoTimeOffset: decodeStart,
    );
    final filterComplex = _composeWithScalePad(
      base.filterComplex,
      videoLabel: base.videoMapLabel ?? '[outv]',
      outWidth: outWidth,
      outHeight: outHeight,
    );
    final videoMapLabel = '[outv_scaled]';
    final audioMapLabel = base.audioMapLabel;

    // Output duration: sum over slices of effectiveLength / playbackSpeed.
    final outputDurationSec = _slicedOutputSeconds(slicedState.timeline.clips);

    final encoder = FfmpegEncoder(
      outputPath: outputPath,
      width: outWidth,
      height: outHeight,
      fps: outFps,
      bitrateKbps: bitrateKbps,
      audioSourcePath: audioMapLabel != null ? sourcePath : null,
      filterComplex: filterComplex,
      videoOutLabel: videoMapLabel,
      audioOutLabel: audioMapLabel,
      // Composited frames arrive at renderSize (totalSize unless the
      // compositor is downscale-rendering); the filter graph handles the
      // trim/concat/fade then post-processes to outWidth × outHeight.
      sourceWidth: compositor.renderSize.width.toInt(),
      sourceHeight: compositor.renderSize.height.toInt(),
      sourceFps: pipelineFps,
      pixelFormat: FfmpegPixelFormat.rgba,
    );

    final decodedQueue =
        BoundedAsyncQueue<({int sourceIndex, Uint8List bytes})>(2);
    final composedQueue =
        BoundedAsyncQueue<({int sourceIndex, Uint8List bytes})>(2);
    cancelToken?.whenCancelled.then((_) {
      decoder.kill();
      encoder.kill();
      unawaited(cameraSource?.dispose() ?? Future.value());
      decodedQueue.close();
      composedQueue.close();
    });

    if (cancelToken?.isCancelled ?? false) {
      decodedQueue.close();
      composedQueue.close();
      await compositor.dispose();
      await cameraSource?.dispose();
      throw const ExportCancelledException();
    }
    try {
      await encoder.start();
    } catch (_) {
      await compositor.dispose();
      await cameraSource?.dispose();
      if (cancelToken?.isCancelled ?? false) {
        throw const ExportCancelledException();
      }
      rethrow;
    }
    // Cancellation can land while the hardware probe or Process.start is
    // pending, before encoder.kill() has a process handle. Recheck with the
    // newly-started encoder wired, reap it, and remove the fragment.
    if (cancelToken?.isCancelled ?? false) {
      encoder.kill();
      try {
        await encoder.finish();
      } catch (_) {}
      await compositor.dispose();
      await cameraSource?.dispose();
      try {
        final out = File(outputPath);
        if (await out.exists()) await out.delete();
      } catch (_) {}
      throw const ExportCancelledException();
    }

    final wallSw = Stopwatch()..start();
    final compositeSw = Stopwatch();
    int totalFrames = 0;
    int skippedFrames = 0;
    int composedFrames = 0;

    // Progress inputs. Frames are fed to ffmpeg at SOURCE cadence
    // (leading trims, gaps, and sped-up slices all pass through the
    // pipe and are dropped by the filter graph), so frame counts can't
    // be compared against the edited output length — that pinned the
    // bar at 100% halfway through any back-trimmed export. Instead the
    // encode stage maps each fed frame's source timestamp through
    // editedProgressAtSource. The probed source duration is only a
    // fallback for the no-slice-data case.
    final probedDurationSec = probed.durationSec;
    final Duration? sourceFallbackTotal =
        (probedDurationSec != null && probedDurationSec > 0)
        ? Duration(microseconds: (probedDurationSec * 1e6).round())
        : null;

    // Three-stage producer/consumer pipeline. Decode reads from ffmpeg's
    // stdout, compose rasterizes the frame chrome + cursor + zoom, encode
    // pipes the result to the encoder's stdin. Without queues, each frame
    // serializes through all three; the encoder sits idle while compose
    // awaits Picture.toImage, the decoder sits idle while the encoder's
    // stdin flush awaits, etc. Capacity-2 queues give each stage one
    // frame in hand and one in flight so adjacent stages overlap their
    // I/O, while still bounding memory (a composed RGBA frame is ~10MB
    // at 1440p, so worst case ~7 frames in flight ≈ 70MB).
    final decodeFuture = () async {
      try {
        var sourceIndex = decodeStartFrame;
        await for (final raw in decoder.frames()) {
          if (decodedQueue.isClosed) break;
          try {
            await decodedQueue.add((sourceIndex: sourceIndex, bytes: raw));
            sourceIndex++;
          } on StateError {
            // Encode stage closed the queue early (e.g., ffmpeg's filter
            // trim was satisfied so it stopped consuming stdin). Cooperative
            // exit — not a pipeline failure.
            break;
          }
        }
      } finally {
        decodedQueue.close();
      }
    }();

    // Slice-aware skip: frames outside every slice's [trimStart, trimEnd]
    // window (plus a one-frame margin for trim-boundary rounding) are
    // dropped by the filter graph, so their pixels never reach the output.
    // Feed a single reused blank buffer instead of composing them — the
    // encoder awaits stdin.flush() per write and the buffer is never
    // mutated, so reuse across queue slots is safe. Scene state still
    // advances (see ExportCompositor.advance) so kept frames after a gap
    // stay byte-identical to a full compose.
    Uint8List? blankFrame;

    Uint8List blank() => blankFrame ??= Uint8List(
      compositor.renderSize.width.toInt() *
          compositor.renderSize.height.toInt() *
          4,
    );

    Future<bool> enqueueSourceFrame({
      required int sourceIndex,
      Uint8List? raw,
    }) async {
      final scenePosition = Duration(
        microseconds: (1000000 * sourceIndex) ~/ pipelineFps,
      );
      final Uint8List composited;
      if (raw == null ||
          !sourceFrameContributes(
            progressClips,
            scenePosition,
            margin: skipMargin,
          )) {
        await advanceExportCompositor(compositor, scenePosition);
        skippedFrames++;
        composited = blank();
      } else {
        compositeSw.start();
        try {
          composited = await compositor.compose(
            bgra: raw,
            position: scenePosition,
          );
          composedFrames++;
        } finally {
          compositeSw.stop();
        }
      }
      try {
        await composedQueue.add((sourceIndex: sourceIndex, bytes: composited));
        return true;
      } on StateError {
        // The encoder completed its trim window and closed the queue.
        return false;
      }
    }

    final composeFuture = () async {
      try {
        // Prime the stateful controllers once immediately before the seek
        // window. A leading trim is a hard output boundary, so replaying every
        // removed frame from source time zero is both unnecessary and wrong
        // for very long recordings: the first retained frame must start from
        // reset state, not inherit motion from footage that does not exist in
        // the edited timeline.
        if (decodeStartFrame > 0) {
          final sourceMicros =
              (1000000 * (decodeStartFrame - 1)) ~/ pipelineFps;
          await advanceExportCompositor(
            compositor,
            Duration(microseconds: sourceMicros),
          );
          skippedFrames += decodeStartFrame;
          final progress = editedProgressAtSource(
            progressClips,
            Duration(microseconds: sourceMicros),
            sourceFallbackTotal: sourceFallbackTotal,
          );
          if (progress != null) onProgress?.call(progress);
        }

        while (true) {
          final decoded = await decodedQueue.take();
          if (decoded == null) break;
          if (composedQueue.isClosed) break;
          // The decoder is configured with `-vf fps=pipelineFps`, so
          // frames arrive at strictly constant cadence regardless of
          // whether the source is VFR. Per-index timing is therefore
          // accurate against the cursor recording's wall clock.
          //
          // Frames arrive at source-time (the decoder no longer
          // trims) — cursor / zoom sampling is direct.
          if (!await enqueueSourceFrame(
            sourceIndex: decoded.sourceIndex,
            raw: decoded.bytes,
          )) {
            break;
          }
        }
      } finally {
        composedQueue.close();
      }
    }();

    final encodeFuture = () async {
      while (true) {
        final composed = await composedQueue.take();
        if (composed == null) break;
        final stillOpen = await encoder.writeFrame(composed.bytes);
        if (!stillOpen) {
          // ffmpeg closed stdin early — typically because the filter graph's
          // trim window is satisfied and ffmpeg has all frames it needs.
          // Drop any remaining frames; tear down the upstream stages.
          //
          // Correctness here relies on FfmpegDecoder treating `kill()`
          // followed by SIGKILL-exit as a clean stream termination (the
          // `frames()` stream ends cleanly rather than raising). The
          // aggressive-trim regression test in
          // export_pipeline_trim_test.dart pins that contract; if a
          // future decoder refactor makes SIGKILL surface as an exception
          // here, the test will fail and the cooperative teardown will
          // need an explicit catch.
          decoder.kill();
          decodedQueue.close();
          composedQueue.close();
          break;
        }
        totalFrames++;
        if (onProgress != null) {
          final sourceMicros = (1000000 * composed.sourceIndex) ~/ pipelineFps;
          final progress = editedProgressAtSource(
            progressClips,
            Duration(microseconds: sourceMicros),
            sourceFallbackTotal: sourceFallbackTotal,
          );
          if (progress != null) onProgress(progress);
        }
      }
    }();

    final stageFutures = [decodeFuture, composeFuture, encodeFuture];
    try {
      await Future.wait(stageFutures, eagerError: true);
    } catch (_) {
      decoder.kill();
      encoder.kill();
      // First stage to fail surfaces here. Close the queues so any
      // sibling stage parked on take/add unblocks and exits, then wait
      // for them to fully wind down before we tear the compositor down
      // — letting them leak into the background risks them touching
      // disposed engine resources.
      decodedQueue.close();
      composedQueue.close();
      await Future.wait(
        stageFutures.map((f) => f.then<void>((_) {}, onError: (_) {})),
      );
      await compositor.dispose();
      await cameraSource?.dispose();
      // The encoder was killed mid-write, so any output on disk is a
      // truncated fragment — delete it so a cancelled/failed export isn't
      // mistaken for a real MP4.
      try {
        final out = File(outputPath);
        if (await out.exists()) await out.delete();
      } catch (_) {}
      if (cancelToken?.isCancelled ?? false) {
        throw const ExportCancelledException();
      }
      rethrow;
    }
    await compositor.dispose();
    await cameraSource?.dispose();

    // Cancellation can fire AFTER the stages all unblock cleanly (kill +
    // queue close drain everyone without an error). Detect that here so
    // encoder.finish() doesn't trip the "ffmpeg exited -9" path and
    // surface the right ExportCancelledException to the caller.
    if (cancelToken?.isCancelled ?? false) {
      try {
        await encoder.finish();
      } catch (_) {
        // Expected: the encoder was killed; finish() throws.
      }
      try {
        final out = File(outputPath);
        if (await out.exists()) await out.delete();
      } catch (_) {}
      throw const ExportCancelledException();
    }

    try {
      final finish = finishForTesting;
      if (finish == null) {
        await encoder.finish();
      } else {
        await finish(encoder);
      }
    } catch (_) {
      // Late codec/mux/disk failures surface only while ffmpeg finalizes.
      // They are still failed exports, so never leave a playable-looking but
      // truncated file behind.
      try {
        final out = File(outputPath);
        if (await out.exists()) await out.delete();
      } catch (_) {}
      if (cancelToken?.isCancelled ?? false) {
        throw const ExportCancelledException();
      }
      rethrow;
    }
    wallSw.stop();

    // The cooperative early-exit (ffmpeg trim-closes stdin before the
    // final fed frame is counted) can leave the last reported value a
    // hair under 1.0 — pin the bar on success.
    onProgress?.call(1.0);

    final wallSec = wallSw.elapsedMilliseconds / 1000.0;
    final inputDuration = outputDurationSec > 0
        ? outputDurationSec
        : (totalFrames > 0 ? totalFrames / pipelineFps : 0.0);
    final outputBytes = await _fileLength(outputPath);

    // A camera decode error can surface mid-encode (the source disables itself
    // on the first failed read). Capture it as a warning so the export still
    // succeeds, just without the overlay.
    if (cameraSource?.failed == true &&
        !warnings.contains(_kCameraDecodeWarning)) {
      warnings.add(_kCameraDecodeWarning);
    }

    // Blank-skipped frames pass through the encode stage (they're counted
    // in totalFrames) but never touch the compositor — divide composite
    // time by the frames actually composed.
    final summary = ExportPerfSummary(
      inputDurationSeconds: inputDuration,
      wallTimeSeconds: wallSec,
      decodeMsPerFrame: totalFrames > 0
          ? decoder.totalDecodeMs / totalFrames
          : 0,
      compositeMsPerFrame: composedFrames > 0
          ? compositeSw.elapsedMilliseconds / composedFrames
          : 0,
      encodeMsPerFrame: totalFrames > 0
          ? encoder.totalEncodeMs / totalFrames
          : 0,
      outputBytes: outputBytes,
      outputCodec: encoder.codecUsed,
      usedHardwareEncoder: encoder.usedHardware,
      warnings: warnings,
      skippedCompositeFrames: skippedFrames,
    );
    AppLogger.ffmpeg.i(summary.format());
    return summary;
  }

  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }
}

/// Decode resolution needed to preserve all source detail that can become
/// visible at the export's strongest zoom. Logical scene geometry remains in
/// [sourceSize]; only the raw pixel transport is reduced.
Size recommendedVideoDecodeSize({
  required Size sourceSize,
  required Size composedCanvas,
  required Size outputSize,
  required double maxZoom,
  bool allowDownscale = true,
}) {
  if (!allowDownscale || sourceSize.isEmpty || composedCanvas.isEmpty) {
    return sourceSize;
  }
  final rasterScale = (outputSize.width / composedCanvas.width).clamp(0.0, 1.0);
  final rasterScaleY = (outputSize.height / composedCanvas.height).clamp(
    0.0,
    1.0,
  );
  final neededScale =
      ((rasterScale < rasterScaleY ? rasterScale : rasterScaleY) *
              (maxZoom < 1 ? 1 : maxZoom))
          .clamp(0.0, 1.0);
  return _evenScaledSize(sourceSize, neededScale);
}

/// Decode resolution for a camera sidecar. The PiP is canvas-fixed and never
/// needs more pixels than its largest physical output box; retain 25% headroom
/// for filtering/reveal transforms.
Size recommendedCameraDecodeSize({
  required Size sourceSize,
  required Size outputSize,
  required double maxSizeFraction,
  required double shapeAspect,
}) {
  if (sourceSize.isEmpty || maxSizeFraction <= 0 || shapeAspect <= 0) {
    return sourceSize;
  }
  final boxWidth = outputSize.width * maxSizeFraction;
  final boxHeight = boxWidth / shapeAspect;
  final scaleX = boxWidth / sourceSize.width;
  final scaleY = boxHeight / sourceSize.height;
  final neededScale = ((scaleX > scaleY ? scaleX : scaleY) * 1.25).clamp(
    0.0,
    1.0,
  );
  return _evenScaledSize(sourceSize, neededScale);
}

Size _evenScaledSize(Size source, double scale) {
  int even(double value, double max) {
    final limit = max.toInt();
    if (limit <= 1) return limit;
    var result = (value / 2).ceil() * 2;
    if (result > limit) result = limit.isEven ? limit : limit - 1;
    return result < 2 ? 2 : result;
  }

  return Size(
    even(source.width * scale, source.width).toDouble(),
    even(source.height * scale, source.height).toDouble(),
  );
}

/// Ensures [state.timeline.clips] is non-empty. B-era recordings (no saved
/// editor project) have an empty slice list — synthesize a full-source slice
/// so the N-slice filter graph degenerates cleanly to N=1.
EditorProjectState _ensureSlices(
  EditorProjectState state,
  Duration sourceDuration,
) {
  if (state.timeline.clips.isNotEmpty) return state;
  // Use sourceDuration as the cut span; if sourceDuration is zero (probe
  // failed to report) fall back to 1ms so ClipSlice's clamps don't throw.
  final span = sourceDuration > Duration.zero
      ? sourceDuration
      : const Duration(milliseconds: 1);
  return state.copyWith(
    timeline: state.timeline.copyWith(
      clips: [ClipSlice(cutStart: Duration.zero, cutEnd: span)],
    ),
  );
}

/// Sum of slice output durations: `Σ effectiveLength / playbackSpeed`.
/// Frames the encoder will emit for the progress denominator. m9: prefer the
/// EDITED output length ([outputDurationSec], which already accounts for slice
/// trims and per-slice playback speed) so trimmed exports reach 100%. Falls
/// back to the probed source duration, then to scaling nb_frames by the rate
/// ratio, and finally null (indeterminate) when nothing usable is available.
int? expectedOutputFrames({
  required double outputDurationSec,
  required int pipelineFps,
  double? sourceDurationSec,
  int? sourceNbFrames,
  num sourceFps = 0,
}) {
  if (outputDurationSec > 0) {
    return (outputDurationSec * pipelineFps).round();
  }
  if (sourceDurationSec != null && sourceDurationSec > 0) {
    return (sourceDurationSec * pipelineFps).round();
  }
  if (sourceNbFrames != null && sourceFps > 0) {
    return (sourceNbFrames * pipelineFps / sourceFps).round();
  }
  return null;
}

double _slicedOutputSeconds(List<ClipSlice> clips) {
  var acc = 0.0;
  for (final c in clips) {
    if (c.playbackSpeed <= 0) continue;
    acc += (c.effectiveLength.inMicroseconds / 1000000) / c.playbackSpeed;
  }
  return acc;
}

/// Wraps the N-slice graph's `[outv]` in a final scale/pad stage so the
/// composed/concatted video lands at the export resolution. Returns a single
/// filter_complex string that produces `[outv_scaled]` (and the original
/// `[outa]` if present, untouched).
String _composeWithScalePad(
  String base, {
  required String videoLabel,
  required int outWidth,
  required int outHeight,
}) {
  final scalePad =
      '${videoLabel}scale=$outWidth:$outHeight:'
      'force_original_aspect_ratio=decrease,'
      'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black,'
      'setsar=1[outv_scaled]';
  return '$base;$scalePad';
}
