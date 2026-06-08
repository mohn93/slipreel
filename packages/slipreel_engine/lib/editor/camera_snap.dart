import 'dart:ui' show Offset, Size;

/// Padding (as a fraction of each canvas axis) kept between the camera bubble's
/// edges and the canvas edges — both as the snap anchor inset AND as the
/// hard clamp, so the bubble never sits flush against the frame.
const double kCameraEdgeMargin = 0.06;

/// Result of snapping a camera bubble center to the standard anchor grid.
class CameraSnapResult {
  const CameraSnapResult({required this.center, required this.snapped});

  /// The (possibly snapped, always in-view + padded) normalized center.
  final Offset center;

  /// True when the center locked onto an anchor (the caller can show a guide).
  final bool snapped;
}

/// Normalized half-extents of the bubble: [halfW] relative to canvas width,
/// [halfH] relative to canvas height. The bubble is sized as a fraction of
/// canvas WIDTH ([size]) with a pixel aspect of [shapeAspect] (w/h), so on a
/// non-square canvas the height fraction is scaled by [canvasAspect] (w/h).
({double halfW, double halfH}) cameraHalfExtents({
  required double size,
  required double shapeAspect,
  required double canvasAspect,
}) {
  final sa = (shapeAspect.isFinite && shapeAspect > 0) ? shapeAspect : 1.0;
  final ca = (canvasAspect.isFinite && canvasAspect > 0) ? canvasAspect : 1.0;
  final halfW = size / 2;
  final halfH = (size / 2) * ca / sa;
  return (halfW: halfW, halfH: halfH);
}

/// Clamps a normalized center so the bubble stays fully within the canvas with
/// [marginX]/[marginY] padding on each side. If the bubble (+ padding) is
/// larger than the canvas on an axis it's centered on that axis.
({double cx, double cy}) clampCameraCenterInView({
  required double centerX,
  required double centerY,
  required double halfW,
  required double halfH,
  double marginX = kCameraEdgeMargin,
  double marginY = kCameraEdgeMargin,
}) {
  double axis(double v, double half, double margin) {
    final lo = half + margin, hi = 1 - half - margin;
    if (lo > hi) return 0.5; // bigger than the padded canvas → centered
    return v.clamp(lo, hi).toDouble();
  }

  return (cx: axis(centerX, halfW, marginX), cy: axis(centerY, halfH, marginY));
}

/// The 9 standard PiP snap anchors as normalized **centers**, inset so the
/// bubble's EDGES sit [marginX]/[marginY] from the canvas edge (NOT its
/// center). Pass the bubble's [halfW]/[halfH] (see [cameraHalfExtents]).
/// Row-major: top row, middle row, bottom row.
List<Offset> cameraSnapAnchors({
  double halfW = 0.0,
  double halfH = 0.0,
  double marginX = kCameraEdgeMargin,
  double marginY = kCameraEdgeMargin,
}) {
  var l = marginX + halfW;
  var r = 1 - marginX - halfW;
  var t = marginY + halfH;
  var b = 1 - marginY - halfH;
  if (l > r) l = r = 0.5; // too wide to inset → center column
  if (t > b) t = b = 0.5; // too tall to inset → center row
  const c = 0.5;
  return <Offset>[
    Offset(l, t), Offset(c, t), Offset(r, t),
    Offset(l, c), Offset(c, c), Offset(r, c),
    Offset(l, b), Offset(c, b), Offset(r, b),
  ];
}

/// Clamps a normalized bubble center into the padded safe area, then snaps it
/// to the nearest [cameraSnapAnchors] anchor when within [thresholdPx]
/// **pixels** of one (distance in canvas pixels via [canvasSize]). [size] is
/// the bubble width fraction, [shapeAspect] its pixel w/h. The returned center
/// is always fully in view with [kCameraEdgeMargin] padding.
CameraSnapResult snapCameraCenter({
  required double centerX,
  required double centerY,
  required Size canvasSize,
  required double size,
  required double shapeAspect,
  double marginX = kCameraEdgeMargin,
  double marginY = kCameraEdgeMargin,
  double thresholdPx = 22,
}) {
  final ca = canvasSize.height == 0 ? 1.0 : canvasSize.width / canvasSize.height;
  final ext =
      cameraHalfExtents(size: size, shapeAspect: shapeAspect, canvasAspect: ca);
  final clamped = clampCameraCenterInView(
    centerX: centerX,
    centerY: centerY,
    halfW: ext.halfW,
    halfH: ext.halfH,
    marginX: marginX,
    marginY: marginY,
  );

  final anchors = cameraSnapAnchors(
    halfW: ext.halfW,
    halfH: ext.halfH,
    marginX: marginX,
    marginY: marginY,
  );
  Offset? best;
  var bestSq = double.infinity;
  for (final a in anchors) {
    final dx = (clamped.cx - a.dx) * canvasSize.width;
    final dy = (clamped.cy - a.dy) * canvasSize.height;
    final dSq = dx * dx + dy * dy;
    if (dSq < bestSq) {
      bestSq = dSq;
      best = a;
    }
  }
  if (best != null && bestSq <= thresholdPx * thresholdPx) {
    return CameraSnapResult(center: best, snapped: true);
  }
  return CameraSnapResult(
      center: Offset(clamped.cx, clamped.cy), snapped: false);
}
