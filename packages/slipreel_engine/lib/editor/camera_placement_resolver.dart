import 'package:flutter/animation.dart';

import 'package:slipreel_engine/models/camera_region.dart';

/// The interpolated camera bubble placement at a playhead instant. All
/// values are normalized canvas-space (see [CameraRegion]).
class CameraPlacement {
  const CameraPlacement({
    required this.centerX,
    required this.centerY,
    required this.size,
  });

  final double centerX;
  final double centerY;
  final double size;

  @override
  bool operator ==(Object other) =>
      other is CameraPlacement &&
      other.centerX == centerX &&
      other.centerY == centerY &&
      other.size == size;

  @override
  int get hashCode => Object.hash(centerX, centerY, size);
}

/// Maps a playhead position to a [CameraPlacement], or `null` when the
/// camera is hidden (the playhead is in a gap between regions).
///
/// Within a region the placement is static, EXCEPT a lead-in glide when the
/// immediately-preceding region **touches** this one (their boundary is
/// within [joinTolerance]): over the first [glideDuration] the placement
/// lerps from the predecessor's to this region's, eased by [glideCurve].
/// Shared by the preview ([PlaybackCanvas]) and, in Plan 3, the exporter.
class CameraPlacementResolver {
  const CameraPlacementResolver._();

  static const Duration defaultGlideDuration = Duration(milliseconds: 350);
  static const Duration defaultJoinTolerance = Duration(milliseconds: 4);

  static CameraPlacement? placementAt(
    Duration position,
    List<CameraRegion> regions, {
    Duration glideDuration = defaultGlideDuration,
    Curve glideCurve = Curves.easeInOut,
    Duration joinTolerance = defaultJoinTolerance,
  }) {
    if (regions.isEmpty) return null;

    // Active region (half-open). If none, the camera is hidden.
    CameraRegion? active;
    for (final r in regions) {
      if (r.isActive(position)) {
        active = r;
        break;
      }
    }
    if (active == null) return null;

    final base = CameraPlacement(
      centerX: active.centerX,
      centerY: active.centerY,
      size: active.size,
    );

    if (glideDuration <= Duration.zero) return base;

    // Predecessor = the region with the greatest endTime <= active.startTime.
    CameraRegion? pred;
    for (final r in regions) {
      if (identical(r, active)) continue;
      if (r.endTime <= active.startTime) {
        if (pred == null || r.endTime > pred.endTime) pred = r;
      }
    }
    if (pred == null) return base;

    // Only glide when the predecessor TOUCHES the active region.
    final joinGap = active.startTime - pred.endTime;
    if (joinGap > joinTolerance) return base;

    final into = position - active.startTime;
    if (into >= glideDuration) return base;

    final tRaw = into.inMicroseconds / glideDuration.inMicroseconds;
    final t = glideCurve.transform(tRaw.clamp(0.0, 1.0));
    return CameraPlacement(
      centerX: _lerp(pred.centerX, active.centerX, t),
      centerY: _lerp(pred.centerY, active.centerY, t),
      size: _lerp(pred.size, active.size, t),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
