import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slipreel_engine/captions/caption_transcriber.dart'
    show CaptionCancelledException;
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
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

/// The microsecond offset between whisper's timestamps (relative to the start
/// of the extracted WAV, which drops any audio leading-gap) and the recording's
/// movie-time — i.e. the `start_time` of the stream(s) [source] is extracted
/// from. Adding it to a whisper timestamp maps the caption onto movie-time,
/// where the video and the preview/export playhead live. Mirrors the
/// source→stream mapping in [buildCaptionAudioArgs]; `mixed` uses the EARLIER
/// of the two streams, since amix aligns to its earliest input.
int captionAudioOffsetMicros(
  CaptionAudioSource source,
  List<AudioStreamInfo> streams,
) {
  if (streams.isEmpty) return 0;
  final twoStreams = streams.length >= 2;
  switch (source) {
    case CaptionAudioSource.mixed when twoStreams:
      final a = streams[0].startMicros;
      final b = streams[1].startMicros;
      return a < b ? a : b;
    case CaptionAudioSource.system when twoStreams:
      return streams[1].startMicros;
    case CaptionAudioSource.mic:
    case CaptionAudioSource.system:
    case CaptionAudioSource.mixed:
      return streams[0].startMicros;
  }
}

/// Extracts a 16 kHz mono WAV for transcription. Returns the WAV path, or null
/// when the recording has no audio or extraction fails. Mirrors
/// `WaveformExtractor`.
class CaptionAudioExtractor {
  const CaptionAudioExtractor();

  /// [cancelToken]: firing it SIGKILLs the ffmpeg subprocess and throws
  /// [CaptionCancelledException] (unlike ordinary failures, which return
  /// null) so callers can tell "user cancelled" from "no audio".
  Future<String?> extract(
    String videoPath,
    CaptionAudioSource source, {
    String? outPath,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const CaptionCancelledException();
    }
    // A temp dir we minted ourselves (only when the caller didn't inject an
    // outPath). We hand its WAV path to the caller on success — the
    // controller reaps it then. On any non-success exit (cancel, ffmpeg
    // failure, missing output) the caller never gets the path, so we must
    // delete it here or it leaks; ownership transfers to the caller only on
    // the success return below.
    Directory? ownedTempDir;
    try {
      final probe = await ffmpegProbe(path: videoPath);
      final streamCount = probe.audioStreams.length;
      if (streamCount == 0) return null;

      final String out;
      if (outPath != null) {
        out = outPath;
      } else {
        ownedTempDir = Directory.systemTemp.createTempSync('slipreel_caption_');
        out = p.join(ownedTempDir.path, 'caption_audio.wav');
      }
      final process = await Process.start(
        Ffmpeg.resolve(),
        buildCaptionAudioArgs(videoPath, source, streamCount, out),
      );
      cancelToken?.whenCancelled
          .then((_) => process.kill(ProcessSignal.sigkill));
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final exitCode = await process.exitCode;
      if (cancelToken?.isCancelled ?? false) {
        throw const CaptionCancelledException();
      }
      if (exitCode != 0) return null;
      if (!File(out).existsSync()) return null;
      ownedTempDir = null; // success: the caller now owns the temp dir
      return out;
    } on CaptionCancelledException {
      rethrow;
    } catch (_) {
      return null;
    } finally {
      if (ownedTempDir != null && ownedTempDir.existsSync()) {
        try {
          ownedTempDir.deleteSync(recursive: true);
        } catch (_) {
          // Best-effort; the OS temp reaper is the backstop.
        }
      }
    }
  }
}
