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
  ///
  /// [rampCurve] shapes the zoom factor's enter/exit ramps. Defaults
  /// to easeInOutQuad to match the original hand-rolled curve.
  Matrix4 getTransform({
    required Duration position,
    required ZoomRegion zoomRegion,
    required Size videoSize,
    Offset? focalPoint,
    Curve rampCurve = Curves.easeInOutQuad,
  }) {
    if (!zoomRegion.isActive(position)) {
      return Matrix4.identity();
    }
    final z = _calculateZoomFactor(position, zoomRegion, rampCurve);
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

  /// Three-phase zoom: ease-in over [enterDuration], hold at full
  /// zoomLevel for the middle, ease-out over [exitDuration]. If the
  /// requested enter+exit don't fit inside the region, both are scaled
  /// down proportionally so the shape is preserved (and the hold goes
  /// to zero in the limit).
  double _calculateZoomFactor(
      Duration position, ZoomRegion z, Curve curve) {
    final tIntoRegionUs =
        (position - z.startTime).inMicroseconds.clamp(0, z.duration.inMicroseconds);
    final regionUs = z.duration.inMicroseconds;
    if (regionUs <= 0) return 1.0;

    var enterUs = z.enterDuration.inMicroseconds;
    var exitUs = z.exitDuration.inMicroseconds;
    final totalRamp = enterUs + exitUs;
    if (totalRamp > regionUs && totalRamp > 0) {
      final scale = regionUs / totalRamp;
      enterUs = (enterUs * scale).round();
      exitUs = (exitUs * scale).round();
    }

    if (tIntoRegionUs < enterUs) {
      final t = enterUs == 0 ? 1.0 : tIntoRegionUs / enterUs;
      return 1.0 + (z.zoomLevel - 1.0) * curve.transform(t);
    }
    final exitStartUs = regionUs - exitUs;
    if (tIntoRegionUs >= exitStartUs && exitUs > 0) {
      final t = ((tIntoRegionUs - exitStartUs) / exitUs).clamp(0.0, 1.0);
      return 1.0 + (z.zoomLevel - 1.0) * (1 - curve.transform(t));
    }
    // Hold phase.
    return z.zoomLevel;
  }
}
