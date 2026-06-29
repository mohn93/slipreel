import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  // A click-to-add (manual) zoom is created with the default ZoomRegion ramps
  // (500 ms enter / 500 ms exit) and a duration of kGhostZoomSpan. That should
  // leave an 1800 ms hold — matching the auto-detector's shape.
  test('manual click-to-add zoom holds 1800 ms with default ramps', () {
    final zoom = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 1920, 1080),
      startTime: Duration.zero,
      duration: kGhostZoomSpan,
      zoomLevel: 2,
      videoBounds: const Size(1920, 1080),
    );

    expect(kGhostZoomSpan, const Duration(milliseconds: 2800));
    expect(zoom.enterDuration, const Duration(milliseconds: 500));
    expect(zoom.exitDuration, const Duration(milliseconds: 500));
    final hold = zoom.duration - zoom.enterDuration - zoom.exitDuration;
    expect(hold, const Duration(milliseconds: 1800));
  });
}
