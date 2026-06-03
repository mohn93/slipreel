// packages/slipreel_engine/lib/snap/snap_resolver.dart

/// Outcome of [resolveSnap].
class SnapResult {
  const SnapResult(this.time, this.snappedFrom);

  /// The chosen cut time — either the original requested time
  /// (no snap) or a candidate from the input list (snapped).
  final Duration time;

  /// The candidate the cut snapped to, or null if no snap occurred.
  /// When equal to [time] AND non-null, the snap landed exactly on
  /// the candidate (informational; the UI uses this for the flash
  /// regardless of whether the candidate equals the request).
  final Duration? snappedFrom;
}

const Duration kDefaultSnapRadius = Duration(milliseconds: 150);

/// Returns the snap decision for a cut at [requestedTime].
///
/// [candidates] MUST be sorted ascending. Behavior is undefined if not.
/// Picks the closest candidate within [radius] of [requestedTime].
/// On ties, the earlier candidate wins.
SnapResult resolveSnap({
  required Duration requestedTime,
  required List<Duration> candidates,
  Duration radius = kDefaultSnapRadius,
}) {
  if (candidates.isEmpty) return SnapResult(requestedTime, null);

  // Floor-style binary search: largest index i with candidates[i] <= requestedTime,
  // or -1 if requestedTime is below all candidates.
  final target = requestedTime.inMicroseconds;
  int lo = 0;
  int hi = candidates.length - 1;
  int floor = -1;
  if (candidates.first.inMicroseconds <= target) {
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (candidates[mid].inMicroseconds <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    floor = lo;
  }
  final ceil = floor + 1; // may be == candidates.length

  Duration? best;
  int bestDist = 1 << 62;
  // Check floor neighbor.
  if (floor >= 0) {
    final c = candidates[floor];
    final d = target - c.inMicroseconds; // >= 0
    if (d < bestDist) {
      bestDist = d;
      best = c;
    }
  }
  // Check ceil neighbor; on equidistant tie the earlier (floor) wins, so use < not <=.
  if (ceil < candidates.length) {
    final c = candidates[ceil];
    final d = c.inMicroseconds - target; // > 0
    if (d < bestDist) {
      bestDist = d;
      best = c;
    }
  }

  if (best == null || bestDist > radius.inMicroseconds) {
    return SnapResult(requestedTime, null);
  }
  return SnapResult(best, best);
}
