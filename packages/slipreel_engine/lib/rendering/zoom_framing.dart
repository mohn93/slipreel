import 'dart:math' as math;

import 'package:flutter/painting.dart' show Offset, Rect, Size;
import 'package:flutter/rendering.dart' show Matrix4;

import 'package:slipreel_engine/effects/zoom_transformer.dart';

/// Perspective "focal length" multiplier: the camera distance used for the 3D
/// tilt is `canvasHeight * kPerspective`. Derived from canvas height so the
/// projection is resolution-independent (1080p preview == 4K export).
const double kPerspective = 1.6;

/// Owns the "where is the source video drawn, and what bounds must the zoomed
/// viewport stay within" math for the zoom pipeline.
///
/// All public focal arguments and results are in SOURCE-VIDEO coordinates (the
/// space [ZoomFocalController] integrates in) EXCEPT [centerOffset] /
/// [centerOffsetInPlace], which return the canvas-pixel translation the zoom
/// matrix applies.
///
/// Two translation laws share this type, selected per zoom region by the
/// caller: [centerOffset] (follow-cursor) centers the focal and clamps the
/// viewport to the canvas; [centerOffsetInPlace] (manual placement) magnifies
/// in place — `(toCanvas(focal) − canvasCenter)·(1 − 1/z)` — so the placed
/// point holds its frame fraction across zoom levels and never needs clamping.
///
/// [ZoomFraming.device] frames the COMPOSED canvas: the video is rendered into
/// [videoRect] (offset + scaled) inside [canvasSize], so clamps/centering stay
/// inside the PADDED canvas and the surrounding padding, wallpaper, and any
/// device bezel are preserved. It is used for ALL recordings whose composition
/// has padding and/or a device frame — not only device bezels.
/// [ZoomFraming.identity] is the degenerate case (video fills the canvas 1:1,
/// centered; clamps stay inside the VIDEO bounds) and is exactly what
/// [ZoomFraming.device] reduces to when `videoRect == (0,0,W,H)` and
/// `canvasSize == videoSize` (zero padding, no bezel) — byte-identical.
class ZoomFraming {
  const ZoomFraming._({
    required this.videoSize,
    required this.videoRect,
    required this.canvasSize,
    required this.isIdentity,
  });

  factory ZoomFraming.identity(Size videoSize) => ZoomFraming._(
        videoSize: videoSize,
        videoRect: Rect.fromLTWH(0, 0, videoSize.width, videoSize.height),
        canvasSize: videoSize,
        isIdentity: true,
      );

  /// Device-bezel framing. Falls back to identity when the inputs are
  /// degenerate (zero-area videoRect/canvas) so callers never divide by zero.
  factory ZoomFraming.device({
    required Size videoSize,
    required Rect videoRect,
    required Size canvasSize,
  }) {
    if (videoSize.width <= 0 ||
        videoSize.height <= 0 ||
        videoRect.width <= 0 ||
        videoRect.height <= 0 ||
        canvasSize.width <= 0 ||
        canvasSize.height <= 0) {
      return ZoomFraming.identity(videoSize);
    }
    return ZoomFraming._(
      videoSize: videoSize,
      videoRect: videoRect,
      canvasSize: canvasSize,
      isIdentity: false,
    );
  }

  final Size videoSize;
  final Rect videoRect;
  final Size canvasSize;
  final bool isIdentity;

  double get _sx => videoRect.width / videoSize.width;
  double get _sy => videoRect.height / videoSize.height;

  /// Maps a SOURCE-VIDEO point to its CANVAS-pixel position (offset + scaled
  /// into [videoRect] inside [canvasSize]).
  Offset toCanvas(Offset p) =>
      Offset(videoRect.left + p.dx * _sx, videoRect.top + p.dy * _sy);

  /// Inverse of [toCanvas]: maps a CANVAS-pixel point back to SOURCE-VIDEO
  /// coordinates.
  Offset fromCanvas(Offset q) => Offset(
        (q.dx - videoRect.left) / _sx,
        (q.dy - videoRect.top) / _sy,
      );

  Offset _toCanvas(Offset p) => toCanvas(p);
  Offset _fromCanvas(Offset q) => fromCanvas(q);

  Offset get _canvasCenter =>
      Offset(canvasSize.width / 2, canvasSize.height / 2);

  /// Per-axis reachable-bounds clamp, returned in source-video coordinates.
  Offset clampFocal(Offset focal, double z) {
    if (isIdentity) {
      return ZoomTransformer.clampFocalToBounds(focal, videoSize, z);
    }
    final clamped =
        ZoomTransformer.clampFocalToBounds(_toCanvas(focal), canvasSize, z);
    return _fromCanvas(clamped);
  }

  /// Radial reachable-bounds clamp (used by the manual enter/exit pan),
  /// returned in source-video coordinates.
  Offset clampFocalRadial(Offset focal, double z) {
    if (isIdentity) {
      return ZoomTransformer.clampFocalToBoundsRadial(focal, videoSize, z);
    }
    final clamped = ZoomTransformer.clampFocalToBoundsRadial(
        _toCanvas(focal), canvasSize, z);
    return _fromCanvas(clamped);
  }

  /// Pulls [focal] the minimum amount so the live [cursor] stays at least
  /// [edgeMarginFraction] of the VIEWPORT (`canvasDim / z`, per axis) inside the
  /// zoomed viewport, then re-imposes [clampFocal] on the pulled axis so the
  /// viewport never leaves the canvas (near a true edge the reachable clamp
  /// wins — graceful degradation). When the cursor is already inside the safe
  /// area on an axis, that axis is returned VERBATIM (the controller's focal is
  /// intentionally unclamped; the transformer clamps at paint). At `z <= 1`
  /// there is no viewport crop, so it delegates to [clampFocal].
  ///
  /// Pure function (focal, cursor, z, margin) — identical for identity and
  /// device framing because the math runs in canvas space. The margin is
  /// viewport-relative so the safety is zoom-invariant and stays outside the
  /// deadzone.
  Offset clampFocalKeepCursorInView(
    Offset focal,
    Offset cursor,
    double z,
    double edgeMarginFraction,
  ) {
    if (z <= 1.0) return clampFocal(focal, z);
    final cf = toCanvas(focal);
    final cc = toCanvas(cursor);
    final m = edgeMarginFraction.clamp(0.0, 0.49);
    final allowedX = math.max(0.0, (canvasSize.width / z) * (0.5 - m));
    final allowedY = math.max(0.0, (canvasSize.height / z) * (0.5 - m));
    final nx = cf.dx.clamp(cc.dx - allowedX, cc.dx + allowedX);
    final ny = cf.dy.clamp(cc.dy - allowedY, cc.dy + allowedY);
    final pulledX = nx != cf.dx;
    final pulledY = ny != cf.dy;
    if (!pulledX && !pulledY) return focal;
    final clamped = clampFocal(fromCanvas(Offset(nx, ny)), z);
    return Offset(
      pulledX ? clamped.dx : focal.dx,
      pulledY ? clamped.dy : focal.dy,
    );
  }

  /// The `pCenterRel` the zoom matrix translates by, in CANVAS pixels:
  /// the clamped focal's canvas position minus the canvas center. The matrix
  /// then applies `translate(-z * centerOffset) * scale(z)` about the canvas
  /// center so the focal lands at the viewport center.
  Offset centerOffset(Offset focal, double z) {
    final canvasFocal = _toCanvas(focal);
    final clamped =
        ZoomTransformer.clampFocalToBounds(canvasFocal, canvasSize, z);
    return clamped - Offset(canvasSize.width / 2, canvasSize.height / 2);
  }

  /// Unclamped version of [centerOffset]: returns the translation needed to
  /// center the viewport on the focal point, without reachability constraints.
  /// Formula: `(toCanvas(focal) - canvasCenter) * (1 - 1/z)`.
  Offset centerOffsetInPlace(Offset focal, double z) {
    final canvasFocal = _toCanvas(focal);
    final center = _canvasCenter;
    final k = 1.0 - 1.0 / z;
    return (canvasFocal - center) * k;
  }

  /// The focal's offset from the canvas center, normalized so each axis is in
  /// `[-1, 1]` (clamped). Used to derive the auto 3D-tilt direction: a focal to
  /// the right of center → `dx > 0`, below center → `dy > 0`.
  Offset normalizedFocalOffset(Offset focal) {
    final cf = toCanvas(focal);
    final nx = ((cf.dx - canvasSize.width / 2) / (canvasSize.width / 2))
        .clamp(-1.0, 1.0);
    final ny = ((cf.dy - canvasSize.height / 2) / (canvasSize.height / 2))
        .clamp(-1.0, 1.0);
    return Offset(nx, ny);
  }

  /// The perspective + rotation matrix for a 3D tilt, in canvas-center-relative
  /// coordinates (the space the zoom matrix already operates in). Composed by
  /// [ZoomTransformer.getTransform] on top of the 2D scale+translate matrix.
  /// Perspective strength scales with [canvasSize] height (see [kPerspective]).
  Matrix4 perspectiveTilt(double axRad, double ayRad) {
    return Matrix4.identity()
      ..setEntry(3, 2, -1.0 / (canvasSize.height * kPerspective))
      ..rotateX(axRad)
      ..rotateY(ayRad);
  }

  /// The visible CANVAS region for a manual (magnify-in-place) zoom on [focal]
  /// at level [z]. The matrix maps the screen-center pre-image to
  /// [centerOffsetInPlace], so the visible-region center in absolute canvas
  /// coords is `canvasCenter + centerOffsetInPlace`, with size `canvasSize / z`.
  Rect manualViewportRect(Offset focal, double z) {
    final center = _canvasCenter + centerOffsetInPlace(focal, z);
    return Rect.fromCenter(
      center: center,
      width: canvasSize.width / z,
      height: canvasSize.height / z,
    );
  }

  /// Exact inverse of [manualViewportRect].center for the picker drag: given a
  /// viewport-box center in canvas coords, returns the SOURCE-VIDEO focal that
  /// produces it. Guards z≈1 (the `1 - 1/z` factor collapses) by returning the
  /// canvas-center focal.
  Offset manualFocalForViewportCenter(Offset viewportCenter, double z) {
    final center = _canvasCenter;
    final k = 1.0 - 1.0 / z;
    if (k.abs() < 1e-6) return fromCanvas(center);
    return fromCanvas(center + (viewportCenter - center) / k);
  }

  /// Clamps a viewport-box center (canvas coords) so the box of size
  /// `canvasSize / z` stays fully inside the canvas.
  Offset clampManualViewportCenter(Offset viewportCenter, double z) {
    final halfW = canvasSize.width / (2 * z);
    final halfH = canvasSize.height / (2 * z);
    return Offset(
      viewportCenter.dx.clamp(halfW, canvasSize.width - halfW),
      viewportCenter.dy.clamp(halfH, canvasSize.height - halfH),
    );
  }
}
