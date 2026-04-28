import 'native_perf_stats.dart';

/// Result of a live recording session: the output file path plus the actual
/// capture dimensions and native perf stats for the session.
class RecordingResult {
  final String outputPath;
  final int width;
  final int height;
  final NativePerfStats perfStats;

  const RecordingResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.perfStats,
  });

  factory RecordingResult.fromMap(Map<String, dynamic> map) {
    return RecordingResult(
      outputPath: map['outputPath'] as String? ?? '',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      perfStats: NativePerfStats.fromMap(map),
    );
  }
}
