import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:slipreel_engine/models/zoom_region.dart';

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
    // Route the activation check through [ZoomRegion.activeAt] so the
    // closed end-edge frame (`position == endTime`) resolves consistently
    // with the focal controller, scene-pass builder, and frame compositor:
    // at exactly endTime the just-ended region still wins and the math
    // below collapses to identity via the 1.0× zoom factor — keeping the
    // ramp completion frame coherent across every consumer.
    final active = ZoomRegion.activeAt(position, <ZoomRegion>[zoomRegion]);
    if (active == null) {
      return Matrix4.identity();
    }
    final z = _calculateZoomFactor(position, zoomRegion, rampCurve);
    if (z == 1.0) return Matrix4.identity();

    final focal = focalPoint ?? zoomRegion.rect.center;
    final clamped = clampFocalToBounds(focal, videoSize, z);
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
  ///
  /// This is the single source of truth for "where can the focal actually
  /// sit at zoom z". [ZoomFocalController]'s enter ramp aims its pan at the
  /// FULL-zoom-clamped point via this same formula so the eased focal never
  /// crosses the per-frame clamp mid-ramp (which would pin the viewport to
  /// the video edge before the magnification finishes). Keep the two in
  /// lock-step by routing both through here.
  static Offset clampFocalToBounds(Offset focal, Size videoSize, double z) {
    final halfW = videoSize.width / (2 * z);
    final halfH = videoSize.height / (2 * z);
    final maxX = videoSize.width - halfW;
    final maxY = videoSize.height - halfH;
    return Offset(
      halfW <= maxX ? focal.dx.clamp(halfW, maxX) : videoSize.width / 2,
      halfH <= maxY ? focal.dy.clamp(halfH, maxY) : videoSize.height / 2,
    );
  }

  /// Result of [resolveCardPushIn]: the clamped card scale, the centered
  /// on-canvas card rect at that scale, and the effective (scaled) corner
  /// radius.
  static ({double zCard, Rect cardRect, double cornerRadius}) resolveCardPushIn({
    required Rect videoRect,
    required Size canvasSize,
    required double cornerRadius,
    required double zoom,
    double paddingFloorFraction = 0.4,
  }) {
    // Padding (per axis) is the inset of the centered 1× video rect.
    final padX = (canvasSize.width - videoRect.width) / 2;
    final padY = (canvasSize.height - videoRect.height) / 2;
    final floorX = paddingFloorFraction * padX;
    final floorY = paddingFloorFraction * padY;
    // Largest card scale that keeps each axis inset >= its floor:
    //   zCardMax_axis = (canvas_axis - 2*floor_axis) / videoRect_axis.
    final zCardMaxX = videoRect.width <= 0
        ? 1.0
        : (canvasSize.width - 2 * floorX) / videoRect.width;
    final zCardMaxY = videoRect.height <= 0
        ? 1.0
        : (canvasSize.height - 2 * floorY) / videoRect.height;
    final zCardMax = zCardMaxX < zCardMaxY ? zCardMaxX : zCardMaxY;
    final cappedMax = zCardMax < 1.0 ? 1.0 : zCardMax;
    var zCard = zoom < 1.0 ? 1.0 : zoom;
    if (zCard > cappedMax) zCard = cappedMax;
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final cardRect = Rect.fromCenter(
      center: center,
      width: videoRect.width * zCard,
      height: videoRect.height * zCard,
    );
    return (
      zCard: zCard,
      cardRect: cardRect,
      cornerRadius: cornerRadius * zCard,
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
