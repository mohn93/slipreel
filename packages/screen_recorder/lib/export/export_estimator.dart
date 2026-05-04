import 'package:screen_recorder/models/compression_bitrate.dart';
import 'package:screen_recorder/models/export_settings.dart';

/// Pixel area (`1920 × 1080`) at which [ExportEstimator]'s
/// [lastRealtimeMultiplier] is normalized. The time formula scales an
/// export's predicted wall time by `outputArea / kBaselineAreaPixels`
/// because the encoder + compositor are roughly linear in pixel count.
const int kBaselineAreaPixels = 1920 * 1080;

class ExportEstimator {
  const ExportEstimator({this.lastRealtimeMultiplier = 0.7});

  /// Observed `realtimeMultiple` normalized to [kBaselineFrameRate] +
  /// [kBaselineAreaPixels]. 0.7× is a conservative fallback for the
  /// first-ever export (before we have a real measurement); the
  /// telemetry store overwrites this after every successful export.
  final double lastRealtimeMultiplier;

  /// Wall-clock seconds we estimate it'll take to encode a
  /// [durationSec]-long source at [frameRate] and [outputArea]. Time
  /// scales linearly with both inputs because the compose+encode work
  /// is roughly proportional to pixels-per-second — 4K is ~4× the work
  /// of 1080p, 60fps is 2× the work of 30fps. Always ≥ 0.5s — the
  /// dialog refreshes fast and "0 seconds" reads as broken even if the
  /// math says so.
  Duration estimateExportTime(
    double durationSec, {
    int frameRate = kBaselineFrameRate,
    int outputArea = kBaselineAreaPixels,
  }) {
    final fpsScale = frameRate / kBaselineFrameRate;
    final areaScale = outputArea / kBaselineAreaPixels;
    final estimatedSeconds =
        durationSec * fpsScale * areaScale / lastRealtimeMultiplier;
    final floored = estimatedSeconds < 0.5 ? 0.5 : estimatedSeconds;
    return Duration(milliseconds: (floored * 1000).round());
  }

  /// Estimated output bytes. For [ExportFormat.mp4] this is video
  /// bitrate × duration plus, when known, the audio stream's bytes
  /// (the encoder muxes audio with `-c:a copy` so the source audio
  /// passes through unchanged). For [ExportFormat.gif] we apply a 0.6
  /// calibration factor against the naive bitrate arithmetic and skip
  /// audio entirely (GIF strips it).
  int estimateOutputBytes({
    required double durationSec,
    required int bitrateKbps,
    required ExportFormat format,
    int? audioBitrateKbps,
  }) {
    final videoBytes = bitrateKbps * durationSec / 8 * 1024;

    return switch (format) {
      ExportFormat.mp4 => () {
        final audioBytes = audioBitrateKbps == null
            ? 0.0
            : audioBitrateKbps * durationSec / 8 * 1024;
        return (videoBytes + audioBytes).round();
      }(),
      ExportFormat.gif => (videoBytes * 0.6).round(),
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
    int frameRate = kBaselineFrameRate,
    int outputArea = kBaselineAreaPixels,
    int? audioBitrateKbps,
  }) {
    final exportTime = estimateExportTime(
      durationSec,
      frameRate: frameRate,
      outputArea: outputArea,
    );
    final outputBytes = estimateOutputBytes(
      durationSec: durationSec,
      bitrateKbps: bitrateKbps,
      format: format,
      audioBitrateKbps: audioBitrateKbps,
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
