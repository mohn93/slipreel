// packages/screen_recorder/lib/utils/perf_summary.dart

/// Phase 9 recording-side performance targets. Used by [RecordingPerfSummary]
/// to compute its PASS/FAIL verdict.
class RecordingTargets {
  static const double maxCpuPctAvg = 10.0;
  static const int maxMemBytes = 500 * 1024 * 1024;
  static const double maxDropFraction = 0.01; // 1%
}

/// Phase 9 export-side performance target.
class ExportTargets {
  static const double minRealtimeMultiple = 1.0;
}

class RecordingPerfSummary {
  final double durationSeconds;
  final int frameCount;
  final int expectedFrameCount;
  final int droppedFrameCount;
  final double cpuPctAvg;
  final double cpuPctP95;
  final int memPeakBytes;
  final int outputBytes;
  final int targetFps;

  const RecordingPerfSummary({
    required this.durationSeconds,
    required this.frameCount,
    required this.expectedFrameCount,
    required this.droppedFrameCount,
    required this.cpuPctAvg,
    required this.cpuPctP95,
    required this.memPeakBytes,
    required this.outputBytes,
    required this.targetFps,
  });

  double get actualFps =>
      durationSeconds > 0 ? frameCount / durationSeconds : 0;

  double get dropFraction =>
      expectedFrameCount > 0 ? droppedFrameCount / expectedFrameCount : 0;

  int get memPeakMB => (memPeakBytes / (1024 * 1024)).round();

  bool get cpuOk => cpuPctAvg <= RecordingTargets.maxCpuPctAvg;
  bool get memOk => memPeakBytes <= RecordingTargets.maxMemBytes;
  bool get fpsOk => actualFps >= targetFps * 0.97; // 3% tolerance
  bool get dropsOk => dropFraction <= RecordingTargets.maxDropFraction;
  bool get pass => cpuOk && memOk && fpsOk && dropsOk;

  String format() {
    final dropPct = (dropFraction * 100).toStringAsFixed(2);
    String mark(bool ok) => ok ? '✓' : '✗';
    return '''
[Recording] summary: duration=${durationSeconds.toStringAsFixed(1)}s frames=$frameCount expectedFrames=$expectedFrameCount droppedFrames=$droppedFrameCount ($dropPct%) actualFps=${actualFps.toStringAsFixed(1)} cpuPctAvg=${cpuPctAvg.toStringAsFixed(1)} cpuPctP95=${cpuPctP95.toStringAsFixed(1)} memPeakMB=$memPeakMB outputBytes=$outputBytes
[Recording] verdict: cpuPct≤10 ${mark(cpuOk)}  memPeak≤500MB ${mark(memOk)}  fps=$targetFps ${mark(fpsOk)}  drops≤1% ${mark(dropsOk)}  -> ${pass ? "PASS" : "FAIL"}'''
        .trim();
  }
}

class ExportPerfSummary {
  final double inputDurationSeconds;
  final double wallTimeSeconds;
  final double decodeMsPerFrame;
  final double compositeMsPerFrame;
  final double encodeMsPerFrame;
  final int outputBytes;
  final String outputCodec;
  final bool usedHardwareEncoder;

  /// Non-fatal issues encountered during export (e.g. the camera overlay was
  /// dropped because the sidecar movie failed to decode). Empty on a clean run.
  final List<String> warnings;

  /// Source frames fed as blank placeholders instead of being composed —
  /// frames in trimmed-away gaps that ffmpeg's per-slice trim drops anyway.
  /// For the two-pass GIF pipeline this counts both passes.
  final int skippedCompositeFrames;

  const ExportPerfSummary({
    required this.inputDurationSeconds,
    required this.wallTimeSeconds,
    required this.decodeMsPerFrame,
    required this.compositeMsPerFrame,
    required this.encodeMsPerFrame,
    required this.outputBytes,
    required this.outputCodec,
    required this.usedHardwareEncoder,
    this.warnings = const [],
    this.skippedCompositeFrames = 0,
  });

  double get realtimeMultiple =>
      wallTimeSeconds > 0 ? inputDurationSeconds / wallTimeSeconds : 0;

  bool get pass => realtimeMultiple >= ExportTargets.minRealtimeMultiple;

  String format() {
    final hw = usedHardwareEncoder ? 'yes' : 'no';
    final mark = pass ? '✓' : '✗';
    return '''
[Export] summary: inputDuration=${inputDurationSeconds.toStringAsFixed(1)}s exportWallTime=${wallTimeSeconds.toStringAsFixed(1)}s realtimeMultiple=${realtimeMultiple.toStringAsFixed(1)}x (HW encoder: $hw) decodeMs/frame=${decodeMsPerFrame.toStringAsFixed(1)} compositeMs/frame=${compositeMsPerFrame.toStringAsFixed(1)} encodeMs/frame=${encodeMsPerFrame.toStringAsFixed(1)} skippedFrames=$skippedCompositeFrames outputBytes=$outputBytes outputCodec=$outputCodec
[Export] verdict: realtimeMultiple≥1.0 $mark  -> ${pass ? "PASS" : "FAIL"}'''
        .trim();
  }
}
