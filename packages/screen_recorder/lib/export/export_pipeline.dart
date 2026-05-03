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
  List<int>? _probedDims; // [width, height, fps]
  int? _probedNbFrames; // null when ffprobe couldn't tell us
  double? _probedDurationSec; // null when ffprobe couldn't tell us

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
    final probed = await _probeSource();
    final srcWidth = probed[0];
    final srcHeight = probed[1];

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
      final dur = _probedDurationSec;
      if (dur != null && dur > 0) {
        return (dur * pipelineFps).round();
      }
      final nb = _probedNbFrames;
      if (nb != null && probed[2] > 0) {
        return (nb * pipelineFps / probed[2]).round();
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

  // ---------------------------------------------------------------------------
  // ffprobe helpers
  // ---------------------------------------------------------------------------

  /// Runs ffprobe once and caches [width, height, fps_int] for this
  /// instance. Also stashes [_probedNbFrames] and [_probedDurationSec]
  /// so callers can derive the frame count after CFR resampling.
  ///
  /// The reported fps is informational — the pipeline runs at
  /// `outputFps` regardless. We still pick `avg_frame_rate` over
  /// `r_frame_rate` for the log line because for VFR captures
  /// `r_frame_rate` reports the declared maximum (e.g. 60) while
  /// `avg_frame_rate` reports what was actually written, which is
  /// what humans expect to see in diagnostics.
  Future<List<int>> _probeSource() async {
    if (_probedDims != null) return _probedDims!;

    final streamResult = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries',
      'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration',
      // `default=nw=1:nk=0` prints `key=value` per line, so we read by
      // field name. ffprobe's CSV order is schema-internal (not
      // -show_entries order), and `width,height,r,avg,duration,nb_frames`
      // looks similar enough to other orderings to silently mis-parse.
      '-of', 'default=nw=1:nk=0',
      sourcePath,
    ]);
    final streamOutput = (streamResult.stdout as String).trim();
    final fields = <String, String>{};
    for (final line in streamOutput.split('\n')) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      fields[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    final w = int.tryParse(fields['width'] ?? '');
    final h = int.tryParse(fields['height'] ?? '');
    if (w == null || h == null) {
      throw Exception('ffprobe missing width/height: $streamOutput');
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

    final rRate = parseRate(fields['r_frame_rate']);
    final avgRate = parseRate(fields['avg_frame_rate']);
    final nbFrames = int.tryParse(fields['nb_frames'] ?? '');
    final dur = double.tryParse(fields['duration'] ?? '');

    int? derivedRate;
    if (nbFrames != null && nbFrames > 0 && dur != null && dur > 0) {
      derivedRate = (nbFrames / dur).round();
    }

    // avg_frame_rate is authoritative for VFR (SCStream); fall back to
    // nb_frames/duration; finally the declared r_frame_rate; finally
    // the recording metadata's claim; finally 30.
    final fps = avgRate ??
        derivedRate ??
        rRate ??
        (sourceMetadata.fps > 0 ? sourceMetadata.fps : 30);
    AppLogger.ffmpeg.d(
      'probe rates: r=$rRate avg=$avgRate '
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
