import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

/// Sample rate we decode audio to for waveform purposes — low enough to keep
/// the PCM small, high enough that 100 buckets/sec stay meaningful.
const int kWaveformSampleRate = 8000;
const int kWaveformBucketsPerSecond = 100;
const int kWaveformSamplesPerBucket =
    kWaveformSampleRate ~/ kWaveformBucketsPerSecond; // 80 (10ms buckets)

/// Reduces mono PCM (signed 16-bit samples) to a normalized peak-per-bucket
/// array. Peak = max abs sample in the bucket / 32768, then the whole array
/// is normalized to its global max so quiet recordings still read.
List<double> reducePcmToPeaks(
  Int16List samples, {
  required int samplesPerBucket,
}) {
  if (samples.isEmpty || samplesPerBucket <= 0) return const [];
  final bucketCount = (samples.length / samplesPerBucket).ceil();
  final peaks = List<double>.filled(bucketCount, 0.0);
  var globalMax = 0.0;
  for (var b = 0; b < bucketCount; b++) {
    final start = b * samplesPerBucket;
    final end = min(start + samplesPerBucket, samples.length);
    var peak = 0;
    for (var i = start; i < end; i++) {
      final a = samples[i] < 0 ? -samples[i] : samples[i];
      if (a > peak) peak = a;
    }
    final v = peak / 32768.0;
    peaks[b] = v;
    if (v > globalMax) globalMax = v;
  }
  if (globalMax > 0) {
    for (var b = 0; b < bucketCount; b++) {
      peaks[b] = peaks[b] / globalMax;
    }
  }
  return peaks;
}

/// ffmpeg args that emit mono [kWaveformSampleRate] Hz signed-16 little-endian
/// PCM on stdout. Two streams are mixed (`amix`); one stream is mapped
/// directly.
List<String> buildWaveformPcmArgs(String videoPath, int streamCount) {
  final args = <String>['-v', 'error', '-i', videoPath];
  if (streamCount >= 2) {
    // Exactly-two-streams (mic + system audio) case. Our recording model only
    // ever produces two audio streams; a hypothetical 3rd would be dropped
    // here since amix only references 0:a:0 and 0:a:1.
    args.addAll([
      '-filter_complex',
      '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]',
      '-map',
      '[aout]',
    ]);
  } else {
    args.addAll(['-map', '0:a:0']);
  }
  args.addAll(
      ['-vn', '-ac', '1', '-ar', '$kWaveformSampleRate', '-f', 's16le', '-']);
  return args;
}

/// Extracts a [WaveformPeaks] for a recording, or null when the recording has
/// no audio or extraction fails. Runs one ffprobe (stream count) + one ffmpeg
/// (PCM decode) pass. Pure helpers above are unit-tested separately.
class WaveformExtractor {
  const WaveformExtractor();

  Future<WaveformPeaks?> extract(String videoPath) async {
    try {
      final probe = await ffmpegProbe(path: videoPath);
      final streamCount = probe.audioStreams.length;
      if (streamCount == 0) return null;

      final result = await Process.run(
        Ffmpeg.resolve(),
        buildWaveformPcmArgs(videoPath, streamCount),
        stdoutEncoding: null, // keep stdout as raw bytes (List<int>)
      );
      if (result.exitCode != 0) return null;
      final stdout = result.stdout;
      final bytes = stdout is Uint8List
          ? stdout
          : Uint8List.fromList(stdout as List<int>);
      if (bytes.length < 2) return null;

      final peaks = await Isolate.run(() => _decodeAndReducePcm(bytes));
      if (peaks.isEmpty) return null;

      final sampleCount = bytes.length ~/ 2;
      final micros = (sampleCount / kWaveformSampleRate * 1e6).round();
      return WaveformPeaks(
        bucketsPerSecond: kWaveformBucketsPerSecond,
        peaks: peaks,
        sourceDuration: Duration(microseconds: micros),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Runs on a worker isolate: decode PCM bytes to Int16 samples and reduce to
/// the normalized peak array. Pure CPU work kept off the calling isolate.
List<double> _decodeAndReducePcm(Uint8List bytes) {
  final samples = _int16FromBytes(bytes);
  return reducePcmToPeaks(samples, samplesPerBucket: kWaveformSamplesPerBucket);
}

Int16List _int16FromBytes(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final n = bd.lengthInBytes ~/ 2;
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little);
  }
  return out;
}
