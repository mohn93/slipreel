import 'native_perf_stats.dart';

/// Result of a live recording session: the output file path plus the actual
/// capture dimensions, native perf stats, and (when a camera was recorded) the
/// camera sidecar dimensions, frame count, alignment offset, and self-view
/// position.
class RecordingResult {
  final String outputPath;
  final int width;
  final int height;
  final NativePerfStats perfStats;

  /// Camera sidecar info. [cameraFrameCount] == 0 means no camera was recorded.
  final int cameraFrameCount;
  final int cameraWidth;
  final int cameraHeight;

  /// Microseconds to add to a camera-track time to get screen-track time
  /// (`cameraFirst − screenFirst`). Usually small; can be negative.
  final int cameraOffsetMicros;

  /// Self-view final center, normalized (0..1) in canvas space, top-left origin.
  final double cameraSelfViewX;
  final double cameraSelfViewY;

  const RecordingResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.perfStats,
    this.cameraFrameCount = 0,
    this.cameraWidth = 0,
    this.cameraHeight = 0,
    this.cameraOffsetMicros = 0,
    this.cameraSelfViewX = 0.82,
    this.cameraSelfViewY = 0.82,
  });

  bool get hasCamera => cameraFrameCount > 0;

  factory RecordingResult.fromMap(Map<String, dynamic> map) {
    return RecordingResult(
      outputPath: map['outputPath'] as String? ?? '',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      perfStats: NativePerfStats.fromMap(map),
      cameraFrameCount: (map['cameraFrameCount'] as num?)?.toInt() ?? 0,
      cameraWidth: (map['cameraWidth'] as num?)?.toInt() ?? 0,
      cameraHeight: (map['cameraHeight'] as num?)?.toInt() ?? 0,
      cameraOffsetMicros: (map['cameraOffsetMicros'] as num?)?.toInt() ?? 0,
      cameraSelfViewX: (map['cameraSelfViewX'] as num?)?.toDouble() ?? 0.82,
      cameraSelfViewY: (map['cameraSelfViewY'] as num?)?.toDouble() ?? 0.82,
    );
  }
}
