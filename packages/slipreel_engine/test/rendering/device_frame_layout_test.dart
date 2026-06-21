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
    expect(layout.canvasSize.height, closeTo(2760, 1e-6));
    expect(layout.bezelRect, const Rect.fromLTWH(0, 0, 1350, 2760));
    // screen rect = normalized * bezel
    expect(layout.screenRect.left, closeTo(0.0533 * 1350, 1e-3));
    expect(layout.screenRect.width, closeTo((0.9467 - 0.0533) * 1350, 1e-3));
    // adjustSize: video fills the screen rect exactly
    expect(layout.videoRect, layout.screenRect);
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

  test('adjustSize=false letterboxes a wider recording inside the screen', () {
    // A 1:1 recording inside a portrait screen -> contained, centered.
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1000, 1000),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: false,
    );
    // bezel keeps native proportions
    expect(layout.canvasSize.height / layout.canvasSize.width, closeTo(2760 / 1350, 1e-6));
    // video is square, fit within the (taller) screen rect -> width-limited
    expect(layout.videoRect.width, closeTo(layout.screenRect.width, 1e-3));
    expect(layout.videoRect.height, closeTo(layout.screenRect.width, 1e-3));
    // centered vertically within the screen rect
    final screenCenterY = layout.screenRect.top + layout.screenRect.height / 2;
    final videoCenterY = layout.videoRect.top + layout.videoRect.height / 2;
    expect(videoCenterY, closeTo(screenCenterY, 1e-3));
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
    expect(layout.videoRect, layout.screenRect);
  });
}
