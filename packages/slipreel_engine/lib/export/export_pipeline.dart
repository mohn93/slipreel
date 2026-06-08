// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../models/camera_sidecar_meta.dart';
import '../models/compression_bitrate.dart';
import '../models/cursor_recording.dart';
import '../models/export_settings.dart';
import '../models/recording_metadata.dart';
import '../rendering/output_canvas_resolver.dart';
import '../state/clip_slice.dart';
import '../state/editor_project_state.dart';
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
}) =>
    hasSidecar && enabled && hasRegions && movieExists;

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

  // Cache for a single ffprobe result per pipeline instance.
  FfmpegProbeResult? _probeCache;

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.projectState,
    required this.settings,
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

    // Camera PiP (Plan 3): composite the webcam sidecar into export frames when
    // present + enabled. Decode failures degrade gracefully (warning, no abort).
    final warnings = <String>[];
    final cameraMeta = await CameraSidecarMeta.loadForVideo(sourcePath);
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
        cameraOriginalAspect =
            cameraSrcHeight == 0 ? 1.0 : cameraSrcWidth / cameraSrcHeight;
        final camDecoder = FfmpegDecoder(
          inputPath: cameraMoviePath,
          width: cameraSrcWidth,
          height: cameraSrcHeight,
          cfrFps: pipelineFps,
        );
        cameraSource = CameraFrameSource(
          frames: camDecoder.frames(),
          fps: pipelineFps,
          offsetMicros: cameraMeta.offsetMicros,
        );
      } catch (e, st) {
        AppLogger.ffmpeg.w('Camera export decode setup failed: $e',
            error: e, stackTrace: st);
        cameraSource = null;
        warnings.add(
            'Camera could not be decoded; exported without the camera overlay.');
      }
    }

    final ExportCompositor compositor = InProcessExportCompositor(FrameCompositor(
      projectState: projectState,
      cursorRecording: cursorRecording,
      metadata: sourceMetadata,
      videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
      fps: pipelineFps,
      cameraFrameSource: cameraSource,
      cameraOriginalAspect: cameraOriginalAspect,
      cameraSrcWidth: cameraSrcWidth,
      cameraSrcHeight: cameraSrcHeight,
    ));

    final decoder = FfmpegDecoder(
      inputPath: sourcePath,
      width: srcWidth,
      height: srcHeight,
      cfrFps: pipelineFps,
    );

    // Resolve the slice list for the filter graph. An empty timeline (no
    // saved editor project, B-era recordings) gets a synthetic full-source
    // slice so the N-slice filter graph degenerates to a clean
    // concat=n=1 + scale/pad chain.
    final sourceDuration = probed.durationSec != null
        ? Duration(microseconds: (probed.durationSec! * 1000000).round())
        : Duration.zero;
    final slicedState = _ensureSlices(projectState, sourceDuration);

    // Build the per-slice ffmpeg filter graph. Per-slice trim/setpts/fade/
    // atempo/concat/amix all live in this string; the encoder just routes
    // the composed-frames stdin + audio-source-file pair through it.
    final base = buildExportFilterGraph(
      state: slicedState,
      audioStreams: probed.audioStreams,
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
      // Composited frames arrive at totalSize; the filter graph handles
      // the trim/concat/fade then post-processes to outWidth × outHeight.
      sourceWidth: compositor.totalSize.width.toInt(),
      sourceHeight: compositor.totalSize.height.toInt(),
      sourceFps: pipelineFps,
      pixelFormat: FfmpegPixelFormat.rgba,
    );

    await encoder.start();

    final decodedQueue = BoundedAsyncQueue<Uint8List>(2);
    final composedQueue = BoundedAsyncQueue<Uint8List>(2);
    cancelToken?.whenCancelled.then((_) {
      decoder.kill();
      encoder.kill();
      decodedQueue.close();
      composedQueue.close();
    });

    final wallSw = Stopwatch()..start();
    final compositeSw = Stopwatch();
    int totalFrames = 0;

    // After CFR-resampling at pipelineFps the actual frame count is
    // duration * pipelineFps. Prefer the probed duration (most
    // accurate); fall back to scaling nb_frames by the rate ratio if
    // duration was missing. If neither is available, leave it null —
    // the progress bar will stay indeterminate, which is preferable
    // to a wrong percentage. (Final so Dart can promote across the
    // encode-stage closure that reads it.)
    final int? expectedFrames = () {
      final dur = probed.durationSec;
      if (dur != null && dur > 0) {
        return (dur * pipelineFps).round();
      }
      final nb = probed.nbFrames;
      if (nb != null && probed.fps > 0) {
        return (nb * pipelineFps / probed.fps).round();
      }
      return null;
    }();

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
        await for (final raw in decoder.frames()) {
          if (decodedQueue.isClosed) break;
          try {
            await decodedQueue.add(raw);
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

    final composeFuture = () async {
      try {
        var index = 0;
        while (true) {
          final raw = await decodedQueue.take();
          if (raw == null) break;
          if (composedQueue.isClosed) break;
          // The decoder is configured with `-vf fps=pipelineFps`, so
          // frames arrive at strictly constant cadence regardless of
          // whether the source is VFR. Per-index timing is therefore
          // accurate against the cursor recording's wall clock.
          //
          // Frames arrive at source-time (the decoder no longer
          // trims) — cursor / zoom sampling is direct.
          final tsMicros = (1000000 * index) ~/ pipelineFps;
          final scenePosition = Duration(microseconds: tsMicros);
          compositeSw.start();
          final composited = await compositor.compose(
            bgra: raw,
            position: scenePosition,
          );
          compositeSw.stop();
          try {
            await composedQueue.add(composited);
          } on StateError {
            // Same cooperative-exit case as decode (see above).
            break;
          }
          index++;
        }
      } finally {
        composedQueue.close();
      }
    }();

    final encodeFuture = () async {
      while (true) {
        final composed = await composedQueue.take();
        if (composed == null) break;
        final stillOpen = await encoder.writeFrame(composed);
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
        if (onProgress != null &&
            expectedFrames != null &&
            expectedFrames > 0) {
          onProgress((totalFrames / expectedFrames).clamp(0.0, 1.0));
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

    await encoder.finish();
    wallSw.stop();

    final wallSec = wallSw.elapsedMilliseconds / 1000.0;
    final inputDuration = outputDurationSec > 0
        ? outputDurationSec
        : (totalFrames > 0 ? totalFrames / pipelineFps : 0.0);
    final outputBytes = await _fileLength(outputPath);

    // A camera decode error can surface mid-encode (the source disables itself
    // on the first failed read). Capture it as a warning so the export still
    // succeeds, just without the overlay.
    if (cameraSource?.failed == true &&
        !warnings.contains(
            'Camera could not be decoded; exported without the camera overlay.')) {
      warnings.add(
          'Camera could not be decoded; exported without the camera overlay.');
    }

    final summary = ExportPerfSummary(
      inputDurationSeconds: inputDuration,
      wallTimeSeconds: wallSec,
      decodeMsPerFrame: totalFrames > 0 ? decoder.totalDecodeMs / totalFrames : 0,
      compositeMsPerFrame: totalFrames > 0
          ? compositeSw.elapsedMilliseconds / totalFrames
          : 0,
      encodeMsPerFrame: totalFrames > 0 ? encoder.totalEncodeMs / totalFrames : 0,
      outputBytes: outputBytes,
      outputCodec: encoder.codecUsed,
      usedHardwareEncoder: encoder.usedHardware,
      warnings: warnings,
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
      clips: [
        ClipSlice(cutStart: Duration.zero, cutEnd: span),
      ],
    ),
  );
}

/// Sum of slice output durations: `Σ effectiveLength / playbackSpeed`.
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
  final scalePad = '${videoLabel}scale=$outWidth:$outHeight:'
      'force_original_aspect_ratio=decrease,'
      'pad=$outWidth:$outHeight:(ow-iw)/2:(oh-ih)/2:color=black,'
      'setsar=1[outv_scaled]';
  return '$base;$scalePad';
}
