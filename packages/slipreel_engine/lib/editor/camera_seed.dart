import 'package:slipreel_engine/models/camera_region.dart';

/// Builds the first camera region for a freshly-opened recording that has a
/// `.camera.json` sidecar but no saved camera regions yet. Mirrors the
/// auto-zoom seeding pattern: the region spans the whole video and is placed
/// at the self-view's final normalized center so the editor bubble starts
/// where the user framed themselves. Saved immediately by the caller so a
/// later delete sticks.
///
/// [widthFraction] is the bubble width as a fraction of canvas width
/// (default 0.22). Height is derived at render time from the global shape,
/// so the seed only carries placement + width.
CameraRegion cameraSeedRegion({
  required Duration videoDuration,
  required double selfViewX,
  required double selfViewY,
  double widthFraction = 0.22,
}) {
  return CameraRegion(
    startTime: Duration.zero,
    duration: videoDuration <= Duration.zero
        ? const Duration(milliseconds: 1)
        : videoDuration,
    centerX: selfViewX,
    centerY: selfViewY,
    size: widthFraction,
  );
}
