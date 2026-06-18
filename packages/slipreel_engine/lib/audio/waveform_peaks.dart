/// Bumped when the on-disk sidecar format changes; stale sidecars with a
/// different version are ignored and re-extracted.
const int kWaveformSidecarVersion = 1;

/// Normalized per-bucket audio loudness across a whole recording's source
/// timeline. `peaks[i]` is in 0.0..1.0 (normalized to the recording's global
/// loudest bucket). Buckets are evenly spaced at [bucketsPerSecond].
class WaveformPeaks {
  WaveformPeaks({
    required this.bucketsPerSecond,
    required List<double> peaks,
    required this.sourceDuration,
  }) : peaks = List<double>.unmodifiable(peaks);

  final int bucketsPerSecond;
  final List<double> peaks;
  final Duration sourceDuration;

  /// Buckets covering the SOURCE-time window [start, end). Clamped to the
  /// array bounds; returns an empty list for a degenerate/empty window.
  List<double> slice(Duration start, Duration end) {
    if (peaks.isEmpty) return const [];
    final perMicro = bucketsPerSecond / 1e6;
    final startIdx =
        (start.inMicroseconds * perMicro).floor().clamp(0, peaks.length);
    final endIdx =
        (end.inMicroseconds * perMicro).ceil().clamp(0, peaks.length);
    if (endIdx <= startIdx) return const [];
    return peaks.sublist(startIdx, endIdx);
  }

  Map<String, dynamic> toJson() => {
        'version': kWaveformSidecarVersion,
        'bucketsPerSecond': bucketsPerSecond,
        'sourceDurationMicros': sourceDuration.inMicroseconds,
        // 8-bit quantized to keep the sidecar small; a waveform doesn't need
        // more than 256 amplitude levels.
        'peaks': peaks
            .map((p) => (p.clamp(0.0, 1.0) * 255).round())
            .toList(growable: false),
      };

  factory WaveformPeaks.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != kWaveformSidecarVersion) {
      throw FormatException('WaveformPeaks: unsupported version $version');
    }
    final bps = json['bucketsPerSecond'];
    final durMicros = json['sourceDurationMicros'];
    final rawPeaks = json['peaks'];
    if (bps is! num || durMicros is! num || rawPeaks is! List) {
      throw const FormatException('WaveformPeaks: malformed json');
    }
    return WaveformPeaks(
      bucketsPerSecond: bps.toInt(),
      sourceDuration: Duration(microseconds: durMicros.toInt()),
      peaks: rawPeaks
          .map((v) => (v is num ? v.toInt() : 0) / 255.0)
          .toList(growable: false),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaveformPeaks &&
          other.bucketsPerSecond == bucketsPerSecond &&
          other.sourceDuration == sourceDuration &&
          _listEquals(other.peaks, peaks);

  @override
  int get hashCode => Object.hash(
        bucketsPerSecond,
        sourceDuration,
        // Length + a coarse sample so hashCode stays O(1)-ish for big arrays.
        peaks.length,
        peaks.isEmpty ? 0 : peaks[peaks.length ~/ 2],
      );

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
