import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/models/caption_segment.dart';

/// whisper.cpp expects 16 kHz mono 16-bit PCM WAV.
const int kCaptionSampleRate = 16000;

/// The caption sources offered for a recording with [streamCount] audio
/// streams. Our recording model writes mic as stream 0 and system audio as
/// stream 1, so two streams unlock mic/system/mixed; one stream offers just the
/// single track (labeled "Microphone"); none offers nothing.
List<CaptionAudioSource> availableCaptionSources(int streamCount) {
  if (streamCount >= 2) {
    return const [
      CaptionAudioSource.mic,
      CaptionAudioSource.system,
      CaptionAudioSource.mixed,
    ];
  }
  if (streamCount == 1) return const [CaptionAudioSource.mic];
  return const [];
}

/// ffmpeg args that decode [videoPath] to a 16 kHz mono WAV at [outPath] for
/// the chosen [source]. `mixed`/`system` gracefully fall back to stream 0 when
/// the source only has one audio stream.
List<String> buildCaptionAudioArgs(
  String videoPath,
  CaptionAudioSource source,
  int streamCount,
  String outPath,
) {
  final args = <String>['-v', 'error', '-y', '-i', videoPath];
  final twoStreams = streamCount >= 2;
  switch (source) {
    case CaptionAudioSource.mixed when twoStreams:
      args.addAll([
        '-filter_complex',
        '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]',
        '-map',
        '[aout]',
      ]);
    case CaptionAudioSource.system when twoStreams:
      args.addAll(['-map', '0:a:1']);
    case CaptionAudioSource.mic:
    case CaptionAudioSource.system:
    case CaptionAudioSource.mixed:
      args.addAll(['-map', '0:a:0']);
  }
  args.addAll([
    '-vn',
    '-ac', '1',
    '-ar', '$kCaptionSampleRate',
    '-c:a', 'pcm_s16le',
    '-f', 'wav',
    outPath,
  ]);
  return args;
}

/// Extracts a 16 kHz mono WAV for transcription. Returns the WAV path, or null
/// when the recording has no audio or extraction fails. Mirrors
/// `WaveformExtractor`.
class CaptionAudioExtractor {
  const CaptionAudioExtractor();

  Future<String?> extract(
    String videoPath,
    CaptionAudioSource source, {
    String? outPath,
  }) async {
    try {
      final probe = await ffmpegProbe(path: videoPath);
      final streamCount = probe.audioStreams.length;
      if (streamCount == 0) return null;

      final out = outPath ??
          p.join(
            Directory.systemTemp.createTempSync('slipreel_caption_').path,
            'caption_audio.wav',
          );
      final result = await Process.run(
        Ffmpeg.resolve(),
        buildCaptionAudioArgs(videoPath, source, streamCount, out),
      );
      if (result.exitCode != 0) return null;
      if (!File(out).existsSync()) return null;
      return out;
    } catch (_) {
      return null;
    }
  }
}
