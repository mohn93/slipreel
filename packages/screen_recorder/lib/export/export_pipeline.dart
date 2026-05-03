// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:io';
import 'dart:typed_data';
import '../models/cursor_recording.dart';
import '../models/recording_metadata.dart';
import '../rendering/cursor_click_effect.dart';
import '../rendering/cursor_glyph.dart';
import '../rendering/cursor_renderer.dart';
import '../utils/perf_summary.dart';
import '../utils/app_logger.dart';
import 'ffmpeg_decoder.dart';
import 'ffmpeg_encoder.dart';

/// Orchestrates: decode source MP4 → composite cursor + effects → encode HW.
class ExportPipeline {
  final String sourcePath;
  final String outputPath;
  final RecordingMetadata sourceMetadata;
  final CursorRecording cursorRecording;
  final int bitrateKbps;

  /// Desired output dimensions / frame rate (from the chosen ExportPreset).
  final int outputWidth;
  final int outputHeight;
  final int outputFps;

  /// Cursor visual settings carried over from the editor.
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;

  // Cache for a single ffprobe result per pipeline instance.
  List<int>? _probedDims; // [width, height, fps]

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.bitrateKbps,
    required this.outputWidth,
    required this.outputHeight,
    required this.outputFps,
    this.cursorSize = 1.0,
    this.cursorStyle = CursorStyle.modernDark,
    this.cursorClickEffect = CursorClickEffect.ripple,
  });

  Future<ExportPerfSummary> run() async {
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
    final srcFps =
        probed[2] > 0 ? probed[2] : (sourceMetadata.fps > 0 ? sourceMetadata.fps : 30);

    final decoder = FfmpegDecoder(
      inputPath: sourcePath,
      width: srcWidth,
      height: srcHeight,
    );
    final encoder = FfmpegEncoder(
      outputPath: outputPath,
      width: outputWidth,
      height: outputHeight,
      fps: outputFps,
      bitrateKbps: bitrateKbps,
      audioSourcePath: sourcePath,
      sourceWidth: srcWidth,
      sourceHeight: srcHeight,
      sourceFps: srcFps,
    );

    final cursorRenderer = CursorRenderer(
      sizeMultiplier: cursorSize,
      style: cursorStyle,
      clickEffect: cursorClickEffect,
    );
    if (sourceMetadata.isPureSource && cursorRecording.count > 0) {
      await cursorRenderer.initialize();
    }

    await encoder.start();

    final wallSw = Stopwatch()..start();
    final compositeSw = Stopwatch();
    int frameIndex = 0;
    int totalFrames = 0;

    try {
      await for (final raw in decoder.frames()) {
        Uint8List composited = raw;

        if (sourceMetadata.isPureSource && cursorRecording.count > 0) {
          compositeSw.start();
          final ts = ((1000000 * frameIndex) ~/ srcFps);
          composited = await cursorRenderer.renderCursorOnFrame(
            frameData: raw,
            width: srcWidth,
            height: srcHeight,
            timestampMicros: ts,
            cursorRecording: cursorRecording,
          );
          compositeSw.stop();
        }

        await encoder.writeFrame(composited);
        frameIndex++;
        totalFrames++;
      }
    } finally {
      cursorRenderer.dispose();
    }

    await encoder.finish();
    wallSw.stop();

    final wallSec = wallSw.elapsedMilliseconds / 1000.0;
    final inputDuration = totalFrames > 0 ? totalFrames / srcFps : 0.0;
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

  /// Runs ffprobe once and caches [width, height, fps_int] for this instance.
  Future<List<int>> _probeSource() async {
    if (_probedDims != null) return _probedDims!;

    final result = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height,r_frame_rate',
      '-of', 'csv=p=0',
      sourcePath,
    ]);
    final output = (result.stdout as String).trim();
    // Expected format: "width,height,num/den"
    final parts = output.split(',');
    if (parts.length < 3) {
      throw Exception('ffprobe returned unexpected output: $output');
    }
    final w = int.parse(parts[0].trim());
    final h = int.parse(parts[1].trim());
    final fpsStr = parts[2].trim();
    int fps;
    if (fpsStr.contains('/')) {
      final nd = fpsStr.split('/');
      final num = int.parse(nd[0]);
      final den = int.parse(nd[1]);
      fps = den > 0 ? (num / den).round() : 30;
    } else {
      fps = int.tryParse(fpsStr) ?? 30;
    }
    _probedDims = [w, h, fps];
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
