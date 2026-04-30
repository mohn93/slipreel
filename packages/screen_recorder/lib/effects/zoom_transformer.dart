import 'package:flutter/material.dart';
import 'package:screen_recorder/models/zoom_region.dart';

/// Builds the per-frame zoom matrix used by the playback preview.
///
/// The matrix scales by the active zoom factor and re-centers the chosen
/// focal point on the viewport, clamping so the visible window never falls
/// outside the video bounds.
class ZoomTransformer {
  /// Returns a transform matrix to apply to a child rendered with
  /// `alignment: Alignment.center`.
  ///
  /// [focalPoint] (in video coords) is what gets centered; pass the
  /// recorded cursor position for cursor-following zoom. When null, falls
  /// back to the zoom region's stored rect center.
  Matrix4 getTransform({
    required Duration position,
    required ZoomRegion zoomRegion,
    required Size videoSize,
    Offset? focalPoint,
  }) {
    if (!zoomRegion.isActive(position)) {
      return Matrix4.identity();
    }
    final progress = _easeInOutCurve(zoomRegion.getProgress(position));
    final z = _calculateZoomFactor(progress, zoomRegion.zoomLevel);
    if (z == 1.0) return Matrix4.identity();

    final focal = focalPoint ?? zoomRegion.rect.center;
    final clamped = _clampFocal(focal, videoSize, z);
    final pCenterRel = clamped -
        Offset(videoSize.width / 2, videoSize.height / 2);

    // With `alignment: Alignment.center` the matrix operates in
    // center-relative coordinates. Scale by Z, then translate by -Z·pCr so
    // the focal point lands exactly at the origin (= viewport center).
    return Matrix4.identity()
      ..translateByDouble(-z * pCenterRel.dx, -z * pCenterRel.dy, 0, 1.0)
      ..scaleByDouble(z, z, 1.0, 1.0);
  }

  /// Clamp the focal point so the zoomed-in visible window stays entirely
  /// within the video. At a zoom factor of Z, the visible window's
  /// half-extents in source space are videoSize/(2Z); the focal point must
  /// stay at least that far from each edge.
  Offset _clampFocal(Offset focal, Size videoSize, double z) {
    final halfW = videoSize.width / (2 * z);
    final halfH = videoSize.height / (2 * z);
    final maxX = videoSize.width - halfW;
    final maxY = videoSize.height - halfH;
    return Offset(
      halfW <= maxX ? focal.dx.clamp(halfW, maxX) : videoSize.width / 2,
      halfH <= maxY ? focal.dy.clamp(halfH, maxY) : videoSize.height / 2,
    );
  }

  double _easeInOutCurve(double t) =>
      t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);

  /// Goes 1 → zoomLevel → 1 across the region (sine ramp).
  double _calculateZoomFactor(double progress, double maxZoom) {
    final ramp = 1 - (progress * 2 - 1).abs();
    return 1.0 + (maxZoom - 1.0) * ramp;
  }
}
