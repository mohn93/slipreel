/// Exponential-moving-average smoother for the raw per-sample display latency
/// (AVPlayer clock − presented frame time) reported by the native
/// `slipreel/video_sync` channel. Pure and timer-free so it can be unit-tested;
/// [DisplayLatencyProbe] owns the polling.
class DisplayLatencySmoother {
  DisplayLatencySmoother({this.alpha = 0.3}) : assert(alpha > 0 && alpha <= 1);

  /// EMA weight for each new sample (0..1]. Higher = snappier, noisier.
  final double alpha;

  double? _emaMicros;

  /// Current smoothed latency. [Duration.zero] until the first non-null sample.
  Duration get value =>
      Duration(microseconds: (_emaMicros ?? 0).round());

  /// Feed one raw sample in microseconds. `null` (channel had no reading) is
  /// ignored and the current value holds. Negative samples clamp to zero.
  void add(int? rawMicros) {
    if (rawMicros == null) return;
    final sample = rawMicros < 0 ? 0.0 : rawMicros.toDouble();
    final prev = _emaMicros;
    _emaMicros = prev == null ? sample : alpha * sample + (1 - alpha) * prev;
  }
}
