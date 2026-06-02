// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../models/compression_bitrate.dart';
import '../models/cursor_recording.dart';
import '../models/export_settings.dart';
import '../models/recording_metadata.dart';
import '../models/trim_selection.dart';
import '../rendering/output_canvas_resolver.dart';
import '../state/audio_mix.dart';
import '../state/clip_slice.dart';
import '../state/editor_project_state.dart';
import '../utils/perf_summary.dart';
import '../utils/app_logger.dart';
import 'audio_mix_args.dart';
import 'bounded_async_queue.dart';
import 'export_cancellation.dart';
import 'export_compositor.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_encoder.dart';
import 'ffmpeg_probe.dart';
import 'frame_compositor.dart';

/// Orchestrates: decode source MP4 → composite (wallpaper + frame +
/// video + cursor + zoom) via [FrameCompositor] → encode HW.
///
/// The compositor renders at the framed `totalSize` (videoSize +
/// effective padding) so the export matches the editor preview pixel
/// for pixel; ffmpeg's `-vf scale=...,pad=...` then fits/letterboxes
/// that into the user-chosen output [ExportSettings].
class ExportPipeline {
  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;

  /// The full editor project — wallpaper, frame chrome, zoom regions,
  /// animation configs, and cursor visuals. Loaded from the
  /// `<videoPath>.editor.json` sidecar by the caller.
  final EditorProjectState projectState;

  /// Export settings: resolution, compression, frame rate, and destination.
  /// Must have [ExportSettings.format] == [ExportFormat.mp4].
  final ExportSettings settings;

  /// When set, only the slice [trim.start, trim.end] is exported.
  final TrimSelection? trim;

  // Cache for a single ffprobe result per pipeline instance.
  FfmpegProbeResult? _probeCache;

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.projectState,
    required this.settings,
    this.trim,
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

    final ExportCompositor compositor = InProcessExportCompositor(FrameCompositor(
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
      trim: trim,
    );
    // Slice-editor model: playback speed, fades, and the audio mix all live on
    // the timeline's first (and currently only) clip slice. Pipelines remain
    // single-slice for now; iterating multiple clips happens in a later phase.
    final clip0 = _firstClipOrEmpty(projectState);
    final audioMixPlan = buildAudioMixArgs(
      probed.audioStreams,
      AudioMix(
        micGainPercent: clip0.micGainPercent,
        micMuted: clip0.micMuted,
        systemGainPercent: clip0.systemGainPercent,
        systemMuted: clip0.systemMuted,
      ),
    );
    // Output duration after trim + speed, used to position the fade-out.
    final inputDurationSec = trim != null
        ? trim!.duration.inMicroseconds / 1000000
        : (probed.durationSec ?? 0);
    final outputDurationSec = inputDurationSec / clip0.playbackSpeed;
    final encoder = FfmpegEncoder(
      outputPath: outputPath,
      width: outWidth,
      height: outHeight,
      fps: outFps,
      bitrateKbps: bitrateKbps,
      audioSourcePath: sourcePath,
      audioMixPlan: audioMixPlan,
      trim: trim,
      playbackSpeed: clip0.playbackSpeed,
      fadeIn: clip0.fadeIn,
      fadeOut: clip0.fadeOut,
      outputDuration: outputDurationSec > 0
          ? Duration(microseconds: (outputDurationSec * 1000000).round())
          : null,
      // The encoder receives composed frames at totalSize (the framed
      // output), not the source video resolution.
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
      if (trim != null) {
        return (trim!.duration.inMicroseconds / 1000000 * pipelineFps).round();
      }
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
          // Decoded frames start at trim.start (the decoder reset PTS to 0),
          // but cursor/zoom timestamps are relative to the full recording —
          // so sample the scene at trim.start + elapsed.
          final scenePosition =
              (trim?.start ?? Duration.zero) + Duration(microseconds: tsMicros);
          compositeSw.start();
          final composited = await compositor.compose(
            bgra: raw,
            position: scenePosition,
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

/// Returns the first slice in [state.timeline.clips], or a zero-length default
/// when the timeline is empty. Centralises the "single-slice bridge" the
/// export pipelines use to read playback/fade/audio fields off the timeline.
ClipSlice _firstClipOrEmpty(EditorProjectState state) {
  final clips = state.timeline.clips;
  if (clips.isEmpty) {
    return ClipSlice(cutStart: Duration.zero, cutEnd: Duration.zero);
  }
  return clips.first;
}
