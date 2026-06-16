import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:slipreel_engine/audio/waveform_extractor.dart';

String _sidecarPath(String videoPath) => '$videoPath.waveform.json';

/// Reads a cached [WaveformPeaks] sidecar next to the recording. Returns null
/// if it's missing, unreadable, or a stale/unsupported version.
Future<WaveformPeaks?> loadWaveformSidecar(String videoPath) async {
  try {
    final file = File(_sidecarPath(videoPath));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) return null;
    return WaveformPeaks.fromJson(json);
  } catch (_) {
    return null; // missing/corrupt/version-mismatch -> re-extract
  }
}

/// Writes the sidecar next to the recording. Best-effort; swallows IO errors.
Future<void> saveWaveformSidecar(String videoPath, WaveformPeaks peaks) async {
  try {
    await File(_sidecarPath(videoPath))
        .writeAsString(jsonEncode(peaks.toJson()));
  } catch (_) {/* non-fatal: waveform just won't be cached */}
}

/// Per-recording waveform peaks. Sidecar hit returns instantly; a miss runs
/// one ffmpeg extraction, caches it, and returns it. Errors resolve to null so
/// the UI simply draws no waveform.
final waveformProvider =
    FutureProvider.autoDispose.family<WaveformPeaks?, String>((ref, videoPath) async {
  final cached = await loadWaveformSidecar(videoPath);
  if (cached != null) return cached;
  try {
    final peaks = await const WaveformExtractor().extract(videoPath);
    if (peaks != null) await saveWaveformSidecar(videoPath, peaks);
    return peaks;
  } catch (_) {
    return null;
  }
});
