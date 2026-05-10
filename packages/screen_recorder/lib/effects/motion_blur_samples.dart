import 'package:flutter/painting.dart';

/// One stamp emitted by [sampleMotionBlurStamps]: where to draw the
/// cursor sprite, and what alpha to apply. Coordinates are in the same
/// space as the input polyline (typically widget pixels).
class MotionBlurStamp {
  const MotionBlurStamp({required this.position, required this.alpha});

  final Offset position;
  final double alpha;
}

/// Distributes up to [maxStamps] cursor stamps evenly along [polyline]
/// by arc length and returns the position + alpha of each.
///
/// **Path-aware motion blur.** The caller passes the cursor's recorded
/// path during the virtual shutter window. Every emitted stamp lies on
/// that polyline, so the trail can never extend to a position the
/// cursor wasn't actually at — even when the cursor curves or
/// reverses inside the window. The polyline's first point is the tail
/// (oldest sample); the last is the head (current position).
///
/// Stamps are spaced uniformly by arc length (~1 stamp per 2 px so
/// consecutive cursor-body stamps overlap on a typical 32-px cursor)
/// and capped at [maxStamps] to bound per-frame work. Alphas linearly
/// taper from `1/count` at the tail to `1.0` at the head, so the head
/// composites opaque over the trail and the cursor stays sharp.
///
/// Returns an empty list when the polyline has fewer than 2 points or
/// total arc length is sub-pixel — caller treats this as "no blur"
/// and short-circuits to direct paint.
List<MotionBlurStamp> sampleMotionBlurStamps({
  required List<Offset> polyline,
  int maxStamps = 40,
}) {
  if (polyline.length < 2) return const [];

  final cum = List<double>.filled(polyline.length, 0);
  for (var i = 1; i < polyline.length; i++) {
    cum[i] = cum[i - 1] + (polyline[i] - polyline[i - 1]).distance;
  }
  final total = cum.last;

  // Stamp count grows with reach (~1 stamp per 2 px), capped at
  // maxStamps. count == 1 means the path is sub-pixel: no blur.
  final count = ((total / 2).round() + 1).clamp(1, maxStamps);
  if (count <= 1) return const [];

  final stamps = <MotionBlurStamp>[];
  for (var i = 0; i < count; i++) {
    // Arc-length parameter from 0 (tail) to total (head).
    final s = (i / (count - 1)) * total;
    // Find the polyline segment containing s. count <= 40 so the
    // total cost of these scans is bounded.
    var seg = 1;
    while (seg < polyline.length - 1 && cum[seg] < s) {
      seg++;
    }
    final segLen = cum[seg] - cum[seg - 1];
    final t = segLen > 0 ? (s - cum[seg - 1]) / segLen : 0.0;
    final pos = Offset(
      polyline[seg - 1].dx + (polyline[seg].dx - polyline[seg - 1].dx) * t,
      polyline[seg - 1].dy + (polyline[seg].dy - polyline[seg - 1].dy) * t,
    );
    stamps.add(MotionBlurStamp(position: pos, alpha: (i + 1) / count));
  }
  return stamps;
}
