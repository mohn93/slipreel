// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../models/cursor_recording.dart';
import '../models/recording_metadata.dart';
import '../state/editor_project_state.dart';
import '../utils/perf_summary.dart';
import '../utils/app_logger.dart';
import 'bounded_async_queue.dart';
import 'export_compositor.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_encoder.dart';
import 'ffmpeg_probe.dart';
import 'frame_compositor.dart';
import 'isolate_frame_compositor.dart';

/// Orchestrates: decode source MP4 → composite (wallpaper + frame +
/// video + cursor + zoom) via [FrameCompositor] → encode HW.
///
/// The compositor renders at the framed `totalSize` (videoSize +
/// effective padding) so the export matches the editor preview pixel
/// for pixel; ffmpeg's `-vf scale=...,pad=...` then fits/letterboxes
/// that into the user-chosen output preset.
class ExportPipeline {
  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;

  /// The full editor project — wallpaper, frame chrome, zoom regions,
  /// animation configs, and cursor visuals. Loaded from the
  /// `<videoPath>.editor.json` sidecar by the caller.
  final EditorProjectState projectState;

  final int bitrateKbps;

  /// Desired output dimensions / frame rate (from the chosen ExportPreset).
  final int outputWidth;
  final int outputHeight;
  final int outputFps;

  // Cache for a single ffprobe result per pipeline instance.
  FfmpegProbeResult? _probeCache;

  /// Off by default — `Picture.toImage` in a background isolate
  /// crashes the Flutter engine on macOS (segfaults on `flutter test`,
  /// "Lost connection to device" on a real desktop run). The isolate
  /// path stays in the tree behind this flag so we can revisit it
  /// once engine support stabilizes; until then, compose runs on the
  /// main isolate and we accept the throughput hit.
  final bool useIsolateCompositor;

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.projectState,
    required this.bitrateKbps,
    required this.outputWidth,
    required this.outputHeight,
    required this.outputFps,
    this.useIsolateCompositor = false,
  });

  /// [onProgress] is called after every encoded frame with a value in
  /// `[0, 1]`. The denominator is `ffprobe`'s `nb_frames`; if that's
  /// unavailable the callback is suppressed (a determinate UI would
  /// rather show nothing than a wildly-wrong percentage).
  Future<ExportPerfSummary> run({
    void Function(double progress)? onProgress,
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

    // Drive the entire pipeline at the chosen output rate. The decoder
    // resamples the source (which may be VFR, e.g. SCStream skips
    // unchanged frames) to constant-rate outputFps via `-vf fps=`; the
    // compositor samples cursor / zoom animations at outputFps; the
    // encoder pipes through 1:1 with no internal up/downsample. Going
    // through a single rate eliminates the jitter caused by mislabeling
    // VFR frames as evenly spaced or by ffmpeg duplicating/dropping
    // frames internally to bridge two different rates.
    final pipelineFps = outputFps;

    final ExportCompositor compositor = useIsolateCompositor
        ? await IsolateFrameCompositor.spawn(
            projectState: projectState,
            cursorRecording: cursorRecording,
            metadata: sourceMetadata,
            videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
            fps: pipelineFps,
          )
        : InProcessExportCompositor(FrameCompositor(
            projectState: projectState,
            cursorRecording: cursorRecording,
            metadata: sourceMetadata,
            videoSize: Size(srcWidth.toDouble(), srcHeight.toDouble()),
            fps: pipelineFps,
          ));

    final decoder = FfmpegDecoder(
      inputPath: sourcePath,
      width: srcWidth,
      height: srcHeight,
      cfrFps: pipelineFps,
    );
    final encoder = FfmpegEncoder(
      outputPath: outputPath,
      width: outputWidth,
      height: outputHeight,
      fps: outputFps,
      bitrateKbps: bitrateKbps,
      audioSourcePath: sourcePath,
      // The encoder receives composed frames at totalSize (the framed
      // output), not the source video resolution.
      sourceWidth: compositor.totalSize.width.toInt(),
      sourceHeight: compositor.totalSize.height.toInt(),
      sourceFps: pipelineFps,
      pixelFormat: FfmpegPixelFormat.rgba,
    );

    await encoder.start();

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
    final decodedQueue = BoundedAsyncQueue<Uint8List>(2);
    final composedQueue = BoundedAsyncQueue<Uint8List>(2);

    final decodeFuture = () async {
      try {
        await for (final raw in decoder.frames()) {
          await decodedQueue.add(raw);
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
          // The decoder is configured with `-vf fps=pipelineFps`, so
          // frames arrive at strictly constant cadence regardless of
          // whether the source is VFR. Per-index timing is therefore
          // accurate against the cursor recording's wall clock.
          final tsMicros = (1000000 * index) ~/ pipelineFps;
          compositeSw.start();
          final composited = await compositor.compose(
            bgra: raw,
            position: Duration(microseconds: tsMicros),
          );
          compositeSw.stop();
          await composedQueue.add(composited);
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
        await encoder.writeFrame(composed);
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
      rethrow;
    }
    await compositor.dispose();

    await encoder.finish();
    wallSw.stop();

    final wallSec = wallSw.elapsedMilliseconds / 1000.0;
    final inputDuration = totalFrames > 0 ? totalFrames / pipelineFps : 0.0;
    final outputBytes = await _fileLength(outputPath);

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
