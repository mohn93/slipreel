// packages/screen_recorder/lib/export/ffmpeg_probe.dart
import 'dart:io';

import '../utils/app_logger.dart';
import 'audio_streams.dart';

/// The resolved output of a single `ffprobe` run.
class FfmpegProbeResult {
  const FfmpegProbeResult({
    required this.width,
    required this.height,
    required this.fps,
    this.nbFrames,
    this.durationSec,
    this.audioBitrateKbps,
    this.audioStreams = const [],
  });

  final int width;
  final int height;

  /// Best-effort integer frame rate using the fallback chain:
  /// `avg_frame_rate → nb_frames/duration → r_frame_rate → metadataFps → 30`.
  /// See the why-comment in [ffmpegProbe] for the VFR rationale.
  final int fps;

  /// The `nb_frames` field as reported by the container, if present.
  /// May be absent for VFR or poorly-muxed files.
  final int? nbFrames;

  /// The `duration` field in seconds, if present.
  final double? durationSec;

  /// Bitrate of the first audio stream in kbps, if the source has audio
  /// and ffprobe could determine it. The encoder uses `-c:a copy` so the
  /// audio bytes pass through unchanged into the output — callers add
  /// `audioBitrateKbps × duration / 8 × 1024` to size estimates.
  final int? audioBitrateKbps;

  /// All audio streams in the source, in container order. Drives editor audio
  /// controls and the export mix. Empty when the source has no audio.
  final List<AudioStreamInfo> audioStreams;
}

/// Runs `ffprobe` once on [path] and returns the resolved dimensions,
/// fps, and whatever frame-count + duration the source declared.
///
/// The fps fallback chain is:
///   1. `avg_frame_rate` — authoritative for VFR captures (e.g. SCStream),
///      which report the *average* rate actually written rather than a
///      declared maximum.
///   2. `nb_frames / duration` — derived from container metadata; useful
///      when `avg_frame_rate` is absent or zero.
///   3. `r_frame_rate` — the declared maximum. For VFR sources this is
///      often too high (e.g. 60 fps when the true average is 25 fps), so
///      it is the last numerical resort.
///   4. `metadataFps` — the fps the recording plugin reported at capture
///      time; a reasonable human-entered fallback.
///   5. 30 — a safe hard default.
///
/// Why `-of default=nw=1:nk=0`: this format prints `key=value` per line,
/// which we read by field name. ffprobe's CSV/default output order is
/// schema-internal (not -show_entries order), and `width,height,r,avg,
/// duration,nb_frames` looks similar enough to other orderings to silently
/// mis-parse if consumed positionally.
///
/// Throws [Exception] if ffprobe exits non-zero or if width/height are
/// missing from the output.
Future<FfmpegProbeResult> ffmpegProbe({
  required String path,
  int? metadataFps,
}) async {
  final result = await Process.run('ffprobe', [
    '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries',
    'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration',
    '-of', 'default=nw=1:nk=0',
    path,
  ]);

  if (result.exitCode != 0) {
    throw Exception(
        'ffprobe exited ${result.exitCode}: ${result.stderr}');
  }

  final output = (result.stdout as String).trim();
  final fields = <String, String>{};
  for (final line in output.split('\n')) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    fields[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }

  final w = int.tryParse(fields['width'] ?? '');
  final h = int.tryParse(fields['height'] ?? '');
  if (w == null || h == null) {
    throw Exception('ffprobe missing width/height for $path: $output');
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

  final avgRate = parseRate(fields['avg_frame_rate']);
  final rRate = parseRate(fields['r_frame_rate']);
  final nbFrames = int.tryParse(fields['nb_frames'] ?? '');
  final dur = double.tryParse(fields['duration'] ?? '');

  int? derivedRate;
  if (nbFrames != null && nbFrames > 0 && dur != null && dur > 0) {
    derivedRate = (nbFrames / dur).round();
  }

  final fps = avgRate ??
      derivedRate ??
      rRate ??
      (metadataFps != null && metadataFps > 0 ? metadataFps : 30);

  AppLogger.ffmpeg.d(
    'ffprobe [$path]: avg=$avgRate derived=$derivedRate r=$rRate '
    'nb_frames=$nbFrames duration=$dur → using $fps fps',
  );

  // Audio probe is a separate ffprobe call so the parser stays simple
  // (one stream type per call). Failure here is non-fatal — files with
  // no audio track or with an unreported bitrate just leave the field
  // null, and the size estimator skips the audio adjustment.
  final audioStreams = await _probeAudioStreams(path);
  final audioBitrateKbps =
      audioStreams.isEmpty ? null : audioStreams.first.bitrateKbps;

  return FfmpegProbeResult(
    width: w,
    height: h,
    fps: fps,
    nbFrames: nbFrames,
    durationSec: dur,
    audioBitrateKbps: audioBitrateKbps,
    audioStreams: audioStreams,
  );
}

Future<List<AudioStreamInfo>> _probeAudioStreams(String path) async {
  try {
    final result = await Process.run('ffprobe', [
      '-v', 'error',
      '-select_streams', 'a',
      '-show_entries', 'stream=index,codec_name,channels,bit_rate',
      '-of', 'json',
      path,
    ]);
    if (result.exitCode != 0) return const [];
    return parseAudioStreams(result.stdout as String);
  } catch (_) {
    return const [];
  }
}
