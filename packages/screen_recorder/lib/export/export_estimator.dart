import 'package:screen_recorder/models/export_settings.dart';

class ExportEstimator {
  const ExportEstimator({this.lastRealtimeMultiplier = 0.7});

  /// Most-recent observed `realtimeMultiple` from the perf summary,
  /// used as the time predictor. 0.7× is a conservative fallback for
  /// the first-ever export (before we have a real measurement).
  final double lastRealtimeMultiplier;

  /// Wall-clock seconds we estimate it'll take to encode a
  /// [durationSec]-long source. Always ≥ 0.5s — the dialog refreshes
  /// fast and "0 seconds" reads as broken even if the math says so.
  Duration estimateExportTime(double durationSec) {
    final estimatedSeconds = durationSec / lastRealtimeMultiplier;
    final floored = estimatedSeconds < 0.5 ? 0.5 : estimatedSeconds;
    return Duration(milliseconds: (floored * 1000).round());
  }

  /// Estimated output bytes. For [ExportFormat.mp4] this is rounded
  /// to the nearest int. For [ExportFormat.gif] we apply a calibration
  /// factor (0.6 for now — palettegen + dither produces consistently
  /// smaller files than naive bitrate arithmetic; refine the constant
  /// once Task 3's pipeline ships and we have real measurements).
  int estimateOutputBytes({
    required double durationSec,
    required int bitrateKbps,
    required ExportFormat format,
  }) {
    final mp4Bytes = bitrateKbps * durationSec / 8 * 1024;
    final bytes = mp4Bytes.round();

    return switch (format) {
      ExportFormat.mp4 => bytes,
      ExportFormat.gif => (bytes * 0.6).round(),
    };
  }

  /// Renders the line shown beneath the export button:
  ///   "Estimation — Export time 1 second — Output size 0.2MB"
  /// Time formatting:
  ///   < 60s   → "X seconds" (or "1 second" — singular)
  ///   60-3599s → "X minutes Y seconds" (drop seconds when 0)
  ///   ≥ 3600s → "X hours Y minutes" (drop minutes when 0)
  /// Size formatting:
  ///   < 1MB    → "X.XKB"  (one decimal, e.g. "230.4KB")
  ///   < 1GB    → "X.XMB"  (one decimal, e.g. "12.4MB", "0.2MB")
  ///   ≥ 1GB    → "X.XGB"  (one decimal)
  String formatLine({
    required double durationSec,
    required int bitrateKbps,
    required ExportFormat format,
  }) {
    final exportTime = estimateExportTime(durationSec);
    final outputBytes = estimateOutputBytes(
      durationSec: durationSec,
      bitrateKbps: bitrateKbps,
      format: format,
    );

    final timeStr = _formatTime(exportTime);
    final sizeStr = _formatSize(outputBytes);

    return 'Estimation — Export time $timeStr — Output size $sizeStr';
  }

  String _plural(int n, String unit) =>
      n == 1 ? '1 $unit' : '$n ${unit}s';

  String _formatTime(Duration duration) {
    final totalSeconds = (duration.inMilliseconds / 1000).ceil();

    if (totalSeconds < 60) {
      return _plural(totalSeconds, 'second');
    }

    if (totalSeconds < 3600) {
      final m = totalSeconds ~/ 60;
      final s = totalSeconds % 60;
      return s == 0 ? _plural(m, 'minute') : '${_plural(m, 'minute')} ${_plural(s, 'second')}';
    }

    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    return m == 0 ? _plural(h, 'hour') : '${_plural(h, 'hour')} ${_plural(m, 'minute')}';
  }

  String _formatSize(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;

    if (bytes < mb) {
      final kbVal = bytes / kb;
      return '${kbVal.toStringAsFixed(1)}KB';
    }

    if (bytes < gb) {
      final mbVal = bytes / mb;
      return '${mbVal.toStringAsFixed(1)}MB';
    }

    final gbVal = bytes / gb;
    return '${gbVal.toStringAsFixed(1)}GB';
  }
}
