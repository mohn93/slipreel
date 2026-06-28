// packages/slipreel_engine/lib/rendering/device_frame_layout.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

/// Resolved geometry for drawing a device frame: the output canvas, the
/// rect where the bezel PNG is drawn, the screen cutout sub-rect, and
/// the rect where the source video is drawn.
///
/// Downstream the bezel PNG is drawn into [bezelRect] with `BoxFit.fill` and
/// the video into [videoRect]. Both [screenRect] and [videoRect] derive from
/// the same [bezelRect], so the video always lands inside the PNG's
/// transparent screen cutout — even when [resolveDeviceFrameLayout] stretches
/// the bezel (the PNG's hole stretches with it).
class DeviceFrameLayout {
  const DeviceFrameLayout({
    required this.canvasSize,
    required this.bezelRect,
    required this.screenRect,
    required this.videoRect,
    this.videoCornerRadius = 0,
  });

  final Size canvasSize;
  final Rect bezelRect;
  final Rect screenRect;
  final Rect videoRect;

  /// Corner radius (canvas px) to clip the video to, matching the device
  /// screen's rounded corners — so the recording's square corners don't show
  /// through the bezel PNG's transparent rounded cutout. 0 = no clip.
  final double videoCornerRadius;
}

/// Overscan applied to the video relative to the screen cutout, as a fraction
/// of the cutout's shorter side. The video is scaled to cover the cutout PLUS
/// this bleed on every side so its edges always tuck under the bezel — hiding
/// both aspect-mismatch letterbox gaps and sub-pixel seams at the bezel's inner
/// edge. Small enough that the cropped sliver is imperceptible.
const double _kScreenBleedFraction = 0.006;

/// Computes the device-frame layout. See [DeviceFrameLayout].
///
/// [adjustSize] == true stretches the bezel height so the screen cutout
/// matches the recording's aspect; the video then covers the cutout with only
/// the bleed cropped. Because the bezel PNG is later drawn into the (stretched)
/// [bezelRect] with `BoxFit.fill`, its transparent hole stretches with it and
/// stays aligned with the video.
///
/// [adjustSize] == false keeps the bezel's true proportions; the video is
/// cover-fit (aspect-preserved, centered) so it fully fills the native cutout,
/// cropping the longer axis when the recording's aspect differs.
///
/// In both modes the video COVERS the cutout (never letterboxes) plus a small
/// [_kScreenBleedFraction] overscan, so no canvas background can show through
/// the transparent screen cutout.
DeviceFrameLayout resolveDeviceFrameLayout({
  required DeviceFrameOrientationAsset asset,
  required Size recordingSize,
  required EdgeInsets padding,
  required OutputAspect aspect,
  required bool adjustSize,
}) {
  final bw = asset.bezelWidth.toDouble();
  final bh = asset.bezelHeight.toDouble();
  final sr = asset.screenRect;

  // Native screen cutout px and its aspect.
  final nativeScreenW = sr.width * bw;
  final nativeScreenH = sr.height * bh;
  final recAspect = recordingSize.height <= 0
      ? 1.0
      : recordingSize.width / recordingSize.height;

  // Content (bezel) size, stretched vertically when adjustSize so the
  // screen cutout takes on the recording's aspect. The bezel PNG is later
  // drawn into the resulting bezelRect, so its hole stretches in lock-step.
  Size contentSize = Size(bw, bh);
  if (adjustSize && nativeScreenW > 0 && recAspect > 0) {
    final desiredScreenH = nativeScreenW / recAspect;
    final scaleY = desiredScreenH / nativeScreenH;
    contentSize = Size(bw, bh * scaleY);
  }

  final resolved = OutputCanvasResolver.resolve(
    videoSize: contentSize,
    padding: padding,
    aspect: aspect,
  );
  final canvasSize = resolved.canvasSize;
  final bezelRect = resolved.videoRect;

  // Screen cutout = normalized sub-rect of the (possibly stretched) bezelRect.
  final screenRect = Rect.fromLTRB(
    bezelRect.left + sr.l * bezelRect.width,
    bezelRect.top + sr.t * bezelRect.height,
    bezelRect.left + sr.r * bezelRect.width,
    bezelRect.top + sr.b * bezelRect.height,
  );

  // Always COVER the screen cutout (never letterbox): scale the recording to
  // fill the cutout on both axes, plus a small bleed so the video's edges tuck
  // under the bezel. This guarantees no canvas background shows through the
  // transparent cutout — neither as an aspect-mismatch letterbox gap (when the
  // recording has no exact-match device frame, e.g. an iPhone model that isn't
  // in the catalog) nor as a sub-pixel seam at the bezel's inner edge. The
  // bezel PNG (drawn on top) hides the overscan. With adjustSize the cutout
  // aspect already matches the recording, so the only crop is the bleed.
  final Rect videoRect;
  if (recordingSize.width <= 0 || recordingSize.height <= 0) {
    videoRect = screenRect;
  } else {
    final bleed = screenRect.shortestSide * _kScreenBleedFraction;
    final target = screenRect.inflate(bleed);
    final scaleW = target.width / recordingSize.width;
    final scaleH = target.height / recordingSize.height;
    final s = scaleW > scaleH ? scaleW : scaleH; // cover: fill both axes
    final w = recordingSize.width * s;
    final h = recordingSize.height * s;
    videoRect = Rect.fromLTWH(
      target.center.dx - w / 2,
      target.center.dy - h / 2,
      w,
      h,
    );
  }

  // Screen corner radius at display scale (normalized to bezel width → px).
  // Apple screen corners are CONTINUOUS (squircle); the extracted inset
  // measures the squircle's extent, which is ~1.5× the equivalent CIRCULAR
  // radius. A plain ClipRRect uses a circular radius, so clip at the
  // circular-equivalent to avoid over-rounding. Clamp to half the video's
  // smaller side so a small letterboxed video can't over-round.
  const squircleExtentToCircular = 0.65;
  final maxRadius = 0.5 *
      (videoRect.width < videoRect.height ? videoRect.width : videoRect.height);
  final videoCornerRadius =
      (asset.screenCornerRadius * bezelRect.width * squircleExtentToCircular)
          .clamp(0.0, maxRadius);

  return DeviceFrameLayout(
    canvasSize: canvasSize,
    bezelRect: bezelRect,
    screenRect: screenRect,
    videoRect: videoRect,
    videoCornerRadius: videoCornerRadius,
  );
}
