import 'native_perf_stats.dart';

/// Result of a live recording session: the output file path plus the native
/// perf stats for the session.
class RecordingResult {
  final String outputPath;
  final NativePerfStats perfStats;

  const RecordingResult({
    required this.outputPath,
    required this.perfStats,
  });

  factory RecordingResult.fromMap(Map<String, dynamic> map) {
    return RecordingResult(
      outputPath: map['outputPath'] as String? ?? '',
      perfStats: NativePerfStats.fromMap(map),
    );
  }
}
