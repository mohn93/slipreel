import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

typedef _ResolvedZoomRamps = ({int enterUs, int exitUs});

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
    Offset? exitOrientationFocalPoint,
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
    final ramps = zoomRegion.duration.inMicroseconds <= 0
        ? (enterUs: 0, exitUs: 0)
        : zoomRegion.resolvedRampsUs(rampDurationScale);
    final z = _calculateZoomFactor(position, zoomRegion, rampCurve, ramps);
    if (z == 1.0) return Matrix4.identity();

    final focal = focalPoint ?? zoomRegion.rect.center;
    final f = framing ?? ZoomFraming.identity(videoSize);

    // Ramp progress (0 at z==1, 1 at settled zoom) — drives BOTH the tilt
    // magnitude and the movement fade, so movement is zero during the ramps
    // and full only at the settled hold.
    final denom = zoomRegion.zoomLevel - 1.0;
    final rampGate = denom <= 0 ? 0.0 : ((z - 1.0) / denom).clamp(0.0, 1.0);
    // Perspective gets its own time-based ramp. The Smooth scale curve is very
    // steep through its middle: driving orientation from the already-eased
    // scale gate keeps yaw/pitch near full strength too long, then removes most
    // of the angle in only a few hundred milliseconds. Enter uses smoothstep;
    // exit uses a decelerating return-to-flat curve so it starts unwinding as
    // soon as zoom-out begins and cannot appear to hold before dropping late.
    final orientationGate = _calculateOrientationGate(
      position,
      zoomRegion,
      ramps,
    );

    // Follow-camera ramps move the focal itself between the canvas centre and
    // the settled cursor target. Using that already-ramped focal as the 3D
    // direction and then multiplying the angle by [rampGate] again makes the
    // orientation fade twice. It is especially visible on zoom-out: halfway
    // through the ramp a Sweep can already be down near 20% strength and reads
    // as though the camera snapped back to centre.
    //
    // Recover the settled direction by dividing out the focal ramp. The gate
    // below remains the single envelope controlling how much tilt/movement is
    // visible. Clamp each axis because edge targets and radial reachability can
    // legitimately lead the scale ramp. Manual placements keep a fixed focal,
    // so their direction must not be compensated.
    final normalizedFocal = f.normalizedFocalOffset(focal);
    // Mouse-following exits can use a nonlinear/back-loaded radial return,
    // especially when the cursor is near an edge. Dividing that live focal by
    // the zoom gate cannot reconstruct the settled direction: its magnitude
    // changes as the reachable viewport changes and the tilt appears to hold,
    // then correct itself near the end. The focal controller/deterministic
    // track therefore supplies the exit-start focal captured before recentering.
    // Keep the division as the compatibility fallback for callers that do not
    // yet provide that anchor.
    final directionalFocal = exitOrientationFocalPoint != null
        ? f.normalizedFocalOffset(exitOrientationFocalPoint)
        : zoomRegion.followCursor && rampGate > 1e-6
        ? Offset(
            (normalizedFocal.dx / rampGate).clamp(-1.0, 1.0),
            (normalizedFocal.dy / rampGate).clamp(-1.0, 1.0),
          )
        : normalizedFocal;

    // Movement (Phase 2): a pure, position-parameterized additive sample folded
    // on top of the settled 2D+tilt transform. None => identity sample => the
    // math below collapses to the Phase 1 result.
    final mv = zoomRegion.movement.resolveAt(
      holdProgress: _holdProgress(position, zoomRegion, ramps),
      rampGate: rampGate,
      normalizedFocal: directionalFocal,
      followCursor: zoomRegion.followCursor,
      orientationRampGate: orientationGate,
    );
    final zEff = z * mv.scaleMul;
    final focalEff = mv.focalDriftFrac == Offset.zero
        ? focal
        : Offset(
            focal.dx + mv.focalDriftFrac.dx * videoSize.width,
            focal.dy + mv.focalDriftFrac.dy * videoSize.height,
          );
    // Defensive: keep a drifted focal in-bounds for follow-cursor zooms (the UI
    // never offers Drift there, but hand-edited JSON could). Manual placements
    // magnify in place and are intentionally unclamped, so leave them.
    final focalUsed =
        (zoomRegion.followCursor && mv.focalDriftFrac != Offset.zero)
        ? clampFocalToBounds(focalEff, videoSize, zEff)
        : focalEff;

    // pCenterRel is in canvas px. Follow-cursor zooms center-and-clamp (the
    // moving cursor must be brought to the viewport center); for identity
    // framing that equals the legacy `clampFocalToBounds(focal, videoSize, z)
    // - videoCenter`. MANUAL placements magnify-in-place: the placed point
    // stays at the same frame fraction at every zoom level (no clamp, no
    // zoom-dependent re-frame), so the placement never lurches when its level
    // changes. See ZoomFraming.centerOffsetInPlace.
    final pCenterRel = zoomRegion.followCursor
        ? f.centerOffset(focalUsed, zEff) // center-and-clamp (unchanged)
        : f.centerOffsetInPlace(focalUsed, zEff); // magnify-in-place (new)

    // The 2D zoom: scale by Z, then translate so the focal lands at the
    // viewport center (operates in canvas-center-relative coords because both
    // pipelines apply this with alignment == center).
    final base = Matrix4.identity()
      ..translateByDouble(-zEff * pCenterRel.dx, -zEff * pCenterRel.dy, 0, 1.0)
      ..scaleByDouble(zEff, zEff, 1.0, 1.0);

    // 2D / flat AND no movement tilt => return the legacy 2D matrix. (Push-in /
    // Drift add no tilt, so they fall through here with only base changed.)
    // Drift can alter a manual placement's direction. Cursor-following drift
    // is not exposed by the editor; for defensive imported projects, keep the
    // stable follow direction rather than reintroducing the double-ramp.
    final tiltDirection = zoomRegion.followCursor
        ? directionalFocal
        : f.normalizedFocalOffset(focalUsed);
    final angles = zoomRegion.tilt.resolveAngles(
      normalizedFocal: tiltDirection,
      progress: orientationGate,
    );
    final axRad = angles.xRad + mv.extraTiltXRad;
    final ayRad = angles.yRad + mv.extraTiltYRad;
    if (axRad == 0.0 && ayRad == 0.0) return base;
    return f.perspectiveTilt(axRad, ayRad).multiplied(base);
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

  /// Smoothstep used by the independent 3D orientation track. Public so its
  /// endpoint and monotonicity contract can be regression-tested directly.
  static double orientationRampProgress(double linearProgress) {
    final t = linearProgress.clamp(0.0, 1.0).toDouble();
    return t * t * (3.0 - 2.0 * t);
  }

  /// Remaining orientation during exit, from fully tilted at `t == 0` to
  /// flat at `t == 1`.
  ///
  /// A symmetric smoothstep is a poor fit for returning the camera to rest:
  /// its zero initial velocity visually holds the old angle, then its peak
  /// velocity lands in the middle of the zoom-out and reads as a snap. This
  /// quadratic ease-out starts the unwind immediately and continuously sheds
  /// angular velocity until it reaches flat with zero terminal velocity.
  static double orientationExitGate(double linearProgress) {
    final t = linearProgress.clamp(0.0, 1.0).toDouble();
    final remaining = 1.0 - t;
    return remaining * remaining;
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
    Offset focal,
    Size videoSize,
    double z,
  ) {
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
    Duration position,
    ZoomRegion z,
    Curve curve,
    _ResolvedZoomRamps ramps,
  ) {
    final tIntoRegionUs = (position - z.startTime).inMicroseconds.clamp(
      0,
      z.duration.inMicroseconds,
    );
    final regionUs = z.duration.inMicroseconds;
    if (regionUs <= 0) return 1.0;

    final enterUs = ramps.enterUs;
    final exitUs = ramps.exitUs;

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

  double _calculateOrientationGate(
    Duration position,
    ZoomRegion region,
    _ResolvedZoomRamps ramps,
  ) {
    final regionUs = region.duration.inMicroseconds;
    if (regionUs <= 0) return 0.0;
    final intoUs = (position - region.startTime).inMicroseconds.clamp(
      0,
      regionUs,
    );

    if (ramps.enterUs > 0 && intoUs < ramps.enterUs) {
      return orientationRampProgress(intoUs / ramps.enterUs);
    }
    final exitStartUs = regionUs - ramps.exitUs;
    if (ramps.exitUs > 0 && intoUs >= exitStartUs) {
      final exitProgress = (intoUs - exitStartUs) / ramps.exitUs;
      return orientationExitGate(exitProgress);
    }
    return 1.0;
  }
}

/// Normalized position within a region's HOLD window (between the enter and
/// exit ramps): 0 before the hold, 0→1 across it, 1 after. A degenerate hold
/// (resolved enter+exit consume the region) stays at 0, so movement cannot
/// appear as a discontinuous step on a tiny zoom.
double _holdProgress(
  Duration position,
  ZoomRegion r,
  _ResolvedZoomRamps ramps,
) {
  final regionUs = r.duration.inMicroseconds;
  if (regionUs <= 0) return 0.0;
  final holdStartUs = ramps.enterUs;
  final holdEndUs = regionUs - ramps.exitUs;
  final spanUs = holdEndUs - holdStartUs;
  // When resolved ramps consume the whole region there is no hold track to
  // play. Keeping movement at identity avoids a mid-ramp step from 0 to 1.
  if (spanUs <= 0) return 0.0;
  final intoRegionUs = (position - r.startTime).inMicroseconds;
  final e = (intoRegionUs - holdStartUs) / spanUs;
  return e.clamp(0.0, 1.0);
}
