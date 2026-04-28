/// Native-side performance counters captured during a recording session.
///
/// Returned to Dart as part of [RecordingResult] when a live recording stops.
class NativePerfStats {
  final int droppedFrames;
  final List<double> cpuPctSamples;
  final List<int> memBytesSamples;

  const NativePerfStats({
    required this.droppedFrames,
    required this.cpuPctSamples,
    required this.memBytesSamples,
  });

  factory NativePerfStats.fromMap(Map<String, dynamic> map) {
    return NativePerfStats(
      droppedFrames: (map['droppedFrames'] as num?)?.toInt() ?? 0,
      cpuPctSamples: ((map['cpuPctSamples'] as List?) ?? const [])
          .map((e) => (e as num).toDouble())
          .toList(),
      memBytesSamples: ((map['memBytesSamples'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }

  static const empty = NativePerfStats(
    droppedFrames: 0,
    cpuPctSamples: [],
    memBytesSamples: [],
  );

  double get cpuPctAvg {
    if (cpuPctSamples.isEmpty) return 0;
    return cpuPctSamples.reduce((a, b) => a + b) / cpuPctSamples.length;
  }

  double get cpuPctP95 {
    if (cpuPctSamples.isEmpty) return 0;
    final sorted = [...cpuPctSamples]..sort();
    final idx = ((sorted.length - 1) * 0.95).round();
    return sorted[idx];
  }

  int get memBytesPeak {
    if (memBytesSamples.isEmpty) return 0;
    return memBytesSamples.reduce((a, b) => a > b ? a : b);
  }
}
