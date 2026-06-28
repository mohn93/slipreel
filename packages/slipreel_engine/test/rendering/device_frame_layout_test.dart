// packages/slipreel_engine/test/rendering/device_frame_layout_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';

// iPhone 16 Pro portrait: bezel 1350x2760, screen 1206x2622 inset.
const _asset = DeviceFrameOrientationAsset(
  asset: 'x.png',
  bezelWidth: 1350,
  bezelHeight: 2760,
  screenRect: DeviceScreenRect(l: 0.0533, t: 0.0250, r: 0.9467, b: 0.9750),
);

void main() {
  test('perfect match: no padding -> canvas == bezel, video fills screen rect', () {
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1206, 2622),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.canvasSize.width, closeTo(1350, 1e-6));
    // The declared recording (1206x2622) isn't perfectly consistent with the
    // normalized screenRect (0.8934*1350 = 1206.09, not 1206), so even a
    // "perfect match" picks up a ~0.2px vertical stretch. Sub-pixel, visually
    // irrelevant (the export canvas is even-rounded anyway) -> 0.5px tolerance.
    expect(layout.canvasSize.height, closeTo(2760, 0.5));
    expect(layout.bezelRect.left, closeTo(0, 1e-6));
    expect(layout.bezelRect.top, closeTo(0, 1e-6));
    expect(layout.bezelRect.width, closeTo(1350, 1e-6));
    expect(layout.bezelRect.height, closeTo(2760, 0.5));
    // screen rect = normalized * bezel
    expect(layout.screenRect.left, closeTo(0.0533 * 1350, 1e-3));
    expect(layout.screenRect.width, closeTo((0.9467 - 0.0533) * 1350, 1e-3));
    // Cover+bleed: the video fully COVERS the screen cutout (and overscans a
    // hair beyond it on every side so its edges tuck under the bezel), centered.
    expect(layout.videoRect.left, lessThanOrEqualTo(layout.screenRect.left));
    expect(layout.videoRect.top, lessThanOrEqualTo(layout.screenRect.top));
    expect(layout.videoRect.right, greaterThanOrEqualTo(layout.screenRect.right));
    expect(layout.videoRect.bottom, greaterThanOrEqualTo(layout.screenRect.bottom));
    // Centered on the cutout.
    expect(layout.videoRect.center.dx, closeTo(layout.screenRect.center.dx, 1e-3));
    expect(layout.videoRect.center.dy, closeTo(layout.screenRect.center.dy, 1e-3));
    // Aspect preserved (no distortion): videoRect keeps the recording's aspect.
    expect(layout.videoRect.width / layout.videoRect.height,
        closeTo(1206 / 2622, 1e-3));
  });

  test('padding grows the canvas; bezel is centered inside', () {
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1206, 2622),
      padding: const EdgeInsets.all(50),
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.canvasSize.width, closeTo(1450, 1e-6)); // 1350 + 100
    expect(layout.bezelRect.left, closeTo(50, 1e-6));
    expect(layout.bezelRect.top, closeTo(50, 1e-6));
  });

  test('adjustSize=false covers (no letterbox) a square recording in the screen', () {
    // A 1:1 recording inside a portrait screen -> COVERS the cutout (fills both
    // axes, cropping the longer one), centered. No background can show through.
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1000, 1000),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: false,
    );
    // bezel keeps native proportions
    expect(layout.canvasSize.height / layout.canvasSize.width, closeTo(2760 / 1350, 1e-6));
    // video is square (1:1 preserved) and fully covers the (taller) cutout:
    // height-limited, so width overflows past the cutout's sides.
    expect(layout.videoRect.width, closeTo(layout.videoRect.height, 1e-3));
    expect(layout.videoRect.height,
        greaterThanOrEqualTo(layout.screenRect.height));
    expect(layout.videoRect.width,
        greaterThanOrEqualTo(layout.screenRect.width));
    // centered within the screen rect (both axes)
    expect(layout.videoRect.center.dx, closeTo(layout.screenRect.center.dx, 1e-3));
    expect(layout.videoRect.center.dy, closeTo(layout.screenRect.center.dy, 1e-3));
  });

  test('adjustSize=true stretches bezel so the screen matches recording aspect', () {
    // Square recording -> screen sub-rect should become square.
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1000, 1000),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.screenRect.width, closeTo(layout.screenRect.height, 1e-2));
    // Cover+bleed: video covers the (now ~square) cutout, centered, square.
    expect(layout.videoRect.width, closeTo(layout.videoRect.height, 1.0));
    expect(layout.videoRect.width,
        greaterThanOrEqualTo(layout.screenRect.width));
    expect(layout.videoRect.height,
        greaterThanOrEqualTo(layout.screenRect.height));
    expect(layout.videoRect.center.dx, closeTo(layout.screenRect.center.dx, 1e-3));
    expect(layout.videoRect.center.dy, closeTo(layout.screenRect.center.dy, 1e-3));
  });

  test('videoCornerRadius scales screenCornerRadius by bezel display width', () {
    const roundedAsset = DeviceFrameOrientationAsset(
      asset: 'x.png',
      bezelWidth: 1350,
      bezelHeight: 2760,
      screenRect: DeviceScreenRect(l: 0.0533, t: 0.0250, r: 0.9467, b: 0.9750),
      screenCornerRadius: 0.18, // normalized to bezel width
    );
    final layout = resolveDeviceFrameLayout(
      asset: roundedAsset,
      recordingSize: const Size(1206, 2622),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.videoCornerRadius, greaterThan(0));
    // Clipped to the circular-equivalent, i.e. scaled BELOW the raw
    // squircle-extent inset (so a ClipRRect doesn't over-round).
    expect(layout.videoCornerRadius,
        lessThan(0.18 * layout.bezelRect.width));
  });
}
