// packages/screen_recorder/lib/export/export_pipeline.dart
import 'dart:io';
import 'dart:typed_data';
import '../models/cursor_recording.dart';
import '../models/recording_metadata.dart';
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

  ExportPipeline({
    required this.sourcePath,
    required this.outputPath,
    required this.sourceMetadata,
    required this.cursorRecording,
    required this.bitrateKbps,
  });

  Future<ExportPerfSummary> run() async {
    final width = sourceMetadata.widthPx;
    final height = sourceMetadata.heightPx;
    final fps = sourceMetadata.fps;

    final decoder = FfmpegDecoder(
      inputPath: sourcePath,
      width: width,
      height: height,
    );
    final encoder = FfmpegEncoder(
      outputPath: outputPath,
      width: width,
      height: height,
      fps: fps,
      bitrateKbps: bitrateKbps,
      audioSourcePath: sourcePath,
    );

    final cursorRenderer = CursorRenderer();
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
          final ts = ((1000000 * frameIndex) ~/ fps);
          composited = await cursorRenderer.renderCursorOnFrame(
            frameData: raw,
            width: width,
            height: height,
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
    final inputDuration = totalFrames > 0 ? totalFrames / fps : 0.0;
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
