import 'dart:math' as math;

/// Maps the slice playback-speed range [min]..[max]× onto a normalized slider
/// position 0..1 on a LOGARITHMIC scale, so each octave of speed gets equal
/// slider travel (fine control near 1× instead of a twitchy linear sweep).
///
///   speed = min · (max/min)^t            (speedFromPos)
///   t     = ln(speed/min) / ln(max/min)  (posFromSpeed)
///
/// [snap] pulls a speed to the nearest [detents] entry when it lands within
/// [posTolerance] of it in normalized space, so common values (notably exactly
/// 1×) stay reachable despite the continuous log mapping.
class SpeedScale {
  const SpeedScale._();

  static const double min = 0.25;
  static const double max = 24.0;

  /// Snap targets, ascending — the slice-editor preset chips plus the 0.25×
  /// floor.
  static const List<double> detents = <double>[
    0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 16.0, 24.0,
  ];

  static final double _lnRange = math.log(max / min);

  /// Speed for a normalized position [t] (clamped to 0..1).
  static double speedFromPos(double t) {
    final clamped = t.clamp(0.0, 1.0);
    return min * math.pow(max / min, clamped).toDouble();
  }

  /// Normalized position for a [speed] (clamped to [min]..[max]).
  static double posFromSpeed(double speed) {
    final clamped = speed.clamp(min, max);
    return math.log(clamped / min) / _lnRange;
  }

  /// Returns the nearest detent when [speed] is within [posTolerance] of one
  /// in normalized space; otherwise returns [speed] clamped to range.
  static double snap(double speed, {double posTolerance = 0.02}) {
    final clamped = speed.clamp(min, max).toDouble();
    final pos = posFromSpeed(clamped);
    double? best;
    var bestDelta = posTolerance;
    for (final d in detents) {
      final delta = (posFromSpeed(d) - pos).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = d;
      }
    }
    return best ?? clamped;
  }
}
