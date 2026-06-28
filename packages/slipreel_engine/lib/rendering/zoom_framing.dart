import 'package:flutter/painting.dart' show Offset, Rect, Size;

import 'package:slipreel_engine/effects/zoom_transformer.dart';

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

  Offset _toCanvas(Offset p) =>
      Offset(videoRect.left + p.dx * _sx, videoRect.top + p.dy * _sy);

  Offset _fromCanvas(Offset q) => Offset(
        (q.dx - videoRect.left) / _sx,
        (q.dy - videoRect.top) / _sy,
      );

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
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final k = 1.0 - 1.0 / z;
    return (canvasFocal - center) * k;
  }

  // Test-only accessors for the affine map.
  Offset debugToCanvas(Offset p) => _toCanvas(p);
  Offset debugFromCanvas(Offset q) => _fromCanvas(q);
}
