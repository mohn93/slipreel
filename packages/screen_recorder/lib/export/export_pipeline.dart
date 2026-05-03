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
  ///
  /// **Why both rate fields are read:** SCStream-captured MP4s are VFR
  /// (`minimumFrameInterval=1/60s`, but frames only emitted when the
  /// display changes). For such files `r_frame_rate` reports the
  /// declared/max rate (60 fps) while `avg_frame_rate` reports the
  /// actual average. Piping the limited set of decoded frames to ffmpeg
  /// at the declared 60 fps produces a video stream that ends after a
  /// fraction of the source duration — the audio track keeps playing
  /// to the end and the user sees the video freeze. Prefer
  /// `avg_frame_rate`; fall back to `nb_frames/duration`; finally
  /// `r_frame_rate` (CFR sources where the two agree).
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
