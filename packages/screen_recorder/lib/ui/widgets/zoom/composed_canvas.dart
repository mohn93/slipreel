import 'package:flutter/painting.dart' show Rect, Size;

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

/// The composed-canvas geometry shared by the live render
/// ([PlaybackCanvas]), the scene-blur framing, and the manual placement
/// picker: how big the composited canvas is, where the video is drawn inside
/// it, and (when a device frame is active) the resolved device layout + asset.
///
/// This is the SINGLE source of truth for "where is the source video drawn,
/// and how big is the padded/bezel canvas" on the screen_recorder side, so the
/// picker box, the preview render, and the scene-blur clamp can never drift.
///
/// NOTE: the export side ([frame_compositor]) deliberately uses even-rounded
/// geometry and is intentionally NOT routed through this helper.
class ComposedCanvas {
  const ComposedCanvas({
    required this.canvasSize,
    required this.videoRect,
    this.deviceLayout,
    this.deviceAsset,
  });

  /// Total composited canvas size (wallpaper + padding + bezel + screen).
  final Size canvasSize;

  /// The video's rect within the composed canvas (canvas px).
  final Rect videoRect;

  /// Resolved device-frame layout, or null for a normal recording.
  final DeviceFrameLayout? deviceLayout;

  /// Resolved device-frame orientation asset (carries the bezel asset path),
  /// or null for a normal recording.
  final DeviceFrameOrientationAsset? deviceAsset;
}

/// Resolves the composed-canvas geometry the SAME way [PlaybackCanvas]
/// renders it: [OutputCanvasResolver] for the normal canvas, overridden by
/// [resolveDeviceFrameLayout] when a compatible device frame is active.
///
/// This mirrors the device chain (entryById → compatibility → color → portrait/
/// landscape asset → layout) byte-for-byte; changing it changes the render.
ComposedCanvas resolveComposedCanvas({
  required Size videoSize,
  required WindowFrame frame,
  required OutputAspect aspect,
  DeviceFrameCatalog? catalog,
}) {
  final resolved = OutputCanvasResolver.resolve(
    videoSize: videoSize,
    padding: frame.padding,
    aspect: aspect,
  );

  Size canvasSize = resolved.canvasSize;
  Rect videoRect = resolved.videoRect;
  DeviceFrameLayout? deviceLayout;
  DeviceFrameOrientationAsset? deviceAsset;

  final dfId = frame.deviceFrameId;
  if (dfId != null && catalog != null) {
    final entry = catalog.entryById(dfId);
    if (entry != null && deviceFrameCompatible(entry, videoSize)) {
      final color = entry.colorById(frame.deviceFrameColor ?? '') ??
          (entry.colors.isNotEmpty ? entry.colors.first : null);
      if (color != null) {
        deviceAsset =
            recordingIsPortrait(videoSize) ? color.portrait : color.landscape;
        deviceLayout = resolveDeviceFrameLayout(
          asset: deviceAsset,
          recordingSize: videoSize,
          padding: frame.padding,
          aspect: aspect,
          adjustSize: frame.deviceFrameAdjustSize,
        );
        canvasSize = deviceLayout.canvasSize;
        videoRect = deviceLayout.videoRect;
      }
    }
  }

  return ComposedCanvas(
    canvasSize: canvasSize,
    videoRect: videoRect,
    deviceLayout: deviceLayout,
    deviceAsset: deviceAsset,
  );
}
