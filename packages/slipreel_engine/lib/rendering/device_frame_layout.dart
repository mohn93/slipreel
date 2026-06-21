// packages/slipreel_engine/lib/rendering/device_frame_layout.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

/// Resolved geometry for drawing a device frame: the output canvas, the
/// rect where the bezel PNG is drawn, the screen cutout sub-rect, and
/// the rect where the source video is drawn.
class DeviceFrameLayout {
  const DeviceFrameLayout({
    required this.canvasSize,
    required this.bezelRect,
    required this.screenRect,
    required this.videoRect,
  });

  final Size canvasSize;
  final Rect bezelRect;
  final Rect screenRect;
  final Rect videoRect;
}

/// Computes the device-frame layout. See [DeviceFrameLayout].
///
/// [adjustSize] == true: the bezel keeps its native pixel dimensions, but the
/// screen cutout's height is recomputed so its aspect matches [recordingSize].
/// The video fills the adjusted screen rect exactly.
///
/// [adjustSize] == false: the bezel keeps its true proportions and the screen
/// cutout is the native normalized sub-rect. The video is letterbox-fitted
/// (aspect-preserved, centered) inside that native cutout.
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

  // The bezel is always used at its native pixel size as the "content" fed to
  // OutputCanvasResolver (which adds padding and enforces the output aspect).
  final resolved = OutputCanvasResolver.resolve(
    videoSize: Size(bw, bh),
    padding: padding,
    aspect: aspect,
  );
  final canvasSize = resolved.canvasSize;
  final bezelRect = resolved.videoRect;

  // Native screen cutout in bezel-relative pixels.
  final nativeScreenLeft = bezelRect.left + sr.l * bezelRect.width;
  final nativeScreenRight = bezelRect.left + sr.r * bezelRect.width;
  final nativeScreenWidth = nativeScreenRight - nativeScreenLeft;
  final nativeScreenTop = bezelRect.top + sr.t * bezelRect.height;
  final nativeScreenBottom = bezelRect.top + sr.b * bezelRect.height;
  final nativeScreenHeight = nativeScreenBottom - nativeScreenTop;

  final Rect screenRect;
  if (adjustSize &&
      nativeScreenWidth > 0 &&
      recordingSize.width > 0 &&
      recordingSize.height > 0) {
    // Recompute screen height so the cutout aspect matches the recording.
    // Left/right edges are fixed; center is preserved from the native cutout.
    final recAspect = recordingSize.width / recordingSize.height;
    final adjustedHeight = nativeScreenWidth / recAspect;
    final centerY = (nativeScreenTop + nativeScreenBottom) / 2;
    screenRect = Rect.fromLTRB(
      nativeScreenLeft,
      centerY - adjustedHeight / 2,
      nativeScreenRight,
      centerY + adjustedHeight / 2,
    );
  } else {
    screenRect = Rect.fromLTRB(
      nativeScreenLeft,
      nativeScreenTop,
      nativeScreenRight,
      nativeScreenBottom,
    );
  }

  final Rect videoRect;
  if (adjustSize) {
    // Aspect already matches the screen rect by construction.
    videoRect = screenRect;
  } else {
    // Letterbox-fit the recording inside the native screen cutout.
    if (recordingSize.width <= 0 || recordingSize.height <= 0) {
      videoRect = screenRect;
    } else {
      final scaleW = nativeScreenWidth / recordingSize.width;
      final scaleH = nativeScreenHeight / recordingSize.height;
      final s = scaleW < scaleH ? scaleW : scaleH;
      final w = recordingSize.width * s;
      final h = recordingSize.height * s;
      videoRect = Rect.fromLTWH(
        screenRect.left + (nativeScreenWidth - w) / 2,
        screenRect.top + (nativeScreenHeight - h) / 2,
        w,
        h,
      );
    }
  }

  return DeviceFrameLayout(
    canvasSize: canvasSize,
    bezelRect: bezelRect,
    screenRect: screenRect,
    videoRect: videoRect,
  );
}
