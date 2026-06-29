import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

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
  ///
  /// [framing] (optional) controls focal clamping and canvas translation.
  /// When null, defaults to identity framing (legacy behavior). The translation
  /// law is selected by [zoomRegion].followCursor: follow-cursor centers and
  /// clamps the focal ([ZoomFraming.centerOffset]); a manual placement
  /// magnifies in place ([ZoomFraming.centerOffsetInPlace]).
  /// When the region's `tilt` is 3D, a perspective rotation is composed about
  /// the canvas center on top of the 2D zoom; flat tilt returns the 2D matrix
  /// unchanged.
  Matrix4 getTransform({
    required Duration position,
    required ZoomRegion zoomRegion,
    required Size videoSize,
    Offset? focalPoint,
    Curve rampCurve = Curves.easeInOutQuad,
    double rampDurationScale = 1.0,
    ZoomFraming? framing,
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
    final z = _calculateZoomFactor(
        position, zoomRegion, rampCurve, rampDurationScale);
    if (z == 1.0) return Matrix4.identity();

    final focal = focalPoint ?? zoomRegion.rect.center;
    final f = framing ?? ZoomFraming.identity(videoSize);
    // pCenterRel is in canvas px. Follow-cursor zooms center-and-clamp (the
    // moving cursor must be brought to the viewport center); for identity
    // framing that equals the legacy `clampFocalToBounds(focal, videoSize, z)
    // - videoCenter`. MANUAL placements magnify-in-place: the placed point
    // stays at the same frame fraction at every zoom level (no clamp, no
    // zoom-dependent re-frame), so the placement never lurches when its level
    // changes. See ZoomFraming.centerOffsetInPlace.
    final pCenterRel = zoomRegion.followCursor
        ? f.centerOffset(focal, z) // center-and-clamp (unchanged)
        : f.centerOffsetInPlace(focal, z); // magnify-in-place (new)

    // The 2D zoom: scale by Z, then translate so the focal lands at the
    // viewport center (operates in canvas-center-relative coords because both
    // pipelines apply this with alignment == center).
    final base = Matrix4.identity()
      ..translateByDouble(-z * pCenterRel.dx, -z * pCenterRel.dy, 0, 1.0)
      ..scaleByDouble(z, z, 1.0, 1.0);

    // 2D / flat: return the legacy matrix unchanged (byte-identical).
    if (!zoomRegion.tilt.is3D) return base;

    // 3D: layer a perspective tilt about the canvas center on top of the 2D
    // zoom. Direction is auto-derived from the focal's position in the composed
    // frame; magnitude ramps with the zoom factor (0 at z==1, full at zoomLevel)
    // so the tilt is always in lock-step with the scale.
    final denom = zoomRegion.zoomLevel - 1.0;
    final progress = denom <= 0 ? 0.0 : ((z - 1.0) / denom).clamp(0.0, 1.0);
    final angles = zoomRegion.tilt.resolveAngles(
      normalizedFocal: f.normalizedFocalOffset(focal),
      progress: progress,
    );
    return f.perspectiveTilt(angles.xRad, angles.yRad).multiplied(base);
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

  /// RADIAL counterpart of [clampFocalToBounds]: clamp [focal] into the same
  /// reachable box at zoom [z], but by scaling the whole offset from the
  /// video center by a single scalar instead of clamping each axis
  /// independently. This keeps the result exactly on the ray from the video
  /// center through [focal] (collinear), so a focal that is being panned
  /// along a straight center→placement line stays on that line when it
  /// overshoots the current-frame box — where the per-axis [clampFocalToBounds]
  /// would pin one axis and let the other keep moving, bending the path into a
  /// dog-leg ("the camera takes some turns before landing").
  ///
  /// The reachable box is center-symmetric about the video center with
  /// half-extents `hx = (W/2)(1 − 1/z)`, `hy = (H/2)(1 − 1/z)`. A point at
  /// offset `d` from center is scaled by `s = min(1, hx/|dx|, hy/|dy|)` (axes
  /// with a ~zero offset don't constrain `s`). Because `s` is uniform the
  /// direction is preserved and `|d·s|` is within the box on both axes, so a
  /// subsequent per-axis [clampFocalToBounds] at the same `z` is a no-op.
  ///
  /// [ZoomFocalController] applies this to its MANUAL (non-followCursor)
  /// enter/exit pan, whose anchor is the video center — the only anchor for
  /// which "radial about the video center" is collinear with the pan. At
  /// `z <= 1` the box collapses, so this returns the video center (matching
  /// [clampFocalToBounds]'s degenerate fallback).
  static Offset clampFocalToBoundsRadial(
      Offset focal, Size videoSize, double z) {
    final centre = Offset(videoSize.width / 2, videoSize.height / 2);
    final hx = (videoSize.width / 2) * (1 - 1 / z);
    final hy = (videoSize.height / 2) * (1 - 1 / z);
    if (hx <= 0 || hy <= 0) return centre;
    final d = focal - centre;
    const eps = 1e-9;
    final sx = d.dx.abs() > eps ? hx / d.dx.abs() : double.infinity;
    final sy = d.dy.abs() > eps ? hy / d.dy.abs() : double.infinity;
    final s = math.min(1.0, math.min(sx, sy));
    return centre + d * s;
  }

  /// Three-phase zoom: ease-in over [enterDuration], hold at full
  /// zoomLevel for the middle, ease-out over [exitDuration]. If the
  /// requested enter+exit don't fit inside the region, both are scaled
  /// down proportionally so the shape is preserved (and the hold goes
  /// to zero in the limit).
  double _calculateZoomFactor(
      Duration position, ZoomRegion z, Curve curve, double rampDurationScale) {
    final tIntoRegionUs =
        (position - z.startTime).inMicroseconds.clamp(0, z.duration.inMicroseconds);
    final regionUs = z.duration.inMicroseconds;
    if (regionUs <= 0) return 1.0;

    var enterUs = (z.enterDuration.inMicroseconds * rampDurationScale).round();
    var exitUs = (z.exitDuration.inMicroseconds * rampDurationScale).round();
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
