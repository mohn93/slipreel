import 'dart:ui' show Offset, Size;

/// Result of snapping a camera bubble center to the standard anchor grid.
class CameraSnapResult {
  const CameraSnapResult({required this.center, required this.snapped});

  /// The (possibly snapped) normalized center. Equals the input when no
  /// anchor was within range.
  final Offset center;

  /// True when the center locked onto an anchor (the caller can show a guide).
  final bool snapped;
}

/// The 9 standard picture-in-picture snap anchors in normalized canvas space
/// (top-left origin): 4 inset corners, 4 edge midpoints, and dead center.
/// [marginX]/[marginY] inset the corners/edges from the canvas edge.
List<Offset> cameraSnapAnchors({double marginX = 0.05, double marginY = 0.05}) {
  final l = marginX, r = 1 - marginX, t = marginY, b = 1 - marginY;
  const c = 0.5;
  return <Offset>[
    Offset(l, t), Offset(r, t), Offset(l, b), Offset(r, b), // corners
    Offset(c, t), Offset(c, b), Offset(l, c), Offset(r, c), // edge midpoints
    Offset(c, c), // center
  ];
}

/// Snaps a normalized bubble center to the nearest [cameraSnapAnchors] anchor
/// when it falls within [thresholdPx] **pixels** of one (distance measured in
/// canvas pixels via [canvasSize], so the feel is consistent regardless of the
/// canvas aspect). Returns the snapped center, or the original when nothing is
/// close enough. Shared by the editor preview today and the exporter later.
CameraSnapResult snapCameraCenter({
  required double centerX,
  required double centerY,
  required Size canvasSize,
  double marginX = 0.05,
  double marginY = 0.05,
  double thresholdPx = 24,
}) {
  final anchors = cameraSnapAnchors(marginX: marginX, marginY: marginY);
  Offset? best;
  var bestDistSq = double.infinity;
  for (final a in anchors) {
    final dx = (centerX - a.dx) * canvasSize.width;
    final dy = (centerY - a.dy) * canvasSize.height;
    final dSq = dx * dx + dy * dy;
    if (dSq < bestDistSq) {
      bestDistSq = dSq;
      best = a;
    }
  }
  if (best != null && bestDistSq <= thresholdPx * thresholdPx) {
    return CameraSnapResult(center: best, snapped: true);
  }
  return CameraSnapResult(center: Offset(centerX, centerY), snapped: false);
}
